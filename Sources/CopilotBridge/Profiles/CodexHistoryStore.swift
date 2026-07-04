import Foundation
import SQLite3
import AppKit

/// Reads and (optionally) rewrites the `model_provider` column in Codex's session
/// database (`~/.codex/state_*.sqlite`, table `threads`). Codex groups its history
/// list by the active provider, so switching to Copilot Bridge hides threads created
/// under a previous provider. Migrating relabels those threads so they stay visible.
///
/// Paths resolve from `ConfigWriter.home`, so `ConfigWriter.homeOverride` redirects
/// this at test time. No UI here — callers own presentation.
enum CodexHistoryStore {
    struct ProviderCount: Equatable, Sendable {
        let provider: String
        let count: Int
    }

    enum HistoryError: LocalizedError {
        case codexRunning
        case open(String)
        case sql(String)

        var errorDescription: String? {
            switch self {
            case .codexRunning:
                return "Quit Codex before migrating — its database is in use."
            case .open(let m): return "Could not open Codex database: \(m)"
            case .sql(let m): return "Codex database error: \(m)"
            }
        }
    }

    private static var codexDirectory: URL {
        ConfigWriter.home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Newest `state_*.sqlite` under ~/.codex that actually contains a `threads` table.
    /// The `_N` in the filename is a schema version that changes across Codex releases,
    /// so we glob rather than hardcode it.
    static var stateDBURL: URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let candidates = entries
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }

        return candidates.first { hasThreadsTable($0) }
    }

    private static func hasThreadsTable(_ url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='threads' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Distinct `model_provider` values (with thread counts) other than `target` and
    /// the empty string. Returns `[]` if the DB or table is absent.
    static func otherProviders(excluding target: String = ConfigWriter.providerID) throws -> [ProviderCount] {
        guard let url = stateDBURL else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw HistoryError.open(msg)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = """
        SELECT model_provider, COUNT(*) FROM threads
        WHERE model_provider <> ?1 AND model_provider <> ''
        GROUP BY model_provider ORDER BY COUNT(*) DESC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, target, -1, SQLITE_TRANSIENT)

        var out: [ProviderCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cName = sqlite3_column_text(stmt, 0) else { continue }
            out.append(ProviderCount(provider: String(cString: cName),
                                     count: Int(sqlite3_column_int(stmt, 1))))
        }
        return out
    }

    /// Relabels every thread whose `model_provider` is in `providers` to `target`.
    /// Backs up the database (and its WAL/SHM sidecars) first. Refuses to run while
    /// Codex is open. Returns the number of rows changed.
    ///
    /// `codexRunning` is injectable so tests can exercise the DB path without depending
    /// on whether Codex happens to be running on the machine.
    @discardableResult
    static func migrate(
        providers: [String],
        to target: String = ConfigWriter.providerID,
        codexRunning: () -> Bool = CodexHistoryStore.isCodexRunning
    ) throws -> Int {
        guard !providers.isEmpty else { return 0 }
        guard !codexRunning() else { throw HistoryError.codexRunning }
        guard let url = stateDBURL else { return 0 }

        backupWithSidecars(url)

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw HistoryError.open(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        try exec(db, "BEGIN IMMEDIATE")
        var changed = 0
        do {
            for provider in providers {
                var stmt: OpaquePointer?
                let sql = "UPDATE threads SET model_provider = ?1 WHERE model_provider = ?2"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw HistoryError.sql(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_bind_text(stmt, 1, target, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, provider, -1, SQLITE_TRANSIENT)
                let rc = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                guard rc == SQLITE_DONE else {
                    throw HistoryError.sql(String(cString: sqlite3_errmsg(db)))
                }
                changed += Int(sqlite3_changes(db))
            }
            try exec(db, "COMMIT")
        } catch {
            _ = try? exec(db, "ROLLBACK")
            throw error
        }
        return changed
    }

    /// True if the Codex desktop app or its `codex app-server` CLI is running.
    /// Matches the exact bundle id / process, so unrelated processes that merely have
    /// "codex" in their name (e.g. the "Codex for Chrome" extension host) don't count.
    static func isCodexRunning() -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        if apps.contains(where: { $0.bundleIdentifier == "com.openai.codex" }) {
            return true
        }
        return pgrepMatches("Resources/codex app-server")
    }

    // MARK: - helpers

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func backupWithSidecars(_ url: URL) {
        ConfigWriter.backup(url)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                ConfigWriter.backup(sidecar)
            }
        }
    }

    private static func pgrepMatches(_ pattern: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", pattern]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return !data.isEmpty
    }
}

/// SQLite wants to copy bound text; the default static bind assumes the buffer outlives
/// the call, which isn't true for Swift String bridging.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
