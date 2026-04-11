import Foundation

struct VolumeService: Sendable {
    /// APFS roles to hide from the sidebar — these are internal to the OS /
    /// hardware and do not hold user-visible snapshot histories.
    nonisolated static let hiddenRoles: Set<String> = [
        "System", "Preboot", "Recovery", "VM", "Update",
        "xART", "Hardware", "iSCPreboot", "Reserved"
    ]

    nonisolated func listVolumes() async throws -> [APFSVolume] {
        let data = try await ShellRunner.run(
            "/usr/sbin/diskutil",
            args: ["apfs", "list", "-plist"]
        )

        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] ?? [:]

        let containers = plist["Containers"] as? [[String: Any]] ?? []
        var volumes: [APFSVolume] = []

        for container in containers {
            let entries = container["Volumes"] as? [[String: Any]] ?? []
            for entry in entries {
                guard
                    let uuid = entry["APFSVolumeUUID"] as? String,
                    let name = entry["Name"] as? String,
                    let device = entry["DeviceIdentifier"] as? String
                else { continue }

                let roles = entry["Roles"] as? [String] ?? []
                if roles.contains(where: Self.hiddenRoles.contains) {
                    continue
                }

                let info = await Self.volumeInfo(for: device)
                if info.isDiskImage {
                    continue
                }

                let used = (entry["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                let quota = (entry["CapacityQuota"] as? NSNumber)?.int64Value

                volumes.append(APFSVolume(
                    id: uuid,
                    name: name,
                    deviceIdentifier: device,
                    mountPoint: info.mountPoint,
                    roles: roles,
                    capacityInUse: used,
                    capacityTotal: (quota ?? 0) > 0 ? quota : nil
                ))
            }
        }

        return volumes.sorted { lhs, rhs in
            if lhs.isMounted != rhs.isMounted { return lhs.isMounted }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private struct VolumeInfo {
        let mountPoint: String?
        let isDiskImage: Bool
    }

    private nonisolated static func volumeInfo(for device: String) async -> VolumeInfo {
        do {
            let data = try await ShellRunner.run(
                "/usr/sbin/diskutil",
                args: ["info", "-plist", device]
            )
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any] ?? [:]
            let mp = plist["MountPoint"] as? String ?? ""
            let busProtocol = plist["BusProtocol"] as? String ?? ""
            return VolumeInfo(
                mountPoint: mp.isEmpty ? nil : mp,
                isDiskImage: busProtocol == "Disk Image"
            )
        } catch {
            return VolumeInfo(mountPoint: nil, isDiskImage: false)
        }
    }
}
