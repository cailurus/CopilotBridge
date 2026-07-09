import AppKit
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
        .background(SettingsFocusGuard())
    }
}

private struct SettingsFocusGuard: NSViewRepresentable {
    final class Coordinator {
        var didClearInitialFocus = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard !context.coordinator.didClearInitialFocus else { return }
            guard let window = nsView.window else { return }
            if window.firstResponder is NSTextView {
                window.makeFirstResponder(window.contentView)
            }
            context.coordinator.didClearInitialFocus = true
        }
    }
}

struct SettingsPanel<Accessory: View, Content: View>: View {
    let title: String
    let systemImage: String?
    let accessory: Accessory
    let content: Content

    init(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) where Accessory == EmptyView {
        self.title = title
        self.systemImage = systemImage
        self.accessory = EmptyView()
        self.content = content()
    }

    init(
        _ title: String,
        systemImage: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label {
                    Text(title)
                } icon: {
                    if let systemImage {
                        Image(systemName: systemImage)
                    }
                }
                .font(.headline)
                Spacer()
                accessory
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focusedField: Field?
    @State private var portText: String = ""
    @State private var editingPort = false

    private enum Field: Hashable {
        case port
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPanel("Network") {
                settingRow("Port") {
                    portValue
                }

                settingRow("Host") {
                    Picker("Host", selection: Binding(
                        get: { state.settings.bindMode },
                        set: { state.setBindMode($0) })) {
                        ForEach(BindMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                if state.settings.bindMode == .lan {
                    settingRow("Access key") {
                        HStack(spacing: 8) {
                            TextField("required for other devices", text: $state.settings.accessKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                            Button("Generate") {
                                state.settings.accessKey = AppState.generateAccessKey()
                                state.persist()
                            }
                        }
                    }

                    HStack {
                        Spacer(minLength: 112)
                        if state.lanIsUnauthenticated {
                            Label(
                                "No access key set — any device on your network can use your Copilot through this proxy.",
                                systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Other devices connect to http://\(localIPAddress()):\(state.settings.port) and must send the access key. This Mac still connects with no key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                endpoints
            }

            SettingsPanel("Startup") {
                HStack(spacing: 24) {
                    Toggle("Start proxy automatically", isOn: $state.settings.autoStartProxy)
                    Toggle("Launch at login", isOn: Binding(
                        get: { state.settings.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }))
                    Spacer(minLength: 0)
                }
                .toggleStyle(.checkbox)
            }

            SettingsPanel("Proxy") {
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
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                if editingPort { commitPort() }
            }
        )
        .onAppear {
            syncPortText()
            clearInitialFocus()
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue == .port, newValue == nil { commitPort() }
        }
        .onChange(of: state.settings.port) { _, _ in
            syncPortText()
        }
        .onChange(of: state.settings.bindMode) { _, _ in
            if case .running = state.proxyStatus { state.restartProxy() }
        }
        .onChange(of: state.settings.accessKey) { _, _ in state.persist() }
        .onChange(of: state.settings.autoStartProxy) { _, _ in state.persist() }
    }

    @ViewBuilder
    private var portValue: some View {
        if editingPort {
            TextField("", text: $portText)
                .frame(width: 96)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .port)
                .onSubmit(commitPort)
                .onAppear { focusedField = .port }
        } else {
            HStack(spacing: 6) {
                Text(String(state.settings.port))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Button {
                    portText = String(state.settings.port)
                    DispatchQueue.main.async { editingPort = true }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Edit port")
                .accessibilityLabel("Edit port")
            }
        }
    }

    private func clearInitialFocus() {
        focusedField = nil
        DispatchQueue.main.async { focusedField = nil }
    }

    private func syncPortText() {
        if focusedField != .port {
            portText = String(state.settings.port)
        }
    }

    private func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            portText = String(state.settings.port)
            editingPort = false
            focusedField = nil
            return
        }
        if state.settings.port != port {
            state.settings.port = port
            state.persist()
            if case .running = state.proxyStatus { state.restartProxy() }
        }
        portText = String(state.settings.port)
        editingPort = false
        focusedField = nil
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Spacer(minLength: 16)
            value()
        }
    }

    private var endpoints: some View {
        settingRow("Endpoints") {
            VStack(alignment: .trailing, spacing: 5) {
                endpointRow("OpenAI", "\(state.baseURLSummary)/openai")
                endpointRow("Anthropic", "\(state.baseURLSummary)/anthropic")
            }
            .frame(maxWidth: 420, alignment: .trailing)
        }
    }

    private func endpointRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text("Copilot Bridge").font(.title2.bold())
            Text("v\(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
            Text("A local proxy for your GitHub Copilot subscription.")
                .foregroundStyle(.secondary)

            updateRow
                .padding(.top, 6)

            Text("Unofficial Copilot endpoints — for your own subscription.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding()
        .padding(.top, 60)
    }

    @ViewBuilder
    private var updateRow: some View {
        switch state.updateStatus {
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").font(.caption).foregroundStyle(.secondary)
            }
        case .available(let version, let url):
            VStack(spacing: 6) {
                Text("Version \(version) is available")
                    .font(.callout).foregroundStyle(.primary)
                Button("Download") {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .upToDate:
            HStack(spacing: 6) {
                Text("You're up to date.").font(.caption).foregroundStyle(.secondary)
                Button("Check again") { state.checkForUpdates() }
                    .buttonStyle(.link).font(.caption)
            }
        case .failed(let message):
            VStack(spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { state.checkForUpdates() }
                    .buttonStyle(.link).font(.caption)
            }
        case .idle:
            Button("Check for Updates") { state.checkForUpdates() }
                .buttonStyle(.bordered)
        }
    }
}
