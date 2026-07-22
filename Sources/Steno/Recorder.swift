/*
 Captures the current microphone to one private 16 kHz mono PCM WAV.
 Exports MicrophoneRecorder, RecordingFailure, and one narrow backend test seam.
 Permission is requested only when recording starts, never during app launch.
 While capture is active, level exposes current microphone power from 0 through 1.
 Active capture owns its WAV; Stop transfers a valid WAV to the caller.
 Device loss and encode failure stop capture, delete audio, and report once.
*/
import AVFoundation
import Foundation

enum RecordingFailure: Error, Equatable, LocalizedError {
    case permissionDenied
    case noInputDevice
    case alreadyRecording
    case couldNotStart
    case notRecording
    case inputDeviceLost
    case encodingFailed
    case invalidRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is denied. Allow Steno to use the microphone in System Settings."
        case .noInputDevice:
            "No microphone is available. Connect or select an input device and try again."
        case .alreadyRecording:
            "Steno is already recording."
        case .couldNotStart:
            "Steno could not start microphone recording."
        case .notRecording:
            "Steno is not recording."
        case .inputDeviceLost:
            "The active microphone was disconnected or changed."
        case .encodingFailed:
            "Steno could not encode the microphone recording."
        case .invalidRecording:
            "Steno did not produce a valid microphone recording."
        }
    }
}

@MainActor
protocol AudioRecordingBackend: AnyObject {
    var onEncodingError: (() -> Void)? { get set }
    var level: Float { get }
    func record() -> Bool
    func stop()
}

func normalizedMicrophoneLevel(decibels: Float) -> Float {
    min(max((decibels + 60) / 60, 0), 1)
}

@MainActor
final class MicrophoneRecorder {
    typealias PermissionRequest = @MainActor () async -> Bool
    typealias InputIdentifier = @MainActor () -> String?
    typealias BackendFactory = @MainActor (URL, [String: Any]) throws -> AudioRecordingBackend

    var onFailure: ((RecordingFailure) -> Void)?
    private(set) var isRecording = false
    var level: Float {
        guard isRecording, let backend else { return 0 }
        return min(max(backend.level, 0), 1)
    }

    private let audioStore: TemporaryAudioStore
    private let requestPermission: PermissionRequest
    private let currentInputID: InputIdentifier
    private let makeBackend: BackendFactory
    private let startsDeviceMonitor: Bool
    private var backend: AudioRecordingBackend?
    private var activeURL: URL?
    private var activeInputID: String?
    private var deviceMonitor: Timer?

    convenience init(audioStore: TemporaryAudioStore = TemporaryAudioStore()) {
        self.init(
            audioStore: audioStore,
            requestPermission: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized:
                    return true
                case .notDetermined:
                    return await AVCaptureDevice.requestAccess(for: .audio)
                case .denied, .restricted:
                    return false
                @unknown default:
                    return false
                }
            },
            currentInputID: {
                AVCaptureDevice.default(for: .audio)?.uniqueID
            },
            makeBackend: { url, settings in
                try AVAudioRecordingBackend(url: url, settings: settings)
            }
        )
    }

    init(
        audioStore: TemporaryAudioStore,
        requestPermission: @escaping PermissionRequest,
        currentInputID: @escaping InputIdentifier,
        makeBackend: @escaping BackendFactory,
        startsDeviceMonitor: Bool = true
    ) {
        self.audioStore = audioStore
        self.requestPermission = requestPermission
        self.currentInputID = currentInputID
        self.makeBackend = makeBackend
        self.startsDeviceMonitor = startsDeviceMonitor
    }

    func start() async throws -> URL {
        guard !isRecording else { throw RecordingFailure.alreadyRecording }
        guard await requestPermission() else { throw RecordingFailure.permissionDenied }
        guard let inputID = currentInputID() else { throw RecordingFailure.noInputDevice }

        let url = audioStore.newRecordingURL()
        do {
            let backend = try makeBackend(url, Self.waveSettings)
            backend.onEncodingError = { [weak self] in
                self?.failActiveRecording(with: .encodingFailed)
            }
            guard backend.record() else {
                try? audioStore.deleteRecording(at: url)
                throw RecordingFailure.couldNotStart
            }

            self.backend = backend
            activeURL = url
            activeInputID = inputID
            isRecording = true
            startDeviceMonitorIfNeeded()
            return url
        } catch let failure as RecordingFailure {
            throw failure
        } catch {
            try? audioStore.deleteRecording(at: url)
            throw RecordingFailure.couldNotStart
        }
    }

    func stop() throws -> URL {
        guard isRecording, let backend, let url = activeURL else {
            throw RecordingFailure.notRecording
        }

        stopDeviceMonitor()
        backend.onEncodingError = nil
        backend.stop()
        clearActiveRecording()

        guard audioStore.owns(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0
        else {
            try? audioStore.deleteRecording(at: url)
            throw RecordingFailure.invalidRecording
        }

        return url
    }

    func reset() throws {
        stopDeviceMonitor()
        let url = activeURL
        backend?.onEncodingError = nil
        backend?.stop()
        clearActiveRecording()
        if let url {
            try audioStore.deleteRecording(at: url)
        }
    }

    func checkInputDevice() {
        guard isRecording, currentInputID() != activeInputID else { return }
        failActiveRecording(with: .inputDeviceLost)
    }

    private func startDeviceMonitorIfNeeded() {
        guard startsDeviceMonitor else { return }
        deviceMonitor = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(deviceMonitorFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func deviceMonitorFired() {
        checkInputDevice()
    }

    private func stopDeviceMonitor() {
        deviceMonitor?.invalidate()
        deviceMonitor = nil
    }

    private func failActiveRecording(with failure: RecordingFailure) {
        guard isRecording else { return }
        stopDeviceMonitor()
        let url = activeURL
        backend?.onEncodingError = nil
        backend?.stop()
        clearActiveRecording()
        if let url {
            try? audioStore.deleteRecording(at: url)
        }
        onFailure?(failure)
    }

    private func clearActiveRecording() {
        backend = nil
        activeURL = nil
        activeInputID = nil
        isRecording = false
    }

    private static let waveSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
}

@MainActor
private final class AVAudioRecordingBackend: NSObject, AudioRecordingBackend, AVAudioRecorderDelegate {
    var onEncodingError: (() -> Void)?
    var level: Float {
        recorder.updateMeters()
        return normalizedMicrophoneLevel(decibels: recorder.averagePower(forChannel: 0))
    }
    private let recorder: AVAudioRecorder

    init(url: URL, settings: [String: Any]) throws {
        recorder = try AVAudioRecorder(url: url, settings: settings)
        super.init()
        recorder.delegate = self
        recorder.isMeteringEnabled = true
    }

    func record() -> Bool {
        recorder.record()
    }

    func stop() {
        recorder.stop()
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            self?.onEncodingError?()
        }
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        if !flag {
            Task { @MainActor [weak self] in
                self?.onEncodingError?()
            }
        }
    }
}
