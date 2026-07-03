import Foundation
import Testing
@testable import CopilotBridge

@Test func forceRefreshBypassesFreshModelCache() {
    let cachedAt = Date(timeIntervalSince1970: 1_000)
    let now = cachedAt.addingTimeInterval(30)

    #expect(CopilotModelCachePolicy.canUseCache(
        cachedAt: cachedAt,
        now: now,
        hasModels: true,
        forceRefresh: false
    ))
    #expect(!CopilotModelCachePolicy.canUseCache(
        cachedAt: cachedAt,
        now: now,
        hasModels: true,
        forceRefresh: true
    ))
}
