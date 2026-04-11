import SwiftUI

struct VolumeSidebar: View {
    @Bindable var state: AppState

    var body: some View {
        List(selection: $state.selectedVolumeID) {
            Section("APFS Volumes") {
                ForEach(state.volumes) { volume in
                    VolumeRow(volume: volume)
                        .tag(Optional(volume.id))
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if state.volumes.isEmpty {
                if state.isLoadingVolumes {
                    ProgressView("Loading volumes…")
                } else {
                    ContentUnavailableView(
                        "No APFS Volumes",
                        systemImage: "externaldrive",
                        description: Text("Click refresh to try again.")
                    )
                }
            }
        }
        .onChange(of: state.selectedVolumeID) { _, _ in
            Task { await state.refreshSnapshots() }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await state.refreshVolumes() }
                } label: {
                    Label("Refresh Volumes", systemImage: "arrow.clockwise")
                }
                .help("Refresh APFS volume list")
                .disabled(state.isLoadingVolumes)
            }
        }
        .navigationTitle("SnapTide")
    }
}

private struct VolumeRow: View {
    let volume: APFSVolume

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(volume.isMounted
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(volume.deviceIdentifier)
                    if !volume.isMounted {
                        Text("• Unmounted")
                    } else {
                        Text("• \(ByteCountFormatter.string(fromByteCount: volume.capacityInUse, countStyle: .file))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch volume.primaryRole {
        case "System": return "macwindow"
        case "Data": return "internaldrive"
        case "Recovery": return "lifepreserver"
        case "Preboot": return "bolt.horizontal"
        case "VM": return "memorychip"
        case "Update": return "arrow.triangle.2.circlepath"
        default: return "externaldrive"
        }
    }
}
