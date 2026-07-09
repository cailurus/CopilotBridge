import SwiftUI

/// Activity dashboard: summary counts, a GitHub-style contribution heatmap, and a
/// per-model breakdown. Reads persisted daily/model counts from ActivityStore.
struct ActivityDashboardView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var activity: ActivityStore
    @State private var unit: ActivityStore.Unit = .requests

    init(activity: ActivityStore) {
        _activity = ObservedObject(wrappedValue: activity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            unitPicker
            summary
            heatmapCard
            breakdownCard
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var unitPicker: some View {
        Picker("Show", selection: $unit) {
            ForEach(ActivityStore.Unit.allCases) { u in
                Text(u.title).tag(u)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// A day's value in the current unit as a Double (requests/tokens are integral).
    private func dayValue(_ date: Date) -> Double {
        switch unit {
        case .requests, .tokens: return Double(activity.count(on: date, unit: unit))
        case .cost: return activity.cost(on: date)
        }
    }

    /// Formats a scalar for the current unit.
    private func display(_ value: Double) -> String {
        switch unit {
        case .requests: return "\(Int(value))"
        case .tokens: return formatCompactCount(Int(value))
        case .cost: return formatUSD(value)
        }
    }

    // MARK: Summary

    private var summaryTotal: Double {
        unit == .cost ? activity.costTotal() : Double(activity.total(unit))
    }
    private var summaryToday: Double {
        unit == .cost ? activity.costToday() : Double(activity.today(unit))
    }

    private var summary: some View {
        HStack(spacing: 8) {
            stat("Total", display(summaryTotal), "number.circle")
            stat("Today", display(summaryToday), "calendar")
            stat("Models", "\(modelEntries.count)", "cube.box")
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
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Heatmap

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent activity").font(.headline)
            if summaryTotal == 0 {
                emptyState
            } else {
                GeometryReader { geo in
                    ContributionHeatmap(
                        activity: activity,
                        availableWidth: geo.size.width,
                        dayValue: dayValue,
                        label: { date, v in "\(ActivityStore.dayKey(date)): \(self.display(v))" })
                }
                .frame(height: 112)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        Text("No activity yet. Point a client at the proxy to see activity here.")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .center)
    }

    // MARK: Per-model breakdown

    /// Per-model (label, value) pairs for the current unit, highest first.
    private var modelEntries: [(model: String, value: Double)] {
        if unit == .cost {
            return activity.modelCostTotals().map { (model: $0.model, value: $0.cost) }
        }
        return activity.modelTotals(unit).map { (model: $0.model, value: Double($0.count)) }
    }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By model").font(.headline)
            let totals = modelEntries.filter { $0.value > 0 }
            if totals.isEmpty {
                Text("No model activity recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let maxValue = totals.first?.value ?? 1
                VStack(spacing: 6) {
                    ForEach(totals.prefix(6), id: \.model) { entry in
                        modelBar(entry.model, entry.value, max: maxValue)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func modelBar(_ model: String, _ value: Double, max: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model).font(.caption.monospaced()).lineLimit(1)
                Spacer()
                Text(display(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let frac = max > 0 ? value / max : 0
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
/// weekdays (Sun → Sat). Cell color intensity scales with `dayValue(date)`.
struct ContributionHeatmap: View {
    @ObservedObject var activity: ActivityStore
    let availableWidth: CGFloat
    let dayValue: (Date) -> Double
    let label: (Date, Double) -> String

    private let cell: CGFloat = 10
    private let spacing: CGFloat = 3
    private let labelWidth: CGFloat = 10

    private var weeks: Int {
        let usable = max(0, availableWidth - labelWidth - spacing)
        let weekWidth = cell + spacing
        return max(26, min(52, Int((usable + spacing) / weekWidth)))
    }

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

    /// Highest single-day value in the window, for scaling intensity.
    private var maxDaily: Double {
        grid.flatMap { $0 }.compactMap { $0 }.map { dayValue($0) }.max() ?? 0
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
            let v = dayValue(date)
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: v))
                .frame(width: cell, height: cell)
                .help(label(date, v))
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.clear)
                .frame(width: cell, height: cell)
        }
    }

    private func color(for value: Double) -> Color {
        guard value > 0, maxDaily > 0 else { return Color.gray.opacity(0.15) }
        let frac = value / maxDaily
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
