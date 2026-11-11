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
                    .help("What these tokens would cost at API rates. Your subscriptions already cover them — this is not money charged.")
            }

            row("Today", spend.today)
            row("Last 7 days", spend.week)
            row("Last 30 days", spend.last30)

            if !spend.daily.isEmpty {
                Divider()
                    .background(Theme.divider)

                SpendChartView(daily: spend.daily, showsCodex: spend.hasCodex)
            }

            if !spend.last30ByModel.isEmpty {
                Divider()
                    .background(Theme.divider)

                ForEach(spend.last30ByModel) { entry in
                    HStack(spacing: 5) {
                        // Only once there are two tools to tell apart.
                        if spend.hasCodex {
                            swatch(entry.provider)
                        }

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

    // The combined total, then — once Codex has spend in the window — its
    // split beneath, so the headline stays one number.
    private func row(_ label: String, _ amount: SpendSplit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)

                Spacer()

                Text(amount.total.usd)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }

            if spend.hasCodex {
                HStack(spacing: 4) {
                    Spacer()
                    swatch(.claude)
                    splitText("Claude \(amount.claude.usd)")
                    swatch(.codex)
                        .padding(.leading, 4)
                    splitText("Codex \(amount.codex.usd)")
                }
            }
        }
    }

    private func splitText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(Theme.textSecondary)
    }

    // The colour carries which tool; the text beside it always names it too.
    private func swatch(_ provider: SpendProvider) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Theme.chartColor(for: provider))
            .frame(width: 6, height: 6)
    }
}

#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let sample = (0..<30).map { offset in
        DailySpend(
            date: calendar.date(byAdding: .day, value: offset - 29, to: today)!,
            claude: [6, 13].contains(offset) ? 0 : Double.random(in: 40...260),
            codex: offset % 3 == 0 ? Double.random(in: 5...60) : 0
        )
    }
    return SpendCardView(spend: SpendData(
        today: SpendSplit(claude: 179.60, codex: 12.40),
        week: SpendSplit(claude: 1301.38, codex: 88.10),
        last30: SpendSplit(claude: 3778.49, codex: 301.75),
        last30ByModel: [
            ModelSpend(model: "Fable 5", cost: 1933.21),
            ModelSpend(model: "Opus 4.8", cost: 1698.25),
            ModelSpend(model: "GPT-6 Astra", cost: 250.12, provider: .codex),
            ModelSpend(model: "Sonnet 5", cost: 145.61),
            ModelSpend(model: "GPT-5.6 Luna", cost: 51.63, provider: .codex),
        ],
        daily: sample,
        lastUpdated: Date()
    ))
    .padding()
    .frame(width: 280)
    .background(Theme.background)
}
