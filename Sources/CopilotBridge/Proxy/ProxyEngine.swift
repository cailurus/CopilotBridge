import Foundation

/// Wires local HTTP routes to the Copilot upstream. Owns model resolution and
/// SSE reformatting. All state needed at request time is captured in a snapshot.
actor ProxyEngine {
    struct Snapshot: Sendable {
        var lanMode: Bool
        var accessKey: String
    }

    private let upstream: CopilotUpstream
    private var snapshot: Snapshot
    private(set) var lastError: String?
    private(set) var requestCount = 0

    init(upstream: CopilotUpstream, snapshot: Snapshot) {
        self.upstream = upstream
        self.snapshot = snapshot
    }

    func update(snapshot: Snapshot) { self.snapshot = snapshot }

    func stats() -> (count: Int, lastError: String?) { (requestCount, lastError) }

    // MARK: Model resolution

    /// Maps a requested (possibly canonical/[1m]-suffixed) id to a real Copilot id.
    private func resolveModel(_ requested: String) async -> String {
        var id = requested
        if id.hasSuffix("[1m]") { id = String(id.dropLast(4)) }
        let models = await upstream.models()
        let ids = models.map(\.id)
        if ids.contains(id) { return id }
        // Canonical dashed -> dotted (claude-opus-4-8 -> claude-opus-4.8) and fuzzy contains.
        let dotted = id.replacingOccurrences(of: "-", with: ".")
        if let hit = ids.first(where: { $0 == dotted }) { return hit }
        if let hit = ids.first(where: { $0.contains(id) || id.contains($0) }) { return hit }
        return id
    }

    // MARK: Routing

    func handle(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        // LAN auth: non-loopback requests need the access key when LAN mode is on.
        if snapshot.lanMode, !req.isLoopback, !snapshot.accessKey.isEmpty {
            let bearer = req.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
            let apiKey = req.headers["x-api-key"]
            if bearer != snapshot.accessKey && apiKey != snapshot.accessKey {
                return .json(401, ["error": ["message": "invalid access key"]])
            }
        }

        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path

        switch (req.method, path) {
        case ("GET", "/health"), ("GET", "/"):
            return .text(200, "copilot-bridge ok")
        case ("GET", "/openai/models"), ("GET", "/openai/v1/models"):
            return await listModels()
        case ("GET", "/anthropic/v1/models"), ("GET", "/anthropic/models"):
            return await listAnthropicModels()
        case ("POST", "/openai/chat/completions"), ("POST", "/openai/v1/chat/completions"):
            return await openAIChat(req)
        case ("POST", "/openai/responses"), ("POST", "/openai/v1/responses"):
            return await openAIResponses(req)
        case ("POST", "/anthropic/v1/messages"), ("POST", "/anthropic/messages"):
            return await anthropicMessages(req)
        default:
            return .json(404, ["error": ["message": "not found: \(req.method) \(path)"]])
        }
    }

    private func listModels() async -> HTTPServer.Response {
        let models = await upstream.models()
        let data = models.map { ["id": $0.id, "object": "model", "owned_by": "copilot-bridge"] }
        return .json(200, ["object": "list", "data": data])
    }

    private func listAnthropicModels() async -> HTTPServer.Response {
        let models = await upstream.models().filter { $0.id.contains("claude") }
        let data = models.map { ["type": "model", "id": $0.id, "display_name": $0.id] }
        return .json(200, ["data": data])
    }

    // MARK: OpenAI chat (Codex-compatible clients that use chat/completions)

    private func openAIChat(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        requestCount += 1
        guard var body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return .json(400, ["error": ["message": "invalid JSON body"]])
        }
        if let model = body["model"] as? String {
            body["model"] = await resolveModel(model)
        }
        let stream = body["stream"] as? Bool ?? false
        guard let outBody = try? JSONSerialization.data(withJSONObject: body) else {
            return .json(400, ["error": ["message": "encode failed"]])
        }
        return await passthrough(outBody, stream: stream) { try await self.upstream.chat(body: $0) }
    }

    // MARK: OpenAI Responses (Codex / Codex CLI default wire_api)

    private func openAIResponses(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        requestCount += 1
        guard var body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return .json(400, ["error": ["message": "invalid JSON body"]])
        }
        if let model = body["model"] as? String {
            body["model"] = await resolveModel(model)
        }
        let stream = body["stream"] as? Bool ?? false
        guard let outBody = try? JSONSerialization.data(withJSONObject: body) else {
            return .json(400, ["error": ["message": "encode failed"]])
        }
        return await passthrough(outBody, stream: stream) { try await self.upstream.responses(body: $0) }
    }

    /// Streams an upstream OpenAI-shaped response straight back to the client.
    private func passthrough(
        _ body: Data,
        stream: Bool,
        call: @escaping @Sendable (Data) async throws -> UpstreamResponse
    ) async -> HTTPServer.Response {
        do {
            let resp = try await call(body)
            if resp.status >= 400 {
                let text = await collect(resp.bytes)
                lastError = "upstream \(resp.status): \(String(data: text, encoding: .utf8) ?? "")"
                return HTTPServer.Response(status: resp.status,
                                          headers: ["Content-Type": resp.contentType],
                                          body: text, stream: nil)
            }
            if stream {
                return HTTPServer.Response(
                    status: 200,
                    headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
                    body: nil,
                    stream: { writer in
                        // Forward raw SSE bytes verbatim, flushing per line. Using
                        // `.lines` here would drop the blank line that terminates each
                        // SSE frame, so clients (Codex) never see `response.completed`
                        // and report "stream closed before response.completed".
                        var buffer = Data()
                        do {
                            for try await byte in resp.bytes {
                                buffer.append(byte)
                                if byte == 0x0A {
                                    await writer.write(buffer)
                                    buffer.removeAll(keepingCapacity: true)
                                }
                            }
                        } catch {}
                        if !buffer.isEmpty { await writer.write(buffer) }
                    })
            } else {
                let data = await collect(resp.bytes)
                return HTTPServer.Response(status: 200,
                                          headers: ["Content-Type": resp.contentType],
                                          body: data, stream: nil)
            }
        } catch {
            lastError = error.localizedDescription
            return .json(502, ["error": ["message": error.localizedDescription]])
        }
    }

    // MARK: Anthropic messages (Claude Code) -> OpenAI chat translation

    private func anthropicMessages(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        requestCount += 1
        guard let anthropic = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return .json(400, ["error": ["message": "invalid JSON body"]])
        }
        let requested = anthropic["model"] as? String ?? "claude-sonnet-4"
        let model = await resolveModel(requested)
        let (openAIBody, stream) = AnthropicTranslate.toOpenAI(anthropic, resolvedModel: model)
        guard let outBody = try? JSONSerialization.data(withJSONObject: openAIBody) else {
            return .json(400, ["error": ["message": "encode failed"]])
        }
        do {
            let resp = try await upstream.chat(body: outBody)
            if resp.status >= 400 {
                let text = await collect(resp.bytes)
                lastError = "upstream \(resp.status)"
                return HTTPServer.Response(status: resp.status,
                                          headers: ["Content-Type": "application/json"],
                                          body: text, stream: nil)
            }
            if stream {
                return anthropicStream(resp: resp, model: model)
            } else {
                let data = await collect(resp.bytes)
                let openai = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let translated = AnthropicTranslate.fromOpenAI(openai, model: model)
                return .json(200, translated)
            }
        } catch {
            lastError = error.localizedDescription
            return .json(502, ["error": ["message": error.localizedDescription]])
        }
    }

    private func anthropicStream(resp: UpstreamResponse, model: String) -> HTTPServer.Response {
        HTTPServer.Response(
            status: 200,
            headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
            body: nil,
            stream: { writer in
                var enc = AnthropicStreamEncoder(model: model)
                await writer.write(enc.start())
                // Anthropic clients expect a ping soon after start.
                await writer.write(AnthropicStreamEncoder.event("ping", ["type": "ping"]))
                do {
                    for try await line in resp.bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let obj = try? JSONSerialization.jsonObject(
                            with: Data(payload.utf8)) as? [String: Any] else { continue }
                        let chunk = enc.handle(obj)
                        if !chunk.isEmpty { await writer.write(chunk) }
                    }
                } catch {
                    // fall through to finish
                }
                await writer.write(enc.finish())
            })
    }

    // MARK: helpers

    private func collect(_ bytes: URLSession.AsyncBytes) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes { data.append(byte) }
        } catch {}
        return data
    }
}
