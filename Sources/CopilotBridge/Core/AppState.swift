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

/// Drives the Codex history-migration sheet: which prior providers were detected
/// (with thread counts) and an optional message from a blocked attempt.
struct MigrationPrompt: Identifiable, Equatable {
    let id = UUID()
    let providers: [CodexHistoryStore.ProviderCount]
    var errorMessage: String?
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
    @Published private(set) var requestCount = 0
    @Published private(set) var lastError: String?
    /// Set after applying a Codex profile when prior threads use another provider,
    /// which drives the migration prompt sheet.
    @Published var pendingMigration: MigrationPrompt?
    let activity = ActivityStore()

    private let upstream: CopilotUpstream
    private let readGitHubToken: @Sendable () -> String?
    private let getCopilotToken: @Sendable () async throws -> CopilotTokenStore.Token
    private let invalidateCopilotToken: @Sendable () async -> Void
    private let fetchAvailableModels: @Sendable (Bool) async -> [CopilotUpstream.ModelInfo]
    private let forceFetchAvailableModels: @Sendable () async throws -> [CopilotUpstream.ModelInfo]
    private var engine: ProxyEngine?
    private var server: HTTPServer?
    private var loginTask: Task<Void, Never>?
    private var modelRefreshTask: Task<Void, Never>?
    private var statsTimer: Timer?

    convenience init() {
        let store = CopilotTokenStore(readGitHubToken: { Keychain.load() })
        let upstream = CopilotUpstream(tokens: store)
        self.init(
            settings: SettingsStore.load(),
            readGitHubToken: { Keychain.load() },
            getCopilotToken: { try await store.get() },
            invalidateCopilotToken: { await store.invalidate() },
            fetchAvailableModels: { forceRefresh in await upstream.models(forceRefresh: forceRefresh) },
            forceFetchAvailableModels: { try await upstream.refreshModels() },
            upstream: upstream
        )
    }

    init(
        settings: AppSettings,
        readGitHubToken: @escaping @Sendable () -> String?,
        getCopilotToken: @escaping @Sendable () async throws -> CopilotTokenStore.Token,
        invalidateCopilotToken: @escaping @Sendable () async -> Void,
        fetchAvailableModels: @escaping @Sendable (Bool) async -> [CopilotUpstream.ModelInfo],
        forceFetchAvailableModels: @escaping @Sendable () async throws -> [CopilotUpstream.ModelInfo],
        upstream: CopilotUpstream
    ) {
        self.settings = settings
        self.readGitHubToken = readGitHubToken
        self.getCopilotToken = getCopilotToken
        self.invalidateCopilotToken = invalidateCopilotToken
        self.fetchAvailableModels = fetchAvailableModels
        self.forceFetchAvailableModels = forceFetchAvailableModels
        self.upstream = upstream
        if readGitHubToken() != nil {
            self.loginStatus = .checking
        }
    }

    // MARK: Lifecycle

    func onLaunch() {
        guard !didLaunch else { return }
        didLaunch = true
        Task {
            let signedIn = await verifyLogin()
            if signedIn, settings.autoStartProxy {
                startProxy()
            }
        }
    }

    var endpoint: ConfigWriter.Endpoint {
        ConfigWriter.Endpoint(
            host: settings.bindMode == .lan ? localIPAddress() : "127.0.0.1",
            port: settings.port,
            apiKey: settings.accessKey.isEmpty ? "copilot-bridge-local" : settings.accessKey
        )
    }

    /// Switches the bind mode. Turning on LAN with no key generates a secure one
    /// (safe default), but the user may still clear it afterwards to run without
    /// auth — their machine, their call.
    func setBindMode(_ mode: BindMode) {
        settings.bindMode = mode
        if mode == .lan, settings.accessKey.isEmpty {
            settings.accessKey = Self.generateAccessKey()
        }
        persist()
    }

    static func generateAccessKey() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    }

    /// True when LAN mode is on but no access key is set, i.e. any device on the
    /// network can use the proxy unauthenticated. Drives the inline warning.
    var lanIsUnauthenticated: Bool {
        settings.bindMode == .lan && settings.accessKey.isEmpty
    }

    // MARK: Auth

    @discardableResult
    func verifyLogin() async -> Bool {
        guard readGitHubToken() != nil else {
            loginStatus = .signedOut
            availableModels = []
            stopProxyIfNeeded(activity: nil)
            return false
        }
        loginStatus = .checking
        do {
            _ = try await getCopilotToken()
            loginStatus = .signedIn
            refreshModelsInBackground()
            return true
        } catch {
            await invalidateCopilotToken()
            loginStatus = .signedOut
            availableModels = []
            lastActivity = "Login check failed: \(error.localizedDescription)"
            stopProxyIfNeeded(activity: lastActivity)
            return false
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
                await invalidateCopilotToken()
                let signedIn = await verifyLogin()
                if signedIn, settings.autoStartProxy { startProxy() }
            } catch {
                if !Task.isCancelled {
                    loginStatus = .signedOut
                    availableModels = []
                    lastActivity = "Login failed: \(error.localizedDescription)"
                    stopProxyIfNeeded(activity: lastActivity)
                }
            }
        }
    }

    func signOut() {
        loginTask?.cancel()
        modelRefreshTask?.cancel()
        Keychain.clear()
        Task { await invalidateCopilotToken() }
        loginStatus = .signedOut
        stopProxy()
    }

    func forceRefreshModels() async throws {
        availableModels = try await forceFetchAvailableModels()
    }

    private func refreshModelsInBackground(forceRefresh: Bool = false) {
        modelRefreshTask?.cancel()
        modelRefreshTask = Task { [weak self] in
            guard let self else { return }
            let models = await self.fetchAvailableModels(forceRefresh)
            guard !Task.isCancelled else { return }
            self.availableModels = models
        }
    }

    // MARK: Proxy

    func startProxy() {
        guard loginStatus == .signedIn else {
            proxyStatus = .stopped
            lastActivity = "Sign in to GitHub before starting the proxy"
            return
        }
        guard server == nil else { return }
        let engine = ProxyEngine(
            upstream: upstream,
            snapshot: .init(lanMode: settings.bindMode == .lan, accessKey: settings.accessKey))
        self.engine = engine
        let server = HTTPServer { [engine] req in
            await engine.handle(req)
        }
        server.setFailureHandler { [weak self] message in
            Task { @MainActor in self?.handleProxyFailure(message) }
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

    /// Called when the running listener stops serving unexpectedly. Reflects the real
    /// listener state in the UI instead of leaving a stale "Running". Ignored if the
    /// proxy was already torn down (stale callback after a deliberate stop).
    func handleProxyFailure(_ message: String) {
        guard server != nil else { return }
        server = nil
        engine = nil
        statsTimer?.invalidate()
        statsTimer = nil
        proxyStatus = .error(message)
        lastError = message
        lastActivity = "Proxy stopped: \(message)"
        requestCount = 0
    }

    #if DEBUG
    /// Test seam: puts the proxy into the running state without binding a socket.
    func forceProxyRunningForTesting() {
        server = HTTPServer { _ in .text(200, "test") }
        proxyStatus = .running
    }
    #endif

    func stopProxy() {
        server?.stop()
        server = nil
        engine = nil
        statsTimer?.invalidate()
        statsTimer = nil
        proxyStatus = .stopped
        lastActivity = "Proxy stopped"
        requestCount = 0
        lastError = nil
    }

    private func stopProxyIfNeeded(activity: String? = "Proxy stopped") {
        guard server != nil else {
            proxyStatus = .stopped
            return
        }
        stopProxy()
        if let activity {
            lastActivity = activity
        }
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
                self.requestCount = count
                self.lastError = err
                let stats = await engine.drainModelStats()
                self.activity.record(requests: stats.requests, tokens: stats.tokens)
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
            offerHistoryMigrationIfNeeded(for: profile)
        } catch {
            lastActivity = "Apply failed: \(error.localizedDescription)"
        }
    }

    // MARK: Codex history migration

    /// After applying a Codex profile, offer to relabel threads from a previously-used
    /// provider so they stay visible in Codex's provider-grouped history list.
    private func offerHistoryMigrationIfNeeded(for profile: Profile) {
        guard profile.client == .codex || profile.client == .codexCLI else { return }
        guard let others = try? CodexHistoryStore.otherProviders(), !others.isEmpty else { return }
        pendingMigration = MigrationPrompt(providers: others)
    }

    /// Relabels the chosen providers' threads to Copilot Bridge. Keeps the sheet open
    /// with a message if Codex is still running (its database can't be written safely).
    func confirmMigration(providers: [String]) {
        do {
            let moved = try CodexHistoryStore.migrate(providers: providers)
            lastActivity = "Migrated \(moved) conversation(s) to Copilot Bridge"
            pendingMigration = nil
        } catch let error as CodexHistoryStore.HistoryError {
            if case .codexRunning = error, let current = pendingMigration {
                pendingMigration = MigrationPrompt(
                    providers: current.providers,
                    errorMessage: error.localizedDescription)
            } else {
                lastActivity = "Migration failed: \(error.localizedDescription)"
                pendingMigration = nil
            }
        } catch {
            lastActivity = "Migration failed: \(error.localizedDescription)"
            pendingMigration = nil
        }
    }

    func dismissMigration() {
        pendingMigration = nil
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
