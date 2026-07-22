// swift-tools-version: 6.2
/*
 Defines Steno's only build graph: one native executable and one test target.
 The package targets Brandon's Apple Silicon Mac and pins inference exactly.
 WhisperKit is imported as a library; Steno does not ship a local server.
 Offline assets remain repository installation inputs, not executable resources.
 No Xcode project or generated build description is authoritative.
*/
import PackageDescription
import Foundation

let assetRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources", isDirectory: true)

func requireMaterializedAssets() {
    let requiredPaths = [
        "AssetManifest.json",
        "Models/openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc",
        "Models/openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc",
        "Models/openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc",
        "Tokenizers/openai-whisper-large-v3/tokenizer.json",
        "Tokenizers/openai-whisper-large-v3/tokenizer_config.json",
        "Tokenizers/openai-whisper-large-v3/config.json",
    ]
    let manager = FileManager.default

    for path in requiredPaths {
        guard manager.fileExists(atPath: assetRoot.appendingPathComponent(path).path) else {
            fatalError("Missing required offline asset: Resources/\(path)")
        }
    }

    guard let files = manager.enumerator(
        at: assetRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
    ) else {
        fatalError("Cannot inspect Resources for offline assets")
    }

    for case let file as URL in files {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { continue }
        guard let size = values.fileSize, size > 0 else {
            fatalError("Offline asset is empty: \(file.path)")
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            fatalError("Offline asset cannot be read: \(file.path)")
        }
        let prefix = try? handle.read(upToCount: 128)
        try? handle.close()
        if let prefix, String(decoding: prefix, as: UTF8.self)
            .hasPrefix("version https://git-lfs.github.com/spec/v1") {
            fatalError("Resolve Git-LFS asset before building: \(file.path)")
        }
    }
}

requireMaterializedAssets()

let package = Package(
    name: "Steno",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.0.0"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            exact: "0.12.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "Steno",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "StenoTests",
            dependencies: [
                "Steno",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
