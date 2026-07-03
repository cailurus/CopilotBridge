import Testing
@testable import CopilotBridge

@Test func microsoftMaiModelsAreGroupedSeparatelyFromGPT() {
    let model = CopilotUpstream.ModelInfo(
        id: "mai-ds-r1",
        clientID: "mai-ds-r1",
        claudeModelID: "mai-ds-r1",
        name: "MAI DS R1",
        vendor: "microsoft",
        contextWindow: 128_000,
        supportsResponses: true,
        supportsMessages: false
    )

    #expect(ModelFamily.family(of: model) == "Microsoft")
}
