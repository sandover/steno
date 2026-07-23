/*
 Guards the repository boundary for Steno's externally prepared speech assets.
 Source control retains only the pinned manifest, never model or tokenizer payloads.
 SwiftPM must compile and test without inspecting a developer's local model state.
 Runtime and installation remain fail-closed against the persistent installed tree.
*/
import Foundation
import Testing

struct RepositoryAssetContractTests {
    @Test func sourceTreeContainsNoSpeechPayloads() throws {
        let resources = assetRepositoryRoot.appendingPathComponent(
            "Resources",
            isDirectory: true
        )

        #expect(
            !FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("Models").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("Tokenizers").path
            )
        )
    }

    @Test func packageManifestDoesNotRequirePreparedAssets() throws {
        let packageManifest = try String(
            contentsOf: assetRepositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        #expect(!packageManifest.contains("requireMaterializedAssets"))
        #expect(!packageManifest.contains("Resources/Models"))
        #expect(!packageManifest.contains("Resources/Tokenizers"))
    }
}
