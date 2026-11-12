import SwiftUI

@main
struct ProxyBarApp: App {
    // A plain `let` instead of @State: SwiftUI's @State macro needs Xcode's
    // macro plugins, and this project builds with Command Line Tools only.
    // The App struct is created once, so the store lives for the whole run.
    private let store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Image(systemName: store.proxyState == .down ? "network.slash" : "network")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
