import SwiftUI

/// The menu-bar dropdown. Compact status + primary actions; deep config in Settings.
struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusRows
            Divider()
            authSection
            if case .signedIn = state.loginStatus {
                Divider()
                proxySection
                if !state.settings.profiles.isEmpty {
                    Divider()
                    profileSection
                }
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.tint)
            Text("Copilot Bridge").font(.headline)
            Spacer()
            statusDot
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(proxyColor)
            .frame(width: 10, height: 10)
    }

    private var proxyColor: Color {
        switch state.proxyStatus {
        case .running: return .green
        case .stopped: return .secondary
        case .error: return .red
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Endpoint", state.baseURLSummary)
            row("Proxy", proxyText)
            row("Activity", state.lastActivity)
                .lineLimit(1)
        }
        .font(.caption)
    }

    private var proxyText: String {
        switch state.proxyStatus {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .error(let e): return "Error: \(e.prefix(40))"
        }
    }

    @ViewBuilder
    private var authSection: some View {
        switch state.loginStatus {
        case .signedOut:
            Button {
                state.startLogin()
            } label: {
                Label("Sign in to GitHub", systemImage: "person.crop.circle.badge.plus")
            }
        case .checking:
            Label("Checking login…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .pending(let code, let url):
            VStack(alignment: .leading, spacing: 4) {
                Text("Enter this code at \(url):").font(.caption)
                HStack {
                    Text(code).font(.title3.monospaced().bold())
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
        case .signedIn:
            Label("Signed in to GitHub", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state.proxyStatus {
            case .running:
                Button {
                    state.stopProxy()
                } label: {
                    Label("Stop proxy", systemImage: "stop.circle")
                }
            default:
                Button {
                    state.startProxy()
                } label: {
                    Label("Start proxy", systemImage: "play.circle")
                }
            }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles").font(.caption).foregroundStyle(.secondary)
            ForEach(state.settings.profiles) { profile in
                HStack {
                    Image(systemName: profile.applied ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(profile.applied ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(profile.name).font(.caption).lineLimit(1)
                        Text(profile.model).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if profile.applied {
                        Button("Revert") { state.unapplyProfile(profile) }
                            .buttonStyle(.borderless).font(.caption)
                    } else {
                        Button("Apply") { state.applyProfile(profile) }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
