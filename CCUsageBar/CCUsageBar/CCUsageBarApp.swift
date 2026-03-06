import SwiftUI

@main
struct CCUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window scenes — all UI is in the status bar popover.
        Settings { EmptyView() }
    }
}
