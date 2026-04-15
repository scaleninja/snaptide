import Foundation

enum SnapshotKind: String, Hashable, Sendable {
    case timeMachine = "Time Machine"
    case systemUpdate = "System"
    case snapTide = "SnapTide"
    case manual = "Manual"

    nonisolated init(name: String) {
        if name.hasPrefix("com.apple.TimeMachine") {
            self = .timeMachine
        } else if name.hasPrefix("com.apple.os.update") || name.contains("bootsnapshot") {
            self = .systemUpdate
        } else if name.hasPrefix("com.scaleninja.SnapTide") || name.hasPrefix("com.scaleninja.snaptide") {
            self = .snapTide
        } else {
            self = .manual
        }
    }
}

struct APFSSnapshot: Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    let displayName: String?
    let createdAt: Date?
    let kind: SnapshotKind
    let purgeable: Bool
    let xid: Int64?
    /// Private (exclusive) byte count reported by `diskutil apfs listSnapshots -plist`.
    /// `nil` when diskutil did not return a size (most volumes / older OS).
    let privateSize: Int64?

    nonisolated var id: String { uuid }

    nonisolated var effectiveName: String { displayName ?? name }
    nonisolated var hasAlias: Bool { displayName != nil }

    /// `YYYY-MM-DD-HHmmss` date token embedded in SnapTide or Time Machine
    /// snapshot names (always at the 4th dot-separated component).
    nonisolated var snapshotDateToken: String? {
        guard kind == .snapTide || kind == .timeMachine else { return nil }
        let parts = name.components(separatedBy: ".")
        guard parts.count >= 4 else { return nil }
        let token = parts[3]
        return token.count == 17 ? token : nil
    }

    /// Kept for backward compatibility; same as `snapshotDateToken` but only
    /// for Time Machine snapshots (used by the tmutil deletion path).
    nonisolated var timeMachineDateToken: String? {
        guard kind == .timeMachine else { return nil }
        return snapshotDateToken
    }

    func with(privateSize: Int64?) -> APFSSnapshot {
        APFSSnapshot(
            uuid: uuid, name: name, displayName: displayName,
            createdAt: createdAt, kind: kind, purgeable: purgeable,
            xid: xid, privateSize: privateSize
        )
    }
}
