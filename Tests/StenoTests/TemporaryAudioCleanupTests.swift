/*
 Proves temporary audio paths are unique, private to Steno, and disposable.
 The tests use an isolated directory and never inspect or remove user files.
 Only the exact Steno recording filename contract qualifies for stale cleanup.
 Cleanup must ignore unrelated WAV files, malformed names, and directories.
*/
import Foundation
import Testing
@testable import Steno

@Suite("TemporaryAudioCleanupTests")
struct TemporaryAudioCleanupTests {
    @Test func createsUniqueOwnedWavePaths() throws {
        try withTemporaryDirectory { directory in
            let store = TemporaryAudioStore(directory: directory)

            let first = store.newRecordingURL()
            let second = store.newRecordingURL()

            #expect(first != second)
            #expect(store.owns(first))
            #expect(store.owns(second))
            #expect(first.pathExtension == "wav")
        }
    }

    @Test func launchCleanupRemovesOnlyOwnedWaveFiles() throws {
        try withTemporaryDirectory { directory in
            let store = TemporaryAudioStore(directory: directory)
            let owned = store.newRecordingURL()
            let unrelatedWave = directory.appendingPathComponent("meeting.wav")
            let malformedStenoName = directory.appendingPathComponent("Steno-Recording-latest.wav")
            let ownedLookingDirectory = store.newRecordingURL()
            try Data([1]).write(to: owned)
            try Data([2]).write(to: unrelatedWave)
            try Data([3]).write(to: malformedStenoName)
            try FileManager.default.createDirectory(
                at: ownedLookingDirectory,
                withIntermediateDirectories: false
            )

            let removed = try store.removeStaleRecordings()

            #expect(removed.map(\.lastPathComponent) == [owned.lastPathComponent])
            #expect(!FileManager.default.fileExists(atPath: owned.path))
            #expect(FileManager.default.fileExists(atPath: unrelatedWave.path))
            #expect(FileManager.default.fileExists(atPath: malformedStenoName.path))
            #expect(FileManager.default.fileExists(atPath: ownedLookingDirectory.path))
        }
    }

    @Test func refusesToDeleteAnUnownedPath() throws {
        try withTemporaryDirectory { directory in
            let store = TemporaryAudioStore(directory: directory)
            let unrelated = directory.appendingPathComponent("meeting.wav")
            try Data([1]).write(to: unrelated)

            try store.deleteRecording(at: unrelated)

            #expect(FileManager.default.fileExists(atPath: unrelated.path))
        }
    }
}

private func withTemporaryDirectory(
    _ operation: (URL) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}
