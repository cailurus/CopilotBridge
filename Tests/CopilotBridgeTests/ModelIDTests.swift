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

@Test func claudeCodeOneMillionMarkerOnlyAppliesToClaudeModels() throws {
    let tempHome = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    ConfigWriter.homeOverride = tempHome
    defer {
        ConfigWriter.homeOverride = nil
        try? FileManager.default.removeItem(at: tempHome)
    }

    let endpoint = ConfigWriter.Endpoint(host: "127.0.0.1", port: 10086, apiKey: "test")
    let profile = Profile(name: "GPT", client: .claudeCode, model: "gpt-5.5", contextWindow: 1_050_000)

    try ConfigWriter.applyClaude(profile, endpoint: endpoint)

    let data = try Data(contentsOf: tempHome.appendingPathComponent(".claude/settings.json"))
    let settings = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let env = try #require(settings["env"] as? [String: Any])
    #expect(env["ANTHROPIC_MODEL"] as? String == "gpt-5.5")
}
