import Darwin
import Foundation

enum SnapshotServiceError: LocalizedError {
    case couldNotParseToken
    case cannotCreateOnExternalVolume

    var errorDescription: String? {
        switch self {
        case .couldNotParseToken:
            return "Could not extract a date token from tmutil output."
        case .cannotCreateOnExternalVolume:
            return "Cannot create a snapshot on this volume without root privileges or the private snapshot entitlement. Re-sign the app using the scheme pre-action, or run Xcode with 'debug as root'."
        }
    }
}

struct SnapshotService: Sendable {

    // MARK: - List

    nonisolated func listSnapshots(
        forVolumeAt path: String,
        device: String? = nil,
        aliases: [String: String] = [:]
    ) async throws -> [APFSSnapshot] {
        // Kick off diskutil size fetch concurrently while the syscall listing runs.
        let sizesTask = Task<[String: Int64], Never> {
            guard let dev = device else { return [:] }
            return (try? await Self.fetchSnapshotSizes(device: dev)) ?? [:]
        }

        let names: [String] = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try SnapshotListing.list(volumePath: path))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        let sizes = await sizesTask.value
        let snapshots = names.map { name -> APFSSnapshot in
            let snap = Self.makeSnapshot(name: name, aliases: aliases)
            let sz = sizes[name]
            return sz != nil ? snap.with(privateSize: sz) : snap
        }
        return Self.sorted(snapshots)
    }

    // MARK: - Create

    /// Creates a new APFS snapshot named `com.scaleninja.SnapTide.<YYYY-MM-DD-HHmmss>`.
    ///
    /// Strategy:
    /// 1. Try `fs_snapshot_create(2)` directly — works when the app has the
    ///    `com.apple.developer.vfs.snapshot` entitlement AND the kernel honours it
    ///    for this volume (future OS releases or specific ownership situations).
    /// 2. On EPERM, fall back **only for the internal boot Data volume** (`/`):
    ///    `tmutil localsnapshot <volumePath>` carries Apple's private entitlement.
    ///    External / non-boot volumes throw `cannotCreateOnExternalVolume` instead,
    ///    since tmutil is unreliable on externals and the error message guides the
    ///    user to enable the private entitlement via the scheme pre-action.
    ///
    /// Returns the `YYYY-MM-DD-HHmmss` date token so the caller can persist an alias.
    nonisolated func createSnapshot(volumePath: String, isBootVolume: Bool = false) async throws -> String {
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
            guard let listingErr = err as? SnapshotListingError,
                  case .createFailed(let code) = listingErr,
                  code == EPERM else {
                throw err
            }
            // EPERM on an external volume — guide the user rather than silently falling back.
            guard isBootVolume else {
                throw SnapshotServiceError.cannotCreateOnExternalVolume
            }
        }

        // --- Fallback path (boot Data volume only): tmutil + rename ---
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

    /// Fetches private (exclusive) snapshot sizes from `diskutil apfs listSnapshots -plist`.
    /// Returns an empty dict if diskutil doesn't report sizes or the call fails.
    private nonisolated static func fetchSnapshotSizes(device: String) async throws -> [String: Int64] {
        let data = try await ShellRunner.run(
            "/usr/sbin/diskutil", args: ["apfs", "listSnapshots", device, "-plist"]
        )
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let list = dict["Snapshots"] as? [[String: Any]] else { return [:] }
        var result: [String: Int64] = [:]
        for snap in list {
            guard let name = snap["SnapshotName"] as? String else { continue }
            if let sz = snap["SnapshotSize"] as? Int64, sz > 0 {
                result[name] = sz
            } else if let sz = snap["SnapshotSize"] as? Int, sz > 0 {
                result[name] = Int64(sz)
            }
        }
        return result
    }

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
            xid: nil,
            privateSize: nil
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
