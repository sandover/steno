/*
 Prepares and retains one WhisperKit model, then serializes every inference run.
 TranscriptionEngine accepts narrow asset and inference seams for deterministic tests.
 Production loads the pinned local model at launch and reuses it until app exit.
 A canceled caller cannot return text; WAV teardown finishes before the next run.
 Actor reentrancy is controlled by an explicit FIFO gate around the whole run.
*/
import Foundation
import OSLog
import WhisperKit

struct TranscriptionDecodingSettings: Codable, Equatable, Sendable {
    let task: String
    let language: String?
    let usePrefillPrompt: Bool
    let detectLanguage: Bool
    let skipSpecialTokens: Bool
    let concurrentWorkerCount: Int
    let chunkingStrategy: String
}

enum TranscriptionEngineError: LocalizedError {
    case notPrepared

    var errorDescription: String? {
        "Steno's speech model is not ready."
    }
}

actor TranscriptionEngine {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? AppIdentity.name,
        category: "engine"
    )

    typealias Preparation = @Sendable (AssetLocations) async throws -> Void
    typealias Inference = @Sendable (URL, AssetLocations) async throws -> String
    typealias Unload = @Sendable () async -> Void
    typealias AssetSeeder = @Sendable (URL) async throws -> Void
    typealias AssetLoader = @Sendable (URL) async throws -> AssetLocations

    private let resourceRoot: URL
    private let assetSeeder: AssetSeeder
    private let assetLoader: AssetLoader
    private let injectedPreparation: Preparation?
    private let injectedInference: Inference?
    private let injectedUnload: Unload?
    private var whisperKit: WhisperKit?
    private var prepared = false
    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(resourceRoot: URL) {
        self.resourceRoot = resourceRoot
        assetSeeder = { root in
            try await BundledAssets.seedIfNeeded(destination: root)
        }
        assetLoader = AssetPreflight.check
        injectedPreparation = nil
        injectedInference = nil
        injectedUnload = nil
    }

    init(
        resourceRoot: URL,
        assetSeeder: @escaping AssetSeeder = { _ in },
        assetLoader: @escaping AssetLoader = AssetPreflight.check,
        preparation: @escaping Preparation = { _ in },
        inference: @escaping Inference,
        unload: @escaping Unload = {}
    ) {
        self.resourceRoot = resourceRoot
        self.assetSeeder = assetSeeder
        self.assetLoader = assetLoader
        injectedPreparation = preparation
        injectedInference = inference
        injectedUnload = unload
    }

    func prepare() async throws {
        await acquire()
        guard !prepared else {
            release()
            return
        }
        var preparationStarted = false

        do {
            try Task.checkCancellation()
            try await assetSeeder(resourceRoot)
            try Task.checkCancellation()
            let assets = try await assetLoader(resourceRoot)
            try Task.checkCancellation()

            preparationStarted = true
            if let injectedPreparation {
                try await injectedPreparation(assets)
            } else {
                let kit = try await makeWhisperKit(for: assets)
                whisperKit = kit
                try await kit.loadModels()
            }
            try Task.checkCancellation()
            prepared = true
            release()
        } catch {
            prepared = false
            await unload(operationStarted: preparationStarted)
            release()
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        await acquire()
        var inferenceStarted = false

        do {
            try Task.checkCancellation()
            let assets = try await assetLoader(resourceRoot)
            try Task.checkCancellation()
            guard prepared else { throw TranscriptionEngineError.notPrepared }

            let text: String
            if let injectedInference {
                inferenceStarted = true
                Self.logger.notice("Injected inference started")
                text = try await injectedInference(audioURL, assets)
                Self.logger.notice("Injected inference returned")
            } else {
                guard let kit = whisperKit else { throw TranscriptionEngineError.notPrepared }
                inferenceStarted = true
                Self.logger.notice("Whisper inference started")
                let results = try await kit.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: Self.decodingOptions
                )
                text = results
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                Self.logger.notice("Whisper inference returned")
            }

            try Task.checkCancellation()
            Self.logger.notice("Engine teardown started")
            await teardown(audioURL: audioURL, inferenceStarted: inferenceStarted)
            Self.logger.notice("Engine teardown finished")
            release()
            Self.logger.notice("Engine returning transcript")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await teardown(audioURL: audioURL, inferenceStarted: inferenceStarted)
            release()
            throw error
        }
    }

    static func configuration(for assets: AssetLocations) -> WhisperKitConfig {
        WhisperKitConfig(
            modelFolder: assets.modelFolder.path,
            tokenizerFolder: assets.tokenizerFolder,
            verbose: false,
            prewarm: false,
            load: false,
            download: false,
            useBackgroundDownloadSession: false
        )
    }

    private func makeWhisperKit(for assets: AssetLocations) async throws -> WhisperKit {
        try await WhisperKit(Self.configuration(for: assets))
    }

    private func teardown(audioURL: URL, inferenceStarted: Bool) async {
        if inferenceStarted, injectedInference == nil {
            whisperKit?.clearState()
        }
        try? FileManager.default.removeItem(at: audioURL)
    }

    private func unload(operationStarted: Bool) async {
        if operationStarted {
            if let injectedUnload {
                await injectedUnload()
            } else if let whisperKit {
                await whisperKit.unloadModels()
                whisperKit.clearState()
            }
        }
        whisperKit = nil
        prepared = false
    }

    private func acquire() async {
        guard active else {
            active = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            active = false
            return
        }
        waiters.removeFirst().resume()
    }

    static let decodingSettings = TranscriptionDecodingSettings(
        task: "transcribe",
        language: nil,
        usePrefillPrompt: true,
        detectLanguage: true,
        skipSpecialTokens: true,
        concurrentWorkerCount: 1,
        chunkingStrategy: "vad"
    )

    private static var decodingOptions: DecodingOptions { DecodingOptions(
        task: .transcribe,
        language: decodingSettings.language,
        usePrefillPrompt: decodingSettings.usePrefillPrompt,
        detectLanguage: decodingSettings.detectLanguage,
        skipSpecialTokens: decodingSettings.skipSpecialTokens,
        concurrentWorkerCount: decodingSettings.concurrentWorkerCount,
        chunkingStrategy: .vad
    ) }
}
