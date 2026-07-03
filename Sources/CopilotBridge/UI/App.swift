import SwiftUI

@main
struct CopilotBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel("Copilot Bridge")
        }
        .menuBarExtraStyle(.window)

        Window("Preferences", id: "preferences") {
            SettingsView()
                .environmentObject(state)
                .frame(width: 620, height: 520)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentSize)
    }

    private var menuBarSymbol: String {
        switch state.proxyStatus {
        case .running: return "bolt.horizontal.circle.fill"
        case .stopped: return "bolt.horizontal.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

/// Keeps the app as a menu-bar accessory (no Dock icon) and starts services.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.onLaunch()
    }
}
