/*
 Runs approved private fixtures through the production TranscriptionEngine.
 The suite skips when STENO_BENCHMARK_DIR is absent or blank and never invents data.
 Fixture WAVs are copied because production inference deletes its owned input file.
 Speech gates use weighted and per-sample WER; silence permits fewer than five words.
 Every printed result binds scores to source, assets, options, and manifest digest.
*/
import Foundation
import Testing
@testable import Steno

@Suite("AccuracyBenchmarkTests", .serialized)
struct AccuracyBenchmarkTests {
    @Test(.enabled(
        if: configuredBenchmarkDirectory() != nil,
        "Set STENO_BENCHMARK_DIR to the approved private fixture directory"
    ))
    func approvedCorpusMeetsAccuracyGates() async throws {
        let fixtureDirectory = try #require(configuredBenchmarkDirectory())
        let manifest = try BenchmarkHarness.loadManifest(at: benchmarkManifestURL)
        try BenchmarkHarness.validateRequiredCorpus(manifest)
        let samples = try BenchmarkHarness.validate(
            manifest: manifest,
            fixtureDirectory: fixtureDirectory
        )
        #expect(!samples.isEmpty, "The approved benchmark manifest must contain samples")

        let assets = try await AssetPreflight.check(resourceRoot: productionResources)
        let engine = TranscriptionEngine(resourceRoot: productionResources)
        var speechScores: [WordErrorRateScore] = []
        var reports: [BenchmarkSampleReport] = []

        for sample in samples {
            let workingAudio = FileManager.default.temporaryDirectory
                .appendingPathComponent("Steno-Benchmark-\(UUID().uuidString).wav")
            try FileManager.default.copyItem(at: sample.audioURL, to: workingAudio)
            defer { try? FileManager.default.removeItem(at: workingAudio) }

            let hypothesis = try await engine.transcribe(audioURL: workingAudio)
            let reference = try String(contentsOf: sample.referenceURL, encoding: .utf8)
            if sample.metadata.kind.isSpeech {
                let score = WordErrorRate.score(reference: reference, hypothesis: hypothesis)
                speechScores.append(score)
                #expect(
                    score.rate <= 0.15,
                    "\(sample.metadata.id) WER \(score.rate) exceeds 0.15"
                )
                reports.append(BenchmarkSampleReport(
                    id: sample.metadata.id,
                    kind: sample.metadata.kind.rawValue,
                    wordErrorRate: score.rate,
                    normalizedWordCount: TranscriptNormalizer.words(in: hypothesis).count
                ))
            } else {
                let wordCount = TranscriptNormalizer.words(in: hypothesis).count
                #expect(
                    wordCount < 5,
                    "\(sample.metadata.id) invented \(wordCount) consecutive words"
                )
                reports.append(BenchmarkSampleReport(
                    id: sample.metadata.id,
                    kind: sample.metadata.kind.rawValue,
                    wordErrorRate: nil,
                    normalizedWordCount: wordCount
                ))
            }
        }

        let aggregate = WordErrorRate.aggregate(speechScores)
        #expect(!speechScores.isEmpty, "The approved benchmark needs speech samples")
        #expect(aggregate.rate <= 0.10, "Aggregate WER \(aggregate.rate) exceeds 0.10")

        let report = BenchmarkRunReport(
            appCommit: try repositoryRevision(),
            modelRevision: assets.manifest.model.revision,
            tokenizerRevision: assets.manifest.tokenizer.revision,
            decodingOptions: TranscriptionEngine.decodingSettings,
            manifestSHA256: try BenchmarkHarness.sha256(of: benchmarkManifestURL),
            aggregateWordErrorRate: aggregate.rate,
            samples: reports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}

private struct BenchmarkSampleReport: Codable {
    let id: String
    let kind: String
    let wordErrorRate: Double?
    let normalizedWordCount: Int
}

private struct BenchmarkRunReport: Codable {
    let appCommit: String
    let modelRevision: String
    let tokenizerRevision: String
    let decodingOptions: TranscriptionDecodingSettings
    let manifestSHA256: String
    let aggregateWordErrorRate: Double
    let samples: [BenchmarkSampleReport]
}

private func configuredBenchmarkDirectory() -> URL? {
    guard let value = ProcessInfo.processInfo.environment["STENO_BENCHMARK_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty else { return nil }
    return URL(fileURLWithPath: value, isDirectory: true)
}

private func repositoryRevision() throws -> String {
    let repository = benchmarkManifestURL.deletingLastPathComponent()
    let revision = try gitOutput(["-C", repository.path, "rev-parse", "HEAD"])
    let dirty = try gitOutput(["-C", repository.path, "status", "--porcelain"])
    guard dirty.isEmpty else {
        throw BenchmarkHarnessError.invalidSample("benchmark requires a clean repository")
    }
    return revision
}

private func gitOutput(_ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw BenchmarkHarnessError.invalidSample("cannot identify app commit")
    }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
