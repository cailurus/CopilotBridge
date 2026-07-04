import SwiftUI

/// Manage system-level profiles, grouped by client. Each client (Codex, Codex CLI,
/// Claude Code) can have its own profiles; applying one writes that client's config
/// file. Only one profile per client is active at a time.
///
/// Uses compact profile sections plus a single model-refresh row so the tab reads
/// like a settings panel instead of a long form.
struct ProfilesSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showingAdd = false
    @State private var showingModels = false
    @State private var isRefreshingModels = false
    @State private var modelRefreshMessage: String?
    @State private var addClient: ClientKind = .codexCLI

    var body: some View {
        Group {
            if state.loginStatus != .signedIn {
                signInPrompt
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(ClientKind.allCases) { client in
                                ClientSection(client: client) { addClient = client; showingAdd = true }
                            }
                            modelRefreshRow
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddProfileSheet(initialClient: addClient)
                .environmentObject(state)
        }
        .sheet(isPresented: $showingModels) {
            ModelListSheet(models: state.availableModels)
        }
        .sheet(item: $state.pendingMigration) { prompt in
            MigrationPromptSheet(prompt: prompt)
                .environmentObject(state)
        }
    }

    private var modelRefreshRow: some View {
        SettingsPanel("Models", systemImage: "cube.box") {
            HStack(spacing: 10) {
                Button {
                    refreshModels()
                } label: {
                    HStack(spacing: 8) {
                        if isRefreshingModels {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRefreshingModels ? "Refreshing model list" : "Refresh model list")
                    }
                }
                .disabled(isRefreshingModels)

                Spacer()

                Text(modelStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showingModels = true
                } label: {
                    Image(systemName: "info.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show model details")
                .disabled(state.availableModels.isEmpty)
            }
        }
    }

    private var modelStatusText: String {
        modelRefreshMessage ?? "\(state.availableModels.count) Copilot models available"
    }

    private func refreshModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        modelRefreshMessage = nil
        Task {
            let start = ContinuousClock.now
            do {
                try await state.forceRefreshModels()
                let elapsed = start.duration(to: .now)
                try? await Task.sleep(for: max(.zero, .milliseconds(800) - elapsed))
                await MainActor.run {
                    modelRefreshMessage = "\(state.availableModels.count) models refreshed in \(formatDuration(elapsed))"
                    isRefreshingModels = false
                }
            } catch {
                let elapsed = start.duration(to: .now)
                try? await Task.sleep(for: max(.zero, .milliseconds(800) - elapsed))
                await MainActor.run {
                    modelRefreshMessage = error.localizedDescription
                    isRefreshingModels = false
                }
            }
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.1fs", seconds)
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

struct ModelListSheet: View {
    let models: [CopilotUpstream.ModelInfo]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Available models")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            List {
                ForEach(groupedModels, id: \.family) { group in
                    Section(group.family) {
                        ForEach(group.models, id: \.id) { model in
                            modelRow(model)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(18)
        .frame(width: 560, height: 460)
    }

    private var groupedModels: [(family: String, models: [CopilotUpstream.ModelInfo])] {
        var buckets: [String: [CopilotUpstream.ModelInfo]] = [:]
        for model in models {
            buckets[ModelFamily.family(of: model), default: []].append(model)
        }
        return ModelFamily.order.compactMap { family in
            guard let models = buckets[family], !models.isEmpty else { return nil }
            return (family, models.sorted { $0.displayID < $1.displayID })
        }
    }

    private func modelRow(_ model: CopilotUpstream.ModelInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayID)
                    .font(.body.monospaced())
                    .lineLimit(1)
                if let name = model.name, name != model.displayID {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let ctx = formatContextWindow(model.contextWindow) {
                Text(ctx)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if model.supportsMessages {
                Text("Messages")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.supportsResponses {
                Text("Responses")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One panel per client, listing its profiles with an inline add button in the header.
struct ClientSection: View {
    @EnvironmentObject var state: AppState
    let client: ClientKind
    let onAdd: () -> Void

    private var profiles: [Profile] {
        state.settings.profiles.filter { $0.client == client }
    }

    var body: some View {
        SettingsPanel(client.displayName, systemImage: client.icon) {
            addButton
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if profiles.isEmpty {
                    Text("No profiles yet — add one to use \(client.displayName) through Copilot Bridge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                } else {
                    VStack(spacing: 6) {
                        ForEach(profiles) { profile in
                            ProfileRow(profile: profile)
                        }
                    }
                }
            }
        }
    }

    private var addButton: some View {
        Button {
            onAdd()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help("Add profile")
        .accessibilityLabel("Add profile")
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

    let client: ClientKind
    @State private var model: String = ""
    @State private var name: String = ""

    init(initialClient: ClientKind) {
        self.client = initialClient
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                Picker("Model", selection: $model) {
                    Text("Select a model").tag("")
                    ForEach(groupedModels, id: \.family) { group in
                        Section(group.family) {
                            ForEach(group.models, id: \.id) { m in
                                Text(modelLabel(m)).tag(m.displayID)
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
                    let selected = CopilotModelID.model(matching: model, in: state.availableModels)
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
    }

    private var defaultName: String {
        Profile.defaultName(for: client, model: model.isEmpty ? "model" : model)
    }

    /// Groups models by family for the picker. Every client can choose any Copilot
    /// model; the selected client only controls which config file the profile writes.
    private var groupedModels: [(family: String, models: [CopilotUpstream.ModelInfo])] {
        var buckets: [String: [CopilotUpstream.ModelInfo]] = [:]
        for m in state.availableModels {
            buckets[ModelFamily.family(of: m), default: []].append(m)
        }
        return ModelFamily.order.compactMap { key in
            guard let models = buckets[key], !models.isEmpty else { return nil }
            return (key, models.sorted { $0.id < $1.id })
        }
    }

    private func modelLabel(_ m: CopilotUpstream.ModelInfo) -> String {
        let title = m.name.map { "\($0) (\(m.displayID))" } ?? m.displayID
        if let ctx = formatContextWindow(m.contextWindow) {
            return "\(title)  ·  \(ctx)"
        }
        return title
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

/// Prompt shown after applying a Codex profile when prior conversations used another
/// provider. Codex groups its history by provider, so migrating relabels those threads
/// to Copilot Bridge; skipping leaves them in place (still reachable by switching back).
struct MigrationPromptSheet: View {
    @EnvironmentObject var state: AppState

    let prompt: MigrationPrompt
    @State private var selected: Set<String>

    init(prompt: MigrationPrompt) {
        self.prompt = prompt
        _selected = State(initialValue: Set(prompt.providers.map(\.provider)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bring your Codex history along?").font(.title3.bold())

            Text("Codex groups its conversation list by model provider. Your earlier chats "
                 + "are still saved, but Codex only shows the ones matching the active provider. "
                 + "Migrate them to Copilot Bridge to keep them visible.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(prompt.providers, id: \.provider) { entry in
                    Toggle(isOn: binding(for: entry.provider)) {
                        HStack(spacing: 8) {
                            Text(entry.provider).font(.body.monospaced())
                            Text("\(entry.count)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(entry.count == 1 ? "conversation" : "conversations")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if let message = prompt.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Leave them") { state.dismissMigration() }
                Button(migrateLabel) { state.confirmMigration(providers: Array(selected)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var migrateLabel: String {
        let total = prompt.providers
            .filter { selected.contains($0.provider) }
            .reduce(0) { $0 + $1.count }
        return total > 0 ? "Migrate \(total)" : "Migrate"
    }

    private func binding(for provider: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(provider) },
            set: { isOn in
                if isOn { selected.insert(provider) } else { selected.remove(provider) }
            }
        )
    }
}
