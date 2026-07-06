import Foundation

/// Which local API surface a client speaks to.
enum ClientKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex          // Codex.app (VS Code extension config lives in ~/.codex/config.toml too)
    case codexCLI       // codex CLI -> ~/.codex/config.toml
    case claudeCode     // claude CLI -> ~/.claude/settings.json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .codexCLI: return "Codex CLI"
        case .claudeCode: return "Claude Code"
        }
    }

    /// SF Symbol used to represent this client in the UI.
    var icon: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .codexCLI: return "terminal"
        case .claudeCode: return "sparkles"
        }
    }

    /// Wire protocol the client expects from our local proxy.
    var wire: WireProtocol {
        switch self {
        case .codex, .codexCLI: return .openAIResponses
        case .claudeCode: return .anthropic
        }
    }
}

enum WireProtocol: String, Codable, Sendable {
    case openAIResponses     // POST /openai/responses (Codex)
    case anthropic           // POST /anthropic/v1/messages (Claude Code)
}

/// A named, system-level configuration mapping a client to a Copilot model.
struct Profile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var client: ClientKind
    var model: String
    /// Real context window (tokens); enables 1M handling + auto-compaction hints.
    var contextWindow: Int?
    /// Whether this profile is currently applied to the system config file.
    var applied: Bool = false

    static func defaultName(for client: ClientKind, model: String) -> String {
        "\(client.displayName) · \(model)"
    }
}

/// How the proxy binds: loopback-only (private) or all interfaces (LAN).
enum BindMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case localhost   // 127.0.0.1 — only this Mac
    case lan         // 0.0.0.0   — reachable from other devices on the network

    var id: String { rawValue }
    var bindHost: String { self == .localhost ? "127.0.0.1" : "0.0.0.0" }
    var title: String { self == .localhost ? "This Mac only (127.0.0.1)" : "Local network (0.0.0.0)" }
}

/// Persisted app settings.
struct AppSettings: Codable, Sendable {
    var port: Int = 10086
    /// Bind mode: localhost (private) vs LAN (shared with other devices).
    var bindMode: BindMode = .localhost
    /// Access key required for remote (non-loopback) requests in LAN mode.
    var accessKey: String = ""
    /// Start the proxy automatically when the app launches.
    var autoStartProxy: Bool = true
    /// Launch the app at login (registered via SMAppService).
    var launchAtLogin: Bool = false
    var profiles: [Profile] = []

    static let `default` = AppSettings()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case port, bindMode, accessKey, autoStartProxy, launchAtLogin, profiles
        // Legacy keys (pre-0.1 schema) migrated on load.
        case lanMode
    }

    /// Tolerant decoder: any missing key falls back to its default, and the old
    /// `lanMode` boolean is migrated to `bindMode`. This keeps existing settings
    /// files working after the schema change instead of resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.port = (try? c.decode(Int.self, forKey: .port)) ?? 10086
        if let mode = try? c.decode(BindMode.self, forKey: .bindMode) {
            self.bindMode = mode
        } else if let legacyLan = try? c.decode(Bool.self, forKey: .lanMode) {
            self.bindMode = legacyLan ? .lan : .localhost
        } else {
            self.bindMode = .localhost
        }
        self.accessKey = (try? c.decode(String.self, forKey: .accessKey)) ?? ""
        self.autoStartProxy = (try? c.decode(Bool.self, forKey: .autoStartProxy)) ?? true
        self.launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? false
        self.profiles = (try? c.decode([Profile].self, forKey: .profiles)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(port, forKey: .port)
        try c.encode(bindMode, forKey: .bindMode)
        try c.encode(accessKey, forKey: .accessKey)
        try c.encode(autoStartProxy, forKey: .autoStartProxy)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(profiles, forKey: .profiles)
    }
}


/// Human-readable context window, e.g. 1M, 200K, 128K.
func formatContextWindow(_ tokens: Int?) -> String? {
    guard let tokens, tokens > 0 else { return nil }
    if tokens >= 1_000_000 {
        let millions = Double(tokens) / 1_000_000
        return millions == millions.rounded()
            ? "\(Int(millions))M"
            : String(format: "%.1fM", millions)
    }
    return "\(tokens / 1000)K"
}

/// Compact count for dashboard values: exact under 1K, then 1.2K / 3.4M.
func formatCompactCount(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
    if n >= 1_000 {
        return String(format: "%.1fK", Double(n) / 1_000)
    }
    return "\(n)"
}
