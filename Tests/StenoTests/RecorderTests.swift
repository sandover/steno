/*
 Exercises microphone recording behavior through one narrow backend seam.
 The production recorder still owns permission, input selection, WAV settings,
 active-file cleanup, device-loss detection, and encode-failure handling.
 Tests use real temporary files but never request microphone permission.
*/
import AVFoundation
import Foundation
import Testing
@testable import Steno

@Suite("RecorderTests")
@MainActor
struct RecorderTests {
    @Test func startCreatesOneCorrectlyConfiguredWaveRecording() async throws {
        try await withRecorderTest { context in
            let url = try await context.recorder.start()

            #expect(context.factory.makeCount == 1)
            #expect(context.backend.recordCount == 1)
            #expect(context.recorder.isRecording)
            #expect(context.store.owns(url))
            #expect(context.factory.settings?[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
            #expect(context.factory.settings?[AVSampleRateKey] as? Double == 16_000)
            #expect(context.factory.settings?[AVNumberOfChannelsKey] as? Int == 1)
            #expect(context.factory.settings?[AVLinearPCMBitDepthKey] as? Int == 16)
            #expect(context.factory.settings?[AVLinearPCMIsFloatKey] as? Bool == false)
        }
    }

    @Test func stopClosesAndReturnsAValidWaveFile() async throws {
        try await withRecorderTest { context in
            let startedURL = try await context.recorder.start()

            let completedURL = try context.recorder.stop()

            #expect(completedURL == startedURL)
            #expect(context.backend.stopCount == 1)
            #expect(!context.recorder.isRecording)
            #expect(FileManager.default.fileExists(atPath: completedURL.path))
            #expect((try Data(contentsOf: completedURL)).isEmpty == false)
        }
    }

    @Test func levelReadsTheActiveBackendAndStaysNormalized() async throws {
        try await withRecorderTest { context in
            #expect(context.recorder.level == 0)
            _ = try await context.recorder.start()

            context.backend.level = 0.42
            #expect(context.recorder.level == 0.42)

            context.backend.level = -1
            #expect(context.recorder.level == 0)

            context.backend.level = 2
            #expect(context.recorder.level == 1)

            _ = try context.recorder.stop()
            #expect(context.recorder.level == 0)
        }
    }

    @Test func decibelPowerIgnoresRoomNoiseAndMapsSpeechRange() {
        #expect(normalizedMicrophoneLevel(decibels: -160) == 0)
        #expect(normalizedMicrophoneLevel(decibels: -40) == 0)
        #expect(normalizedMicrophoneLevel(decibels: -25) == 0.5)
        #expect(normalizedMicrophoneLevel(decibels: -10) == 1)
        #expect(normalizedMicrophoneLevel(decibels: 0) == 1)
        #expect(normalizedMicrophoneLevel(decibels: 4) == 1)
    }

    @Test func resetStopsAndDeletesAnActiveRecording() async throws {
        try await withRecorderTest { context in
            let url = try await context.recorder.start()

            try context.recorder.reset()

            #expect(context.backend.stopCount == 1)
            #expect(!context.recorder.isRecording)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func deniedPermissionCreatesNoRecorder() async throws {
        try await withRecorderTest(permissionGranted: false) { context in
            do {
                _ = try await context.recorder.start()
                Issue.record("Expected microphone permission denial")
            } catch let failure as RecordingFailure {
                #expect(failure == .permissionDenied)
            }

            #expect(context.factory.makeCount == 0)
            #expect(!context.recorder.isRecording)
        }
    }

    @Test func unavailableInputCreatesNoRecorder() async throws {
        try await withRecorderTest(inputID: nil) { context in
            do {
                _ = try await context.recorder.start()
                Issue.record("Expected an unavailable input failure")
            } catch let failure as RecordingFailure {
                #expect(failure == .noInputDevice)
            }

            #expect(context.factory.makeCount == 0)
        }
    }

    @Test func failedBackendStartDeletesItsWavePath() async throws {
        try await withRecorderTest(recordSucceeds: false) { context in
            do {
                _ = try await context.recorder.start()
                Issue.record("Expected the recorder start to fail")
            } catch let failure as RecordingFailure {
                #expect(failure == .couldNotStart)
            }

            let url = try #require(context.factory.url)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func changedOrLostInputStopsDeletesAndReportsFailure() async throws {
        try await withRecorderTest { context in
            let url = try await context.recorder.start()
            context.input.id = "different-input"

            context.recorder.checkInputDevice()

            #expect(context.failures == [.inputDeviceLost])
            #expect(context.backend.stopCount == 1)
            #expect(!context.recorder.isRecording)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func encodeErrorStopsDeletesAndReportsFailure() async throws {
        try await withRecorderTest { context in
            let url = try await context.recorder.start()

            context.backend.reportEncodingError()

            #expect(context.failures == [.encodingFailed])
            #expect(context.backend.stopCount == 1)
            #expect(!context.recorder.isRecording)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}

@MainActor
private final class FakeRecordingBackend: AudioRecordingBackend {
    var onEncodingError: (() -> Void)?
    var level: Float = 0
    let recordSucceeds: Bool
    let url: URL
    private(set) var recordCount = 0
    private(set) var stopCount = 0

    init(url: URL, recordSucceeds: Bool) {
        self.url = url
        self.recordSucceeds = recordSucceeds
    }

    func record() -> Bool {
        recordCount += 1
        guard recordSucceeds else { return false }
        try? Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        return true
    }

    func stop() {
        stopCount += 1
    }

    func reportEncodingError() {
        onEncodingError?()
    }
}

@MainActor
private final class BackendFactory {
    let recordSucceeds: Bool
    private(set) var makeCount = 0
    private(set) var url: URL?
    private(set) var settings: [String: Any]?
    private(set) var backend: FakeRecordingBackend?

    init(recordSucceeds: Bool) {
        self.recordSucceeds = recordSucceeds
    }

    func make(url: URL, settings: [String: Any]) -> AudioRecordingBackend {
        makeCount += 1
        self.url = url
        self.settings = settings
        let backend = FakeRecordingBackend(url: url, recordSucceeds: recordSucceeds)
        self.backend = backend
        return backend
    }
}

@MainActor
private final class MutableInput {
    var id: String?

    init(id: String?) {
        self.id = id
    }
}

@MainActor
private struct RecorderTestContext {
    let recorder: MicrophoneRecorder
    let store: TemporaryAudioStore
    let factory: BackendFactory
    let input: MutableInput
    var backend: FakeRecordingBackend { factory.backend! }
    var failures: [RecordingFailure] { failureBox.values }
    fileprivate let failureBox: FailureBox
}

@MainActor
private final class FailureBox {
    var values: [RecordingFailure] = []
}

@MainActor
private func withRecorderTest(
    permissionGranted: Bool = true,
    inputID: String? = "built-in-microphone",
    recordSucceeds: Bool = true,
    operation: (RecorderTestContext) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoRecorderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = TemporaryAudioStore(directory: directory)
    let input = MutableInput(id: inputID)
    let factory = BackendFactory(recordSucceeds: recordSucceeds)
    let failures = FailureBox()
    let recorder = MicrophoneRecorder(
        audioStore: store,
        requestPermission: { permissionGranted },
        currentInputID: { input.id },
        makeBackend: { url, settings in factory.make(url: url, settings: settings) },
        startsDeviceMonitor: false
    )
    recorder.onFailure = { failures.values.append($0) }

    // The fake writes through its initialized URL. Match it to the path selected
    // by production by creating the file in the factory when the paths differ.
    try await operation(
        RecorderTestContext(
            recorder: recorder,
            store: store,
            factory: factory,
            input: input,
            failureBox: failures
        )
    )
}
