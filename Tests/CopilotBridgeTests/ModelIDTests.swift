import Testing
@testable import CopilotBridge
import Foundation

@Test func claudeClientModelIDUsesClaudeCodeVersionStyle() {
    #expect(CopilotModelID.clientID(forUpstreamID: "claude-opus-4.5") == "claude-opus-4-5")
    #expect(CopilotModelID.clientID(forUpstreamID: "claude-3.5-sonnet") == "claude-sonnet-3-5")
    #expect(CopilotModelID.clientID(forUpstreamID: "gpt-5") == "gpt-5")
}

@Test func oneMillionContextClaudeModelExposesClaudeCodeMarker() {
    let model = CopilotUpstream.ModelInfo(
        id: "claude-opus-4.5-1m-internal",
        clientID: "claude-opus-4-5-1m-internal",
        claudeModelID: "claude-opus-4-5-1m-internal[1m]",
        name: "Claude Opus 4.5 1M",
        vendor: "anthropic",
        contextWindow: 1_000_000,
        supportsResponses: false,
        supportsMessages: true
    )

    #expect(model.displayID == "claude-opus-4-5-1m-internal[1m]")
}

@Test func resolverMapsClaudeCodeIDsBackToUpstreamIDs() {
    let models = [
        CopilotUpstream.ModelInfo(
            id: "claude-opus-4.5",
            clientID: "claude-opus-4-5",
            claudeModelID: "claude-opus-4-5",
            name: "Claude Opus 4.5",
            vendor: "anthropic",
            contextWindow: 200_000,
            supportsResponses: false,
            supportsMessages: true
        )
    ]

    #expect(CopilotModelID.resolve("claude-opus-4-5", in: models) == "claude-opus-4.5")
    #expect(CopilotModelID.resolve("claude-opus-4-5[1m]", in: models) == "claude-opus-4.5")
}

@Test func resolveDoesNotFuzzyMatchShorterRequestToLongerModel() {
    let models = [
        CopilotUpstream.ModelInfo(
            id: "gpt-4o", clientID: "gpt-4o", claudeModelID: "gpt-4o",
            name: "GPT-4o", vendor: "openai", contextWindow: 128_000,
            supportsResponses: false, supportsMessages: false)
    ]
    // "gpt-4" has no exact match; it must NOT be silently mapped to "gpt-4o".
    #expect(CopilotModelID.resolve("gpt-4", in: models) == "gpt-4")
    // Exact match still works.
    #expect(CopilotModelID.resolve("gpt-4o", in: models) == "gpt-4o")
}

