/*
 Locates and validates Steno's single pinned model and tokenizer before WhisperKit.
 InstalledResources derives the sole runtime root from sandbox Application Support.
 AssetPreflight accepts an explicit resource root so tests and the app share checks.
 It rejects missing, empty, or malformed files before inference begins.
 Successful output contains the only model and tokenizer URLs inference may use.
 Tokenizer loading is semantic and local; this code never names a remote fallback.
*/
import ArgmaxCore
import Foundation

enum InstalledResources {
    static func root(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
    }

    static func root(fileManager: FileManager = .default) -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure("macOS did not provide an Application Support directory")
        }
        return root(in: applicationSupport)
    }
}

struct AssetManifest: Codable, Equatable, Sendable {
    struct Downloader: Codable, Equatable, Sendable {
        let package: String
        let version: String
    }

    struct Model: Codable, Equatable, Sendable {
        let repository: String
        let revision: String
        let sourceDirectory: String
        let directory: String
        let sha256: String
    }

    struct Tokenizer: Codable, Equatable, Sendable {
        let repository: String
        let revision: String
        let directory: String
        let sha256: String
        let files: [String]
    }

    let schemaVersion: Int
    let downloader: Downloader
    let model: Model
    let tokenizer: Tokenizer
}

struct AssetLocations: Equatable, Sendable {
    let manifest: AssetManifest
    let modelFolder: URL
    let tokenizerFolder: URL
}

enum AssetPreflightError: LocalizedError, Equatable {
    case missing(String)
    case empty(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case let .missing(path):
            "A required offline speech asset is missing: \(path)"
        case let .empty(path):
            "A required offline speech asset is empty: \(path)"
        case let .malformed(detail):
            "The installed speech assets are malformed: \(detail)"
        }
    }
}

enum AssetPreflight {
    private static let modelComponents = [
        "AudioEncoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "TextDecoder.mlmodelc",
    ]
    private static let requiredTokens = [
        "<|endoftext|>",
        "<|startoftranscript|>",
        "<|transcribe|>",
        "<|0.00|>",
    ]

    static func check(resourceRoot: URL) async throws -> AssetLocations {
        let manifestURL = resourceRoot.appendingPathComponent("AssetManifest.json")
        try inspectFile(manifestURL, relativeTo: resourceRoot)

        let manifest: AssetManifest
        do {
            manifest = try JSONDecoder().decode(
                AssetManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw AssetPreflightError.malformed("AssetManifest.json")
        }
        guard manifest.schemaVersion == 2 else {
            throw AssetPreflightError.malformed("unsupported asset manifest version")
        }
        guard manifest.downloader.package == "hf",
              manifest.downloader.version.isEmpty == false,
              manifest.model.sha256.count == 64,
              manifest.tokenizer.sha256.count == 64,
              manifest.tokenizer.files.isEmpty == false else {
            throw AssetPreflightError.malformed("incomplete asset manifest")
        }

        let modelFolder = resourceRoot.appendingPathComponent(
            manifest.model.directory,
            isDirectory: true
        )
        let tokenizerFolder = resourceRoot.appendingPathComponent(
            manifest.tokenizer.directory,
            isDirectory: true
        )

        for component in modelComponents {
            try inspectDirectory(
                modelFolder.appendingPathComponent(component, isDirectory: true),
                relativeTo: resourceRoot
            )
        }
        for file in manifest.tokenizer.files {
            try inspectFile(
                tokenizerFolder.appendingPathComponent(file),
                relativeTo: resourceRoot
            )
        }

        let tokenizer: TokenizerWrapper
        do {
            tokenizer = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
        } catch {
            throw AssetPreflightError.malformed("local tokenizer snapshot")
        }
        guard requiredTokens.allSatisfy({ tokenizer.convertTokenToId($0) != nil }) else {
            throw AssetPreflightError.malformed("local tokenizer lacks Whisper tokens")
        }

        return AssetLocations(
            manifest: manifest,
            modelFolder: modelFolder,
            tokenizerFolder: tokenizerFolder
        )
    }

    private static func inspectDirectory(_ url: URL, relativeTo root: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AssetPreflightError.missing(relativePath(url, root: root))
        }
        guard let files = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw AssetPreflightError.missing(relativePath(url, root: root))
        }
        var foundFile = false
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            foundFile = true
            try inspectFile(file, relativeTo: root)
        }
        if !foundFile {
            throw AssetPreflightError.empty(relativePath(url, root: root))
        }
    }

    private static func inspectFile(_ url: URL, relativeTo root: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AssetPreflightError.missing(relativePath(url, root: root))
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else {
            throw AssetPreflightError.empty(relativePath(url, root: root))
        }
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }
}
