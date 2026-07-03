import SwiftUI

/// The menu-bar dropdown. Compact status + primary actions; deep config in Settings.
struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            statusRows
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
        .padding(10)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.tint)
            Text("Copilot Bridge").font(.headline)
            Spacer()
            Circle().fill(proxyColor).frame(width: 8, height: 8)
        }
    }

    private var proxyColor: Color {
        switch state.proxyStatus {
        case .running: return .green
        case .stopped: return .secondary
        case .error: return .red
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("Endpoint", state.baseURLSummary)
            row("Proxy", proxyText)
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

    /// Only shown while signed out or mid-login. Once signed in, the header dot and
    /// proxy controls convey state — a "signed in" row would be redundant.
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
                .font(.caption)
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
            EmptyView()
        }
    }

    private var proxySection: some View {
        Group {
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

    /// Applied/available profiles, grouped under their client so each app is labeled.
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ClientKind.allCases) { client in
                let profiles = state.settings.profiles.filter { $0.client == client }
                if !profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(client.displayName, systemImage: client.icon)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(profiles) { profile in
                            profileRow(profile)
                        }
                    }
                }
            }
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: profile.applied ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(profile.applied ? .green : .secondary)
            Text(profile.model).font(.caption).lineLimit(1)
            Spacer()
            if profile.applied {
                Button("Revert") { state.unapplyProfile(profile) }
                    .buttonStyle(.borderless).font(.caption)
            } else {
                Button("Apply") { state.applyProfile(profile) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.leading, 4)
    }

    private var footer: some View {
        HStack {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
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
            Text(value).multilineTextAlignment(.trailing).lineLimit(1)
        }
    }
}
