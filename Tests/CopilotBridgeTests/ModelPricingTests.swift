import Foundation
import Testing
@testable import CopilotBridge

@Test func pricingKnownModelComputesInputPlusOutput() {
    // gpt-4o: input $2.5/M, output $10/M (see ModelPricing.table).
    let cost = ModelPricing.cost(model: "gpt-4o", inputTokens: 1_000_000, outputTokens: 1_000_000)
    #expect(abs(cost - (2.5 + 10.0)) < 0.0001)
}

@Test func pricingHalfMillionScales() {
    let cost = ModelPricing.cost(model: "gpt-4o", inputTokens: 500_000, outputTokens: 0)
    #expect(abs(cost - 1.25) < 0.0001)
}

@Test func pricingUnknownModelIsZero() {
    #expect(ModelPricing.cost(model: "totally-made-up-model", inputTokens: 1_000_000, outputTokens: 1_000_000) == 0)
}

@Test func pricingFamilyFallbackForDatedClaude() {
    // A dated/suffixed Claude id should fall back to the sonnet row, not price at 0.
    let dated = ModelPricing.cost(model: "claude-3.5-sonnet-20240620", inputTokens: 1_000_000, outputTokens: 0)
    let base = ModelPricing.cost(model: "claude-sonnet-4", inputTokens: 1_000_000, outputTokens: 0)
    #expect(dated > 0)
    #expect(abs(dated - base) < 0.0001)
}

@Test func pricingStripsOneMSuffix() {
    let a = ModelPricing.cost(model: "gpt-5", inputTokens: 1_000_000, outputTokens: 0)
    let b = ModelPricing.cost(model: "gpt-5[1m]", inputTokens: 1_000_000, outputTokens: 0)
    #expect(a > 0)
    #expect(abs(a - b) < 0.0001)
}
