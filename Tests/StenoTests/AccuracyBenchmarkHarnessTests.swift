/*
 Proves manifest parsing, fixture safety, and SHA-256 validation without real audio.
 The committed empty manifest establishes the contract before private capture.
 Temporary byte fixtures exercise valid metadata and deterministic digest failure.
 These tests never invoke WhisperKit or depend on STENO_BENCHMARK_DIR.
*/
import Foundation
import Testing
@testable import Steno

@Suite("AccuracyBenchmarkHarnessTests")
struct AccuracyBenchmarkHarnessTests {
    @Test func committedManifestDefinesAnEmptyVersionedCorpus() throws {
        let manifest = try BenchmarkHarness.loadManifest(at: benchmarkManifestURL)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.normalization == .current)
        #expect(manifest.samples.isEmpty)
    }

    @Test func acceptsSyntheticMetadataWhenBothDigestsMatch() throws {
        try withSyntheticFixture { directory, manifest in
            let samples = try BenchmarkHarness.validate(
                manifest: manifest,
                fixtureDirectory: directory
            )

            #expect(samples.count == 1)
            #expect(samples[0].metadata.id == "synthetic-speech")
        }
    }

    @Test func rejectsChangedFixtureBytes() throws {
        try withSyntheticFixture { directory, manifest in
            try Data("changed".utf8).write(
                to: directory.appendingPathComponent("synthetic.wav")
            )

            #expect(throws: BenchmarkHarnessError.digestMismatch("synthetic.wav")) {
                try BenchmarkHarness.validate(
                    manifest: manifest,
                    fixtureDirectory: directory
                )
            }
        }
    }

    @Test func rejectsNormalizationDrift() throws {
        try withSyntheticFixture { directory, manifest in
            let changed = BenchmarkManifest(
                schemaVersion: manifest.schemaVersion,
                normalization: BenchmarkNormalization(
                    version: 2,
                    unicode: "different",
                    caseFolding: "different",
                    nonAlphanumeric: "different",
                    whitespace: "different"
                ),
                samples: manifest.samples
            )

            #expect(throws: BenchmarkHarnessError.normalizationMismatch) {
                try BenchmarkHarness.validate(
                    manifest: changed,
                    fixtureDirectory: directory
                )
            }
        }
    }

    @Test func requiredCorpusRejectsMissingOrShortScenarios() {
        let incomplete = BenchmarkManifest(
            schemaVersion: 1,
            normalization: .current,
            samples: [metadata(id: "quiet", kind: .quietSpeech, duration: 299)]
        )

        #expect(throws: BenchmarkHarnessError.invalidCorpusShape) {
            try BenchmarkHarness.validateRequiredCorpus(incomplete)
        }
    }

    @Test func requiredCorpusAcceptsAllFixedScenarios() throws {
        let manifest = BenchmarkManifest(
            schemaVersion: 1,
            normalization: .current,
            samples: [
                metadata(id: "quiet", kind: .quietSpeech, duration: 300),
                metadata(id: "two-person", kind: .twoPerson, duration: 300),
                metadata(id: "room-noise", kind: .moderateRoomNoise, duration: 300),
                metadata(id: "silence", kind: .silence, duration: 10),
            ]
        )

        try BenchmarkHarness.validateRequiredCorpus(manifest)
    }
}

var benchmarkManifestURL: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("BenchmarkManifest.json")
}

private func withSyntheticFixture(
    _ operation: (URL, BenchmarkManifest) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoBenchmarkHarness-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let audioURL = directory.appendingPathComponent("synthetic.wav")
    let referenceURL = directory.appendingPathComponent("synthetic.txt")
    try Data("synthetic wave bytes".utf8).write(to: audioURL)
    try Data("a short reference".utf8).write(to: referenceURL)

    let manifest = BenchmarkManifest(
        schemaVersion: 1,
        normalization: .current,
        samples: [
            BenchmarkManifest.Sample(
                id: "synthetic-speech",
                kind: .quietSpeech,
                durationSeconds: 5,
                audioFile: audioURL.lastPathComponent,
                audioSHA256: try BenchmarkHarness.sha256(of: audioURL),
                referenceFile: referenceURL.lastPathComponent,
                referenceSHA256: try BenchmarkHarness.sha256(of: referenceURL)
            ),
        ]
    )
    try operation(directory, manifest)
}

private func metadata(
    id: String,
    kind: BenchmarkManifest.Sample.Kind,
    duration: Double
) -> BenchmarkManifest.Sample {
    BenchmarkManifest.Sample(
        id: id,
        kind: kind,
        durationSeconds: duration,
        audioFile: "\(id).wav",
        audioSHA256: String(repeating: "a", count: 64),
        referenceFile: "\(id).txt",
        referenceSHA256: String(repeating: "b", count: 64)
    )
}
