import Foundation
import Testing
@testable import CopilotBridge

/// All tests here persist settings, so they must isolate SettingsStore to a temp dir
/// (otherwise `swift test` overwrites the user's real ~/Library/.../settings.json).
/// `.serialized` prevents the shared override from racing across tests.
@Suite(.serialized)
@MainActor
struct LANKeySuite {
    private func makeState(_ tempDir: URL) -> AppState {
        SettingsStore.directoryOverride = tempDir
        let upstream = CopilotUpstream(tokens: CopilotTokenStore(readGitHubToken: { "unused" }))
        return AppState(
            settings: AppSettings(),
            readGitHubToken: { "github-token" },
            getCopilotToken: {
                CopilotTokenStore.Token(value: "t", apiBaseURL: CopilotUpstream.defaultAPIBaseURL)
            },
            invalidateCopilotToken: {},
            fetchAvailableModels: { _ in [] },
            forceFetchAvailableModels: { [] },
            upstream: upstream
        )
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func switchingToLANGeneratesKeyWhenEmpty() {
        let dir = tempDir()
        let state = makeState(dir)
        defer { SettingsStore.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        #expect(state.settings.accessKey.isEmpty)

        state.setBindMode(.lan)

        #expect(state.settings.bindMode == BindMode.lan)
        #expect(!state.settings.accessKey.isEmpty)
        #expect(state.settings.accessKey.count >= 16)
    }

    @Test func switchingToLANKeepsExistingKey() {
        let dir = tempDir()
        let state = makeState(dir)
        defer { SettingsStore.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        state.settings.accessKey = "my-existing-key"

        state.setBindMode(.lan)

        #expect(state.settings.accessKey == "my-existing-key")
    }

    @Test func userCanClearKeyInLANMode() {
        let dir = tempDir()
        let state = makeState(dir)
        defer { SettingsStore.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        state.setBindMode(.lan)
        #expect(!state.settings.accessKey.isEmpty)

        state.settings.accessKey = ""
        state.persist()

        #expect(state.settings.accessKey.isEmpty)
        #expect(state.settings.bindMode == BindMode.lan)
    }
}
