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

        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(minWidth: 560, idealWidth: 580, minHeight: 540, idealHeight: 600)
        }
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
