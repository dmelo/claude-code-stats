import SwiftUI

@main
struct ClaudeCodeStatsApp: App {
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var viewModel = UsageViewModel()
    @AppStorage("showSessionInMenuBar") private var showSession = false
    @AppStorage("showWeeklyInMenuBar") private var showWeekly = false

    private var menuBarText: String? {
        guard showSession || showWeekly else { return nil }
        var parts: [String] = []
        if showSession {
            let pct = viewModel.webUsage.map { "\(Int($0.sessionUsage))%" } ?? "--%"
            parts.append("S: \(pct)")
        }
        if showWeekly {
            let pct = viewModel.webUsage.map { "\(Int($0.weeklyUsage))%" } ?? "--%"
            parts.append("W: \(pct)")
        }
        return parts.joined(separator: " ")
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(updateChecker)
                .environmentObject(viewModel)
        } label: {
            ZStack(alignment: .topTrailing) {
                if let text = menuBarText {
                    Text(text)
                        .monospacedDigit()
                } else {
                    Image(systemName: "chart.bar.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                if updateChecker.hasUpdate {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .offset(x: 4, y: -3)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
