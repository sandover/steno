/*
 Proves one engine run returns text only after inference and WAV teardown.
 Tests inject only the expensive inference boundary; asset preflight remains real.
 Success, cancellation, local preflight failure, and inference failure delete WAVs.
 The configuration test locks WhisperKit to explicit local, non-downloading paths.
*/
import Foundation
import Testing
@testable import Steno

@Suite("TranscriptionEngineTests", .serialized)
struct TranscriptionEngineTests {
    @Test func successfulRunReturnsTextAndDeletesWaveWithoutUnloading() async throws {
        let audio = try temporaryAudio()
        let probe = EngineProbe(result: "  useful transcript  ")
        let engine = testEngine(probe: probe)
        try await engine.prepare()

        let text = try await engine.transcribe(audioURL: audio)

        #expect(text == "useful transcript")
        #expect(await probe.events == ["start", "finish"])
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func inferenceFailureKeepsPreparedModelAndDeletesWave() async throws {
        let audio = try temporaryAudio()
        let probe = EngineProbe(error: TestInferenceError.failed)
        let engine = testEngine(probe: probe)
        try await engine.prepare()

        do {
            _ = try await engine.transcribe(audioURL: audio)
            Issue.record("Expected transcription to fail")
        } catch let error as TestInferenceError {
            #expect(error == .failed)
        }

        #expect(await probe.events == ["start", "finish"])
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func cancellationDiscardsLateTextAfterInferenceExits() async throws {
        let audio = try temporaryAudio()
        let probe = EngineProbe(result: "late text", waitsForRelease: true)
        let engine = testEngine(probe: probe)
        try await engine.prepare()
        let task = Task { try await engine.transcribe(audioURL: audio) }
        await probe.waitUntilStarted(count: 1)

        task.cancel()
        await probe.releaseOne()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to discard late text")
        } catch is CancellationError {
            // Expected.
        }
        #expect(await probe.events == ["start", "finish"])
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func missingAssetsFailBeforeInferenceAndDeleteWave() async throws {
        let audio = try temporaryAudio()
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoMissingAssets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let probe = EngineProbe(result: "must not run")
        let engine = TranscriptionEngine(
            resourceRoot: emptyRoot,
            inference: { url, locations in try await probe.run(url, locations: locations) },
            unload: { await probe.unload() }
        )

        do {
            _ = try await engine.transcribe(audioURL: audio)
            Issue.record("Expected local asset preflight to fail")
        } catch is AssetPreflightError {
            // Expected.
        }

        #expect(await probe.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func configurationCannotDownloadOrLoadEarly() async throws {
        let assets = try await AssetPreflight.check(resourceRoot: productionResources)
        let configuration = TranscriptionEngine.configuration(for: assets)

        #expect(configuration.modelFolder == assets.modelFolder.path)
        #expect(configuration.tokenizerFolder == assets.tokenizerFolder)
        #expect(configuration.load == false)
        #expect(configuration.download == false)
        #expect(configuration.useBackgroundDownloadSession == false)
    }
}

private enum TestInferenceError: Error, Equatable {
    case failed
}

func testEngine(probe: EngineProbe) -> TranscriptionEngine {
    TranscriptionEngine(
        resourceRoot: productionResources,
        inference: { url, locations in try await probe.run(url, locations: locations) },
        unload: { await probe.unload() }
    )
}

var productionResources: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)
}

func temporaryAudio() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoEngineTest-\(UUID().uuidString).wav")
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
    return url
}
