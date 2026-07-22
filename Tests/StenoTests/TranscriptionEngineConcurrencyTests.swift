/*
 Proves the engine's FIFO gate covers inference, unload, and file deletion.
 Actor reentrancy must never permit two WhisperKit-style operations to overlap.
 A canceled waiter waits for prior teardown, skips inference, and deletes its WAV.
 These tests coordinate through an actor and use no timing-based sleeps.
*/
import Foundation
import Testing
@testable import Steno

@Suite("TranscriptionEngineConcurrencyTests", .serialized)
struct TranscriptionEngineConcurrencyTests {
    @Test func secondRunWaitsForFirstTeardown() async throws {
        let firstAudio = try temporaryAudio()
        let secondAudio = try temporaryAudio()
        let probe = EngineProbe(result: "done", waitsForRelease: true)
        let engine = testEngine(probe: probe)

        let first = Task { try await engine.transcribe(audioURL: firstAudio) }
        await probe.waitUntilStarted(count: 1)
        let second = Task { try await engine.transcribe(audioURL: secondAudio) }
        await Task.yield()

        #expect(await probe.startedCount == 1)
        await probe.releaseOne()
        _ = try await first.value
        await probe.waitUntilStarted(count: 2)
        #expect(await probe.maxActive == 1)

        await probe.releaseOne()
        _ = try await second.value
        #expect(await probe.maxActive == 1)
        #expect(await probe.events == [
            "start", "finish", "unload",
            "start", "finish", "unload",
        ])
        #expect(!FileManager.default.fileExists(atPath: firstAudio.path))
        #expect(!FileManager.default.fileExists(atPath: secondAudio.path))
    }

    @Test func canceledWaiterNeverStartsOrUnloadsActiveInference() async throws {
        let firstAudio = try temporaryAudio()
        let canceledAudio = try temporaryAudio()
        let probe = EngineProbe(result: "done", waitsForRelease: true)
        let engine = testEngine(probe: probe)

        let first = Task { try await engine.transcribe(audioURL: firstAudio) }
        await probe.waitUntilStarted(count: 1)
        let canceled = Task { try await engine.transcribe(audioURL: canceledAudio) }
        canceled.cancel()
        await Task.yield()

        #expect(await probe.startedCount == 1)
        #expect(await probe.unloadCount == 0)
        await probe.releaseOne()
        _ = try await first.value

        do {
            _ = try await canceled.value
            Issue.record("Expected waiting transcription to remain canceled")
        } catch is CancellationError {
            // Expected.
        }
        #expect(await probe.startedCount == 1)
        #expect(await probe.unloadCount == 1)
        #expect(!FileManager.default.fileExists(atPath: canceledAudio.path))
    }
}

actor EngineProbe {
    private let result: String
    private let error: (any Error)?
    private let waitsForRelease: Bool
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var events: [String] = []
    private(set) var startedCount = 0
    private(set) var unloadCount = 0
    private(set) var maxActive = 0
    private var active = 0

    init(
        result: String = "",
        error: (any Error)? = nil,
        waitsForRelease: Bool = false
    ) {
        self.result = result
        self.error = error
        self.waitsForRelease = waitsForRelease
    }

    func run(_ audioURL: URL, locations: AssetLocations) async throws -> String {
        _ = audioURL
        _ = locations
        active += 1
        startedCount += 1
        maxActive = max(maxActive, active)
        events.append("start")
        resumeStartWaiters()

        if waitsForRelease {
            await withCheckedContinuation { continuation in
                releases.append(continuation)
            }
        }

        active -= 1
        events.append("finish")
        if let error { throw error }
        return result
    }

    func unload() {
        unloadCount += 1
        events.append("unload")
    }

    func releaseOne() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }

    func waitUntilStarted(count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    private func resumeStartWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in startWaiters {
            if startedCount >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        startWaiters = pending
    }
}
