import Foundation
import ServiceManagement
import SwiftUI

enum ProxyStatus: Equatable {
    case stopped
    case running
    case error(String)
}

enum LoginStatus: Equatable {
    case signedOut
    case pending(userCode: String, url: String)
    case signedIn
    case checking
}

/// Central app state: auth, proxy lifecycle, profiles, and settings persistence.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private var didLaunch = false
    @Published var settings: AppSettings
    @Published private(set) var proxyStatus: ProxyStatus = .stopped
    @Published private(set) var loginStatus: LoginStatus = .signedOut
    @Published private(set) var availableModels: [CopilotUpstream.ModelInfo] = []
    @Published var lastActivity: String = "Idle"

    private let tokens: CopilotTokenStore
    private let upstream: CopilotUpstream
    private var engine: ProxyEngine?
    private var server: HTTPServer?
    private var loginTask: Task<Void, Never>?
    private var statsTimer: Timer?

    init() {
        let settings = SettingsStore.load()
        self.settings = settings
        let store = CopilotTokenStore(readGitHubToken: { Keychain.load() })
        self.tokens = store
        self.upstream = CopilotUpstream(tokens: store)
        if Keychain.load() != nil {
            self.loginStatus = .checking
        }
    }

    // MARK: Lifecycle

    func onLaunch() {
        guard !didLaunch else { return }
        didLaunch = true
        Task { await verifyLogin() }
        if settings.autoStartProxy, Keychain.load() != nil {
            startProxy()
        }
    }

    var endpoint: ConfigWriter.Endpoint {
        ConfigWriter.Endpoint(
            host: settings.bindMode == .lan ? localIPAddress() : "127.0.0.1",
            port: settings.port,
            apiKey: settings.accessKey.isEmpty ? "copilot-bridge-local" : settings.accessKey
        )
    }

    // MARK: Auth

    func verifyLogin() async {
        guard Keychain.load() != nil else {
            loginStatus = .signedOut
            return
        }
        loginStatus = .checking
        do {
            _ = try await tokens.get()
            loginStatus = .signedIn
            await refreshModels()
        } catch {
            loginStatus = .signedOut
        }
    }

    func startLogin() {
        loginTask?.cancel()
        loginTask = Task {
            do {
                let device = try await CopilotAuth.requestDeviceCode()
                loginStatus = .pending(userCode: device.userCode, url: device.verificationURI)
                if let url = URL(string: device.verificationURI) {
                    NSWorkspace.shared.open(url)
                }
                let ghToken = try await CopilotAuth.pollForToken(
                    deviceCode: device.deviceCode,
                    intervalMs: max(device.interval, 5) * 1000)
                Keychain.save(ghToken)
                await tokens.invalidate()
                await verifyLogin()
                if settings.autoStartProxy { startProxy() }
            } catch {
                if !Task.isCancelled {
                    loginStatus = .signedOut
                    lastActivity = "Login failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func signOut() {
        loginTask?.cancel()
        Keychain.clear()
        Task { await tokens.invalidate() }
        loginStatus = .signedOut
        stopProxy()
    }

    func refreshModels() async {
        availableModels = await upstream.models()
    }

    // MARK: Proxy

    func startProxy() {
        guard server == nil else { return }
        let engine = ProxyEngine(
            upstream: upstream,
            snapshot: .init(lanMode: settings.bindMode == .lan, accessKey: settings.accessKey))
        self.engine = engine
        let server = HTTPServer { [engine] req in
            await engine.handle(req)
        }
        do {
            let host = settings.bindMode.bindHost
            try server.start(host: host, port: settings.port)
            self.server = server
            proxyStatus = .running
            lastActivity = "Proxy listening on \(settings.port)"
            startStatsTimer()
        } catch {
            proxyStatus = .error(error.localizedDescription)
            self.server = nil
            self.engine = nil
        }
    }

    func stopProxy() {
        server?.stop()
        server = nil
        engine = nil
        statsTimer?.invalidate()
        statsTimer = nil
        proxyStatus = .stopped
        lastActivity = "Proxy stopped"
    }

    func restartProxy() {
        stopProxy()
        startProxy()
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                let (count, err) = await engine.stats()
                if let err {
                    self.lastActivity = "Last error: \(err.prefix(80))"
                } else if count > 0 {
                    self.lastActivity = "\(count) request(s) served"
                }
            }
        }
    }

    // MARK: Settings persistence + propagation

    func persist() {
        SettingsStore.save(settings)
        if let engine {
            let snapshot = ProxyEngine.Snapshot(lanMode: settings.bindMode == .lan, accessKey: settings.accessKey)
            Task { await engine.update(snapshot: snapshot) }
        }
    }

    // MARK: Profiles

    func addProfile(_ profile: Profile) {
        settings.profiles.append(profile)
        persist()
    }

    func removeProfile(_ profile: Profile) {
        try? ConfigWriter.revert(profile.client)
        settings.profiles.removeAll { $0.id == profile.id }
        persist()
    }

    /// Applies a profile to its client's system config; unapplies others of the same client.
    func applyProfile(_ profile: Profile) {
        do {
            try ConfigWriter.apply(profile, endpoint: endpoint)
            for idx in settings.profiles.indices {
                if settings.profiles[idx].client == profile.client {
                    settings.profiles[idx].applied = (settings.profiles[idx].id == profile.id)
                }
            }
            persist()
            lastActivity = "Applied \(profile.name)"
        } catch {
            lastActivity = "Apply failed: \(error.localizedDescription)"
        }
    }

    func unapplyProfile(_ profile: Profile) {
        do {
            try ConfigWriter.revert(profile.client)
            if let idx = settings.profiles.firstIndex(where: { $0.id == profile.id }) {
                settings.profiles[idx].applied = false
            }
            persist()
            lastActivity = "Reverted \(profile.client.displayName) config"
        } catch {
            lastActivity = "Revert failed: \(error.localizedDescription)"
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastActivity = "Launch-at-login: \(error.localizedDescription)"
        }
        persist()
    }

    // MARK: helpers

    var baseURLSummary: String {
        "http://\(settings.bindMode == .lan ? localIPAddress() : "127.0.0.1"):\(settings.port)"
    }
}

/// Best-effort primary LAN IPv4 for LAN-mode display.
func localIPAddress() -> String {
    var address = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = ptr {
        let flags = Int32(cur.pointee.ifa_flags)
        let addr = cur.pointee.ifa_addr.pointee
        if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
           addr.sa_family == UInt8(AF_INET) {
            let name = String(cString: cur.pointee.ifa_name)
            if name == "en0" || name == "en1" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(cur.pointee.ifa_addr, socklen_t(addr.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = host.withUnsafeBufferPointer { String(decoding: $0.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                }
            }
        }
        ptr = cur.pointee.ifa_next
    }
    freeifaddrs(ifaddr)
    return address
}
