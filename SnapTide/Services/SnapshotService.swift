import Darwin
import Foundation

enum SnapshotServiceError: LocalizedError {
    case couldNotParseToken

    var errorDescription: String? {
        "Could not extract a date token from tmutil output."
    }
}

struct SnapshotService: Sendable {

    // MARK: - List

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

    // MARK: - Create

    /// Creates a new APFS snapshot named `com.scaleninja.SnapTide.<YYYY-MM-DD-HHmmss>`.
    ///
    /// Strategy:
    /// 1. Try `fs_snapshot_create(2)` directly — works when the app has the
    ///    `com.apple.developer.vfs.snapshot` entitlement AND the kernel honours it
    ///    for this volume (future OS releases or specific ownership situations).
    /// 2. On EPERM (kernel requires root even with the public entitlement),
    ///    fall back to `tmutil localsnapshot <volumePath>`, which carries Apple's
    ///    private `com.apple.private.vfs.snapshot` entitlement and works without root
    ///    on any mounted APFS volume. The resulting TM snapshot is immediately renamed
    ///    to the SnapTide convention via `fs_snapshot_rename(2)`.
    ///
    /// Returns the `YYYY-MM-DD-HHmmss` date token so the caller can persist an alias.
    nonisolated func createSnapshot(volumePath: String) async throws -> String {
        // --- Primary path: direct syscall ---
        let directResult: Result<String, Error> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let token = Self.makeDateToken()
                    let name = "com.scaleninja.SnapTide.\(token)"
                    try SnapshotListing.createSnapshot(volumePath: volumePath, name: name)
                    cont.resume(returning: .success(token))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }

        switch directResult {
        case .success(let token):
            return token

        case .failure(let err):
            // EPERM: kernel requires root for fs_snapshot_create even with the public
            // entitlement. Fall back to tmutil, which holds the private entitlement.
            guard let listingErr = err as? SnapshotListingError,
                  case .createFailed(let code) = listingErr,
                  code == EPERM else {
                throw err
            }
        }

        // --- Fallback path: tmutil + rename ---
        return try await createSnapshotViaTmutil(volumePath: volumePath)
    }

    /// Uses `tmutil localsnapshot <volumePath>` to create a TM-named snapshot on
    /// the specified volume, then renames it to the SnapTide convention.
    ///
    /// If the rename fails with EPERM (external volumes require the private
    /// `com.apple.private.vfs.snapshot` entitlement, which is only active once
    /// the app has been re-signed with the scheme pre-action), the snapshot is
    /// kept under its original Time Machine name and the token is returned as-is.
    /// It will appear as kind=TimeMachine in the UI with whatever alias the user
    /// chose, and deletion will use `tmutil deletelocalsnapshots` as normal.
    private nonisolated func createSnapshotViaTmutil(volumePath: String) async throws -> String {
        let data = try await ShellRunner.run(
            "/usr/bin/tmutil", args: ["localsnapshot", volumePath]
        )
        let output = String(data: data, encoding: .utf8) ?? ""
        guard let token = Self.parseDateToken(fromTmutilOutput: output) else {
            throw SnapshotServiceError.couldNotParseToken
        }
        let oldName = "com.apple.TimeMachine.\(token).local"
        let newName = "com.scaleninja.SnapTide.\(token)"
        do {
            try SnapshotListing.renameSnapshot(
                volumePath: volumePath, oldName: oldName, newName: newName
            )
        } catch let err as SnapshotListingError {
            if case .renameFailed(let code) = err, code == EPERM {
                // Private entitlement not yet active — keep the TM name.
                // Once the scheme pre-action re-signs the app, fs_snapshot_create
                // will succeed on the primary path and no rename will be needed.
                print("[SnapTide] fs_snapshot_rename EPERM — keeping TM name \(oldName)")
            } else {
                throw err
            }
        }
        return token
    }

    // MARK: - Delete

    /// Deletes `snapshot` from the volume at `volumePath`.
    ///
    /// - SnapTide / Manual / System: `fs_snapshot_delete(2)` first.
    ///   On EPERM falls back to `diskutil apfs deleteSnapshot` via an admin prompt.
    /// - Time Machine: `tmutil deletelocalsnapshots <token>` — user-level, no password.
    nonisolated func deleteSnapshot(
        _ snapshot: APFSSnapshot,
        on device: String,
        volumePath: String
    ) async throws {
        switch snapshot.kind {
        case .timeMachine:
            if let token = snapshot.timeMachineDateToken {
                _ = try await ShellRunner.run(
                    "/usr/bin/tmutil", args: ["deletelocalsnapshots", token]
                )
            } else {
                try await deleteViaSyscallOrPrivileged(
                    snapshot: snapshot, device: device, volumePath: volumePath
                )
            }

        case .snapTide, .systemUpdate, .manual:
            try await deleteViaSyscallOrPrivileged(
                snapshot: snapshot, device: device, volumePath: volumePath
            )
        }
    }

    /// Tries `fs_snapshot_delete(2)`. On EPERM escalates via osascript + diskutil
    /// (one password prompt per session, same as the original behaviour).
    private nonisolated func deleteViaSyscallOrPrivileged(
        snapshot: APFSSnapshot,
        device: String,
        volumePath: String
    ) async throws {
        let deleteResult: Result<Void, Error> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try SnapshotListing.deleteSnapshot(
                        volumePath: volumePath, name: snapshot.name
                    )
                    cont.resume(returning: .success(()))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }

        switch deleteResult {
        case .success: return

        case .failure(let err):
            guard let listingErr = err as? SnapshotListingError,
                  case .deleteFailed(let code) = listingErr,
                  code == EPERM else {
                throw err
            }
            // EPERM: fall back to diskutil with admin privileges.
            let cmd = "/usr/sbin/diskutil apfs deleteSnapshot \(device) -name \(Self.shellQuote(snapshot.name))"
            try await ShellRunner.runPrivileged(cmd)
        }
    }

    // MARK: - Mount

    /// Deterministic per-snapshot mount path under `/tmp/SnapTide/`.
    nonisolated static func mountPath(for snapshot: APFSSnapshot, device: String) -> String {
        let sanitized = snapshot.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "/tmp/SnapTide/\(device)-\(sanitized)"
    }

    /// Mounts `snapshot` from the volume at `volumeMountPoint` using
    /// `fs_snapshot_mount(2)`. The kernel always mounts read-only.
    nonisolated func mountSnapshot(
        _ snapshot: APFSSnapshot,
        device: String,
        volumeMountPoint: String
    ) async throws -> String {
        let target = Self.mountPath(for: snapshot, device: device)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.createDirectory(
                        atPath: target,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try SnapshotListing.mountSnapshot(
                        volumePath: volumeMountPoint,
                        snapshotName: snapshot.name,
                        mountPoint: target
                    )
                    cont.resume()
                } catch {
                    try? FileManager.default.removeItem(atPath: target)
                    cont.resume(throwing: error)
                }
            }
        }
        return target
    }

    // MARK: - Unmount

    nonisolated func unmountSnapshot(at path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try SnapshotListing.unmountSnapshot(mountPoint: path)
                    try? FileManager.default.removeItem(atPath: path)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Mount state

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

    // MARK: - Private helpers

    private nonisolated static func makeDateToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Finds a 17-character `YYYY-MM-DD-HHmmss` token anywhere in tmutil's stdout.
    /// tmutil has used different phrasings across macOS releases so we scan blindly.
    private nonisolated static func parseDateToken(fromTmutilOutput output: String) -> String? {
        let chars = Array(output)
        let n = chars.count
        guard n >= 17 else { return nil }
        for start in 0...(n - 17) {
            let slice = chars[start..<(start + 17)]
            if isDateToken(slice) { return String(slice) }
        }
        return nil
    }

    private nonisolated static func isDateToken(_ slice: ArraySlice<Character>) -> Bool {
        // yyyy-MM-dd-HHmmss: dashes at indices 4, 7, 10; digits elsewhere.
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
}
