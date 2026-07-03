import SwiftUI

/// Manage system-level profiles, grouped by client. Each client (Codex, Codex CLI,
/// Claude Code) can have its own profiles; applying one writes that client's config
/// file. Only one profile per client is active at a time.
///
/// Uses the same Form/.formStyle(.grouped) container as General so both Settings
/// tabs share one consistent width and layout.
struct ProfilesSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showingAdd = false
    @State private var addClient: ClientKind = .codexCLI

    var body: some View {
        Group {
            if state.loginStatus != .signedIn {
                signInPrompt
            } else {
                Form {
                    ForEach(ClientKind.allCases) { client in
                        ClientSection(client: client) { addClient = client; showingAdd = true }
                    }

                    Section {
                        Button {
                            Task { await state.refreshModels() }
                        } label: {
                            Label("Refresh model list", systemImage: "arrow.clockwise")
                        }
                    } footer: {
                        Text("\(state.availableModels.count) Copilot models available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddProfileSheet(initialClient: addClient)
                .environmentObject(state)
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Sign in first").font(.headline)
            Text("Sign in to GitHub from the menu bar to load Copilot models.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// One Section per client, listing its profiles with an inline add button in the header.
struct ClientSection: View {
    @EnvironmentObject var state: AppState
    let client: ClientKind
    let onAdd: () -> Void

    private var profiles: [Profile] {
        state.settings.profiles.filter { $0.client == client }
    }

    var body: some View {
        Section {
            if profiles.isEmpty {
                Text("No profiles yet — add one to use \(client.displayName) through Copilot Bridge.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(profiles) { profile in
                    ProfileRow(profile: profile)
                }
            }
        } header: {
            HStack {
                Label(client.displayName, systemImage: client.icon)
                Spacer()
                Button {
                    onAdd()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct ProfileRow: View {
    @EnvironmentObject var state: AppState
    let profile: Profile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.applied ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.applied ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body)
                HStack(spacing: 6) {
                    Text(profile.model).font(.caption).foregroundStyle(.secondary)
                    if let ctx = formatContextWindow(profile.contextWindow) {
                        Text(ctx)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            Spacer()
            if profile.applied {
                Button("Revert") { state.unapplyProfile(profile) }
                    .buttonStyle(.bordered)
            } else {
                Button("Apply") { state.applyProfile(profile) }
                    .buttonStyle(.borderedProminent)
            }
            Button(role: .destructive) {
                state.removeProfile(profile)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct AddProfileSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var client: ClientKind
    @State private var model: String = ""
    @State private var name: String = ""

    init(initialClient: ClientKind) {
        _client = State(initialValue: initialClient)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Client").font(.caption).foregroundStyle(.secondary)
                Picker("Client", selection: $client) {
                    ForEach(ClientKind.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                Picker("Model", selection: $model) {
                    Text("Select a model").tag("")
                    ForEach(groupedModels, id: \.family) { group in
                        Section(group.family) {
                            ForEach(group.models, id: \.id) { m in
                                Text(modelLabel(m)).tag(m.id)
                            }
                        }
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField(defaultName, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Label(hint, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let selected = state.availableModels.first { $0.id == model }
                    let finalName = name.isEmpty ? defaultName : name
                    let profile = Profile(name: finalName, client: client, model: model,
                                          contextWindow: selected?.contextWindow)
                    state.addProfile(profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: client) { _, _ in
            if !filteredModels.contains(where: { $0.id == model }) { model = "" }
        }
    }

    private var defaultName: String {
        Profile.defaultName(for: client, model: model.isEmpty ? "model" : model)
    }

    private var filteredModels: [CopilotUpstream.ModelInfo] {
        let models = state.availableModels
        switch client {
        case .claudeCode:
            let claude = models.filter { $0.id.contains("claude") }
            return claude.isEmpty ? models : claude
        case .codex, .codexCLI:
            return models
        }
    }

    /// Groups models by family (claude / gpt / gemini / o-series / other) for the picker.
    private var groupedModels: [(family: String, models: [CopilotUpstream.ModelInfo])] {
        var buckets: [String: [CopilotUpstream.ModelInfo]] = [:]
        for m in filteredModels {
            buckets[Self.family(of: m.id), default: []].append(m)
        }
        let order = ["Claude", "GPT", "o-series", "Gemini", "Other"]
        return order.compactMap { key in
            guard let models = buckets[key], !models.isEmpty else { return nil }
            return (key, models.sorted { $0.id < $1.id })
        }
    }

    private static func family(of id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("claude") { return "Claude" }
        if lower.contains("gemini") { return "Gemini" }
        if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") { return "o-series" }
        if lower.contains("gpt") || lower.hasPrefix("mai-") { return "GPT" }
        return "Other"
    }

    private func modelLabel(_ m: CopilotUpstream.ModelInfo) -> String {
        if let ctx = formatContextWindow(m.contextWindow) {
            return "\(m.id)  ·  \(ctx)"
        }
        return m.id
    }

    private var hint: String {
        switch client {
        case .codex, .codexCLI:
            return "Writes a managed provider block to ~/.codex/config.toml (wire_api = responses)."
        case .claudeCode:
            return "Writes ANTHROPIC_BASE_URL + model into ~/.claude/settings.json."
        }
    }
}
