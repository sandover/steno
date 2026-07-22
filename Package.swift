// swift-tools-version: 6.2
/*
 Defines Steno's only build graph: one native executable and one test target.
 The package targets Brandon's Apple Silicon Mac and pins inference exactly.
 WhisperKit is imported as a library; Steno does not ship a local server.
 Resources are declared here only when the offline model task adds them.
 No Xcode project or generated build description is authoritative.
*/
import PackageDescription

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
