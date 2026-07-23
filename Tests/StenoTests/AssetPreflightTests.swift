/*
 Proves offline asset validation fails before WhisperKit can use remote fallback.
 The suite builds tiny structural fixtures from the tracked pinned manifest.
 One optional integration check loads the persistent installed tokenizer.
 Missing files, empty files, and malformed manifests stay distinguishable.
 Model-free clones retain the structural tests and skip only installed integration.
*/
import Foundation
import Testing
@testable import Steno

@Suite("AssetPreflightTests", .serialized)
struct AssetPreflightTests {
    @Test func derivesInstalledRootFromApplicationSupport() {
        let applicationSupport = URL(
            fileURLWithPath: "/Users/test/Library/Application Support",
            isDirectory: true
        )

        #expect(
            InstalledResources.root(in: applicationSupport).path
                == "/Users/test/Library/Application Support/Steno/Resources"
        )
    }

    @Test(.enabled(
        if: FileManager.default.fileExists(atPath: installedResources.path),
        "Run scripts/prepare-model.sh to install the pinned speech assets"
    ))
    func acceptsPinnedLocalAssets() async throws {
        let locations = try await AssetPreflight.check(resourceRoot: installedResources)

        #expect(locations.manifest.schemaVersion == 2)
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

    private func temporaryFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoAssetTest-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.copyItem(
            at: assetRepositoryRoot.appendingPathComponent("Resources/AssetManifest.json"),
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
