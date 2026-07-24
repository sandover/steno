/*
 Proves a colleague release seeds signed bootstrap assets only when needed.
 Fixtures use a tiny manifest-like file and inject validation to avoid model I/O.
 Missing or invalid persistent assets are replaced from the bundled source.
 A valid persistent tree wins, so ordinary app updates avoid copying the model.
 Every fixture remains under a unique temporary directory and is removed after use.
*/
import Foundation
import Testing
@testable import Steno

@Suite("BundledAssetsTests", .serialized)
struct BundledAssetsTests {
    @Test func seedsBundledAssetsWhenPersistentTreeIsInvalid() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("invalid", to: fixture.destination)
        try fixture.write("verified", to: fixture.source)

        try await BundledAssets.seedIfNeeded(
            destination: fixture.destination,
            bundledRoot: fixture.source,
            validate: fixture.validate
        )

        #expect(try fixture.read(fixture.destination) == "verified")
    }

    @Test func preservesExistingValidPersistentAssets() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("verified", to: fixture.destination)
        try fixture.write("replacement", to: fixture.source)

        try await BundledAssets.seedIfNeeded(
            destination: fixture.destination,
            bundledRoot: fixture.source,
            validate: fixture.validate
        )

        #expect(try fixture.read(fixture.destination) == "verified")
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoBundledAssets-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("persistent/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var validate: BundledAssets.Validator {
        { root in
            guard try self.read(root) == "verified" else {
                throw AssetPreflightError.malformed("fixture")
            }
        }
    }

    func write(_ value: String, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: root.appendingPathComponent("AssetManifest.json"))
    }

    func read(_ root: URL) throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent("AssetManifest.json"))
        return String(decoding: data, as: UTF8.self)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
