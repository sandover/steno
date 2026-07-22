/*
 Owns Steno's five visible states and the complete Record, Stop, Copy, Reset loop.
 SessionModel is the sole source of visible transcript and session generation.
 Recorder and engine behavior enter through five direct closures for headless tests.
 Reset invalidates the generation before canceling work, so late text is ignored.
 Clipboard text is the only output and is available only for nonempty completion.
*/
import AppKit
import Foundation

@MainActor
final class SessionModel: ObservableObject {
    struct Failure: Equatable {
        let message: String
        let showsMicrophoneSettings: Bool
    }

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case complete(String)
        case error(Failure)
    }

    typealias StartRecording = @MainActor () async throws -> URL
    typealias StopRecording = @MainActor () throws -> URL
    typealias ResetRecording = @MainActor () throws -> Void
    typealias Transcribe = @Sendable (URL) async throws -> String
    typealias WriteClipboard = @MainActor (String) -> Void

    @Published private(set) var state: State = .idle
    @Published private(set) var didCopy = false

    var transcript: String {
        guard case let .complete(text) = state else { return "" }
        return text
    }

    var canCopy: Bool {
        !transcript.isEmpty
    }

    private let startRecording: StartRecording
    private let stopRecording: StopRecording
    private let resetRecording: ResetRecording
    private let transcribe: Transcribe
    private let writeClipboard: WriteClipboard
    private var generation = 0
    private var transcriptionTask: Task<String, Error>?

    init(
        recorder: MicrophoneRecorder,
        engine: TranscriptionEngine,
        pasteboard: NSPasteboard = .general
    ) {
        startRecording = { try await recorder.start() }
        stopRecording = { try recorder.stop() }
        resetRecording = { try recorder.reset() }
        transcribe = { try await engine.transcribe(audioURL: $0) }
        writeClipboard = { text in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        recorder.onFailure = { [weak self] failure in
            self?.recordingFailed(failure)
        }
    }

    init(
        initialState: State = .idle,
        startRecording: @escaping StartRecording,
        stopRecording: @escaping StopRecording,
        resetRecording: @escaping ResetRecording,
        transcribe: @escaping Transcribe,
        writeClipboard: @escaping WriteClipboard
    ) {
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.resetRecording = resetRecording
        self.transcribe = transcribe
        self.writeClipboard = writeClipboard
        state = initialState
    }

    func record() async {
        guard state == .idle else { return }
        generation += 1
        let recordingGeneration = generation
        state = .recording
        didCopy = false

        do {
            _ = try await startRecording()
            guard generation == recordingGeneration, state == .recording else {
                try? resetRecording()
                return
            }
        } catch {
            guard generation == recordingGeneration else { return }
            state = .error(Self.failure(for: error))
        }
    }

    func stop() async {
        guard state == .recording else { return }
        let audioURL: URL
        do {
            audioURL = try stopRecording()
        } catch {
            state = .error(Self.failure(for: error))
            return
        }

        let transcriptionGeneration = generation
        state = .transcribing
        let task = Task { try await transcribe(audioURL) }
        transcriptionTask = task

        do {
            let text = try await task.value
            guard generation == transcriptionGeneration, state == .transcribing else { return }
            transcriptionTask = nil
            state = .complete(text)
        } catch is CancellationError {
            if generation == transcriptionGeneration, state == .transcribing {
                transcriptionTask = nil
                state = .idle
            }
        } catch {
            guard generation == transcriptionGeneration, state == .transcribing else { return }
            transcriptionTask = nil
            state = .error(Self.failure(for: error))
        }
    }

    @discardableResult
    func copy() -> Bool {
        guard case let .complete(text) = state, !text.isEmpty else { return false }
        writeClipboard(text)
        didCopy = true
        let copiedGeneration = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.generation == copiedGeneration else { return }
            self.didCopy = false
        }
        return true
    }

    func reset() {
        let priorState = state
        generation += 1
        state = .idle
        didCopy = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if priorState == .recording {
            try? resetRecording()
        }
    }

    func recordingFailed(_ failure: RecordingFailure) {
        guard state == .recording else { return }
        generation += 1
        state = .error(Self.failure(for: failure))
    }

    private static func failure(for error: any Error) -> Failure {
        if let recording = error as? RecordingFailure {
            return Failure(
                message: recording.localizedDescription,
                showsMicrophoneSettings: recording == .permissionDenied
            )
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return Failure(message: description, showsMicrophoneSettings: false)
        }
        return Failure(
            message: "Steno could not transcribe this recording. Reset and try again.",
            showsMicrophoneSettings: false
        )
    }
}
