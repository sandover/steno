/*
 Proves model preparation uses pinned local assets and the engine's FIFO gate.
 Success retains one ready model; failure unloads partial model state.
 A transcription queued during preparation cannot overlap specialization.
 Tests inject asset loading and expensive model operations independently.
*/
import Foundation
import Testing
@testable import Steno

@Suite("TranscriptionEnginePreparationTests", .serialized)
struct TranscriptionEnginePreparationTests {
    @Test func successfulPreparationUsesLocalAssetsAndRetainsModel() async throws {
        let probe = EnginePreparationProbe()
        let engine = preparationEngine(probe: probe)

        try await engine.prepare()

        #expect(await probe.events == ["prepare-start", "prepare-finish"])
        #expect(await probe.modelRevision == "97a5bf9bbc74c7d9c12c755d04dea59e672e3808")
    }

    @Test func preparationSeedsBundledAssetsBeforeLoading() async throws {
        let probe = EnginePreparationProbe()
        let engine = TranscriptionEngine(
            resourceRoot: assetRepositoryRoot,
            assetSeeder: { _ in await probe.seed() },
            assetLoader: { _ in
                await probe.load()
                return try testAssetLocations()
            },
            preparation: { assets in try await probe.prepare(assets) },
            inference: { audio, assets in await probe.transcribe(audio, assets: assets) }
        )

        try await engine.prepare()

        #expect(await probe.events == ["seed", "load", "prepare-start", "prepare-finish"])
    }

    @Test func failedPreparationStillUnloads() async {
        let probe = EnginePreparationProbe(preparationFails: true)
        let engine = preparationEngine(probe: probe)

        do {
            try await engine.prepare()
            Issue.record("Expected preparation failure")
        } catch is EnginePreparationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await probe.events == ["prepare-start", "prepare-finish", "unload"])
    }

    @Test func transcriptionWaitsForPreparationAndReusesPreparedModel() async throws {
        let audio = try temporaryAudio()
        let probe = EnginePreparationProbe(waitsForPreparationRelease: true)
        let engine = preparationEngine(probe: probe)
        let preparation = Task { try await engine.prepare() }
        await probe.waitUntilPreparationStarted()

        let transcription = Task { try await engine.transcribe(audioURL: audio) }
        await Task.yield()
        #expect(await probe.startedCount == 1)

        await probe.releasePreparation()
        try await preparation.value
        let text = try await transcription.value

        #expect(text == "prepared transcript")
        #expect(await probe.maxActive == 1)
        #expect(await probe.events == [
            "prepare-start", "prepare-finish",
            "transcribe-start", "transcribe-finish",
        ])
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }
}

private enum EnginePreparationError: Error {
    case failed
}

private actor EnginePreparationProbe {
    private let preparationFails: Bool
    private let waitsForPreparationRelease: Bool
    private var preparationRelease: CheckedContinuation<Void, Never>?
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var active = 0
    private(set) var events: [String] = []
    private(set) var modelRevision: String?
    private(set) var startedCount = 0
    private(set) var maxActive = 0

    init(preparationFails: Bool = false, waitsForPreparationRelease: Bool = false) {
        self.preparationFails = preparationFails
        self.waitsForPreparationRelease = waitsForPreparationRelease
    }

    func prepare(_ assets: AssetLocations) async throws {
        begin("prepare")
        modelRevision = assets.manifest.model.revision
        preparationWaiters.forEach { $0.resume() }
        preparationWaiters.removeAll()
        if waitsForPreparationRelease {
            await withCheckedContinuation { preparationRelease = $0 }
        }
        finish("prepare")
        if preparationFails { throw EnginePreparationError.failed }
    }

    func seed() {
        events.append("seed")
    }

    func load() {
        events.append("load")
    }

    func transcribe(_ audio: URL, assets: AssetLocations) -> String {
        _ = audio
        _ = assets
        begin("transcribe")
        finish("transcribe")
        return "prepared transcript"
    }

    func unload() {
        events.append("unload")
    }

    func waitUntilPreparationStarted() async {
        guard startedCount == 0 else { return }
        await withCheckedContinuation { preparationWaiters.append($0) }
    }

    func releasePreparation() {
        preparationRelease?.resume()
        preparationRelease = nil
    }

    private func begin(_ operation: String) {
        active += 1
        startedCount += 1
        maxActive = max(maxActive, active)
        events.append("\(operation)-start")
    }

    private func finish(_ operation: String) {
        active -= 1
        events.append("\(operation)-finish")
    }
}

private func preparationEngine(probe: EnginePreparationProbe) -> TranscriptionEngine {
    TranscriptionEngine(
        resourceRoot: assetRepositoryRoot,
        assetLoader: { _ in try testAssetLocations() },
        preparation: { assets in try await probe.prepare(assets) },
        inference: { audio, assets in await probe.transcribe(audio, assets: assets) },
        unload: { await probe.unload() }
    )
}
