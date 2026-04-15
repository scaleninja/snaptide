import Foundation

struct APFSVolume: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let deviceIdentifier: String
    let mountPoint: String?
    let roles: [String]
    let capacityInUse: Int64
    let capacityTotal: Int64?
    /// Bus protocol reported by `diskutil info` (e.g. "USB", "PCIe", "SATA", "Thunderbolt").
    let connection: String?

    nonisolated var isMounted: Bool {
        guard let mp = mountPoint else { return false }
        return !mp.isEmpty
    }

    nonisolated var primaryRole: String {
        roles.first ?? "Data"
    }

    /// True when this is the internal boot Data volume (the root of the running OS).
    /// Only the boot Data volume can use `tmutil localsnapshot` as a fallback for
    /// `fs_snapshot_create`; external / secondary volumes must use the syscall directly
    /// (which requires root or the private `com.apple.private.vfs.snapshot` entitlement).
    nonisolated var isBootDataVolume: Bool {
        mountPoint == "/"
    }
}
