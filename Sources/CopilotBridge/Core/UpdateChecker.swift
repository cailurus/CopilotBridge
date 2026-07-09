import Foundation

/// App metadata read from the bundle (single source of truth = Info.plist).
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}

/// Result of an update check, surfaced to the UI.
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, url: String)
    case failed(String)
}

/// Checks GitHub Releases for a newer version. Manual/guided install only — this never
/// downloads or replaces the app; it points the user at the release download.
enum UpdateChecker {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/cailurus/CopilotBridge/releases/latest")!

    /// True if `remote` is a strictly higher semantic version than `local`.
    /// Tolerant of a leading `v` and missing components (treated as 0).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote)
        let l = components(local)
        let n = max(r.count, l.count)
        for i in 0..<n {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespaces)
            .drop { $0 == "v" || $0 == "V" }
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// Parses a GitHub `releases/latest` payload into a tag and a best download URL
    /// (the `.dmg` asset if present, else the release page).
    static func parseLatest(_ data: Data) -> (tag: String, downloadURL: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
        let url = (dmg?["browser_download_url"] as? String)
            ?? (obj["html_url"] as? String)
            ?? "https://github.com/cailurus/CopilotBridge/releases/latest"
        return (tag, url)
    }

    /// Fetches the latest release and compares it to `currentVersion`.
    static func check(currentVersion: String) async -> UpdateStatus {
        var req = URLRequest(url: latestReleaseURL, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CopilotBridge", forHTTPHeaderField: "User-Agent")   // GitHub requires a UA
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed("Update check failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
            }
            guard let parsed = parseLatest(data) else {
                return .failed("Unexpected response from GitHub.")
            }
            return isNewer(parsed.tag, than: currentVersion)
                ? .available(version: parsed.tag, url: parsed.downloadURL)
                : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
