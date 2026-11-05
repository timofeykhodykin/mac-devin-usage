import SwiftUI

struct MacDevinUsageApp: App {
    @StateObject private var store = UsageStore()

    init() {
        MenuBarClickFix.install()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Devin Usage Settings", id: "settings") {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
