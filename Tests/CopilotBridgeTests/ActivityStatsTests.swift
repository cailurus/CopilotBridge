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
            store.record(requests: ["gpt-5": 2, "claude": 1], tokens: ["gpt-5": 300, "claude": 50])
            store.record(requests: ["gpt-5": 1], tokens: ["gpt-5": 100])

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
            store.record(requests: ["m": 5], tokens: ["m": 999])
            #expect(store.today(.requests) == 5)
            #expect(store.today(.tokens) == 999)
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
            #expect(store.modelTotals(.requests).first?.count == 7)
        }
    }

    @Test func usageParserExtractsTotalTokens() {
        // OpenAI non-stream body.
        let body = Data(#"{"id":"x","usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}"#.utf8)
        #expect(ProxyEngine.extractUsageTokens(fromJSON: body) == 30)

        // A single SSE data-frame payload carrying usage.
        let frame = #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12}}"#
        #expect(ProxyEngine.extractUsageTokens(fromFramePayload: frame) == 12)

        // Anthropic-shaped usage (input+output, no total).
        let anthropic = #"{"type":"message_delta","usage":{"input_tokens":8,"output_tokens":4}}"#
        #expect(ProxyEngine.extractUsageTokens(fromFramePayload: anthropic) == 12)

        // No usage → nil.
        #expect(ProxyEngine.extractUsageTokens(fromFramePayload: #"{"choices":[{"delta":{}}]}"#) == nil)
    }
}
