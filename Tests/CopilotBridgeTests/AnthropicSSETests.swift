import Foundation
import Testing
@testable import CopilotBridge

/// Parses the encoder's SSE output into an ordered list of (event, index) pairs.
private func events(_ sse: String) -> [(type: String, index: Int?)] {
    var out: [(String, Int?)] = []
    let frames = sse.components(separatedBy: "\n\n")
    for frame in frames {
        let lines = frame.split(separator: "\n")
        guard let evLine = lines.first(where: { $0.hasPrefix("event: ") }),
              let dataLine = lines.first(where: { $0.hasPrefix("data: ") }) else { continue }
        let type = String(evLine.dropFirst("event: ".count))
        let json = String(dataLine.dropFirst("data: ".count))
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        out.append((type, obj?["index"] as? Int))
    }
    return out
}

@Test func toolUseBlockIsClosedBeforeTrailingTextBlockOpens() {
    var enc = AnthropicStreamEncoder(model: "claude-sonnet-4")
    _ = enc.start()

    // 1) A tool call arrives first.
    var sse = enc.handle([
        "choices": [[
            "delta": ["tool_calls": [[
                "index": 0,
                "id": "toolu_1",
                "function": ["name": "get_weather", "arguments": "{\"city\""]
            ]]]
        ]]
    ])
    // 2) Then a text delta arrives while the tool block is still open.
    sse += enc.handle([
        "choices": [["delta": ["content": "Here is the answer"]]]
    ])

    let ev = events(sse)
    let types = ev.map { $0.type }

    // The tool block must be closed before the text block starts.
    let toolStart = types.firstIndex(of: "content_block_start")
    let toolStop = types.firstIndex(of: "content_block_stop")
    let textStartIdx = types.enumerated().filter { $0.element == "content_block_start" }.map { $0.offset }
    #expect(toolStart != nil)
    #expect(toolStop != nil, "expected content_block_stop for the tool block before the text block opens")
    #expect(textStartIdx.count == 2, "expected two content_block_start events (tool then text)")
    if let stop = toolStop, textStartIdx.count == 2 {
        #expect(stop < textStartIdx[1], "tool block must stop before text block starts")
    }
}

@Test func secondToolBlockClosesFirstToolBlock() {
    var enc = AnthropicStreamEncoder(model: "claude-sonnet-4")
    _ = enc.start()

    var sse = enc.handle([
        "choices": [["delta": ["tool_calls": [[
            "index": 0, "id": "toolu_1", "function": ["name": "a", "arguments": "{}"]
        ]]]]]
    ])
    sse += enc.handle([
        "choices": [["delta": ["tool_calls": [[
            "index": 1, "id": "toolu_2", "function": ["name": "b", "arguments": "{}"]
        ]]]]]
    ])

    let types = events(sse).map { $0.type }
    // Two starts, and at least one stop between them (first tool closed before second opens).
    let starts = types.enumerated().filter { $0.element == "content_block_start" }.map { $0.offset }
    let stops = types.enumerated().filter { $0.element == "content_block_stop" }.map { $0.offset }
    #expect(starts.count == 2)
    #expect(stops.contains { $0 > starts[0] && $0 < starts[1] }, "first tool block must be closed before the second opens")
}
