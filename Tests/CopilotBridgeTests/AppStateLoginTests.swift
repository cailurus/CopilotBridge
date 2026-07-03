import Foundation
import Testing
@testable import CopilotBridge

@Test @MainActor func verifyLoginDoesNotWaitForModelRefresh() async {
    let upstream = CopilotUpstream(tokens: CopilotTokenStore(readGitHubToken: { "unused" }))
    let state = AppState(
        settings: AppSettings(),
        readGitHubToken: { "github-token" },
        getCopilotToken: {
            CopilotTokenStore.Token(
                value: "copilot-token",
                apiBaseURL: CopilotUpstream.defaultAPIBaseURL
            )
        },
        invalidateCopilotToken: {},
        fetchAvailableModels: { _ in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return []
        },
        forceFetchAvailableModels: { [] },
        upstream: upstream
    )

    let start = ContinuousClock.now
    let signedIn = await state.verifyLogin()
    let elapsed = start.duration(to: .now)

    #expect(signedIn)
    #expect(state.loginStatus == LoginStatus.signedIn)
    #expect(elapsed < .milliseconds(200))
}
