import Foundation
import Testing
@testable import CopilotBridge

@Test func isNewerComparesSemver() {
    #expect(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
    #expect(UpdateChecker.isNewer("v0.2.0", than: "0.1.9"))
    #expect(UpdateChecker.isNewer("2.0", than: "1.9.9"))
    #expect(UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
    #expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
    #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))     // equal, padded
    #expect(!UpdateChecker.isNewer("0.1.2", than: "0.1.3"))
    #expect(!UpdateChecker.isNewer("v1.0.0", than: "v1.0.0"))
}

@Test func parseLatestExtractsTagAndDmgURL() throws {
    let json = """
    {
      "tag_name": "v0.1.3",
      "html_url": "https://github.com/cailurus/CopilotBridge/releases/tag/v0.1.3",
      "assets": [
        {"name": "CopilotBridge-0.1.3-app.zip", "browser_download_url": "https://example.com/app.zip"},
        {"name": "CopilotBridge-0.1.3.dmg", "browser_download_url": "https://example.com/CopilotBridge-0.1.3.dmg"}
      ]
    }
    """
    let parsed = try #require(UpdateChecker.parseLatest(Data(json.utf8)))
    #expect(parsed.tag == "v0.1.3")
    // Prefer the .dmg asset over the release page.
    #expect(parsed.downloadURL == "https://example.com/CopilotBridge-0.1.3.dmg")
}

@Test func parseLatestFallsBackToHtmlURLWithoutDmg() throws {
    let json = """
    {
      "tag_name": "v0.1.3",
      "html_url": "https://github.com/cailurus/CopilotBridge/releases/tag/v0.1.3",
      "assets": [
        {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"}
      ]
    }
    """
    let parsed = try #require(UpdateChecker.parseLatest(Data(json.utf8)))
    #expect(parsed.downloadURL == "https://github.com/cailurus/CopilotBridge/releases/tag/v0.1.3")
}

@Test func parseLatestRejectsGarbage() {
    #expect(UpdateChecker.parseLatest(Data("not json".utf8)) == nil)
}
