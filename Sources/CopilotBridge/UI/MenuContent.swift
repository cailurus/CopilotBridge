import SwiftUI

/// The menu-bar dropdown. Compact status + primary actions; deep config in Settings.
struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var copiedLoginCode = false
    @State private var pulseStatusLight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            statusRows
            if case .signedIn = state.loginStatus {
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
            headerProxyControl
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
        .font(.system(size: 13))
    }

    private var proxyText: String {
        switch state.proxyStatus {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .error(let e): return "Error: \(e.prefix(40))"
        }
    }

    @ViewBuilder
    private var headerProxyControl: some View {
        if case .signedIn = state.loginStatus {
            Button {
                switch state.proxyStatus {
                case .running:
                    state.stopProxy()
                case .stopped, .error:
                    state.startProxy()
                }
            } label: {
                Image(systemName: proxyControlSymbol)
            }
            .buttonStyle(.borderless)
            .help(proxyControlLabel)
            .accessibilityLabel(proxyControlLabel)
        }
    }

    private var proxyControlSymbol: String {
        switch state.proxyStatus {
        case .running: return "pause.circle.fill"
        case .stopped, .error: return "play.circle.fill"
        }
    }

    private var proxyControlLabel: String {
        switch state.proxyStatus {
        case .running: return "Stop proxy"
        case .stopped, .error: return "Start proxy"
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
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).font(.caption).lineLimit(1)
                Text(profile.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if profile.applied {
                Button("Revert") { state.unapplyProfile(profile) }
                    .buttonStyle(.borderless).font(.caption)
            } else {
                Button("Apply") {
                    state.applyProfile(profile)
                    // The menu is a popover and can't host the migration sheet, so
                    // surface it in the Preferences window instead.
                    if state.pendingMigration != nil {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "preferences")
                    }
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.leading, 4)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            authFooterControl
            Spacer()
            HStack(spacing: 2) {
                footerIconButton("gearshape", label: "Settings") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "preferences")
                }
                footerIconButton("power", label: "Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(height: 30)
    }

    private func footerIconButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var authFooterControl: some View {
        switch state.loginStatus {
        case .signedOut:
            Button {
                state.startLogin()
            } label: {
                Label("Sign in to GitHub", systemImage: "person.crop.circle.badge.plus")
            }
            .frame(height: 30)
        case .checking:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                Text("Checking login…")
            }
            .frame(height: 30)
                .foregroundStyle(.secondary)
        case .pending(let code, let url):
            pendingLoginControl(code: code, url: url)
        case .signedIn:
            Button {
                state.signOut()
            } label: {
                Label("Sign out of GitHub", systemImage: "person.crop.circle.badge.minus")
            }
            .frame(height: 30)
        }
    }

    private func pendingLoginControl(code: String, url: String) -> some View {
        HStack(spacing: 6) {
            Text("Code")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
            Button {
                copyLoginCode(code)
            } label: {
                Image(systemName: copiedLoginCode ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copiedLoginCode ? .green : .secondary)
            .help(copiedLoginCode ? "Copied" : "Copy code")
            .accessibilityLabel(copiedLoginCode ? "Copied" : "Copy code")
        }
        .help("Enter this code at \(url)")
    }

    private func copyLoginCode(_ code: String) {
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(code, forType: .string)
        copiedLoginCode = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copiedLoginCode = false
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.primary)
            Spacer()
            if label == "Proxy" {
                HStack(spacing: 6) {
                    breathingStatusLight
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
            }
        }
    }

    private var breathingStatusLight: some View {
        Circle()
            .fill(proxyColor)
            .frame(width: 8, height: 8)
            .scaleEffect(pulseStatusLight ? 1.18 : 0.82)
            .opacity(pulseStatusLight ? 0.55 : 1)
            .animation(
                .easeInOut(duration: 1.25).repeatForever(autoreverses: true),
                value: pulseStatusLight
            )
            .onAppear { pulseStatusLight = true }
    }
}
