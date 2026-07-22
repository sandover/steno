/*
 Defines the fixed transcript normalization, word-error-rate, and corpus manifest.
 The same pure scoring code serves synthetic unit tests and private real fixtures.
 BenchmarkHarness validates every fixture digest before audio reaches the engine.
 Private audio and references stay outside the repository; only metadata is public.
 An empty sample list is valid until the consented corpus is captured and approved.
*/
import CryptoKit
import Foundation

struct BenchmarkNormalization: Codable, Equatable, Sendable {
    let version: Int
    let unicode: String
    let caseFolding: String
    let nonAlphanumeric: String
    let whitespace: String

    static let current = BenchmarkNormalization(
        version: 1,
        unicode: "precomposed canonical mapping",
        caseFolding: "Unicode lowercase",
        nonAlphanumeric: "replace each run with one space",
        whitespace: "trim and collapse to one ASCII space"
    )
}

enum TranscriptNormalizer {
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.lowercased()
        var scalars = String.UnicodeScalarView()
        var needsSpace = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSpace, !scalars.isEmpty {
                    scalars.append(" ")
                }
                scalars.append(scalar)
                needsSpace = false
            } else {
                needsSpace = !scalars.isEmpty
            }
        }
        return String(scalars)
    }

    static func words(in text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }
}

struct WordErrorRateScore: Equatable, Sendable {
    let editCount: Int
    let referenceWordCount: Int

    var rate: Double {
        guard referenceWordCount > 0 else { return editCount == 0 ? 0 : 1 }
        return Double(editCount) / Double(referenceWordCount)
    }
}

enum WordErrorRate {
    static func score(reference: String, hypothesis: String) -> WordErrorRateScore {
        score(
            referenceWords: TranscriptNormalizer.words(in: reference),
            hypothesisWords: TranscriptNormalizer.words(in: hypothesis)
        )
    }

    static func aggregate(_ scores: [WordErrorRateScore]) -> WordErrorRateScore {
        WordErrorRateScore(
            editCount: scores.reduce(0) { $0 + $1.editCount },
            referenceWordCount: scores.reduce(0) { $0 + $1.referenceWordCount }
        )
    }

    private static func score(
        referenceWords: [String],
        hypothesisWords: [String]
    ) -> WordErrorRateScore {
        var previous = Array(0...hypothesisWords.count)

        for (referenceIndex, referenceWord) in referenceWords.enumerated() {
            var current = Array(repeating: 0, count: hypothesisWords.count + 1)
            current[0] = referenceIndex + 1
            for (hypothesisIndex, hypothesisWord) in hypothesisWords.enumerated() {
                let substitution = previous[hypothesisIndex]
                    + (referenceWord == hypothesisWord ? 0 : 1)
                let deletion = previous[hypothesisIndex + 1] + 1
                let insertion = current[hypothesisIndex] + 1
                current[hypothesisIndex + 1] = min(substitution, deletion, insertion)
            }
            previous = current
        }

        return WordErrorRateScore(
            editCount: previous[hypothesisWords.count],
            referenceWordCount: referenceWords.count
        )
    }
}

struct BenchmarkManifest: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable {
            case quietSpeech = "quiet-speech"
            case twoPerson = "two-person"
            case moderateRoomNoise = "moderate-room-noise"
            case silence

            var isSpeech: Bool { self != .silence }
        }

        let id: String
        let kind: Kind
        let durationSeconds: Double
        let audioFile: String
        let audioSHA256: String
        let referenceFile: String
        let referenceSHA256: String
    }

    let schemaVersion: Int
    let normalization: BenchmarkNormalization
    let samples: [Sample]
}

struct ValidatedBenchmarkSample: Sendable {
    let metadata: BenchmarkManifest.Sample
    let audioURL: URL
    let referenceURL: URL
}

enum BenchmarkHarnessError: Error, Equatable {
    case malformedManifest
    case unsupportedSchema(Int)
    case normalizationMismatch
    case invalidSample(String)
    case invalidCorpusShape
    case missingFixture(String)
    case digestMismatch(String)
}

enum BenchmarkHarness {
    static func loadManifest(at url: URL) throws -> BenchmarkManifest {
        do {
            return try JSONDecoder().decode(BenchmarkManifest.self, from: Data(contentsOf: url))
        } catch {
            throw BenchmarkHarnessError.malformedManifest
        }
    }

    static func validate(
        manifest: BenchmarkManifest,
        fixtureDirectory: URL
    ) throws -> [ValidatedBenchmarkSample] {
        guard manifest.schemaVersion == 1 else {
            throw BenchmarkHarnessError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.normalization == .current else {
            throw BenchmarkHarnessError.normalizationMismatch
        }

        var seenIDs = Set<String>()
        return try manifest.samples.map { sample in
            guard validID(sample.id), seenIDs.insert(sample.id).inserted,
                  sample.durationSeconds > 0,
                  sample.kind != .silence || sample.durationSeconds >= 10,
                  validFileName(sample.audioFile), sample.audioFile.hasSuffix(".wav"),
                  validFileName(sample.referenceFile),
                  validDigest(sample.audioSHA256), validDigest(sample.referenceSHA256) else {
                throw BenchmarkHarnessError.invalidSample(sample.id)
            }

            let audioURL = fixtureDirectory.appendingPathComponent(sample.audioFile)
            let referenceURL = fixtureDirectory.appendingPathComponent(sample.referenceFile)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw BenchmarkHarnessError.missingFixture(sample.audioFile)
            }
            guard FileManager.default.fileExists(atPath: referenceURL.path) else {
                throw BenchmarkHarnessError.missingFixture(sample.referenceFile)
            }
            guard try sha256(of: audioURL) == sample.audioSHA256 else {
                throw BenchmarkHarnessError.digestMismatch(sample.audioFile)
            }
            guard try sha256(of: referenceURL) == sample.referenceSHA256 else {
                throw BenchmarkHarnessError.digestMismatch(sample.referenceFile)
            }
            if sample.kind.isSpeech {
                let reference = try String(contentsOf: referenceURL, encoding: .utf8)
                guard !TranscriptNormalizer.words(in: reference).isEmpty else {
                    throw BenchmarkHarnessError.invalidSample(sample.id)
                }
            }
            return ValidatedBenchmarkSample(
                metadata: sample,
                audioURL: audioURL,
                referenceURL: referenceURL
            )
        }
    }

    static func validateRequiredCorpus(_ manifest: BenchmarkManifest) throws {
        let requiredSpeechKinds: [BenchmarkManifest.Sample.Kind] = [
            .quietSpeech,
            .twoPerson,
            .moderateRoomNoise,
        ]
        guard requiredSpeechKinds.allSatisfy({ kind in
            manifest.samples.contains { $0.kind == kind && $0.durationSeconds >= 300 }
        }), manifest.samples.contains(where: {
            $0.kind == .silence && $0.durationSeconds >= 10
        }) else {
            throw BenchmarkHarnessError.invalidCorpusShape
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy {
            (97...122).contains($0.value)
                || (48...57).contains($0.value)
                || $0.value == 45
        }
    }

    private static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && URL(fileURLWithPath: name).lastPathComponent == name
    }

    private static func validDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
