import SwiftUI

// One account's limits in a single card, for the multi-account popover. A full
// UsageCardView per limit, repeated per account, would stack six or more cards
// above spend and RTK, so each limit gets one compact row here instead.
struct AccountUsageCardView: View {
    let name: String
    let state: AccountUsage?

    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            if let error = state?.error {
                errorRow(error)
            }

            if let usage = state?.usage, state?.needsLogin != true {
                limitRows(usage)
            } else if state == nil || (state?.usage == nil && state?.error == nil) {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    private func limitRows(_ usage: WebUsageData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            limitRow(title: "Session", usage: usage.sessionUsage, resetsAt: usage.sessionResetsAt)
            limitRow(title: "Weekly", usage: usage.weeklyUsage, resetsAt: usage.weeklyResetsAt)
            ForEach(usage.scopedLimits) { limit in
                limitRow(title: limit.name, usage: limit.usage, resetsAt: limit.resetsAt)
            }
        }
    }

    private func limitRow(title: String, usage: Double, resetsAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 52, alignment: .leading)

                ProgressBarView(progress: usage)

                Text("\(Int(usage))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 36, alignment: .trailing)
            }

            TimelineView(.everyMinute) { context in
                Text(resetTimeString(resetsAt, at: context.date))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 60)
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(Theme.statusWarning)

            Text(message)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resetTimeString(_ resetsAt: Date, at now: Date) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 { return "Resetting..." }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 24 {
            return "Resets \(Self.resetDateFormatter.string(from: resetsAt))"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }
}
