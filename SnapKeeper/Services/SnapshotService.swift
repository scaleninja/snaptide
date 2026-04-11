import Foundation

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

    nonisolated func createSnapshot() async throws -> String {
        let data = try await ShellRunner.run("/usr/bin/tmutil", args: ["localsnapshot"])
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Creates a named APFS snapshot by re-launching SnapKeeper's own binary
    /// under `osascript ... with administrator privileges`, which invokes
    /// `fs_snapshot_create(2)` inside the helper subprocess. The user is
    /// prompted once for their password by macOS.
    nonisolated func createSnapshot(named name: String, onVolumeAt mountPoint: String) async throws {
        guard let executable = Bundle.main.executablePath else {
            throw NSError(
                domain: "SnapKeeper", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate SnapKeeper executable."]
            )
        }
        let safePath = Self.shellQuote(mountPoint)
        let safeName = Self.shellQuote(name)
        let safeExe = Self.shellQuote(executable)
        let command = "\(safeExe) \(HelperMode.createSnapshotFlag) \(safePath) \(safeName)"
        try await ShellRunner.runPrivileged(command)
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated func deleteSnapshot(_ snapshot: APFSSnapshot, on device: String) async throws {
        if let token = snapshot.timeMachineDateToken {
            _ = try await ShellRunner.run("/usr/bin/tmutil", args: ["deletelocalsnapshots", token])
            return
        }
        let cmd = "/usr/sbin/diskutil apfs deleteSnapshot \(device) -uuid \(snapshot.uuid)"
        try await ShellRunner.runPrivileged(cmd)
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
