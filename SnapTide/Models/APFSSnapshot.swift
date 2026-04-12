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
        } else if name.hasPrefix("com.scaleninja.snaptide") {
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

    nonisolated var id: String { uuid }

    nonisolated var effectiveName: String { displayName ?? name }
    nonisolated var hasAlias: Bool { displayName != nil }

    /// "YYYY-MM-DD-HHMMSS" token embedded in Time Machine snapshot names.
    nonisolated var timeMachineDateToken: String? {
        guard kind == .timeMachine else { return nil }
        let parts = name.components(separatedBy: ".")
        guard parts.count >= 4 else { return nil }
        let token = parts[3]
        return token.count == 17 ? token : nil
    }
}
