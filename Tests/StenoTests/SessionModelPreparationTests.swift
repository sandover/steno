/*
 Proves launch preparation gates Record without adding another session state.
 Success enables recording, failure remains actionable, and retry can recover.
 Concurrent prepare requests collapse to one engine operation on the main actor.
 Tests inject preparation and recording closures; no model or microphone is used.
*/
import Foundation
import Testing
@testable import Steno

@Suite("SessionModelPreparationTests", .serialized)
@MainActor
struct SessionModelPreparationTests {
    @Test func recordIsUnavailableUntilPreparationSucceeds() async {
        let probe = PreparationGate()
        let context = PreparationSessionContext(probe: probe)

        await context.model.record()
        #expect(context.startCount == 0)

        await context.model.prepare()
        #expect(context.model.preparationState == .ready)
        await context.model.record()
        #expect(context.startCount == 1)
    }

    @Test func failureIsVisibleAndRetryCanRecover() async {
        let probe = PreparationGate(failuresBeforeSuccess: 1)
        let context = PreparationSessionContext(probe: probe)

        await context.model.prepare()
        guard case let .failed(failure) = context.model.preparationState else {
            Issue.record("Expected failed preparation")
            return
        }
        #expect(!failure.message.isEmpty)
        #expect(!context.model.canRecord)

        await context.model.prepare()
        #expect(context.model.preparationState == .ready)
        #expect(await probe.attemptCount == 2)
    }

    @Test func concurrentRequestsPrepareExactlyOnce() async {
        let probe = PreparationGate(waitsForRelease: true)
        let context = PreparationSessionContext(probe: probe)
        let first = Task { await context.model.prepare() }
        await probe.waitUntilStarted()

        let second = Task { await context.model.prepare() }
        await Task.yield()
        #expect(await probe.attemptCount == 1)

        await probe.release()
        await first.value
        await second.value
        #expect(context.model.preparationState == .ready)
        #expect(await probe.attemptCount == 1)
    }
}

private enum PreparationTestError: Error {
    case failed
}

private actor PreparationGate {
    private let waitsForRelease: Bool
    private var failuresRemaining: Int
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var attemptCount = 0

    init(failuresBeforeSuccess: Int = 0, waitsForRelease: Bool = false) {
        failuresRemaining = failuresBeforeSuccess
        self.waitsForRelease = waitsForRelease
    }

    func run() async throws {
        attemptCount += 1
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        if waitsForRelease {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw PreparationTestError.failed
        }
    }

    func waitUntilStarted() async {
        guard attemptCount == 0 else { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class PreparationSessionContext {
    private(set) var startCount = 0
    private(set) var model: SessionModel!

    init(probe: PreparationGate) {
        model = SessionModel(
            initialPreparationState: .preparing,
            prepareEngine: { try await probe.run() },
            startRecording: {
                self.startCount += 1
                return URL(fileURLWithPath: "/tmp/preparation-test.wav")
            },
            stopRecording: { URL(fileURLWithPath: "/tmp/preparation-test.wav") },
            resetRecording: {},
            transcribe: { _ in "" },
            writeClipboard: { _ in }
        )
    }
}
