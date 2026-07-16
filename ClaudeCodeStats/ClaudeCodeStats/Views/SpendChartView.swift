import Charts
import SwiftUI

/// Daily API-equivalent spend over a rolling window.
///
/// One series, so the caption identifies it and no legend is needed. Bars carry
/// no value labels — hovering reveals the exact figure, and the totals above the
/// chart are the standing readout.
struct SpendChartView: View {
    let daily: [DailySpend]

    @State private var hovered: DailySpend?

    /// The scale picks tick values from the data, so on a quiet month the ticks
    /// land wherever the peak puts them — under a dollar, or on fractions like
    /// 1.5. Rounding those to whole dollars both mislabels them and can print
    /// the same label twice ("$2" for 1.5 and 2.0); truncating thousands loses
    /// the difference between $1.1k and $1.9k. So cents are dropped only from
    /// values that genuinely have none.
    private static func axisLabel(_ amount: Double) -> String {
        if amount >= 1000 {
            let thousands = amount / 1000
            return thousands == thousands.rounded()
                ? "$\(Int(thousands))k"
                : String(format: "$%.1fk", thousands)
        }
        if amount == amount.rounded() {
            return "$\(Int(amount))"
        }
        return String(format: "$%.2f", amount)
    }

    /// Left to itself the scale rounds outward to reach round tick values, which
    /// on a 64pt plot can leave the tallest bar at 60% height. Pin the domain to
    /// the peak plus a little headroom so the shape fills the space it has.
    private var yDomain: ClosedRange<Double> {
        let peak = daily.map(\.cost).max() ?? 0
        return 0...(peak > 0 ? peak * 1.08 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption
            chart
        }
    }

    /// Doubles as the hover readout. A floating tooltip would spend most of its
    /// life clipped against the edges of a plot this narrow, so the value is
    /// surfaced in space the caption already occupies. Fixed height so swapping
    /// between the two states can't shift the chart underneath.
    private var caption: some View {
        HStack(spacing: 5) {
            if let hovered {
                Text(hovered.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textPrimary)

                Text(hovered.cost.usd)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            } else {
                Text("Daily · last \(daily.count) days")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 12)
    }

    private var chart: some View {
        Chart(daily) { day in
            BarMark(
                x: .value("Date", day.date, unit: .day),
                y: .value("Spend", day.cost)
            )
            .foregroundStyle(Theme.chartBar.opacity(dimmed(day) ? 0.3 : 1))
            .cornerRadius(1)
        }
        .chartYScale(domain: yDomain)
        .chartYAxis { yAxis }
        .chartXAxis { xAxis }
        .chartOverlay { proxy in hoverOverlay(proxy) }
        .frame(height: 64)
    }

    private func dimmed(_ day: DailySpend) -> Bool {
        guard let hovered else { return false }
        return hovered.id != day.id
    }

    /// The bars are only a few points wide, so the whole plot is the hit target
    /// and the pointer snaps to the nearest day rather than demanding a hit on
    /// the mark itself.
    private func hoverOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = point.x - geometry[plotFrame].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        hovered = nearestDay(to: date)
                    case .ended:
                        hovered = nil
                    }
                }
        }
    }

    private func nearestDay(to date: Date) -> DailySpend? {
        daily.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    @AxisContentBuilder
    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine()
                .foregroundStyle(Theme.divider)
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(Self.axisLabel(amount))
                        .font(.system(size: 8))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    // A 7-day stride lands a label one day short of the right edge, where the
    // text runs past the plot and is clipped. Striding by 10 keeps every label
    // clear of the edge; the right edge is today, which the caption already says.
    @AxisContentBuilder
    private var xAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: 10)) { value in
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 8))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }
}

#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let sample = (0..<30).map { offset -> DailySpend in
        let date = calendar.date(byAdding: .day, value: offset - 29, to: today)!
        // A couple of idle days, to show the gaps render.
        let cost = [6, 13].contains(offset) ? 0 : Double.random(in: 40...260)
        return DailySpend(date: date, cost: cost)
    }
    return SpendChartView(daily: sample)
        .padding()
        .frame(width: 256)
        .background(Theme.cardBackground)
}
