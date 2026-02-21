import SwiftUI

struct UsageHistoryChartView: View {
    let sessions: [SessionSummary]

    @State private var hoveredIndex: Int?

    private var displayedSessions: [SessionSummary] {
        Array(sessions.suffix(30))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerText
            chartContent
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    private var headerText: some View {
        Group {
            if let idx = hoveredIndex, idx < displayedSessions.count {
                let session = displayedSessions[idx]
                Text(hoverLabel(for: session))
                    .font(.system(size: 11))
                    .foregroundColor(.white)
            } else {
                Text("Session History")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .frame(height: 16)
    }

    private var chartContent: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let count = max(displayedSessions.count, 10)
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = max(4, (geometry.size.width - totalSpacing) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(displayedSessions.enumerated()), id: \.offset) { index, session in
                    barView(for: session, at: index, width: barWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 50)
    }

    private func barView(for session: SessionSummary, at index: Int, width: CGFloat) -> some View {
        let usage = session.peakUsage
        let barHeight = max(2, 50 * CGFloat(usage / 100))
        let isHovered = hoveredIndex == index

        return RoundedRectangle(cornerRadius: 2)
            .fill(barColor(for: usage))
            .frame(width: width, height: barHeight)
            .opacity(isHovered ? 1.0 : 0.8)
            .onHover { hovering in
                hoveredIndex = hovering ? index : nil
            }
    }

    private func barColor(for usage: Double) -> Color {
        if usage < 50 {
            return Color(red: 74/255, green: 222/255, blue: 128/255)
        } else if usage < 75 {
            return Color(red: 250/255, green: 204/255, blue: 21/255)
        } else {
            return Color(red: 248/255, green: 113/255, blue: 113/255)
        }
    }

    private func hoverLabel(for session: SessionSummary) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        let dateStr = formatter.string(from: session.firstSeen)
        return "\(dateStr) — \(Int(session.peakUsage))%"
    }
}

#Preview {
    let now = Date()
    let samples = (0..<20).map { i in
        SessionSummary(
            sessionResetsAt: now.addingTimeInterval(Double(-20 + i) * 18000),
            peakUsage: Double.random(in: 10...90),
            firstSeen: now.addingTimeInterval(Double(-20 + i) * 18000 - 14400),
            lastSeen: now.addingTimeInterval(Double(-20 + i) * 18000 - 3600)
        )
    }
    return UsageHistoryChartView(sessions: samples)
        .padding()
        .background(Theme.background)
}
