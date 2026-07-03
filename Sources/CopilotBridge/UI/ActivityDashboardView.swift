import SwiftUI

/// Activity dashboard: summary counts, a GitHub-style contribution heatmap, and a
/// per-model breakdown. Reads persisted daily/model counts from ActivityStore.
struct ActivityDashboardView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var activity: ActivityStore

    init(activity: ActivityStore) {
        _activity = ObservedObject(wrappedValue: activity)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary
                heatmapCard
                breakdownCard
            }
            .padding(20)
        }
    }

    // MARK: Summary

    private var summary: some View {
        HStack(spacing: 12) {
            stat("Total", "\(activity.totalRequests)", "number.circle")
            stat("Today", "\(activity.todayCount)", "calendar")
            stat("Models", "\(activity.modelTotals.count)", "cube.box")
            stat("Active days", "\(activity.activeDays)", "flame")
        }
    }

    private func stat(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Heatmap

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 26 weeks").font(.headline)
            if activity.totalRequests == 0 {
                emptyState
            } else {
                ContributionHeatmap(activity: activity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        Text("No requests yet. Point a client at the proxy to see activity here.")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }

    // MARK: Per-model breakdown

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By model").font(.headline)
            let totals = activity.modelTotals
            if totals.isEmpty {
                Text("No model activity recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let maxCount = totals.first?.count ?? 1
                VStack(spacing: 8) {
                    ForEach(totals, id: \.model) { entry in
                        modelBar(entry.model, entry.count, max: maxCount)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func modelBar(_ model: String, _ count: Int, max: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model).font(.caption.monospaced()).lineLimit(1)
                Spacer()
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let frac = max > 0 ? Double(count) / Double(max) : 0
                RoundedRectangle(cornerRadius: 4)
                    .fill(.tint)
                    .frame(width: CGFloat(frac) * geo.size.width)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 8)
        }
    }
}

/// GitHub-style contribution grid: columns are weeks (oldest → newest), rows are
/// weekdays (Sun → Sat). Cell color intensity scales with that day's request count.
struct ContributionHeatmap: View {
    @ObservedObject var activity: ActivityStore

    private let weeks = 26
    private let cell: CGFloat = 12
    private let spacing: CGFloat = 3

    /// Grid of dates: [week][weekday]. Aligned so the last column ends at today's week.
    private var grid: [[Date?]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Start of the current week (Sunday-based to match weekday index 1…7).
        let weekdayOfToday = cal.component(.weekday, from: today) // 1 = Sun
        guard let thisWeekStart = cal.date(byAdding: .day, value: -(weekdayOfToday - 1), to: today),
              let firstWeekStart = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeekStart)
        else { return [] }

        var columns: [[Date?]] = []
        for w in 0..<weeks {
            guard let weekStart = cal.date(byAdding: .day, value: 7 * w, to: firstWeekStart) else { continue }
            var col: [Date?] = []
            for d in 0..<7 {
                let day = cal.date(byAdding: .day, value: d, to: weekStart)
                // Don't render future days in the current week.
                if let day, day > today { col.append(nil) } else { col.append(day) }
            }
            columns.append(col)
        }
        return columns
    }

    /// Highest single-day count in the window, for scaling intensity.
    private var maxDaily: Int {
        grid.flatMap { $0 }.compactMap { $0 }.map { activity.count(on: $0) }.max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: spacing) {
                weekdayLabels
                ForEach(Array(grid.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            cellView(column[row])
                        }
                    }
                }
            }
            legend
        }
    }

    private var weekdayLabels: some View {
        VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { row in
                Text(row == 1 ? "M" : row == 3 ? "W" : row == 5 ? "F" : " ")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
                    .frame(width: 10, height: cell)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ date: Date?) -> some View {
        if let date {
            let count = activity.count(on: date)
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: count))
                .frame(width: cell, height: cell)
                .help("\(ActivityStore.dayKey(date)): \(count) request\(count == 1 ? "" : "s")")
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.clear)
                .frame(width: cell, height: cell)
        }
    }

    private func color(for count: Int) -> Color {
        guard count > 0, maxDaily > 0 else { return Color.gray.opacity(0.15) }
        let frac = Double(count) / Double(maxDaily)
        let level: Double
        switch frac {
        case ..<0.25: level = 0.35
        case ..<0.5: level = 0.55
        case ..<0.75: level = 0.75
        default: level = 1.0
        }
        return Color.green.opacity(0.2 + 0.8 * level)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach([0, 1, 2, 3, 4], id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(legendColor(i))
                    .frame(width: 10, height: 10)
            }
            Text("More").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func legendColor(_ i: Int) -> Color {
        if i == 0 { return Color.gray.opacity(0.15) }
        return Color.green.opacity(0.2 + 0.8 * (Double(i) / 4.0))
    }
}
