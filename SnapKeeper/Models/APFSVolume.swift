import Foundation

struct APFSVolume: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let deviceIdentifier: String
    let mountPoint: String?
    let roles: [String]
    let capacityInUse: Int64
    let capacityTotal: Int64?

    nonisolated var isMounted: Bool {
        guard let mp = mountPoint else { return false }
        return !mp.isEmpty
    }

    nonisolated var primaryRole: String {
        roles.first ?? "Data"
    }
}
