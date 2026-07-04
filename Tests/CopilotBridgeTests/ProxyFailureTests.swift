import Foundation
import Testing
@testable import CopilotBridge

@MainActor
private func makeSignedInState() -> AppState {
    let upstream = CopilotUpstream(tokens: CopilotTokenStore(readGitHubToken: { "unused" }))
    return AppState(
        settings: AppSettings(),
        readGitHubToken: { "github-token" },
        getCopilotToken: {
            CopilotTokenStore.Token(value: "copilot-token", apiBaseURL: CopilotUpstream.defaultAPIBaseURL)
        },
        invalidateCopilotToken: {},
        fetchAvailableModels: { _ in [] },
        forceFetchAvailableModels: { [] },
        upstream: upstream
    )
}

@Test @MainActor func listenerFailureFlipsRunningToError() {
    let state = makeSignedInState()
    state.forceProxyRunningForTesting()
    #expect(state.proxyStatus == ProxyStatus.running)

    state.handleProxyFailure("Address already in use")

    guard case .error(let message) = state.proxyStatus else {
        Issue.record("expected .error, got \(state.proxyStatus)")
        return
    }
    #expect(message.contains("Address already in use"))
}

@Test @MainActor func failureAfterDeliberateStopDoesNotClobberStopped() {
    let state = makeSignedInState()
    state.forceProxyRunningForTesting()
    state.stopProxy()
    #expect(state.proxyStatus == ProxyStatus.stopped)

    // A late .cancelled/.failed from the torn-down listener must not resurrect an error.
    state.handleProxyFailure("Operation cancelled")

    #expect(state.proxyStatus == ProxyStatus.stopped)
}
