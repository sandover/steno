/*
 Replaces an installed Steno directory with a staged directory on one volume.
 renamex_np swaps existing and staged directories in one atomic filesystem step.
 The old installed directory then occupies the staging path and is removed there.
 First installation uses the same-volume POSIX rename operation.
 Failure before the swap leaves the existing installed directory untouched.
*/
import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: AtomicReplace.swift STAGED_PATH INSTALLED_PATH\n", stderr)
    exit(64)
}

let stagedPath = CommandLine.arguments[1]
let installedPath = CommandLine.arguments[2]
let manager = FileManager.default

if manager.fileExists(atPath: installedPath) {
    guard renamex_np(stagedPath, installedPath, UInt32(RENAME_SWAP)) == 0 else {
        perror("cannot atomically replace installed directory")
        exit(1)
    }
    do {
        try manager.removeItem(atPath: stagedPath)
    } catch {
        fputs("warning: installed new directory but could not remove the previous one: \(error)\n", stderr)
    }
} else {
    guard rename(stagedPath, installedPath) == 0 else {
        perror("cannot install staged directory")
        exit(1)
    }
}
