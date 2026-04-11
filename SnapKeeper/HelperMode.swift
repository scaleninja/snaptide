import Darwin
import Foundation

/// Helper-mode lets SnapKeeper re-launch itself under `osascript ... with
/// administrator privileges` to perform operations that require root, notably
/// `fs_snapshot_create(2)` and `fs_snapshot_delete(2)`. The privileged child
/// process runs the requested operation and exits immediately — it never
/// initializes AppKit/SwiftUI, so no Dock icon appears.
enum HelperMode {
    nonisolated static let createSnapshotFlag = "--create-snapshot"

    /// Called from `main.swift` before the SwiftUI app starts. Detects helper
    /// invocations on the argv and hands control to the matching operation,
    /// terminating the process on completion.
    static func dispatchIfNeeded() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return }

        switch args[1] {
        case createSnapshotFlag:
            guard args.count >= 4 else {
                fail("usage: SnapKeeper \(createSnapshotFlag) <volume-path> <name>")
            }
            runCreate(volumePath: args[2], name: args[3])
        default:
            return
        }
    }

    private static func runCreate(volumePath: String, name: String) -> Never {
        let fd = open(volumePath, O_RDONLY)
        guard fd >= 0 else {
            fail("open(\(volumePath)) failed: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }

        let result = name.withCString { cname in
            fs_snapshot_create(fd, cname, 0)
        }
        if result != 0 {
            fail("fs_snapshot_create failed: \(String(cString: strerror(errno)))")
        }
        exit(EXIT_SUCCESS)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}
