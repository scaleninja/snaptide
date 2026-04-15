import SwiftUI

struct SnapshotDetailView: View {
    @Bindable var state: AppState
    @State private var selection = Set<APFSSnapshot.ID>()
    @State private var confirmingDelete = false
    @State private var newSnapshotName = ""
    @FocusState private var newSnapshotNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let volume = state.selectedVolume {
                VolumeInfoHeader(volume: volume)
                Divider()
            }

            Table(state.snapshots, selection: $selection) {
                TableColumn("Name") { snap in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snap.effectiveName)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if snap.hasAlias {
                            Text(snap.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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
                TableColumn("Size") { snap in
                    if let bytes = snap.privateSize {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .foregroundStyle(bytes > 0 ? .primary : .secondary)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 90)
                TableColumn("Kind") { snap in
                    Text(snap.kind.rawValue)
                }
                .width(min: 100, ideal: 120)
                TableColumn("") { snap in
                    let mounted = state.isMounted(snap)
                    Button {
                        Task { await state.toggleMount(snap) }
                    } label: {
                        Image(systemName: mounted ? "eject.circle.fill" : "externaldrive")
                            .foregroundStyle(mounted ? .accent : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.isWorking)
                    .help(mounted ? "Eject (unmount) snapshot" : "Mount snapshot read-only")
                }
                .width(28)
            }
            .contextMenu(forSelectionType: APFSSnapshot.ID.self) { ids in
                if ids.count == 1,
                   let id = ids.first,
                   let snap = state.snapshots.first(where: { $0.id == id }) {
                    let mounted = state.isMounted(snap)
                    Button(mounted ? "Eject Snapshot" : "Mount Snapshot") {
                        Task { await state.toggleMount(snap) }
                    }
                    .disabled(state.isWorking)
                    if mounted {
                        Button("Reveal in Finder") {
                            state.revealSnapshotInFinder(snap)
                        }
                    }
                    Divider()
                }
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
            Text("This cannot be undone. SnapTide snapshots are removed via fs_snapshot_delete. Time Machine snapshots are removed via tmutil.")
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

// MARK: - Volume Info Header

private struct VolumeInfoHeader: View {
    let volume: APFSVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            capacityBar
            metadataGrid
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background)
    }

    // MARK: Capacity bar

    @ViewBuilder
    private var capacityBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: 10)
                    if let fraction = usedFraction {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor)
                            .frame(width: max(8, geo.size.width * fraction), height: 10)
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 0) {
                Text(usedLabel)
                    .foregroundStyle(.primary)
                if let available = availableLabel {
                    Text(" · \(available) available")
                        .foregroundStyle(.secondary)
                }
                if let total = totalLabel {
                    Text(" · \(total) total")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)
        }
    }

    // MARK: Metadata grid

    private var metadataGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                metaLabel("Mount Point")
                metaValue(volume.mountPoint ?? "Not mounted")
                metaLabel("Device")
                metaValue(volume.deviceIdentifier)
            }
            GridRow {
                metaLabel("Connection")
                metaValue(volume.connection ?? "Internal")
                metaLabel("Role")
                metaValue(volume.primaryRole)
            }
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .gridColumnAlignment(.leading)
    }

    // MARK: Helpers

    private var usedFraction: Double? {
        guard let total = volume.capacityTotal, total > 0 else { return nil }
        return min(1.0, Double(volume.capacityInUse) / Double(total))
    }

    private var barColor: Color {
        let fraction = usedFraction ?? 0
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return .accentColor
    }

    private var usedLabel: String {
        ByteCountFormatter.string(fromByteCount: volume.capacityInUse, countStyle: .file) + " used"
    }

    private var availableLabel: String? {
        guard let total = volume.capacityTotal, total > 0 else { return nil }
        let free = total - volume.capacityInUse
        return ByteCountFormatter.string(fromByteCount: max(0, free), countStyle: .file)
    }

    private var totalLabel: String? {
        guard let total = volume.capacityTotal, total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Create Snapshot Sheet

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
            Text("Creates an APFS snapshot on \(volumeName.isEmpty ? "the selected volume" : "\u{201C}\(volumeName)\u{201D}").")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Snapshot name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .onSubmit(confirm)

            Text("The snapshot is named com.scaleninja.SnapTide.<date> on disk. Anything you type here is saved as a nickname inside SnapTide and shown alongside the real name — it is not written to APFS.")
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

// MARK: - Status Bar

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
