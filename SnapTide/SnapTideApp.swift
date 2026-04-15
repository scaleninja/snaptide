import Security
import SwiftUI

@main
struct SnapTideApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 820, minHeight: 480)
                .onAppear { Self.logSnapshotEntitlements() }
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

    /// Prints to Xcode's console at launch so you can confirm whether
    /// the ad-hoc re-sign (scheme Run pre-action) embedded the private
    /// snapshot entitlement in the Mach-O code blob.
    ///
    /// Expected output after successful re-sign:
    ///   [SnapTide] com.apple.developer.vfs.snapshot  ✓
    ///   [SnapTide] com.apple.private.vfs.snapshot    ✓  ← fs_snapshot_create will work
    ///
    /// If the private line shows ✗, the pre-action didn't run or didn't stick.
    /// Steps to fix: Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Pre-actions
    /// and confirm the codesign script is present with "SnapTide" as the
    /// build-settings provider. Then close and reopen the project so Xcode
    /// loads the shared scheme from xcshareddata/xcschemes/SnapTide.xcscheme.
    private static func logSnapshotEntitlements() {
        let keys = [
            "com.apple.developer.vfs.snapshot",
            "com.apple.private.vfs.snapshot",
        ]
        guard let task = SecTaskCreateFromSelf(nil) else {
            print("[SnapTide] SecTaskCreateFromSelf returned nil")
            return
        }
        for key in keys {
            var cfErr: Unmanaged<CFError>?
            let value = SecTaskCopyValueForEntitlement(task, key as CFString, &cfErr)
            let mark = value != nil ? "✓" : "✗"
            print("[SnapTide] \(key.padding(toLength: 46, withPad: " ", startingAt: 0)) \(mark)")
        }
    }
}
