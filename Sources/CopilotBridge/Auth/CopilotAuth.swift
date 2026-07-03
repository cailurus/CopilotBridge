import Foundation

/// Community-documented GitHub Copilot OAuth (unofficial; may change).
/// Ports the flow used by copilot-reverse: device-code login, then exchange the
/// GitHub token for a short-lived Copilot token used against api.githubcopilot.com.
enum CopilotAuth {
    static let clientID = "Iv1.b507a08c87ecfe98"
    static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let copilotTokenURL = URL(string: "https://api.github.com/copilot_internal/v2/token")!

    struct DeviceCode: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let interval: Int
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case interval
            case expiresIn = "expires_in"
        }
    }

    enum AuthError: LocalizedError {
        case deviceCodeFailed(Int)
        case authorizationFailed(String)
        case tokenExchangeFailed(Int)
        case noGitHubToken

        var errorDescription: String? {
            switch self {
            case .deviceCodeFailed(let s): return "Device code request failed (\(s))"
            case .authorizationFailed(let e): return "Authorization failed: \(e)"
            case .tokenExchangeFailed(let s):
                return (s == 401 || s == 403)
                    ? "GitHub login expired — sign in again."
                    : "Copilot token exchange failed (\(s))"
            case .noGitHubToken: return "Not signed in to GitHub."
            }
        }
    }

    // MARK: - Device code flow

    static func requestDeviceCode() async throws -> DeviceCode {
        var req = URLRequest(url: deviceCodeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "scope": "read:user",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.deviceCodeFailed((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Polls until the user authorizes; returns the long-lived GitHub token.
    static func pollForToken(deviceCode: String, intervalMs: Int) async throws -> String {
        while true {
            var req = URLRequest(url: accessTokenURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let token = obj["access_token"] as? String {
                return token
            }
            if let err = obj["error"] as? String,
               err != "authorization_pending", err != "slow_down" {
                throw AuthError.authorizationFailed(err)
            }
            try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
    }
}

/// Response shape of the Copilot token exchange.
private struct CopilotTokenResponse: Decodable {
    let token: String
    let expiresAt: Int
    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

/// Caches and refreshes the short-lived Copilot token derived from a GitHub token.
actor CopilotTokenStore {
    private var cached: (token: String, expiresAtMs: Double)?
    private let readGitHubToken: @Sendable () -> String?

    init(readGitHubToken: @escaping @Sendable () -> String?) {
        self.readGitHubToken = readGitHubToken
    }

    func get() async throws -> String {
        let skewMs: Double = 60_000
        if let cached, cached.expiresAtMs - skewMs > Date().timeIntervalSince1970 * 1000 {
            return cached.token
        }
        guard let gh = readGitHubToken() else { throw CopilotAuth.AuthError.noGitHubToken }
        var req = URLRequest(url: CopilotAuth.copilotTokenURL)
        req.setValue("token \(gh)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw CopilotAuth.AuthError.tokenExchangeFailed((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(CopilotTokenResponse.self, from: data)
        cached = (decoded.token, Double(decoded.expiresAt) * 1000)
        return decoded.token
    }

    func invalidate() {
        cached = nil
    }
}
