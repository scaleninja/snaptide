import SwiftUI

struct SnapshotDetailView: View {
    @Bindable var state: AppState
    @State private var selection = Set<APFSSnapshot.ID>()
    @State private var confirmingDelete = false
    @State private var newSnapshotName = ""
    @FocusState private var newSnapshotNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Table(state.snapshots, selection: $selection) {
                TableColumn("Name") { snap in
                    Text(snap.name)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(snap.name)
                }
                TableColumn("Date Created") { snap in
                    if let date = snap.createdAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 160, ideal: 180)
                TableColumn("Size") { _ in
                    Text("—").foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Kind") { snap in
                    Text(snap.kind.rawValue)
                }
                .width(min: 100, ideal: 120)
            }
            .contextMenu(forSelectionType: APFSSnapshot.ID.self) { ids in
                if !ids.isEmpty {
                    Button("Delete \(ids.count == 1 ? "Snapshot" : "Snapshots")", role: .destructive) {
                        selection = ids
                        confirmingDelete = true
                    }
                }
            }
            .overlay { tableOverlay }

            Divider()
            StatusBar(
                count: state.snapshots.count,
                selectedCount: selection.count,
                volume: state.selectedVolume,
                isWorking: state.isWorking || state.isLoadingSnapshots
            )
        }
        .navigationTitle(state.selectedVolume?.name ?? "Snapshots")
        .navigationSubtitle(state.selectedVolume?.deviceIdentifier ?? "")
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Delete \(selection.count) snapshot\(selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = selection
                Task {
                    await state.deleteSnapshots(ids)
                    selection.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Time Machine snapshots are removed via tmutil; other snapshots require an administrator password.")
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .sheet(isPresented: $state.isPresentingCreatePrompt) {
            CreateSnapshotSheet(
                name: $newSnapshotName,
                focused: $newSnapshotNameFocused,
                volumeName: state.selectedVolume?.name ?? ""
            ) {
                let name = newSnapshotName
                newSnapshotName = ""
                state.isPresentingCreatePrompt = false
                Task { await state.createSnapshot(named: name) }
            } cancel: {
                newSnapshotName = ""
                state.isPresentingCreatePrompt = false
            }
            .onAppear { newSnapshotNameFocused = true }
        }
    }

    private func presentCreatePrompt() {
        newSnapshotName = ""
        state.isPresentingCreatePrompt = true
    }

    @ViewBuilder
    private var tableOverlay: some View {
        if state.isLoadingSnapshots {
            ProgressView().controlSize(.small)
        } else if state.selectedVolume == nil {
            ContentUnavailableView(
                "Select a Volume",
                systemImage: "sidebar.left",
                description: Text("Choose an APFS volume from the sidebar.")
            )
        } else if state.snapshots.isEmpty {
            ContentUnavailableView(
                "No Snapshots",
                systemImage: "camera",
                description: Text("This volume has no APFS snapshots.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                presentCreatePrompt()
            } label: {
                Label("Create Snapshot", systemImage: "camera.badge.ellipsis")
            }
            .help("Create a new APFS snapshot on this volume")
            .disabled(state.selectedVolume == nil || state.isWorking)
        }
        ToolbarItem {
            Button {
                confirmingDelete = true
            } label: {
                Label("Delete Snapshot", systemImage: "trash")
            }
            .help("Delete the selected snapshot(s)")
            .disabled(selection.isEmpty || state.isWorking)
        }
        ToolbarItem {
            Button {
                Task { await state.refreshSnapshots() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh snapshots for this volume")
            .disabled(state.selectedVolume == nil || state.isLoadingSnapshots)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )
    }
}

private struct CreateSnapshotSheet: View {
    @Binding var name: String
    var focused: FocusState<Bool>.Binding
    let volumeName: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Snapshot")
                .font(.headline)
            Text("Creates an APFS snapshot on \(volumeName.isEmpty ? "the selected volume" : "“\(volumeName)”").")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Snapshot name (leave blank for an automatic Time Machine snapshot)", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .onSubmit(confirm)

            Text("Named snapshots are created with fs_snapshot_create(2) and require your administrator password. Leaving the name blank uses tmutil and needs no password.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

private struct StatusBar: View {
    let count: Int
    let selectedCount: Int
    let volume: APFSVolume?
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView().controlSize(.mini)
            }
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let volume {
                Text(volume.deviceIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 24)
        .background(.bar)
    }

    private var countText: String {
        let base = "\(count) snapshot\(count == 1 ? "" : "s")"
        if selectedCount > 0 {
            return "\(base) · \(selectedCount) selected"
        }
        return base
    }
}
