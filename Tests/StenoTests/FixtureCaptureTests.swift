/*
 Captures the next unfinished private benchmark WAV through the real recorder.
 STENO_CAPTURE_FIXTURES=1 is the explicit consented action that enables recording.
 Repeated runs advance through the four fixed roles without overwriting any file.
 Captures use the production 16 kHz mono PCM path and never enter the app UI.
 Audio remains ignored under Fixtures; scratch metadata contains no speech content.
*/
import AVFoundation
import Foundation
import Testing
@testable import Steno

@Suite("FixtureCaptureTests", .serialized)
@MainActor
struct FixtureCaptureTests {
    @Test(.enabled(
        if: captureEnabled,
        "Set STENO_CAPTURE_FIXTURES=1 only when intentionally capturing private audio"
    ))
    func captureOrVerifyFixtures() async throws {
        let manager = FileManager.default
        let fixtureDirectory = repositoryRoot.appendingPathComponent("Fixtures", isDirectory: true)
        try manager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        let requested = try nextScenario(in: fixtureDirectory)
        guard let requested else {
            for scenario in CaptureScenario.allCases {
                try validateWave(
                    fixtureDirectory.appendingPathComponent(scenario.audioFile),
                    minimumDuration: scenario.minimumDuration
                )
            }
            return
        }

        let destination = fixtureDirectory.appendingPathComponent(requested.audioFile)
        #expect(
            !manager.fileExists(atPath: destination.path),
            "Refusing to overwrite private fixture \(requested.audioFile)"
        )
        guard !manager.fileExists(atPath: destination.path) else { return }

        let device = try #require(AVCaptureDevice.default(for: .audio))
        let store = TemporaryAudioStore(directory: fixtureDirectory)
        let recorder = MicrophoneRecorder(audioStore: store)
        print("Next fixture: \(requested.rawValue). Recording begins in ten seconds.")
        for second in stride(from: 10, through: 1, by: -1) {
            print("\(second)…")
            try await Task.sleep(for: .seconds(1))
        }
        print("Recording \(requested.rawValue) for \(requested.captureDuration) seconds with \(device.localizedName)")
        let temporaryURL = try await recorder.start()
        defer { try? store.deleteRecording(at: temporaryURL) }
        try await Task.sleep(for: .seconds(requested.captureDuration))
        let completedURL = try recorder.stop()

        let audio = try AVAudioFile(forReading: completedURL)
        let format = audio.fileFormat
        let duration = Double(audio.length) / format.sampleRate
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatInt16)
        #expect(duration >= requested.minimumDuration)
        try manager.moveItem(at: completedURL, to: destination)
        let reference = fixtureDirectory.appendingPathComponent(requested.referenceFile)
        if !manager.fileExists(atPath: reference.path) {
            try Data().write(to: reference)
        }

        let metadata = CaptureMetadata(
            scenario: requested.rawValue,
            durationSeconds: duration,
            device: device.localizedName,
            sampleRateHz: Int(format.sampleRate),
            channels: Int(format.channelCount),
            bitDepth: 16,
            encoding: "signed-little-endian-pcm",
            consentConfirmed: true
        )
        let scratch = repositoryRoot.appendingPathComponent(".scratch", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(
            to: scratch.appendingPathComponent("capture-\(requested.rawValue).json")
        )
    }
}

private enum CaptureScenario: String, CaseIterable {
    case quietSpeech = "quiet-speech"
    case twoPerson = "two-person"
    case moderateRoomNoise = "moderate-room-noise"
    case silence

    var captureDuration: Int { self == .silence ? 11 : 301 }
    var minimumDuration: Double { self == .silence ? 10 : 300 }
    var audioFile: String { "\(rawValue).wav" }
    var referenceFile: String { "\(rawValue).txt" }
}

private struct CaptureMetadata: Codable {
    let scenario: String
    let durationSeconds: Double
    let device: String
    let sampleRateHz: Int
    let channels: Int
    let bitDepth: Int
    let encoding: String
    let consentConfirmed: Bool
}

private let captureEnabled = ProcessInfo.processInfo.environment["STENO_CAPTURE_FIXTURES"] == "1"
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func nextScenario(in directory: URL) throws -> CaptureScenario? {
    for scenario in CaptureScenario.allCases {
        let audio = directory.appendingPathComponent(scenario.audioFile)
        guard FileManager.default.fileExists(atPath: audio.path) else { return scenario }
        let reference = directory.appendingPathComponent(scenario.referenceFile)
        guard FileManager.default.fileExists(atPath: reference.path) else {
            throw BenchmarkHarnessError.missingFixture(scenario.referenceFile)
        }
        if scenario != .silence {
            let text = try String(contentsOf: reference, encoding: .utf8)
            guard !TranscriptNormalizer.words(in: text).isEmpty else {
                throw BenchmarkHarnessError.invalidSample(
                    "Correct Fixtures/\(scenario.referenceFile) before the next capture"
                )
            }
        }
    }
    return nil
}

private func validateWave(_ url: URL, minimumDuration: Double) throws {
    let audio = try AVAudioFile(forReading: url)
    let format = audio.fileFormat
    let duration = Double(audio.length) / format.sampleRate
    #expect(format.sampleRate == 16_000)
    #expect(format.channelCount == 1)
    #expect(format.commonFormat == .pcmFormatInt16)
    #expect(duration >= minimumDuration)
}
