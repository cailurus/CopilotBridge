import Foundation

/// Translates between Anthropic Messages API (what Claude Code speaks) and
/// OpenAI Chat Completions (what Copilot serves). Focused, faithful subset:
/// text, system prompt, multi-turn, tools/tool_use, and streaming.
enum AnthropicTranslate {

    // MARK: Request:  Anthropic Messages -> OpenAI chat body

    /// Returns the OpenAI request body plus the resolved model + stream flag.
    static func toOpenAI(_ anthropic: [String: Any], resolvedModel: String) -> (body: [String: Any], stream: Bool) {
        var messages: [[String: Any]] = []

        // System prompt (string or array of text blocks).
        if let sys = anthropic["system"] as? String, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        } else if let sysArr = anthropic["system"] as? [[String: Any]] {
            let text = sysArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { messages.append(["role": "system", "content": text]) }
        }

        for msg in (anthropic["messages"] as? [[String: Any]] ?? []) {
            let role = msg["role"] as? String ?? "user"
            // Content can be a plain string or an array of blocks.
            if let str = msg["content"] as? String {
                messages.append(["role": role, "content": str])
                continue
            }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            var textParts: [String] = []
            var imageParts: [[String: Any]] = []
            var toolCalls: [[String: Any]] = []
            var toolResults: [[String: Any]] = []

            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String { textParts.append(t) }
                case "image":
                    if let src = block["source"] as? [String: Any],
                       let data = src["data"] as? String,
                       let media = src["media_type"] as? String {
                        imageParts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(media);base64,\(data)"],
                        ])
                    }
                case "tool_use":
                    toolCalls.append([
                        "id": block["id"] as? String ?? UUID().uuidString,
                        "type": "function",
                        "function": [
                            "name": block["name"] as? String ?? "",
                            "arguments": jsonString(block["input"] ?? [:]),
                        ],
                    ])
                case "tool_result":
                    let content: String
                    if let s = block["content"] as? String {
                        content = s
                    } else if let arr = block["content"] as? [[String: Any]] {
                        content = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    } else {
                        content = ""
                    }
                    toolResults.append([
                        "role": "tool",
                        "tool_call_id": block["tool_use_id"] as? String ?? "",
                        "content": content,
                    ])
                default:
                    break
                }
            }

            // Each tool_result becomes its own OpenAI `tool` message.
            if !toolResults.isEmpty {
                messages.append(contentsOf: toolResults)
            }

            if !toolCalls.isEmpty {
                var m: [String: Any] = ["role": "assistant"]
                if !textParts.isEmpty { m["content"] = textParts.joined() }
                m["tool_calls"] = toolCalls
                messages.append(m)
            } else if !imageParts.isEmpty {
                var parts: [[String: Any]] = []
                let text = textParts.joined()
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                parts.append(contentsOf: imageParts)
                messages.append(["role": role, "content": parts])
            } else if !textParts.isEmpty || toolResults.isEmpty {
                messages.append(["role": role, "content": textParts.joined()])
            }
        }

        var body: [String: Any] = [
            "model": resolvedModel,
            "messages": messages,
        ]
        let stream = anthropic["stream"] as? Bool ?? false
        body["stream"] = stream
        if let mt = anthropic["max_tokens"] as? Int { body["max_tokens"] = mt }
        if let temp = anthropic["temperature"] as? Double { body["temperature"] = temp }
        if let topP = anthropic["top_p"] as? Double { body["top_p"] = topP }
        if let stop = anthropic["stop_sequences"] as? [String], !stop.isEmpty { body["stop"] = stop }

        // Tools.
        if let tools = anthropic["tools"] as? [[String: Any]], !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": [
                        "name": t["name"] as? String ?? "",
                        "description": t["description"] as? String ?? "",
                        "parameters": t["input_schema"] as? [String: Any] ?? [:],
                    ],
                ]
            }
            body["tool_choice"] = mapToolChoice(anthropic["tool_choice"])
        }
        // Reasoning effort (Anthropic thinking -> reasoning_effort).
        if let thinking = anthropic["thinking"] as? [String: Any],
           (thinking["type"] as? String) == "enabled" {
            body["reasoning_effort"] = "medium"
        }
        return (body, stream)
    }

    // MARK: Response:  OpenAI non-stream -> Anthropic Messages

    static func fromOpenAI(_ openai: [String: Any], model: String) -> [String: Any] {
        let choice = (openai["choices"] as? [[String: Any]])?.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        var content: [[String: Any]] = []
        if let text = message["content"] as? String, !text.isEmpty {
            content.append(["type": "text", "text": text])
        }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for call in calls {
                let fn = call["function"] as? [String: Any] ?? [:]
                let args = fn["arguments"] as? String ?? "{}"
                content.append([
                    "type": "tool_use",
                    "id": call["id"] as? String ?? UUID().uuidString,
                    "name": fn["name"] as? String ?? "",
                    "input": (try? JSONSerialization.jsonObject(with: Data(args.utf8))) ?? [:],
                ])
            }
        }
        let usage = openai["usage"] as? [String: Any] ?? [:]
        let stop = choice["finish_reason"] as? String
        return [
            "id": openai["id"] as? String ?? "msg_\(UUID().uuidString)",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": content,
            "stop_reason": mapStop(stop),
            "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": usage["prompt_tokens"] as? Int ?? 0,
                "output_tokens": usage["completion_tokens"] as? Int ?? 0,
            ],
        ]
    }

    static func mapStop(_ reason: String?) -> String {
        switch reason {
        case "tool_calls": return "tool_use"
        case "length": return "max_tokens"
        default: return "end_turn"
        }
    }

    /// Maps Anthropic tool_choice to the OpenAI equivalent. Defaults to "auto".
    static func mapToolChoice(_ raw: Any?) -> Any {
        guard let choice = raw as? [String: Any],
              let type = choice["type"] as? String else { return "auto" }
        switch type {
        case "any": return "required"
        case "tool":
            if let name = choice["name"] as? String {
                return ["type": "function", "function": ["name": name]]
            }
            return "required"
        default: return "auto"   // "auto"
        }
    }

    // MARK: helpers

    static func jsonString(_ obj: Any) -> String {
        if let str = obj as? String { return str }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
