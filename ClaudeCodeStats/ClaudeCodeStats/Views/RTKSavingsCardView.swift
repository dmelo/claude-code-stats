import SwiftUI

struct RTKSavingsCardView: View {
    let savings: RTKSavings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("RTK Token Savings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)

                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .help("Tool-output tokens RTK kept out of Claude Code's context, and what they'd cost at API rates. A conservative floor — priced once at the input rate, ignoring the higher cost of re-sending context each turn. Covers only RTK-routed commands, so it's a slice of your usage, not your whole bill.")
            }

            row("Today", savings.todaySaved, value: savings.todayValue)
            row("Last 7 days", savings.weekSaved, value: savings.weekValue)
            row("Month to date", savings.monthSaved, value: savings.monthValue)

            Divider()
                .background(Theme.divider)

            row("Saved all-time", savings.lifetimeSaved)

            reductionMeter

            Text("≈ value kept off your bill (floor)")
                .font(.system(size: 9))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    private func row(_ label: String, _ tokens: Int, value: Double? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)

            Spacer()

            Text(tokens.tokensShort)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)

            // API-equivalent value of those tokens, secondary to the token count
            // and right-aligned in a fixed column so the dollar figures line up.
            if let value {
                Text("~\(value.usdFloor)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    // Blue rather than the usage bars' green→red ramp: on those, fuller is worse;
    // here a higher reduction is better, so the "danger" colouring would invert
    // the meaning. Theme.chartBar reads as neutral-positive on both surfaces.
    private var reductionMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.divider)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.chartBar)
                        .frame(width: max(0, geometry.size.width * savings.reduction), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(Int((savings.reduction * 100).rounded()))% avg reduction")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)

                Spacer()

                Text("\(savings.commandCount.formatted()) cmds")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

#Preview {
    RTKSavingsCardView(savings: RTKSavings(
        todaySaved: 42_842,
        weekSaved: 31_819_035,
        monthSaved: 45_659_821,
        lifetimeSaved: 79_609_145,
        lifetimeRaw: 115_000_000,
        commandCount: 19_574,
        inputRate: 5,
        lastUpdated: Date()
    ))
    .padding()
    .frame(width: 280)
    .background(Theme.background)
}
