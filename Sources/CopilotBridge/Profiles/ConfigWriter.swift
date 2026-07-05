import Foundation

/// Applies a Profile to the client's system-level config file, and reverts it.
/// Ports the write logic of copilot-reverse + agent-maestro.
enum ConfigWriter {
    static let providerID = "copilot-bridge"

    /// Overridable home root (tests point this at a temp dir). Defaults to the real home.
    nonisolated(unsafe) static var homeOverride: URL?
    static var home: URL {
        homeOverride ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
    static let oneMSuffix = "[1m]"

    /// Directory where we keep timestamped backups of any config file we modify.
    static var backupDirectory: URL {
        home.appendingPathComponent("Library/Application Support/CopilotBridge/backups", isDirectory: true)
    }

    /// Snapshots an existing file to the backup directory before we overwrite it.
    /// No-op if the file doesn't exist yet. Best-effort; never throws.
    static func backup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(url.lastPathComponent).\(stamp).bak"
        try? FileManager.default.copyItem(at: url, to: backupDirectory.appendingPathComponent(name))
        // Keep only the newest 20 backups per filename.
        pruneBackups(for: url.lastPathComponent, keep: 20)
    }

    private static func pruneBackups(for filename: String, keep: Int) {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: backupDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let mine = all.filter { $0.lastPathComponent.hasPrefix(filename + ".") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
        for old in mine.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    struct Endpoint {
        let host: String
        let port: Int
        let apiKey: String

        var openAIBase: String { "http://\(host):\(port)/openai" }
        var anthropicBase: String { "http://\(host):\(port)/anthropic" }
    }

    enum WriterError: LocalizedError {
        case ioFailed(String)
        var errorDescription: String? {
            if case .ioFailed(let m) = self { return m }
            return nil
        }
    }

    // MARK: Apply

    static func apply(_ profile: Profile, endpoint: Endpoint) throws {
        switch profile.client {
        case .codex, .codexCLI:
            try applyCodex(profile, endpoint: endpoint)
        case .claudeCode:
            try applyClaude(profile, endpoint: endpoint)
        }
    }

    static func revert(_ client: ClientKind) throws {
        switch client {
        case .codex, .codexCLI:
            try revertCodex()
        case .claudeCode:
            try revertClaude()
        }
    }

    // MARK: Codex (~/.codex/config.toml)

    static var codexConfigPath: URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    private static let managedTopKeys = ["model", "model_provider", "model_context_window"]

    /// Writes a managed provider block while preserving the user's other keys/tables.
    static func applyCodex(_ profile: Profile, endpoint: Endpoint) throws {
        let path = codexConfigPath
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        var keptTopKeys: [String] = []
        var keptTables: [String] = []
        var inTable = false
        var inOurTable = false
        for line in existing.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inTable = true
                inOurTable = trimmed == "[model_providers.\(providerID)]"
            }
            if inOurTable { continue }
            if !inTable, let key = topLevelKey(line), managedTopKeys.contains(key) { continue }
            if inTable { keptTables.append(line) } else { keptTopKeys.append(line) }
        }

        var topKeys = [
            "model = \"\(profile.model)\"",
            "model_provider = \"\(providerID)\"",
        ]
        if let window = profile.contextWindow {
            topKeys.append("model_context_window = \(window)")
        }
        topKeys.append(contentsOf: keptTopKeys.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })

        let ourTable = [
            "[model_providers.\(providerID)]",
            "name = \"Copilot Bridge\"",
            "base_url = \"\(endpoint.openAIBase)\"",
            "wire_api = \"responses\"",
            "requires_openai_auth = false",
            "experimental_bearer_token = \"\(endpoint.apiKey)\"",
        ]

        let userTables = keptTables.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var parts = [topKeys.joined(separator: "\n")]
        if !userTables.isEmpty { parts.append(userTables) }
        parts.append(ourTable.joined(separator: "\n"))
        let body = parts.joined(separator: "\n\n") + "\n"

        backup(path)
        do {
            try body.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            throw WriterError.ioFailed("write config.toml: \(error.localizedDescription)")
        }
    }

    static func revertCodex() throws {
        let path = codexConfigPath
        guard let existing = try? String(contentsOf: path, encoding: .utf8) else { return }
        backup(path)
        var kept: [String] = []
        var inTable = false
        var inOurTable = false
        for line in existing.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inTable = true
                inOurTable = trimmed == "[model_providers.\(providerID)]"
            }
            if inOurTable { continue }
            if !inTable, let key = topLevelKey(line), managedTopKeys.contains(key) { continue }
            kept.append(line)
        }
        let body = kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
        try? body.write(to: path, atomically: true, encoding: .utf8)
    }

    private static func topLevelKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("[") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? key : nil
    }

    // MARK: Claude Code (~/.claude/settings.json)

    static var claudeSettingsPath: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    static func applyClaude(_ profile: Profile, endpoint: Endpoint) throws {
        let path = claudeSettingsPath
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }
        var env = settings["env"] as? [String: Any] ?? [:]
        env.removeValue(forKey: "ANTHROPIC_SMALL_FAST_MODEL")
        env["ANTHROPIC_BASE_URL"] = endpoint.anthropicBase
        env["ANTHROPIC_AUTH_TOKEN"] = endpoint.apiKey
        env["ANTHROPIC_MODEL"] = claudeModelName(profile)
        if let window = profile.contextWindow {
            env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(window)
        }
        env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] = (env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] as? String) ?? "80"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["CLAUDE_CODE_ATTRIBUTION_HEADER"] = "0"
        env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"
        settings["env"] = env

        backup(path)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: [.atomic])
        } catch {
            throw WriterError.ioFailed("write settings.json: \(error.localizedDescription)")
        }
        ensureClaudeConfigExists()
    }

    static func revertClaude() throws {
        let path = claudeSettingsPath
        guard let data = try? Data(contentsOf: path),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var env = settings["env"] as? [String: Any] else { return }
        backup(path)
        for key in [
            "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_ATTRIBUTION_HEADER",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
        ] {
            env.removeValue(forKey: key)
        }
        settings["env"] = env
        if let out = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: path, options: [.atomic])
        }
    }

    private static func claudeModelName(_ profile: Profile) -> String {
        let m = profile.model
        guard m.lowercased().hasPrefix("claude-") else { return m }
        if let window = profile.contextWindow,
           window > 800_000, window < 1_500_000, !m.hasSuffix(oneMSuffix) {
            return m + oneMSuffix
        }
        return m
    }

    /// Marks onboarding complete so Claude Code doesn't prompt on first launch.
    private static func ensureClaudeConfigExists() {
        let path = home.appendingPathComponent(".claude.json")
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        if obj["hasCompletedOnboarding"] == nil {
            obj["hasCompletedOnboarding"] = true
        }
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? out.write(to: path, options: [.atomic])
        }
    }
}
