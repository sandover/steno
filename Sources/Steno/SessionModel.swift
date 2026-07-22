/*
 Owns Steno's five visible states and the complete Record, Stop, Copy, Reset loop.
 SessionModel is the sole source of visible transcript and session generation.
 Recorder and engine behavior enter through direct closures for headless tests.
 Orthogonal model readiness keeps Record unavailable during launch preparation.
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

    enum PreparationState: Equatable {
        case preparing
        case ready
        case failed(Failure)
    }

    typealias PrepareEngine = @Sendable () async throws -> Void
    typealias StartRecording = @MainActor () async throws -> URL
    typealias StopRecording = @MainActor () throws -> URL
    typealias ResetRecording = @MainActor () throws -> Void
    typealias ReadRecordingLevel = @MainActor () -> Float
    typealias Transcribe = @Sendable (URL) async throws -> String
    typealias WriteClipboard = @MainActor (String) -> Void

    @Published private(set) var state: State = .idle
    @Published private(set) var preparationState: PreparationState
    @Published private(set) var didCopy = false

    var transcript: String {
        guard case let .complete(text) = state else { return "" }
        return text
    }

    var canCopy: Bool {
        !transcript.isEmpty
    }

    var canRecord: Bool {
        state == .idle && preparationState == .ready
    }

    var recordingLevel: Float {
        state == .recording ? readRecordingLevel() : 0
    }

    private let prepareEngine: PrepareEngine
    private let startRecording: StartRecording
    private let stopRecording: StopRecording
    private let resetRecording: ResetRecording
    private let readRecordingLevel: ReadRecordingLevel
    private let transcribe: Transcribe
    private let writeClipboard: WriteClipboard
    private var generation = 0
    private var isPreparing = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        recorder: MicrophoneRecorder,
        engine: TranscriptionEngine,
        pasteboard: NSPasteboard = .general
    ) {
        prepareEngine = { try await engine.prepare() }
        startRecording = { try await recorder.start() }
        stopRecording = { try recorder.stop() }
        resetRecording = { try recorder.reset() }
        readRecordingLevel = { recorder.level }
        transcribe = { try await engine.transcribe(audioURL: $0) }
        writeClipboard = { text in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        preparationState = .preparing
        recorder.onFailure = { [weak self] failure in
            self?.recordingFailed(failure)
        }
    }

    init(
        initialState: State = .idle,
        initialPreparationState: PreparationState = .ready,
        prepareEngine: @escaping PrepareEngine = {},
        startRecording: @escaping StartRecording,
        stopRecording: @escaping StopRecording,
        resetRecording: @escaping ResetRecording,
        readRecordingLevel: @escaping ReadRecordingLevel = { 0 },
        transcribe: @escaping Transcribe,
        writeClipboard: @escaping WriteClipboard
    ) {
        self.prepareEngine = prepareEngine
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.resetRecording = resetRecording
        self.readRecordingLevel = readRecordingLevel
        self.transcribe = transcribe
        self.writeClipboard = writeClipboard
        state = initialState
        preparationState = initialPreparationState
    }

    func prepare() async {
        guard preparationState != .ready, !isPreparing else { return }
        isPreparing = true
        preparationState = .preparing
        do {
            try await prepareEngine()
            preparationState = .ready
        } catch {
            preparationState = .failed(Self.failure(for: error))
        }
        isPreparing = false
    }

    func record() async {
        guard canRecord else { return }
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

    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard state == .recording else { return nil }
        let audioURL: URL
        do {
            audioURL = try stopRecording()
        } catch {
            state = .error(Self.failure(for: error))
            return nil
        }

        let transcriptionGeneration = generation
        state = .transcribing
        let transcribe = self.transcribe
        let task = Task { @MainActor [weak self] in
            do {
                let text = try await transcribe(audioURL)
                guard let self,
                      self.generation == transcriptionGeneration,
                      self.state == .transcribing
                else { return }
                self.transcriptionTask = nil
                self.state = .complete(text)
            } catch is CancellationError {
                guard let self,
                      self.generation == transcriptionGeneration,
                      self.state == .transcribing
                else { return }
                self.transcriptionTask = nil
                self.state = .idle
            } catch {
                guard let self,
                      self.generation == transcriptionGeneration,
                      self.state == .transcribing
                else { return }
                self.transcriptionTask = nil
                self.state = .error(Self.failure(for: error))
            }
        }
        transcriptionTask = task
        return task
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
