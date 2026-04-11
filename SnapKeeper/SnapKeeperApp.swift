import SwiftUI

@main
struct SnapKeeperApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 820, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Snapshot…") {
                    state.isPresentingCreatePrompt = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(state.selectedVolume == nil)
            }
        }
    }
}
