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
    /// Per-model request counts accumulated since the last drain. AppState polls and
    /// clears this to feed the persisted ActivityStore, keeping recording off the hot path.
    private var pendingModelCounts: [String: Int] = [:]
    /// Per-model input/output token counts (from upstream `usage`) since the last drain.
    private var pendingModelInput: [String: Int] = [:]
    private var pendingModelOutput: [String: Int] = [:]

    init(upstream: CopilotUpstream, snapshot: Snapshot) {
        self.upstream = upstream
        self.snapshot = snapshot
    }

    func update(snapshot: Snapshot) { self.snapshot = snapshot }

    func stats() -> (count: Int, lastError: String?) { (requestCount, lastError) }

    /// Returns per-model request + input/output token counts since the last call and
    /// resets buffers.
    func drainModelStats() -> (requests: [String: Int], input: [String: Int], output: [String: Int]) {
        defer {
            pendingModelCounts.removeAll(keepingCapacity: true)
            pendingModelInput.removeAll(keepingCapacity: true)
            pendingModelOutput.removeAll(keepingCapacity: true)
        }
        return (pendingModelCounts, pendingModelInput, pendingModelOutput)
    }

    /// Records one served request against its resolved model.
    private func tally(_ model: String) {
        requestCount += 1
        pendingModelCounts[model, default: 0] += 1
    }

    /// Adds observed upstream token usage (split) to the resolved model.
    private func tallyUsage(_ model: String, input: Int, output: Int) {
        if input > 0 { pendingModelInput[model, default: 0] += input }
        if output > 0 { pendingModelOutput[model, default: 0] += output }
    }

    // MARK: Usage extraction (pure, unit-testable)

    /// Extracts (input, output) token usage from a full (non-stream) JSON body.
    static func extractUsage(fromJSON data: Data) -> (input: Int, output: Int)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return usageSplit(obj["usage"])
    }

    /// Extracts (input, output) token usage from a single SSE `data:` frame payload.
    static func extractUsage(fromFramePayload payload: String) -> (input: Int, output: Int)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let s = usageSplit(obj["usage"]) { return s }
        if let msg = obj["message"] as? [String: Any] { return usageSplit(msg["usage"]) }
        return nil
    }

    /// Reads a `usage` object into (input, output). Handles OpenAI
    /// (prompt_tokens/completion_tokens) and Anthropic (input_tokens/output_tokens). If
    /// only `total_tokens` is present, attributes it all to output (documented fallback).
    private static func usageSplit(_ raw: Any?) -> (input: Int, output: Int)? {
        guard let usage = raw as? [String: Any] else { return nil }
        let input = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int ?? 0
        if input > 0 || output > 0 { return (input, output) }
        if let total = usage["total_tokens"] as? Int, total > 0 { return (0, total) }
        return nil
    }

    // MARK: Model resolution

    /// Maps a requested (possibly canonical/[1m]-suffixed) id to a real Copilot id.
    private func resolveModel(_ requested: String) async -> String {
        let models = await upstream.models()
        return CopilotModelID.resolve(requested, in: models)
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
        let data = models.map { model in
            var item: [String: Any] = [
                "id": model.displayID,
                "object": "model",
                "owned_by": model.vendor ?? "copilot-bridge",
                "display_name": model.name ?? model.displayID,
                "upstream_id": model.id,
                "supported_endpoints": model.supportedEndpointNames,
            ]
            if model.claudeModelID != model.displayID || model.displayID.hasPrefix("claude-") {
                item["claude_model_id"] = model.claudeModelID
            }
            if let contextWindow = model.contextWindow {
                item["capabilities"] = [
                    "limits": ["max_context_window_tokens": contextWindow],
                ]
            }
            return item
        }
        return .json(200, ["object": "list", "data": data])
    }

    private func listAnthropicModels() async -> HTTPServer.Response {
        let models = await upstream.models().filter { $0.displayID.contains("claude") }
        let data = models.map { ["type": "model", "id": $0.claudeModelID, "display_name": $0.name ?? $0.claudeModelID] }
        return .json(200, ["data": data])
    }

    // MARK: OpenAI chat (Codex-compatible clients that use chat/completions)

    private func openAIChat(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        guard var body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            requestCount += 1
            return .json(400, ["error": ["message": "invalid JSON body"]])
        }
        var resolvedModel = ""
        if let model = body["model"] as? String {
            let resolved = await resolveModel(model)
            body["model"] = resolved
            resolvedModel = resolved
            tally(resolved)
        } else {
            requestCount += 1
        }
        let stream = body["stream"] as? Bool ?? false
        guard let outBody = try? JSONSerialization.data(withJSONObject: body) else {
            return .json(400, ["error": ["message": "encode failed"]])
        }
        return await passthrough(outBody, stream: stream, model: resolvedModel) { try await self.upstream.chat(body: $0) }
    }

    // MARK: OpenAI Responses (Codex / Codex CLI default wire_api)

    private func openAIResponses(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        guard var body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            requestCount += 1
            return .json(400, ["error": ["message": "invalid JSON body"]])
        }
        var resolvedModel = ""
        if let model = body["model"] as? String {
            let resolved = await resolveModel(model)
            body["model"] = resolved
            resolvedModel = resolved
            tally(resolved)
        } else {
            requestCount += 1
        }
        let stream = body["stream"] as? Bool ?? false
        guard let outBody = try? JSONSerialization.data(withJSONObject: body) else {
            return .json(400, ["error": ["message": "encode failed"]])
        }
        return await passthrough(outBody, stream: stream, model: resolvedModel) { try await self.upstream.responses(body: $0) }
    }

    /// Streams an upstream OpenAI-shaped response straight back to the client.
    private func passthrough(
        _ body: Data,
        stream: Bool,
        model: String,
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
                        var obsIn = 0, obsOut = 0
                        do {
                            for try await byte in resp.bytes {
                                buffer.append(byte)
                                if byte == 0x0A {
                                    await writer.write(buffer)
                                    if let u = Self.sniffUsage(inLine: buffer) { obsIn = max(obsIn, u.input); obsOut = max(obsOut, u.output) }
                                    buffer.removeAll(keepingCapacity: true)
                                }
                            }
                        } catch {}
                        if !buffer.isEmpty {
                            await writer.write(buffer)
                            if let u = Self.sniffUsage(inLine: buffer) { obsIn = max(obsIn, u.input); obsOut = max(obsOut, u.output) }
                        }
                        if obsIn > 0 || obsOut > 0 { await self.tallyUsage(model, input: obsIn, output: obsOut) }
                    })
            } else {
                let data = await collect(resp.bytes)
                if let u = Self.extractUsage(fromJSON: data) { tallyUsage(model, input: u.input, output: u.output) }
                return HTTPServer.Response(status: 200,
                                          headers: ["Content-Type": resp.contentType],
                                          body: data, stream: nil)
            }
        } catch {
            lastError = error.localizedDescription
            return .json(502, ["error": ["message": error.localizedDescription]])
        }
    }

    /// Cheap per-line usage sniff for SSE forwarding: only parses lines that look like a
    /// `data:` frame containing the substring `usage`, so the hot path stays fast.
    private static func sniffUsage(inLine data: Data) -> (input: Int, output: Int)? {
        guard let line = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:"), trimmed.contains("usage") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return extractUsage(fromFramePayload: payload)
    }

    // MARK: Anthropic messages (Claude Code) -> OpenAI chat translation

    private func anthropicMessages(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        guard let anthropic = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            requestCount += 1
            return .json(400, ["error": ["message": "invalid JSON body"]])
        }
        let requested = anthropic["model"] as? String ?? "claude-sonnet-4"
        let selected = CopilotModelID.model(matching: requested, in: await upstream.models())
        let model = selected?.id ?? CopilotModelID.strippedOneMSuffix(requested)
        tally(model)
        let stream = anthropic["stream"] as? Bool ?? false
        if selected?.supportsMessages == true {
            var nativeBody = anthropic
            nativeBody["model"] = model
            guard let outBody = try? JSONSerialization.data(withJSONObject: nativeBody) else {
                return .json(400, ["error": ["message": "encode failed"]])
            }
            let extraHeaders = nativeMessagesHeaders(req, payload: anthropic)
            return await passthrough(outBody, stream: stream, model: model) {
                try await self.upstream.messages(body: $0, extraHeaders: extraHeaders)
            }
        }
        let (openAIBody, translatedStream) = AnthropicTranslate.toOpenAI(anthropic, resolvedModel: model)
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
            if translatedStream {
                return anthropicStream(resp: resp, model: model)
            } else {
                let data = await collect(resp.bytes)
                if let u = Self.extractUsage(fromJSON: data) { tallyUsage(model, input: u.input, output: u.output) }
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
                var obsIn = 0, obsOut = 0
                do {
                    for try await line in resp.bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let obj = try? JSONSerialization.jsonObject(
                            with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if let u = Self.extractUsage(fromFramePayload: payload) { obsIn = max(obsIn, u.input); obsOut = max(obsOut, u.output) }
                        let chunk = enc.handle(obj)
                        if !chunk.isEmpty { await writer.write(chunk) }
                    }
                } catch {
                    // fall through to finish
                }
                await writer.write(enc.finish())
                if obsIn > 0 || obsOut > 0 { await self.tallyUsage(model, input: obsIn, output: obsOut) }
            })
    }

    private func nativeMessagesHeaders(_ req: HTTPServer.Request, payload: [String: Any]) -> [String: String] {
        var headers = ["X-Initiator": nativeMessagesInitiator(payload)]
        if let beta = req.headers["anthropic-beta"], !beta.trimmingCharacters(in: .whitespaces).isEmpty {
            headers["Anthropic-Beta"] = beta
        }
        return headers
    }

    private func nativeMessagesInitiator(_ payload: [String: Any]) -> String {
        guard let messages = payload["messages"] as? [[String: Any]],
              let last = messages.last,
              last["role"] as? String == "user" else {
            return "agent"
        }
        guard let blocks = last["content"] as? [[String: Any]] else { return "user" }
        return blocks.contains { $0["type"] as? String != "tool_result" } ? "user" : "agent"
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
