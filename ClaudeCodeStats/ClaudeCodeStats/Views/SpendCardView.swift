import SwiftUI

struct SpendCardView: View {
    let spend: SpendData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("API-Equivalent Spend")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)

                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .help("What these tokens would cost at API rates. Your subscription already covers them — this is not money charged.")
            }

            row("Today", spend.today)
            row("Last 7 days", spend.week)
            row("Last 30 days", spend.last30)

            if !spend.daily.isEmpty {
                Divider()
                    .background(Theme.divider)

                SpendChartView(daily: spend.daily)
            }

            if !spend.last30ByModel.isEmpty {
                Divider()
                    .background(Theme.divider)

                ForEach(spend.last30ByModel) { entry in
                    HStack {
                        Text(entry.model)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textSecondary)

                        Spacer()

                        Text(entry.cost.usd)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    private func row(_ label: String, _ amount: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)

            Spacer()

            Text(amount.usd)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
    }
}

#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let sample = (0..<30).map { offset in
        DailySpend(
            date: calendar.date(byAdding: .day, value: offset - 29, to: today)!,
            cost: [6, 13].contains(offset) ? 0 : Double.random(in: 40...260)
        )
    }
    return SpendCardView(spend: SpendData(
        today: 179.60,
        week: 1301.38,
        last30: 3778.49,
        last30ByModel: [
            ModelSpend(model: "Fable 5", cost: 1933.21),
            ModelSpend(model: "Opus 4.8", cost: 1698.25),
            ModelSpend(model: "Sonnet 5", cost: 145.61),
            ModelSpend(model: "Haiku 4.5", cost: 1.41),
        ],
        daily: sample,
        lastUpdated: Date()
    ))
    .padding()
    .frame(width: 280)
    .background(Theme.background)
}
