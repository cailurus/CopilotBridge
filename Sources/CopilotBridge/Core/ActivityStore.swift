import Foundation

/// Persists per-day, per-model stats for the Activity dashboard.
///
/// Storage is a single JSON file (`activity.json`) next to settings, keyed by local
/// day (`yyyy-MM-dd`) mapping to a `[modelID: Stat]` dictionary, where each stat carries
/// both a request count and a token count. This keeps the heatmap and per-model
/// breakdown across restarts without logging every request. History is pruned to the
/// last ~370 days on save.
///
/// Legacy files (pre-token schema: `[day: [model: Int]]`) load as requests with 0 tokens.
@MainActor
final class ActivityStore: ObservableObject {
    struct Stat: Codable, Equatable {
        var requests: Int = 0
        /// Total tokens = input + output. Kept for the heatmap/back-compat.
        var tokens: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0

        init(requests: Int = 0, tokens: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0) {
            self.requests = requests
            self.tokens = tokens
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }

        /// Tolerates older files that only had `requests`/`tokens` (split fields absent).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requests = (try? c.decode(Int.self, forKey: .requests)) ?? 0
            tokens = (try? c.decode(Int.self, forKey: .tokens)) ?? 0
            inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
            outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        }
    }

    /// The metric the dashboard is currently showing.
    enum Unit: String, CaseIterable, Identifiable {
        case requests, tokens, cost
        var id: String { rawValue }
        var title: String {
            switch self {
            case .requests: return "Requests"
            case .tokens: return "Tokens"
            case .cost: return "Cost"
            }
        }
    }

    /// day (yyyy-MM-dd, local) -> model id -> stat
    @Published private(set) var days: [String: [String: Stat]] = [:]

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

    private func value(_ stat: Stat, _ unit: Unit) -> Int {
        unit == .requests ? stat.requests : stat.tokens
    }

    /// Records a batch of per-model request counts and input/output token counts on the
    /// current local day with a single save.
    func record(requests: [String: Int], inputTokens: [String: Int], outputTokens: [String: Int], on date: Date = Date()) {
        let models = Set(requests.keys).union(inputTokens.keys).union(outputTokens.keys)
        guard !models.isEmpty else { return }
        let key = Self.dayKey(date)
        for model in models {
            var stat = days[key]?[model] ?? Stat()
            let inTok = max(0, inputTokens[model] ?? 0)
            let outTok = max(0, outputTokens[model] ?? 0)
            stat.requests += max(0, requests[model] ?? 0)
            stat.inputTokens += inTok
            stat.outputTokens += outTok
            stat.tokens += inTok + outTok
            days[key, default: [:]][model] = stat
        }
        save()
    }

    // MARK: Aggregates for the dashboard

    /// Total for the given unit across all history.
    func total(_ unit: Unit) -> Int {
        days.values.reduce(0) { acc, byModel in
            acc + byModel.values.reduce(0) { $0 + value($1, unit) }
        }
    }

    /// Per-model totals for the given unit, highest first.
    func modelTotals(_ unit: Unit) -> [(model: String, count: Int)] {
        var totals: [String: Int] = [:]
        for byModel in days.values {
            for (model, stat) in byModel { totals[model, default: 0] += value(stat, unit) }
        }
        return totals.sorted { $0.value > $1.value }.map { (model: $0.key, count: $0.value) }
    }

    /// Total for a given local day in the given unit.
    func count(on date: Date, unit: Unit) -> Int {
        (days[Self.dayKey(date)]?.values.reduce(0) { $0 + value($1, unit) }) ?? 0
    }

    /// Today's local total in the given unit.
    func today(_ unit: Unit) -> Int { count(on: Date(), unit: unit) }

    /// Number of distinct days with at least one recorded model.
    var activeDays: Int { days.values.filter { !$0.isEmpty }.count }

    // MARK: Cost aggregates (USD, derived from token split × ModelPricing)

    private func cost(_ model: String, _ stat: Stat) -> Double {
        ModelPricing.cost(model: model, inputTokens: stat.inputTokens, outputTokens: stat.outputTokens)
    }

    /// Estimated equivalent API cost (USD) across all history.
    func costTotal() -> Double {
        days.values.reduce(0) { acc, byModel in
            acc + byModel.reduce(0) { $0 + cost($1.key, $1.value) }
        }
    }

    /// Estimated cost for a given local day.
    func cost(on date: Date) -> Double {
        (days[Self.dayKey(date)]?.reduce(0) { $0 + cost($1.key, $1.value) }) ?? 0
    }

    /// Today's estimated cost.
    func costToday() -> Double { cost(on: Date()) }

    /// Per-model cost totals (USD), highest first.
    func modelCostTotals() -> [(model: String, cost: Double)] {
        var totals: [String: Double] = [:]
        for byModel in days.values {
            for (model, stat) in byModel { totals[model, default: 0] += cost(model, stat) }
        }
        return totals.sorted { $0.value > $1.value }.map { (model: $0.key, cost: $0.value) }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        // New schema first.
        if let decoded = try? JSONDecoder().decode([String: [String: Stat]].self, from: data) {
            days = decoded
            return
        }
        // Legacy schema: [day: [model: Int]] -> requests, 0 tokens.
        if let legacy = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            days = legacy.mapValues { byModel in
                byModel.mapValues { Stat(requests: $0, tokens: 0) }
            }
        }
    }

    private func save() {
        prune()
        try? FileManager.default.createDirectory(
            at: SettingsStore.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(days) {
            try? data.write(to: Self.fileURL, options: [.atomic])
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
