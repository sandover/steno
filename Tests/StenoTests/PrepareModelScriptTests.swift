/*
 Verifies the developer-only speech asset preparation contract.
 The test invokes the same check mode used by installation, without networking.
 It runs only when this Mac already has Steno's persistent model installed.
 A successful check proves the installed tree matches the tracked pinned manifest.
 Model-free clones skip this integration boundary and retain ordinary test access.
*/
import Foundation
import Testing

@Suite("PrepareModelScriptTests", .serialized)
struct PrepareModelScriptTests {
    @Test(.enabled(
        if: FileManager.default.fileExists(atPath: installedResources.path),
        "Run scripts/prepare-model.sh to install the pinned speech assets"
    ))
    func installedAssetsMatchPreparationContract() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/prepare-model.sh").path,
            "--check",
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let installedResources = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Containers/com.brandonharvey.steno", isDirectory: true)
    .appendingPathComponent(
        "Data/Library/Application Support/Steno/Resources",
        isDirectory: true
    )
