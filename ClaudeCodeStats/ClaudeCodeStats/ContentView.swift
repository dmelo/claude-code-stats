import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = UsageViewModel()
    @State private var showingSettings = false
    @State private var isSpinning = false

    private var backgroundColor: Color {
        Color(red: 26/255, green: 26/255, blue: 26/255)
    }

    private var textSecondary: Color {
        Color(red: 138/255, green: 138/255, blue: 138/255)
    }

    var body: some View {
        if showingSettings {
            SettingsView(isPresented: $showingSettings)
                .onChange(of: showingSettings) { _, newValue in
                    if !newValue {
                        Task { await viewModel.refresh() }
                    }
                }
        } else {
            mainView
        }
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)

                Text("Claude Code Stats")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(textSecondary)
                }
                .buttonStyle(.plain)

                Button(action: {
                    Task { await viewModel.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(textSecondary)
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
                .padding(.leading, 8)
                .onChange(of: viewModel.isLoading) { _, loading in
                    if loading {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            isSpinning = true
                        }
                    } else {
                        withAnimation(.default) {
                            isSpinning = false
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color(red: 58/255, green: 58/255, blue: 58/255))

            // Content
            if let error = viewModel.error {
                errorView(error)
            } else if let usage = viewModel.webUsage {
                usageView(usage)
            } else {
                loadingView
            }

            Divider()
                .background(Color(red: 58/255, green: 58/255, blue: 58/255))

            // Footer
            footerView
        }
        .frame(width: 280)
        .background(backgroundColor)
        .task {
            await viewModel.refreshIfNeeded()
        }
    }

    private func usageView(_ usage: WebUsageData) -> some View {
        VStack(spacing: 8) {
            UsageCardView(
                title: "Current Session",
                usage: usage.sessionUsage,
                resetsAt: usage.sessionResetsAt
            )

            UsageCardView(
                title: "Weekly Limit (All Models)",
                usage: usage.weeklyUsage,
                resetsAt: usage.weeklyResetsAt
            )

            if let sonnetUsage = usage.sonnetUsage, let sonnetResetsAt = usage.sonnetResetsAt {
                UsageCardView(
                    title: "Sonnet Only",
                    usage: sonnetUsage,
                    resetsAt: sonnetResetsAt
                )
            }
        }
        .padding(12)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading usage data...")
                .font(.system(size: 12))
                .foregroundColor(textSecondary)
        }
        .frame(height: 150)
        .padding(12)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.yellow)

            Text(error)
                .font(.system(size: 12))
                .foregroundColor(textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if !WebSessionService.shared.hasSessionKey {
                Button("Configure Session") {
                    showingSettings = true
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.blue)
                .cornerRadius(6)
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(height: 150)
        .padding(12)
    }

    private var footerView: some View {
        HStack {
            Text(lastUpdatedString)
                .font(.system(size: 10))
                .foregroundColor(textSecondary)

            Spacer()

            statusIndicatorView

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 10))
            .foregroundColor(textSecondary)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var statusIndicatorView: some View {
        HStack(spacing: 4) {
            Button(action: {
                if let url = URL(string: "https://status.claude.com") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.statusColor)
                        .frame(width: 6, height: 6)

                    Text(viewModel.statusText)
                        .font(.system(size: 10))
                        .foregroundColor(textSecondary)

                    if viewModel.isStatusLoading {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(viewModel.claudeStatus?.description ?? "Click to view full status history")

            if !viewModel.isStatusLoading {
                Button(action: {
                    Task { await viewModel.refreshStatus() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8))
                        .foregroundColor(textSecondary)
                }
                .buttonStyle(.plain)
                .help("Refresh status")
            }
        }
    }

    private var lastUpdatedString: String {
        guard let lastUpdated = viewModel.webUsage?.lastUpdated else {
            return "Not yet updated"
        }

        let interval = Date().timeIntervalSince(lastUpdated)
        if interval < 60 {
            return "Updated just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "Updated \(minutes)m ago"
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Updated at \(formatter.string(from: lastUpdated))"
        }
    }
}

@MainActor
class UsageViewModel: ObservableObject {
    @Published var webUsage: WebUsageData?
    @Published var error: String?
    @Published var isLoading = false

    // Status properties
    @Published var claudeStatus: ClaudeStatus?
    @Published var isStatusLoading = false

    private var refreshTimer: Timer?

    init() {
        startAutoRefresh()
    }

    var statusColor: Color {
        claudeStatus?.color ?? .gray
    }

    var statusText: String {
        claudeStatus?.displayText ?? "Status"
    }

    func refresh() async {
        isLoading = true
        error = nil

        do {
            webUsage = try await WebSessionService.shared.fetchUsage()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false

        // Also refresh status
        await refreshStatus()
    }

    func refreshStatus() async {
        guard !isStatusLoading else { return }
        isStatusLoading = true
        defer { isStatusLoading = false }
        do {
            claudeStatus = try await StatusService.shared.fetchStatus()
        } catch {
            // Silently fail - status is non-critical; keep last known status
        }
    }

    func refreshIfNeeded() async {
        // Only auto-refresh if no data or more than 1 minute since last update
        if let lastUpdated = webUsage?.lastUpdated {
            let elapsed = Date().timeIntervalSince(lastUpdated)
            if elapsed < 60 {
                // Still refresh status if we haven't fetched it yet
                if claudeStatus == nil {
                    await refreshStatus()
                }
                return
            }
        }
        await refresh()
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}

#Preview {
    ContentView()
}
