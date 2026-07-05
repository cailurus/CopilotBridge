import Foundation
import Testing
@testable import CopilotBridge

@Test func toOpenAIForwardsSamplingAndStopAndToolChoice() {
    let anthropic: [String: Any] = [
        "model": "claude-sonnet-4",
        "messages": [["role": "user", "content": "hi"]],
        "max_tokens": 100,
        "temperature": 0.4,
        "top_p": 0.9,
        "stop_sequences": ["STOP", "END"],
        "tools": [["name": "get_weather", "description": "d", "input_schema": ["type": "object"]]],
        "tool_choice": ["type": "tool", "name": "get_weather"],
    ]

    let (body, _) = AnthropicTranslate.toOpenAI(anthropic, resolvedModel: "gpt-5")

    #expect(body["top_p"] as? Double == 0.9)
    #expect((body["stop"] as? [String]) == ["STOP", "END"])
    let tc = body["tool_choice"] as? [String: Any]
    #expect(tc?["type"] as? String == "function")
    #expect((tc?["function"] as? [String: Any])?["name"] as? String == "get_weather")
}

@Test func toolChoiceAnyMapsToRequired() {
    #expect(AnthropicTranslate.mapToolChoice(["type": "any"]) as? String == "required")
    #expect(AnthropicTranslate.mapToolChoice(["type": "auto"]) as? String == "auto")
    #expect(AnthropicTranslate.mapToolChoice(nil) as? String == "auto")
}
