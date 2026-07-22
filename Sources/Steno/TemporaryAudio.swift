/*
 Owns Steno's private temporary WAV naming and launch-cleanup contract.
 Exports unique recording URLs plus narrowly scoped delete and stale cleanup.
 A file is owned only when its name contains the exact prefix, UUID, and suffix.
 Cleanup never removes directories, symlinks, malformed names, or other files.
*/
import Foundation

struct TemporaryAudioStore {
    private static let prefix = "Steno-Recording-"
    private let fileManager: FileManager
    let directory: URL

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.temporaryDirectory
    }

    func newRecordingURL() -> URL {
        directory.appendingPathComponent(
            "\(Self.prefix)\(UUID().uuidString).wav",
            isDirectory: false
        )
    }

    func owns(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              url.pathExtension.lowercased() == "wav"
        else {
            return false
        }

        let filename = url.deletingPathExtension().lastPathComponent
        guard filename.hasPrefix(Self.prefix) else { return false }
        let identifier = String(filename.dropFirst(Self.prefix.count))
        return UUID(uuidString: identifier) != nil
    }

    func deleteRecording(at url: URL) throws {
        guard owns(url), fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    @discardableResult
    func removeStaleRecordings() throws -> [URL] {
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var removed: [URL] = []

        for url in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard owns(url) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: url)
            removed.append(url)
        }

        return removed
    }
}
