import Foundation

/// Talks to GitHub Copilot's OpenAI-shaped endpoints (community-documented, unofficial).
actor CopilotUpstream {
    static let modelsURL = URL(string: "https://api.githubcopilot.com/models")!
    static let chatURL = URL(string: "https://api.githubcopilot.com/chat/completions")!
    static let responsesURL = URL(string: "https://api.githubcopilot.com/responses")!

    private let tokens: CopilotTokenStore
    private var modelCache: [ModelInfo] = []
    private var modelCacheAt: Date?

    init(tokens: CopilotTokenStore) {
        self.tokens = tokens
    }

    struct ModelInfo: Sendable, Hashable {
        let id: String
        let contextWindow: Int?
        let supportsResponses: Bool
    }

    private func headers(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Editor-Version": "vscode/1.95.0",
            "Copilot-Integration-Id": "vscode-chat",
        ]
    }

    static let fallbackModels: [ModelInfo] = [
        .init(id: "gpt-4o", contextWindow: 128_000, supportsResponses: false),
        .init(id: "claude-sonnet-4", contextWindow: 200_000, supportsResponses: false),
        .init(id: "gpt-5", contextWindow: 272_000, supportsResponses: true),
    ]

    /// Fetches (and caches for 5 min) the live model catalog.
    func models() async -> [ModelInfo] {
        if let at = modelCacheAt, Date().timeIntervalSince(at) < 300, !modelCache.isEmpty {
            return modelCache
        }
        guard let token = try? await tokens.get() else { return Self.fallbackModels }
        var req = URLRequest(url: Self.modelsURL)
        for (k, v) in headers(token) { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else {
            return modelCache.isEmpty ? Self.fallbackModels : modelCache
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
            out.append(.init(id: id, contextWindow: window,
                             supportsResponses: endpoints.contains("/responses")))
        }
        modelCache = out.isEmpty ? Self.fallbackModels : out
        modelCacheAt = Date()
        return modelCache
    }

    /// Forwards an already-OpenAI-shaped body to Copilot's chat endpoint.
    /// Returns (status, headers, streaming bytes).
    func chat(body: Data) async throws -> UpstreamResponse {
        try await forward(url: Self.chatURL, body: body)
    }

    /// Forwards an OpenAI Responses body to Copilot's responses endpoint.
    func responses(body: Data) async throws -> UpstreamResponse {
        try await forward(url: Self.responsesURL, body: body)
    }

    private func forward(url: URL, body: Data) async throws -> UpstreamResponse {
        let token = try await tokens.get()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers(token) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let http = resp as? HTTPURLResponse
        return UpstreamResponse(
            status: http?.statusCode ?? 502,
            contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json",
            bytes: bytes
        )
    }
}

/// Streaming response handle from an upstream call.
struct UpstreamResponse {
    let status: Int
    let contentType: String
    let bytes: URLSession.AsyncBytes
}
