import SwiftUI

struct UsageCardView: View {
    let title: String
    let usage: Double
    let resetsAt: Date

    private var resetTimeString: String {
        let now = Date()
        let interval = resetsAt.timeIntervalSince(now)

        if interval <= 0 {
            return "Resetting..."
        }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 24 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE h:mm a"
            return "Resets \(formatter.string(from: resetsAt))"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)

            HStack(spacing: 12) {
                ProgressBarView(progress: usage)

                Text("\(Int(usage))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 40, alignment: .trailing)
            }

            Text(resetTimeString)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }
}

#Preview {
    VStack(spacing: 12) {
        UsageCardView(
            title: "Current Session",
            usage: 25,
            resetsAt: Date().addingTimeInterval(3600 * 4 + 60 * 35)
        )
        UsageCardView(
            title: "Weekly Limit",
            usage: 65,
            resetsAt: Date().addingTimeInterval(3600 * 24 * 3)
        )
    }
    .padding()
    .background(Theme.background)
}
