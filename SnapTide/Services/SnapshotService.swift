import Foundation

struct SnapshotService: Sendable {
    nonisolated func listSnapshots(
        forVolumeAt path: String,
        aliases: [String: String] = [:]
    ) async throws -> [APFSSnapshot] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let names = try SnapshotListing.list(volumePath: path)
                    let snapshots = names.map { Self.makeSnapshot(name: $0, aliases: aliases) }
                    cont.resume(returning: Self.sorted(snapshots))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Creates a Time Machine local snapshot via `tmutil localsnapshot`. Works
    /// without a password. Returns the `YYYY-MM-DD-HHMMSS` date token parsed
    /// from tmutil's stdout, or `nil` if the output format is unexpected.
    nonisolated func createSnapshot() async throws -> String? {
        let data = try await ShellRunner.run("/usr/bin/tmutil", args: ["localsnapshot"])
        let output = String(data: data, encoding: .utf8) ?? ""
        return Self.parseDateToken(fromTmutilOutput: output)
    }

    nonisolated func deleteSnapshot(_ snapshot: APFSSnapshot, on device: String) async throws {
        if let token = snapshot.timeMachineDateToken {
            _ = try await ShellRunner.run("/usr/bin/tmutil", args: ["deletelocalsnapshots", token])
            return
        }
        let cmd = "/usr/sbin/diskutil apfs deleteSnapshot \(device) -uuid \(snapshot.uuid)"
        try await ShellRunner.runPrivileged(cmd)
    }

    /// Deterministic per-snapshot mount path under `/tmp/SnapTide/`. macOS
    /// canonicalizes this to `/private/tmp/SnapTide/...` in `mount` output,
    /// so callers comparing against live mounts must check both forms.
    nonisolated static func mountPath(for snapshot: APFSSnapshot, device: String) -> String {
        let sanitized = snapshot.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "/tmp/SnapTide/\(device)-\(sanitized)"
    }

    nonisolated func mountSnapshot(_ snapshot: APFSSnapshot, device: String) async throws -> String {
        let target = Self.mountPath(for: snapshot, device: device)
        let escTarget = Self.shellQuote(target)
        let escName = Self.shellQuote(snapshot.name)
        let cmd = "/bin/mkdir -p \(escTarget) && /sbin/mount_apfs -o nobrowse -s \(escName) /dev/\(device) \(escTarget)"
        try await ShellRunner.runPrivileged(cmd)
        return target
    }

    nonisolated func unmountSnapshot(at path: String) async throws {
        let cmd = "/sbin/umount \(Self.shellQuote(path))"
        try await ShellRunner.runPrivileged(cmd)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Returns the set of active mount points whose paths live under
    /// `SnapTide/`. Both the `/tmp/...` and `/private/tmp/...` forms are
    /// inserted so lookups by the deterministic target path succeed regardless
    /// of how macOS printed the entry.
    nonisolated func currentMountedPaths() async throws -> Set<String> {
        let data = try await ShellRunner.run("/sbin/mount", args: [])
        let output = String(data: data, encoding: .utf8) ?? ""
        var result: Set<String> = []
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            guard let onRange = line.range(of: " on ") else { continue }
            let afterOn = line[onRange.upperBound...]
            guard let parenRange = afterOn.range(of: " (") else { continue }
            let path = String(afterOn[..<parenRange.lowerBound])
            guard path.contains("/SnapTide/") else { continue }
            result.insert(path)
            if path.hasPrefix("/private/") {
                result.insert(String(path.dropFirst("/private".count)))
            } else {
                result.insert("/private" + path)
            }
        }
        return result
    }

    private nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func makeSnapshot(
        name: String,
        aliases: [String: String]
    ) -> APFSSnapshot {
        let alias = AliasStore.dateToken(forSnapshotName: name).flatMap { aliases[$0] }
        return APFSSnapshot(
            uuid: name,
            name: name,
            displayName: alias,
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

    /// Finds a 17-character `YYYY-MM-DD-HHMMSS` token anywhere in tmutil's
    /// stdout — tmutil has used different phrasings across macOS releases
    /// ("Created local snapshot with date: ..." vs. "...succeeded for ...").
    private nonisolated static func parseDateToken(fromTmutilOutput output: String) -> String? {
        let chars = Array(output)
        let n = chars.count
        guard n >= 17 else { return nil }
        for start in 0...(n - 17) {
            let slice = chars[start..<(start + 17)]
            if isDateToken(slice) {
                return String(slice)
            }
        }
        return nil
    }

    private nonisolated static func isDateToken(_ slice: ArraySlice<Character>) -> Bool {
        // yyyy-MM-dd-HHmmss : indices 4,7,10 must be '-', others digits.
        let dashPositions: Set<Int> = [4, 7, 10]
        for (offset, ch) in slice.enumerated() {
            if dashPositions.contains(offset) {
                if ch != "-" { return false }
            } else if !ch.isASCII || !ch.isNumber {
                return false
            }
        }
        return true
    }
}
