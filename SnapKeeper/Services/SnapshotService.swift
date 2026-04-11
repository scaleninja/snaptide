import Darwin
import Foundation

/// Error thrown by the `fs_snapshot_*(2)` wrappers. Wraps the failing syscall
/// name and its errno so DTS / entitlement-request submissions can point at
/// the exact kernel refusal — the `EPERM` case includes the entitlement name
/// the app needs granted.
struct SnapshotAPIError: LocalizedError {
    let syscall: String
    let code: Int32

    var errorDescription: String? {
        let base = "\(syscall) failed (errno \(code): \(String(cString: strerror(code))))."
        if code == EPERM {
            return base
                + "\n\nThis syscall requires the com.apple.developer.vfs.snapshot "
                + "entitlement. Without it, the APFS kernel extension refuses "
                + "the call regardless of uid."
        }
        return base
    }
}

struct SnapshotService: Sendable {
    nonisolated func listSnapshots(forVolumeAt path: String) async throws -> [APFSSnapshot] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let names = try SnapshotListing.list(volumePath: path)
                    let snapshots = names.map { Self.makeSnapshot(name: $0) }
                    cont.resume(returning: Self.sorted(snapshots))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Creates a named APFS snapshot on the volume mounted at `mountPoint` by
    /// calling `fs_snapshot_create(2)` directly. Requires the
    /// `com.apple.developer.vfs.snapshot` entitlement; without it the kernel
    /// returns `EPERM` and `SnapshotAPIError` surfaces that to the UI.
    nonisolated func createSnapshot(named name: String, onVolumeAt mountPoint: String) async throws {
        try await Self.runOnBackground {
            try Self.callFsSnapshotCreate(name: name, volumePath: mountPoint)
        }
    }

    /// Deletes a named APFS snapshot on the volume mounted at `mountPoint` by
    /// calling `fs_snapshot_delete(2)` directly. Same entitlement requirement
    /// as create.
    nonisolated func deleteSnapshot(named name: String, onVolumeAt mountPoint: String) async throws {
        try await Self.runOnBackground {
            try Self.callFsSnapshotDelete(name: name, volumePath: mountPoint)
        }
    }

    private nonisolated static func runOnBackground(
        _ work: @Sendable @escaping () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try work()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func callFsSnapshotCreate(
        name: String, volumePath: String
    ) throws {
        let fd = open(volumePath, O_RDONLY)
        guard fd >= 0 else {
            throw SnapshotAPIError(syscall: "open(\(volumePath))", code: errno)
        }
        defer { Darwin.close(fd) }

        let result = name.withCString { cname in
            fs_snapshot_create(fd, cname, 0)
        }
        if result != 0 {
            let code = errno
            throw SnapshotAPIError(syscall: "fs_snapshot_create", code: code)
        }
    }

    private nonisolated static func callFsSnapshotDelete(
        name: String, volumePath: String
    ) throws {
        let fd = open(volumePath, O_RDONLY)
        guard fd >= 0 else {
            throw SnapshotAPIError(syscall: "open(\(volumePath))", code: errno)
        }
        defer { Darwin.close(fd) }

        let result = name.withCString { cname in
            fs_snapshot_delete(fd, cname, 0)
        }
        if result != 0 {
            let code = errno
            throw SnapshotAPIError(syscall: "fs_snapshot_delete", code: code)
        }
    }

    private nonisolated static func makeSnapshot(name: String) -> APFSSnapshot {
        APFSSnapshot(
            uuid: name,
            name: name,
            createdAt: parseDate(from: name),
            kind: SnapshotKind(name: name),
            purgeable: false,
            xid: nil
        )
    }

    private nonisolated static func sorted(_ list: [APFSSnapshot]) -> [APFSSnapshot] {
        list.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.name < rhs.name
            }
        }
    }

    private nonisolated static func parseDate(from name: String) -> Date? {
        let parts = name.components(separatedBy: ".")
        guard parts.count >= 4 else { return nil }
        let token = parts[3]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: token)
    }
}
