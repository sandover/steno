/*
 Serializes every WhisperKit inference run and owns model and WAV teardown.
 TranscriptionEngine accepts one narrow closure seam for deterministic tests.
 Production always uses the single pinned local model after asset preflight.
 A canceled caller cannot return text; teardown finishes before the next run.
 Actor reentrancy is controlled by an explicit FIFO gate around the whole run.
*/
import Foundation
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

actor TranscriptionEngine {
    typealias Inference = @Sendable (URL, AssetLocations) async throws -> String
    typealias Unload = @Sendable () async -> Void

    private let resourceRoot: URL
    private let injectedInference: Inference?
    private let injectedUnload: Unload?
    private var whisperKit: WhisperKit?
    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(resourceRoot: URL) {
        self.resourceRoot = resourceRoot
        injectedInference = nil
        injectedUnload = nil
    }

    init(
        resourceRoot: URL,
        inference: @escaping Inference,
        unload: @escaping Unload = {}
    ) {
        self.resourceRoot = resourceRoot
        injectedInference = inference
        injectedUnload = unload
    }

    func transcribe(audioURL: URL) async throws -> String {
        await acquire()
        var inferenceStarted = false

        do {
            try Task.checkCancellation()
            let assets = try await AssetPreflight.check(resourceRoot: resourceRoot)
            try Task.checkCancellation()

            let text: String
            if let injectedInference {
                inferenceStarted = true
                text = try await injectedInference(audioURL, assets)
            } else {
                let kit = try await makeWhisperKit(for: assets)
                whisperKit = kit
                inferenceStarted = true
                try await kit.loadModels()
                try Task.checkCancellation()
                let results = try await kit.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: Self.decodingOptions
                )
                text = results
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }

            try Task.checkCancellation()
            await teardown(audioURL: audioURL, inferenceStarted: inferenceStarted)
            release()
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
        if inferenceStarted {
            if let injectedUnload {
                await injectedUnload()
            } else if let whisperKit {
                await whisperKit.unloadModels()
                whisperKit.clearState()
            }
        }
        whisperKit = nil
        try? FileManager.default.removeItem(at: audioURL)
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
