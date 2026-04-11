import Foundation

/// Client-side store mapping Time Machine snapshot date tokens (the
/// `YYYY-MM-DD-HHMMSS` piece inside `com.apple.TimeMachine.<token>.local`)
/// to user-provided display names. Persisted as JSON under
/// `~/Library/Application Support/SnapTide/aliases.json`.
///
/// This is the workaround for the fact that `fs_snapshot_create(2)` on the
/// boot volume group is kernel-gated behind a private Apple entitlement that
/// third-party apps cannot obtain. We create the snapshot with `tmutil
/// localsnapshot` (which works without a password), then attach a nickname
/// here so the UI can display the user's chosen name. The on-disk snapshot
/// still carries its Time Machine name.
@MainActor
final class AliasStore {
    static let shared = AliasStore()

    private let fileURL: URL
    private var cache: [String: String] = [:]
    private var didLoad = false

    private init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SnapTide", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.fileURL = dir.appendingPathComponent("aliases.json")
    }

    func alias(for token: String) -> String? {
        ensureLoaded()
        return cache[token]
    }

    func allAliases() -> [String: String] {
        ensureLoaded()
        return cache
    }

    func setAlias(_ alias: String, for token: String) {
        ensureLoaded()
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cache.removeValue(forKey: token)
        } else {
            cache[token] = trimmed
        }
        persist()
    }

    func removeAlias(for token: String) {
        ensureLoaded()
        if cache.removeValue(forKey: token) != nil {
            persist()
        }
    }

    /// Extracts the `YYYY-MM-DD-HHMMSS` token from a Time Machine snapshot
    /// name. Returns `nil` for non-TM snapshots.
    nonisolated static func dateToken(forSnapshotName name: String) -> String? {
        guard name.hasPrefix("com.apple.TimeMachine") else { return nil }
        let parts = name.components(separatedBy: ".")
        guard parts.count >= 4 else { return nil }
        let token = parts[3]
        return token.count == 17 ? token : nil
    }

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        cache = dict
    }

    private func persist() {
        guard let data = try? JSONEncoder()
            .encode(cache.sorted(by: { $0.key < $1.key })
                .reduce(into: [String: String]()) { $0[$1.key] = $1.value })
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
