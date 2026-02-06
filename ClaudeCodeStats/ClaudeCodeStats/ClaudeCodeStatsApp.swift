import SwiftUI

@main
struct ClaudeCodeStatsApp: App {
    @StateObject private var updateChecker = UpdateChecker()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(updateChecker)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "chart.bar.fill")
                    .symbolRenderingMode(.hierarchical)
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
