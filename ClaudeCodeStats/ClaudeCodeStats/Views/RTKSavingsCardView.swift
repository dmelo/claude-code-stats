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
                    .help("Tool-output tokens RTK kept out of Claude Code's context, and what they'd cost at API rates. The floor prices each token once at the input rate; the ceiling adds the re-billing it would have incurred staying in context — a cache write plus your account's observed cache re-reads. Truth sits between. Covers only RTK-routed commands, so it's a slice of your usage, not your whole bill.")
            }

            row("Today", savings.todaySaved, floor: savings.todayFloor, ceiling: savings.todayCeiling)
            row("Last 7 days", savings.weekSaved, floor: savings.weekFloor, ceiling: savings.weekCeiling)
            row("Month to date", savings.monthSaved, floor: savings.monthFloor, ceiling: savings.monthCeiling)

            Divider()
                .background(Theme.divider)

            row("Saved all-time", savings.lifetimeSaved)

            reductionMeter

            Text("≈ value kept off your bill (floor – ceiling)")
                .font(.system(size: 9))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    private func row(_ label: String, _ tokens: Int, floor: Double? = nil, ceiling: Double? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(tokens.tokensShort)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)

            // API-equivalent value range, secondary to the token count and
            // right-aligned in a fixed column so the ranges line up. Smaller than
            // the token count so it stays subordinate and leaves room for the
            // label without wrapping.
            if let floor, let ceiling {
                Text(Self.range(floor, ceiling))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 78, alignment: .trailing)
            }
        }
    }

    /// "$160–390", collapsing to a single "$160" when the two bounds round
    /// together (e.g. a light day where both are under a dollar). The ceiling is a
    /// plain grouped number — the floor already carries the currency symbol, so we
    /// never strip one off a locale-formatted string.
    private static func range(_ floor: Double, _ ceiling: Double) -> String {
        let lo = floor.usdFloor
        return lo == ceiling.usdFloor ? lo : "\(lo)–\(ceiling.wholeFloor)"
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
                        .frame(width: max(0, geometry.size.width * CGFloat(savings.reduction)), height: 6)
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
        ceilingMultiplier: 2.45,
        lastUpdated: Date()
    ))
    .padding()
    .frame(width: 280)
    .background(Theme.background)
}
