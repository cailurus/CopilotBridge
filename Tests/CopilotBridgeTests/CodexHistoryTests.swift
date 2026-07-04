import Foundation
import SQLite3
import Testing
@testable import CopilotBridge

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Creates a temp home with a `.codex/<name>` SQLite fixture containing a `threads`
/// table seeded with the given (provider, archived, preview) rows. Returns the temp home.
@discardableResult
private func makeCodexFixture(
    dbName: String = "state_5.sqlite",
    rows: [(provider: String, archived: Int, preview: String)],
    createThreadsTable: Bool = true
) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codex = home.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)

    var db: OpaquePointer?
    #expect(sqlite3_open(codex.appendingPathComponent(dbName).path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }

    if createThreadsTable {
        #expect(sqlite3_exec(db, """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                model_provider TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0,
                preview TEXT NOT NULL DEFAULT ''
            );
        """, nil, nil, nil) == SQLITE_OK)

        for (i, row) in rows.enumerated() {
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(db,
                "INSERT INTO threads (id, model_provider, archived, preview) VALUES (?1,?2,?3,?4)",
                -1, &stmt, nil) == SQLITE_OK)
            sqlite3_bind_text(stmt, 1, "id-\(i)", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(row.archived))
            sqlite3_bind_text(stmt, 4, row.preview, -1, SQLITE_TRANSIENT)
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    } else {
        #expect(sqlite3_exec(db, "CREATE TABLE other (id TEXT);", nil, nil, nil) == SQLITE_OK)
    }

    return home
}

private func providerCounts(inDBAt url: URL) -> [String: Int] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT model_provider, COUNT(*) FROM threads GROUP BY 1", -1, &stmt, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_finalize(stmt) }
    var out: [String: Int] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let c = sqlite3_column_text(stmt, 0) {
            out[String(cString: c)] = Int(sqlite3_column_int(stmt, 1))
        }
    }
    return out
}

/// These tests mutate the process-global `ConfigWriter.homeOverride`, so they must not
/// run concurrently with each other (or with other home-override tests). `.serialized`
/// forces sequential execution within the suite.
@Suite(.serialized)
struct CodexHistorySuite {

@Test func otherProvidersExcludesTargetAndEmpty() throws {
    let home = try makeCodexFixture(rows: [
        ("agent-maestro", 0, "hi"),
        ("agent-maestro", 0, "yo"),
        ("copilot-bridge", 0, "already"),
        ("", 0, "no-provider"),
    ])
    ConfigWriter.homeOverride = home
    defer { ConfigWriter.homeOverride = nil; try? FileManager.default.removeItem(at: home) }

    let others = try CodexHistoryStore.otherProviders()
    #expect(others == [CodexHistoryStore.ProviderCount(provider: "agent-maestro", count: 2)])
}

@Test func migrateFlipsProviderAndPreservesOtherColumns() throws {
    let home = try makeCodexFixture(rows: [
        ("agent-maestro", 0, "keep-preview"),
        ("agent-maestro", 1, "archived-one"),
        ("copilot-bridge", 0, "untouched"),
    ])
    ConfigWriter.homeOverride = home
    defer { ConfigWriter.homeOverride = nil; try? FileManager.default.removeItem(at: home) }

    let moved = try CodexHistoryStore.migrate(providers: ["agent-maestro"], codexRunning: { false })
    #expect(moved == 2)

    let dbURL = try #require(CodexHistoryStore.stateDBURL)
    let counts = providerCounts(inDBAt: dbURL)
    #expect(counts["copilot-bridge"] == 3)
    #expect(counts["agent-maestro"] == nil)

    // archived + preview columns must be intact.
    var db: OpaquePointer?
    sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM threads WHERE archived=1 AND preview='archived-one'", -1, &stmt, nil)
    sqlite3_step(stmt)
    #expect(sqlite3_column_int(stmt, 0) == 1)
    sqlite3_finalize(stmt)
}

@Test func migrateBacksUpDatabase() throws {
    let home = try makeCodexFixture(rows: [("agent-maestro", 0, "x")])
    ConfigWriter.homeOverride = home
    defer { ConfigWriter.homeOverride = nil; try? FileManager.default.removeItem(at: home) }

    _ = try CodexHistoryStore.migrate(providers: ["agent-maestro"], codexRunning: { false })

    let backups = home.appendingPathComponent("Library/Application Support/CopilotBridge/backups", isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
    #expect(files.contains { $0.hasPrefix("state_5.sqlite.") && $0.hasSuffix(".bak") })
}

@Test func migrateRefusesWhenCodexRunning() throws {
    let home = try makeCodexFixture(rows: [("agent-maestro", 0, "x")])
    ConfigWriter.homeOverride = home
    defer { ConfigWriter.homeOverride = nil; try? FileManager.default.removeItem(at: home) }

    #expect(throws: CodexHistoryStore.HistoryError.self) {
        try CodexHistoryStore.migrate(providers: ["agent-maestro"], codexRunning: { true })
    }
    // DB must be untouched.
    let dbURL = try #require(CodexHistoryStore.stateDBURL)
    #expect(providerCounts(inDBAt: dbURL)["agent-maestro"] == 1)
}

@Test func stateDBURLIgnoresFileWithoutThreadsTable() throws {
    // Decoy state_9.sqlite lacks a threads table; only state_5.sqlite has one.
    let home = try makeCodexFixture(rows: [("agent-maestro", 0, "x")])
    ConfigWriter.homeOverride = home
    defer { ConfigWriter.homeOverride = nil; try? FileManager.default.removeItem(at: home) }

    // Add a decoy DB with no threads table.
    let codex = home.appendingPathComponent(".codex", isDirectory: true)
    var db: OpaquePointer?
    sqlite3_open(codex.appendingPathComponent("state_9.sqlite").path, &db)
    sqlite3_exec(db, "CREATE TABLE other (id TEXT);", nil, nil, nil)
    sqlite3_close(db)

    let picked = try #require(CodexHistoryStore.stateDBURL)
    #expect(picked.lastPathComponent == "state_5.sqlite")
}

@MainActor
private func makeSignedInState() -> AppState {
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

@Test @MainActor func applyingCodexProfileWithPriorProvidersSetsPendingMigration() throws {
    let home = try makeCodexFixture(rows: [("agent-maestro", 0, "x"), ("agent-maestro", 0, "y")])
    ConfigWriter.homeOverride = home
    defer { ConfigWriter.homeOverride = nil; try? FileManager.default.removeItem(at: home) }

    let state = makeSignedInState()
    state.applyProfile(Profile(name: "Codex · gpt-5", client: .codexCLI, model: "gpt-5"))

    let prompt = try #require(state.pendingMigration)
    #expect(prompt.providers.contains { $0.provider == "agent-maestro" && $0.count == 2 })

    state.dismissMigration()
    #expect(state.pendingMigration == nil)
}

@Test @MainActor func applyingClaudeProfileNeverPrompts() throws {
    let home = try makeCodexFixture(rows: [("agent-maestro", 0, "x")])
    ConfigWriter.homeOverride = home
    defer { ConfigWriter.homeOverride = nil; try? FileManager.default.removeItem(at: home) }

    let state = makeSignedInState()
    state.applyProfile(Profile(name: "Claude", client: .claudeCode, model: "claude-sonnet-4"))
    #expect(state.pendingMigration == nil)
}

@Test func claudeCodeOneMillionMarkerOnlyAppliesToClaudeModels() throws {
    let tempHome = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    ConfigWriter.homeOverride = tempHome
    defer {
        ConfigWriter.homeOverride = nil
        try? FileManager.default.removeItem(at: tempHome)
    }

    let endpoint = ConfigWriter.Endpoint(host: "127.0.0.1", port: 10086, apiKey: "test")
    let profile = Profile(name: "GPT", client: .claudeCode, model: "gpt-5.5", contextWindow: 1_050_000)

    try ConfigWriter.applyClaude(profile, endpoint: endpoint)

    let data = try Data(contentsOf: tempHome.appendingPathComponent(".claude/settings.json"))
    let settings = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let env = try #require(settings["env"] as? [String: Any])
    #expect(env["ANTHROPIC_MODEL"] as? String == "gpt-5.5")
}

}


