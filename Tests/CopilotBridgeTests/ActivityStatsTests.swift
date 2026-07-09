import Foundation
import Testing
@testable import CopilotBridge

/// These tests touch ActivityStore, which persists to SettingsStore.directory — isolate
/// it so `swift test` never writes the user's real activity.json.
@Suite(.serialized)
@MainActor
struct ActivityStatsSuite {
    private func withTempDir(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SettingsStore.directoryOverride = dir
        defer { SettingsStore.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func recordAccumulatesRequestsAndTokensPerModel() {
        withTempDir { _ in
            let store = ActivityStore()
            store.record(requests: ["gpt-5": 2, "claude": 1], inputTokens: ["gpt-5": 200, "claude": 40], outputTokens: ["gpt-5": 100, "claude": 10])
            store.record(requests: ["gpt-5": 1], inputTokens: ["gpt-5": 60], outputTokens: ["gpt-5": 40])

            #expect(store.total(.requests) == 4)
            #expect(store.total(.tokens) == 450)

            let reqTotals = store.modelTotals(.requests)
            #expect(reqTotals.first?.model == "gpt-5")
            #expect(reqTotals.first?.count == 3)

            let tokTotals = store.modelTotals(.tokens)
            #expect(tokTotals.first?.model == "gpt-5")
            #expect(tokTotals.first?.count == 400)
        }
    }

    @Test func todayReflectsSelectedUnit() {
        withTempDir { _ in
            let store = ActivityStore()
            store.record(requests: ["m": 5], inputTokens: ["m": 600], outputTokens: ["m": 399])
            #expect(store.today(.requests) == 5)
            #expect(store.today(.tokens) == 999)
        }
    }

    @Test func costTotalUsesPricing() {
        withTempDir { _ in
            let store = ActivityStore()
            // gpt-4o: $2.5/M input, $10/M output.
            store.record(requests: ["gpt-4o": 1], inputTokens: ["gpt-4o": 1_000_000], outputTokens: ["gpt-4o": 1_000_000])
            #expect(abs(store.costTotal() - 12.5) < 0.0001)
            #expect(abs(store.costToday() - 12.5) < 0.0001)
            #expect(store.modelCostTotals().first?.model == "gpt-4o")
        }
    }

    @Test func legacyActivityJSONLoadsAsRequestsWithZeroTokens() throws {
        try withTempDir { dir in
            // Legacy format: [day: [model: Int]] (requests only).
            let legacy = ["2026-07-01": ["gpt-5": 7]]
            let data = try JSONSerialization.data(withJSONObject: legacy)
            try data.write(to: dir.appendingPathComponent("activity.json"))

            let store = ActivityStore()   // load() runs in init
            #expect(store.total(.requests) == 7)
            #expect(store.total(.tokens) == 0)
            #expect(store.costTotal() == 0)
            #expect(store.modelTotals(.requests).first?.count == 7)
        }
    }

    @Test func midSchemaActivityJSONWithoutSplitLoadsZeroCost() throws {
        try withTempDir { dir in
            // Prior schema: Stat with requests+tokens but no input/output split.
            let mid = ["2026-07-01": ["gpt-5": ["requests": 3, "tokens": 500]]]
            let data = try JSONSerialization.data(withJSONObject: mid)
            try data.write(to: dir.appendingPathComponent("activity.json"))

            let store = ActivityStore()
            #expect(store.total(.requests) == 3)
            #expect(store.total(.tokens) == 500)
            // No split → cost 0 (no crash).
            #expect(store.costTotal() == 0)
        }
    }

    @Test func usageParserExtractsSplitTokens() {
        // OpenAI non-stream body.
        let body = Data(#"{"id":"x","usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}"#.utf8)
        let a = ProxyEngine.extractUsage(fromJSON: body)
        #expect(a?.input == 10)
        #expect(a?.output == 20)

        // OpenAI SSE data-frame payload.
        let frame = #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7}}"#
        let b = ProxyEngine.extractUsage(fromFramePayload: frame)
        #expect(b?.input == 5)
        #expect(b?.output == 7)

        // Anthropic-shaped usage.
        let anthropic = #"{"type":"message_delta","usage":{"input_tokens":8,"output_tokens":4}}"#
        let c = ProxyEngine.extractUsage(fromFramePayload: anthropic)
        #expect(c?.input == 8)
        #expect(c?.output == 4)

        // total_tokens-only → attributed to output.
        let totalOnly = #"{"usage":{"total_tokens":42}}"#
        let d = ProxyEngine.extractUsage(fromFramePayload: totalOnly)
        #expect(d?.input == 0)
        #expect(d?.output == 42)

        // No usage → nil.
        #expect(ProxyEngine.extractUsage(fromFramePayload: #"{"choices":[{"delta":{}}]}"#) == nil)
    }
}
