import Foundation
import SwiftUI

// When re-launched as a privileged helper (via osascript), perform the requested
// filesystem operation and exit before any UI / AppKit initialization.
HelperMode.dispatchIfNeeded()

SnapKeeperApp.main()
