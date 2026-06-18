import SwiftUI

@main
struct PinmageApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark) // Enforce premium dark mode
        }
        .windowStyle(.hiddenTitleBar) // Unified modern title bar
        .windowToolbarStyle(.unifiedCompact)
    }
}
