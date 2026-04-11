import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var volumes: [APFSVolume] = []
    var snapshots: [APFSSnapshot] = []
    var selectedVolumeID: APFSVolume.ID?
    var isLoadingVolumes = false
    var isLoadingSnapshots = false
    var isWorking = false
    var errorMessage: String?
    var isPresentingCreatePrompt = false

    private let volumeService = VolumeService()
    private let snapshotService = SnapshotService()

    var selectedVolume: APFSVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    func refreshVolumes() async {
        isLoadingVolumes = true
        defer { isLoadingVolumes = false }
        do {
            let list = try await volumeService.listVolumes()
            volumes = list
            if selectedVolumeID == nil || !list.contains(where: { $0.id == selectedVolumeID }) {
                selectedVolumeID = list.first(where: \.isMounted)?.id ?? list.first?.id
            }
            await refreshSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSnapshots() async {
        guard let volume = selectedVolume, let mountPoint = volume.mountPoint, !mountPoint.isEmpty else {
            snapshots = []
            return
        }
        isLoadingSnapshots = true
        defer { isLoadingSnapshots = false }
        do {
            snapshots = try await snapshotService.listSnapshots(forVolumeAt: mountPoint)
        } catch {
            errorMessage = error.localizedDescription
            snapshots = []
        }
    }

    /// Calls `fs_snapshot_create(2)` on the currently-selected volume. Without
    /// the `com.apple.developer.vfs.snapshot` entitlement this will surface
    /// an `EPERM` error via `SnapshotAPIError` — that's the demonstrable
    /// failure the DTS entitlement request needs.
    func createSnapshot(named rawName: String?) async {
        guard let volume = selectedVolume,
              let mountPoint = volume.mountPoint, !mountPoint.isEmpty else {
            errorMessage = "Select a mounted APFS volume first."
            return
        }
        let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a name for the snapshot."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await snapshotService.createSnapshot(named: trimmed, onVolumeAt: mountPoint)
            await refreshSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSnapshots(_ ids: Set<APFSSnapshot.ID>) async {
        guard let volume = selectedVolume,
              let mountPoint = volume.mountPoint, !mountPoint.isEmpty else { return }
        let targets = snapshots.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        for snap in targets {
            do {
                try await snapshotService.deleteSnapshot(named: snap.name, onVolumeAt: mountPoint)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        await refreshSnapshots()
    }
}
