/*
 Proves every SessionModel state transition and user-visible side effect.
 Recorder and clipboard seams stay on the main actor; transcription uses one actor.
 Tests cover empty completion, actionable failures, Reset, and late-result rejection.
 No test requests hardware permission, opens UI, or writes a persistent transcript.
*/
import Foundation
import Testing
@testable import Steno

@Suite("SessionModelTests", .serialized)
@MainActor
struct SessionModelTests {
    @Test func emptyCompletionCannotCopy() async {
        let context = SessionTestContext(transcript: "")
        await context.model.record()

        await context.model.stop()?.value

        #expect(context.model.state == .complete(""))
        #expect(!context.model.canCopy)
        #expect(!context.model.copy())
        #expect(context.clipboard.isEmpty)
    }

    @Test func permissionDenialIsActionableAndCreatesNoRecording() async {
        let context = SessionTestContext(startError: RecordingFailure.permissionDenied)

        await context.model.record()

        guard case let .error(failure) = context.model.state else {
            Issue.record("Expected permission error state")
            return
        }
        #expect(failure.showsMicrophoneSettings)
        #expect(failure.message.contains("System Settings"))
        #expect(context.startCount == 1)
        #expect(context.stopCount == 0)
    }

    @Test func recorderAndTranscriptionFailuresUseErrorState() async {
        let stopFailure = SessionTestContext(stopError: RecordingFailure.invalidRecording)
        await stopFailure.model.record()
        await stopFailure.model.stop()?.value
        guard case .error = stopFailure.model.state else {
            Issue.record("Expected recorder error state")
            return
        }

        let transcriptionFailure = SessionTestContext(
            transcriptionError: SessionTestError.transcription
        )
        await transcriptionFailure.model.record()
        await transcriptionFailure.model.stop()?.value
        guard case .error = transcriptionFailure.model.state else {
            Issue.record("Expected transcription error state")
            return
        }
    }

    @Test func asynchronousRecorderFailureBecomesError() async {
        let context = SessionTestContext()
        await context.model.record()

        context.model.recordingFailed(.inputDeviceLost)

        guard case let .error(failure) = context.model.state else {
            Issue.record("Expected device-loss error state")
            return
        }
        #expect(failure.message.contains("microphone"))
        #expect(!failure.showsMicrophoneSettings)
    }

    @Test func resetFromRecordingStopsAndClearsImmediately() async {
        let context = SessionTestContext()
        await context.model.record()

        context.model.reset()

        #expect(context.model.state == .idle)
        #expect(context.resetCount == 1)
        #expect(context.model.transcript.isEmpty)
    }

    @Test func resetFromCompleteClearsWithoutTouchingRecorder() async {
        let context = SessionTestContext(transcript: "finished")
        await context.model.record()
        await context.model.stop()?.value

        context.model.reset()

        #expect(context.model.state == .idle)
        #expect(context.resetCount == 0)
        #expect(context.model.transcript.isEmpty)
    }

    @Test func resetDuringTranscriptionRejectsLateResult() async throws {
        let gate = SessionTranscriptionGate(result: "late text", waitsForRelease: true)
        let context = SessionTestContext(gate: gate)
        await context.model.record()
        let stopTask = context.model.stop()
        await gate.waitUntilStarted()

        context.model.reset()
        #expect(context.model.state == .idle)
        await gate.release()
        await stopTask?.value

        #expect(context.model.state == .idle)
        #expect(context.model.transcript.isEmpty)
    }

    @Test func resetFromIdleAndErrorReturnsToIdle() async {
        let idle = SessionTestContext()
        idle.model.reset()
        #expect(idle.model.state == .idle)

        let failed = SessionTestContext(startError: RecordingFailure.noInputDevice)
        await failed.model.record()
        failed.model.reset()
        #expect(failed.model.state == .idle)
    }
}

enum SessionTestError: Error {
    case transcription
}

@MainActor
final class SessionTestContext {
    let gate: SessionTranscriptionGate
    private(set) var model: SessionModel!
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resetCount = 0
    private(set) var clipboard: [String] = []
    private let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoSessionTest-\(UUID().uuidString).wav")
    private let startError: (any Error)?
    private let stopError: (any Error)?

    init(
        transcript: String = "transcript",
        startError: (any Error)? = nil,
        stopError: (any Error)? = nil,
        transcriptionError: (any Error)? = nil,
        gate: SessionTranscriptionGate? = nil
    ) {
        self.startError = startError
        self.stopError = stopError
        let gate = gate ?? SessionTranscriptionGate(
            result: transcript,
            error: transcriptionError
        )
        self.gate = gate
        model = SessionModel(
            startRecording: {
                self.startCount += 1
                if let startError = self.startError { throw startError }
                return self.audioURL
            },
            stopRecording: {
                self.stopCount += 1
                if let stopError = self.stopError { throw stopError }
                return self.audioURL
            },
            resetRecording: {
                self.resetCount += 1
            },
            transcribe: { url in try await gate.transcribe(url) },
            writeClipboard: { text in self.clipboard.append(text) }
        )
    }
}

actor SessionTranscriptionGate {
    private let result: String
    private let error: (any Error)?
    private let waitsForRelease: Bool
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var started = false

    init(
        result: String,
        error: (any Error)? = nil,
        waitsForRelease: Bool = false
    ) {
        self.result = result
        self.error = error
        self.waitsForRelease = waitsForRelease
    }

    func transcribe(_ url: URL) async throws -> String {
        _ = url
        started = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        if waitsForRelease {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        if let error { throw error }
        return result
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
