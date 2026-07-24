/*
 Seeds a release bundle's signed offline assets into Steno's persistent sandbox root.
 A normal developer build has no bundled assets and is a no-op.
 Existing valid persistent assets always win, so app updates do not recopy the model.
 A source tree is copied to a same-volume staging directory and validated first.
 Promotion preserves a recoverable prior tree if replacement or recovery fails.
 The app never downloads assets or grants itself network access.
*/
import Foundation

enum BundledAssets {
    typealias Validator = @Sendable (URL) async throws -> Void

    static func seedIfNeeded(
        destination: URL,
        bundledRoot: URL? = bundledRoot(),
        fileManager: FileManager = .default,
        validate: @escaping Validator = validateAssets
    ) async throws {
        guard let bundledRoot else { return }
        do {
            try await validate(destination)
            return
        } catch is AssetPreflightError {
            // Bootstrap only known missing, empty, or malformed asset trees.
        }

        try Task.checkCancellation()
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".Resources-seed-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            ".Resources-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        var priorWasMoved = false
        var preserveBackup = false
        defer {
            try? fileManager.removeItem(at: staging)
            if !preserveBackup {
                try? fileManager.removeItem(at: backup)
            }
        }

        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundledRoot, to: staging)
        try await validate(staging)
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
            priorWasMoved = true
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if priorWasMoved, !fileManager.fileExists(atPath: destination.path) {
                do {
                    try fileManager.moveItem(at: backup, to: destination)
                } catch {
                    preserveBackup = true
                }
            }
            throw error
        }
    }

    private static func bundledRoot(bundle: Bundle = .main) -> URL? {
        let root = bundle.resourceURL?.appendingPathComponent(
            "BundledAssets",
            isDirectory: true
        )
        guard let root,
              FileManager.default.fileExists(atPath: root.path) else {
            return nil
        }
        return root
    }

    private static func validateAssets(at root: URL) async throws {
        _ = try await AssetPreflight.check(resourceRoot: root)
    }
}
