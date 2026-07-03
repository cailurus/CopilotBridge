import Foundation

/// Talks to GitHub Copilot's OpenAI-shaped endpoints (community-documented, unofficial).
actor CopilotUpstream {
    static let defaultAPIBaseURL = URL(string: "https://api.githubcopilot.com")!
    private static let vscodeVersion = "1.124.2"
    private static let copilotChatVersion = "0.52.0"

    private let tokens: CopilotTokenStore
    private let editorDeviceID = UUID().uuidString
    private var modelCache: [ModelInfo] = []
    private var modelCacheAt: Date?

    init(tokens: CopilotTokenStore) {
        self.tokens = tokens
    }

    struct ModelInfo: Sendable, Hashable {
        /// Real upstream ID accepted by GitHub Copilot.
        let id: String
        /// Client-facing ID normalized for Claude Code-style model names.
        let clientID: String
        /// Claude Code model env value. Adds [1m] when Copilot reports a 1M context window.
        let claudeModelID: String
        let name: String?
        let vendor: String?
        let contextWindow: Int?
        let supportsResponses: Bool
        let supportsMessages: Bool

        var displayID: String {
            claudeModelID != clientID ? claudeModelID : clientID
        }

        var supportedEndpointNames: [String] {
            var endpoints: [String] = []
            if supportsResponses { endpoints.append("/responses") }
            if supportsMessages { endpoints.append("/v1/messages") }
            return endpoints
        }

        static func model(
            id: String,
            name: String?,
            vendor: String?,
            contextWindow: Int?,
            supportsResponses: Bool,
            supportsMessages: Bool
        ) -> ModelInfo {
            ModelInfo(
                id: id,
                clientID: CopilotModelID.clientID(forUpstreamID: id),
                claudeModelID: CopilotModelID.claudeModelID(forUpstreamID: id, contextWindow: contextWindow),
                name: name,
                vendor: vendor,
                contextWindow: contextWindow,
                supportsResponses: supportsResponses,
                supportsMessages: supportsMessages
            )
        }
    }

    private func headers(_ token: String) -> [String: String] {
        let requestID = UUID().uuidString
        return [
            "Authorization": "Bearer \(token)",
            "Copilot-Integration-Id": "vscode-chat",
            "Editor-Device-Id": editorDeviceID,
            "Editor-Version": "vscode/\(Self.vscodeVersion)",
            "Editor-Plugin-Version": "copilot-chat/\(Self.copilotChatVersion)",
            "User-Agent": "GitHubCopilotChat/\(Self.copilotChatVersion)",
            "OpenAI-Intent": "conversation-agent",
            "X-GitHub-Api-Version": "2026-06-01",
            "X-Request-Id": requestID,
            "X-VSCode-User-Agent-Library-Version": "electron-fetch",
            "X-Agent-Task-Id": requestID,
            "X-Interaction-Type": "conversation-agent",
        ]
    }

    private func modelHeaders(_ token: String) -> [String: String] {
        var h = headers(token)
        h["OpenAI-Intent"] = "model-access"
        h["X-Interaction-Type"] = "model-access"
        h.removeValue(forKey: "Content-Type")
        return h
    }

    static let fallbackModels: [ModelInfo] = [
        .model(id: "gpt-4o", name: "GPT-4o", vendor: "openai", contextWindow: 128_000, supportsResponses: false, supportsMessages: false),
        .model(id: "claude-sonnet-4", name: "Claude Sonnet 4", vendor: "anthropic", contextWindow: 200_000, supportsResponses: false, supportsMessages: true),
        .model(id: "gpt-5", name: "GPT-5", vendor: "openai", contextWindow: 272_000, supportsResponses: true, supportsMessages: false),
    ]

    /// Fetches (and caches for 5 min) the live model catalog.
    func models(forceRefresh: Bool = false) async -> [ModelInfo] {
        if CopilotModelCachePolicy.canUseCache(
            cachedAt: modelCacheAt,
            now: Date(),
            hasModels: !modelCache.isEmpty,
            forceRefresh: forceRefresh
        ) {
            return modelCache
        }
        do {
            return try await refreshModels()
        } catch {
            return modelCache.isEmpty ? Self.fallbackModels : modelCache
        }
    }

    /// Forces a live model catalog fetch. Unlike `models(forceRefresh:)`, this
    /// reports failures so manual refresh does not silently look successful.
    func refreshModels() async throws -> [ModelInfo] {
        let token = try await tokens.get()
        var req = URLRequest(
            url: endpoint("models", base: token.apiBaseURL),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 8
        )
        for (k, v) in modelHeaders(token.value) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ModelRefreshError.invalidResponse(-1)
        }
        guard http.statusCode == 200 else {
            throw ModelRefreshError.invalidResponse(http.statusCode)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else {
            throw ModelRefreshError.invalidPayload
        }
        var out: [ModelInfo] = []
        var seen = Set<String>()
        for m in arr {
            guard let id = m["id"] as? String, !seen.contains(id) else { continue }
            seen.insert(id)
            let caps = m["capabilities"] as? [String: Any]
            let limits = caps?["limits"] as? [String: Any]
            let window = (limits?["max_context_window_tokens"] as? Int)
                ?? (limits?["max_prompt_tokens"] as? Int)
            let endpoints = m["supported_endpoints"] as? [String] ?? []
            out.append(.model(
                id: id,
                name: m["name"] as? String,
                vendor: m["vendor"] as? String,
                contextWindow: window,
                supportsResponses: endpoints.contains("/responses"),
                supportsMessages: endpoints.contains("/v1/messages")
            ))
        }
        guard !out.isEmpty else { throw ModelRefreshError.emptyCatalog }
        modelCache = out
        modelCacheAt = Date()
        return modelCache
    }

    /// Forwards an already-OpenAI-shaped body to Copilot's chat endpoint.
    /// Returns (status, headers, streaming bytes).
    func chat(body: Data) async throws -> UpstreamResponse {
        try await forward(path: "chat/completions", body: body)
    }

    /// Forwards an OpenAI Responses body to Copilot's responses endpoint.
    func responses(body: Data) async throws -> UpstreamResponse {
        try await forward(path: "responses", body: body)
    }

    func messages(body: Data, extraHeaders: [String: String] = [:]) async throws -> UpstreamResponse {
        try await forward(path: "v1/messages", body: body, extraHeaders: extraHeaders)
    }

    private func forward(path: String, body: Data, extraHeaders: [String: String] = [:]) async throws -> UpstreamResponse {
        let token = try await tokens.get()
        var req = URLRequest(url: endpoint(path, base: token.apiBaseURL))
        req.httpMethod = "POST"
        for (k, v) in headers(token.value) { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let http = resp as? HTTPURLResponse
        return UpstreamResponse(
            status: http?.statusCode ?? 502,
            contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json",
            bytes: bytes
        )
    }

    private func endpoint(_ path: String, base: URL) -> URL {
        base.appendingPathComponent(path)
    }
}

enum ModelRefreshError: LocalizedError {
    case invalidResponse(Int)
    case invalidPayload
    case emptyCatalog

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let status): return "Model refresh failed (HTTP \(status))"
        case .invalidPayload: return "Model refresh returned an unexpected payload."
        case .emptyCatalog: return "Model refresh returned no models."
        }
    }
}

enum CopilotModelCachePolicy {
    static let ttl: TimeInterval = 300

    static func canUseCache(cachedAt: Date?, now: Date, hasModels: Bool, forceRefresh: Bool) -> Bool {
        guard !forceRefresh, hasModels, let cachedAt else { return false }
        return now.timeIntervalSince(cachedAt) < ttl
    }
}

/// Streaming response handle from an upstream call.
struct UpstreamResponse {
    let status: Int
    let contentType: String
    let bytes: URLSession.AsyncBytes
}
