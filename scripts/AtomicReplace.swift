/*
 Replaces the installed Steno bundle with a staged bundle on the same volume.
 renamex_np swaps existing and staged directories in one atomic filesystem step.
 The old installed bundle then occupies the staging path and is removed there.
 First installation uses the same-volume POSIX rename operation.
 Failure before the swap leaves the existing installed bundle untouched.
*/
import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: AtomicReplace.swift STAGED_APP INSTALLED_APP\n", stderr)
    exit(64)
}

let stagedPath = CommandLine.arguments[1]
let installedPath = CommandLine.arguments[2]
let manager = FileManager.default

if manager.fileExists(atPath: installedPath) {
    guard renamex_np(stagedPath, installedPath, UInt32(RENAME_SWAP)) == 0 else {
        perror("cannot atomically replace Steno.app")
        exit(1)
    }
    do {
        try manager.removeItem(atPath: stagedPath)
    } catch {
        fputs("installed Steno, but could not remove the previous bundle: \(error)\n", stderr)
        exit(1)
    }
} else {
    guard rename(stagedPath, installedPath) == 0 else {
        perror("cannot install Steno.app")
        exit(1)
    }
}
