import SwiftUI

@main
struct PinmageApp: App {
    @StateObject private var updates = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(updates)
                .preferredColorScheme(.dark) // Enforce premium dark mode
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates") {
                    Task { await updates.check(manual: true) }
                }
                .disabled(updates.isChecking)
            }
        }
        .windowStyle(.hiddenTitleBar) // Unified modern title bar
        .windowToolbarStyle(.unifiedCompact)
    }
}
