import Foundation

/// Persists per-day, per-model request counts for the Activity dashboard.
///
/// Storage is a single JSON file (`activity.json`) next to settings, keyed by local
/// day (`yyyy-MM-dd`) mapping to a `[modelID: count]` dictionary. This keeps the
/// heatmap and per-model breakdown across restarts without logging every request.
/// History is pruned to the last ~370 days on save.
@MainActor
final class ActivityStore: ObservableObject {
    /// day (yyyy-MM-dd, local) -> model id -> count
    @Published private(set) var days: [String: [String: Int]] = [:]

    private static let retentionDays = 370

    private static var fileURL: URL {
        SettingsStore.directory.appendingPathComponent("activity.json")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() { load() }

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func date(fromDayKey key: String) -> Date? { dayFormatter.date(from: key) }

    /// Records a batch of per-model counts on the current local day with a single save.
    func record(counts: [String: Int], on date: Date = Date()) {
        guard !counts.isEmpty else { return }
        let key = Self.dayKey(date)
        for (model, n) in counts where n > 0 {
            days[key, default: [:]][model, default: 0] += n
        }
        save()
    }

    // MARK: Aggregates for the dashboard

    /// Total requests across all history.
    var totalRequests: Int {
        days.values.reduce(0) { $0 + $1.values.reduce(0, +) }
    }

    /// Per-model totals, highest first.
    var modelTotals: [(model: String, count: Int)] {
        var totals: [String: Int] = [:]
        for byModel in days.values {
            for (model, count) in byModel { totals[model, default: 0] += count }
        }
        return totals.sorted { $0.value > $1.value }.map { (model: $0.key, count: $0.value) }
    }

    /// Total requests for a given local day.
    func count(on date: Date) -> Int {
        days[Self.dayKey(date)]?.values.reduce(0, +) ?? 0
    }

    /// Requests in the trailing 24h-equivalent window (today's local count).
    var todayCount: Int { count(on: Date()) }

    /// Number of distinct days with at least one request.
    var activeDays: Int { days.values.filter { !$0.isEmpty }.count }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else {
            return
        }
        days = decoded
    }

    private func save() {
        prune()
        try? FileManager.default.createDirectory(
            at: SettingsStore.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(days) {
            try? data.write(to: Self.fileURL)
        }
    }

    /// Drops days older than the retention window so the file stays bounded.
    private func prune() {
        guard let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.retentionDays, to: Date()) else { return }
        let cutoffKey = Self.dayKey(cutoff)
        days = days.filter { $0.key >= cutoffKey }
    }
}
