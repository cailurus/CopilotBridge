import SwiftUI

/// Tabbed settings window: General (network/startup), Profiles (system config),
/// and Activity (usage dashboard). Tabs share consistent layout and width.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "person.2.badge.gearshape") }
            ActivityDashboardView(activity: state.activity)
                .tabItem { Label("Activity", systemImage: "chart.bar.xaxis") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Network") {
                LabeledContent("Port") {
                    TextField("Port", value: $state.settings.port,
                              format: .number.grouping(.never))
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Accessible from", selection: $state.settings.bindMode) {
                    ForEach(BindMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if state.settings.bindMode == .lan {
                    LabeledContent("Access key") {
                        HStack(spacing: 6) {
                            TextField("required for other devices", text: $state.settings.accessKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Button("Generate") {
                                state.settings.accessKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                                state.persist()
                            }
                        }
                    }
                    Text("Other devices connect to http://\(localIPAddress()):\(state.settings.port) and must send the access key. This Mac still connects with no key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Endpoints") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(state.baseURLSummary)/openai")
                        Text("\(state.baseURLSummary)/anthropic")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }

            Section("Startup") {
                Toggle("Start proxy automatically", isOn: $state.settings.autoStartProxy)
                Toggle("Launch at login", isOn: Binding(
                    get: { state.settings.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }))
            }

            Section("Proxy") {
                HStack {
                    statusLabel
                    Spacer()
                    Button("Restart") { state.restartProxy() }
                    switch state.proxyStatus {
                    case .running: Button("Stop") { state.stopProxy() }
                    default: Button("Start") { state.startProxy() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.settings.port) { _, _ in
            state.persist()
            if case .running = state.proxyStatus { state.restartProxy() }
        }
        .onChange(of: state.settings.bindMode) { _, _ in
            state.persist()
            if case .running = state.proxyStatus { state.restartProxy() }
        }
        .onChange(of: state.settings.accessKey) { _, _ in state.persist() }
        .onChange(of: state.settings.autoStartProxy) { _, _ in state.persist() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state.proxyStatus {
        case .running:
            Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped:
            Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary)
        case .error(let e):
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text("Copilot Bridge").font(.title2.bold())
            Text("v0.1.0").font(.caption).foregroundStyle(.secondary)
            Text("A local proxy for your GitHub Copilot subscription.")
                .foregroundStyle(.secondary)
            Text("Unofficial Copilot endpoints — for your own subscription.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
