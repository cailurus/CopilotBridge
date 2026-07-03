import Foundation

/// Converts an OpenAI chat-completions SSE stream into the Anthropic Messages
/// event stream Claude Code expects. Handles text deltas and tool-call deltas.
struct AnthropicStreamEncoder {
    let model: String
    private let messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

    private var startedMessage = false
    private var textBlockOpen = false
    private var contentIndex = -1
    // Tracks tool-call blocks by their OpenAI streaming index.
    private var toolBlocks: [Int: Int] = [:]   // openAIIndex -> anthropic content index
    private var toolNames: [Int: String] = [:]
    private var promptTokens = 0
    private var completionTokens = 0
    private var finishReason: String?

    init(model: String) { self.model = model }

    static func event(_ type: String, _ payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        return "event: \(type)\ndata: \(data)\n\n"
    }

    mutating func start() -> String {
        startedMessage = true
        let payload: [String: Any] = [
            "type": "message_start",
            "message": [
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": 0, "output_tokens": 0],
            ],
        ]
        return Self.event("message_start", payload)
    }

    /// Feed one parsed OpenAI SSE `data:` object. Returns Anthropic SSE text (possibly empty).
    mutating func handle(_ obj: [String: Any]) -> String {
        var out = ""
        if let usage = obj["usage"] as? [String: Any] {
            promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
            completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
        }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return out }
        if let fr = choice["finish_reason"] as? String { finishReason = fr }
        let delta = choice["delta"] as? [String: Any] ?? [:]

        // Text delta.
        if let text = delta["content"] as? String, !text.isEmpty {
            if !textBlockOpen {
                contentIndex += 1
                textBlockOpen = true
                out += Self.event("content_block_start", [
                    "type": "content_block_start",
                    "index": contentIndex,
                    "content_block": ["type": "text", "text": ""],
                ])
            }
            out += Self.event("content_block_delta", [
                "type": "content_block_delta",
                "index": contentIndex,
                "delta": ["type": "text_delta", "text": text],
            ])
        }

        // Tool-call deltas.
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for call in calls {
                let idx = call["index"] as? Int ?? 0
                let fn = call["function"] as? [String: Any] ?? [:]
                if toolBlocks[idx] == nil {
                    // Close any open text block first.
                    if textBlockOpen {
                        out += Self.event("content_block_stop", ["type": "content_block_stop", "index": contentIndex])
                        textBlockOpen = false
                    }
                    contentIndex += 1
                    toolBlocks[idx] = contentIndex
                    let name = fn["name"] as? String ?? ""
                    toolNames[idx] = name
                    out += Self.event("content_block_start", [
                        "type": "content_block_start",
                        "index": contentIndex,
                        "content_block": [
                            "type": "tool_use",
                            "id": call["id"] as? String ?? "toolu_\(UUID().uuidString)",
                            "name": name,
                            "input": [:],
                        ],
                    ])
                }
                if let args = fn["arguments"] as? String, !args.isEmpty,
                   let blockIdx = toolBlocks[idx] {
                    out += Self.event("content_block_delta", [
                        "type": "content_block_delta",
                        "index": blockIdx,
                        "delta": ["type": "input_json_delta", "partial_json": args],
                    ])
                }
            }
        }
        return out
    }

    /// Emits closing events (block stop, message_delta with usage, message_stop).
    mutating func finish() -> String {
        var out = ""
        if textBlockOpen {
            out += Self.event("content_block_stop", ["type": "content_block_stop", "index": contentIndex])
            textBlockOpen = false
        }
        for (_, blockIdx) in toolBlocks.sorted(by: { $0.value < $1.value }) {
            out += Self.event("content_block_stop", ["type": "content_block_stop", "index": blockIdx])
        }
        out += Self.event("message_delta", [
            "type": "message_delta",
            "delta": [
                "stop_reason": AnthropicTranslate.mapStop(finishReason),
                "stop_sequence": NSNull(),
            ],
            "usage": ["output_tokens": completionTokens],
        ])
        out += Self.event("message_stop", ["type": "message_stop"])
        return out
    }

    var didStart: Bool { startedMessage }
}
