/*
 Validates the approved private corpus against its committed public manifest.
 Digests, required scenarios, minimum durations, device, and PCM format fail closed.
 Speech and reference contents remain ignored and are never printed by this suite.
 STENO_BENCHMARK_DIR selects the private fixture directory explicitly.
 The production benchmark harness remains the sole digest and corpus validator.
*/
import AVFoundation
import Foundation
import Testing
@testable import Steno

@Suite("FixtureManifestTests", .serialized)
struct FixtureManifestTests {
    @Test(.enabled(
        if: fixtureDirectory != nil,
        "Set STENO_BENCHMARK_DIR to the private fixture directory"
    ))
    func approvedFixturesMatchManifestAndWaveFormat() throws {
        let directory = try #require(fixtureDirectory)
        let manifest = try BenchmarkHarness.loadManifest(at: benchmarkManifestURL)
        try BenchmarkHarness.validateRequiredCorpus(manifest)
        let samples = try BenchmarkHarness.validate(
            manifest: manifest,
            fixtureDirectory: directory
        )

        for sample in samples {
            let audio = try AVAudioFile(forReading: sample.audioURL)
            let format = audio.fileFormat
            let duration = Double(audio.length) / format.sampleRate
            #expect(format.sampleRate == 16_000)
            #expect(format.channelCount == 1)
            #expect(format.commonFormat == .pcmFormatInt16)
            #expect(abs(duration - sample.metadata.durationSeconds) <= 1)
        }

        let capture = try #require(manifest.capture)
        let summary = CorpusSummary(
            samples: samples.map {
                .init(id: $0.metadata.id, durationSeconds: $0.metadata.durationSeconds)
            },
            captureDevice: capture.device,
            manifestSHA256: try BenchmarkHarness.sha256(of: benchmarkManifestURL),
            consentConfirmed: capture.consentConfirmed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let scratch = benchmarkManifestURL.deletingLastPathComponent()
            .appendingPathComponent(".scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try encoder.encode(summary).write(
            to: scratch.appendingPathComponent("corpus-summary.json"),
            options: .atomic
        )
    }
}

private struct CorpusSummary: Codable {
    struct Sample: Codable {
        let id: String
        let durationSeconds: Double
    }

    let samples: [Sample]
    let captureDevice: String
    let manifestSHA256: String
    let consentConfirmed: Bool
}

private let fixtureDirectory = ProcessInfo.processInfo.environment["STENO_BENCHMARK_DIR"]
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
