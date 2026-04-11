import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            VolumeSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            SnapshotDetailView(state: state)
        }
        .task {
            if state.volumes.isEmpty {
                await state.refreshVolumes()
            }
        }
    }
}

#Preview {
    ContentView(state: AppState())
        .frame(width: 900, height: 520)
}
