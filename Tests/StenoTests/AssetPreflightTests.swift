/*
 Proves offline asset validation fails before WhisperKit can use remote fallback.
 The suite mutates temporary copies of the manifest rather than production assets.
 One integration check loads the committed tokenizer snapshot from local disk.
 Missing files, empty files, and unresolved Git-LFS pointers stay distinguishable.
 The production resource root is derived from this test file, not process cwd.
*/
import Foundation
import Testing
@testable import Steno

@Suite("AssetPreflightTests", .serialized)
struct AssetPreflightTests {
    @Test func acceptsPinnedLocalAssets() async throws {
        let locations = try await AssetPreflight.check(resourceRoot: productionResources)

        #expect(locations.manifest.schemaVersion == 1)
        #expect(locations.manifest.model.revision.count == 40)
        #expect(locations.manifest.tokenizer.revision.count == 40)
    }

    @Test func rejectsMissingModelComponent() async throws {
        let root = try temporaryFixture()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(
                "Models/openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc"
            )
        )

        await #expect(throws: AssetPreflightError.missing(
            "Models/openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc"
        )) {
            try await AssetPreflight.check(resourceRoot: root)
        }
    }

    @Test func rejectsUnresolvedGitLFSPointer() async throws {
        let root = try temporaryFixture()
        let tokenizer = root.appendingPathComponent(
            "Tokenizers/openai-whisper-large-v3/tokenizer.json"
        )
        try Data("version https://git-lfs.github.com/spec/v1\n".utf8).write(to: tokenizer)

        await #expect(throws: AssetPreflightError.unresolvedGitLFS(
            "Tokenizers/openai-whisper-large-v3/tokenizer.json"
        )) {
            try await AssetPreflight.check(resourceRoot: root)
        }
    }

    private var productionResources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private func temporaryFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoAssetTest-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.copyItem(
            at: productionResources.appendingPathComponent("AssetManifest.json"),
            to: root.appendingPathComponent("AssetManifest.json")
        )

        let model = root.appendingPathComponent(
            "Models/openai_whisper-large-v3-v20240930_turbo_632MB",
            isDirectory: true
        )
        for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            let directory = model.appendingPathComponent(component, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: directory.appendingPathComponent("model.mil"))
        }

        let tokenizer = root.appendingPathComponent(
            "Tokenizers/openai-whisper-large-v3",
            isDirectory: true
        )
        try manager.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        for file in [
            "added_tokens.json", "config.json", "generation_config.json", "merges.txt",
            "normalizer.json", "preprocessor_config.json", "special_tokens_map.json",
            "tokenizer.json", "tokenizer_config.json", "vocab.json",
        ] {
            try Data("fixture".utf8).write(to: tokenizer.appendingPathComponent(file))
        }
        return root
    }
}
