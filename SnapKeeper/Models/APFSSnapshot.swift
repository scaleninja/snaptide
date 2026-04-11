import Foundation

enum SnapshotKind: String, Hashable, Sendable {
    case timeMachine = "Time Machine"
    case systemUpdate = "System"
    case manual = "Manual"

    nonisolated init(name: String) {
        if name.hasPrefix("com.apple.TimeMachine") {
            self = .timeMachine
        } else if name.hasPrefix("com.apple.os.update") || name.contains("bootsnapshot") {
            self = .systemUpdate
        } else {
            self = .manual
        }
    }
}

struct APFSSnapshot: Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    let createdAt: Date?
    let kind: SnapshotKind
    let purgeable: Bool
    let xid: Int64?

    nonisolated var id: String { uuid }

    /// "YYYY-MM-DD-HHMMSS" token embedded in Time Machine snapshot names.
    nonisolated var timeMachineDateToken: String? {
        guard kind == .timeMachine else { return nil }
        let parts = name.components(separatedBy: ".")
        guard parts.count >= 4 else { return nil }
        let token = parts[3]
        return token.count == 17 ? token : nil
    }
}
