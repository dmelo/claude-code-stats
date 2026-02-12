import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: UsageViewModel
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var showingSettings = false
    @State private var isSpinning = false

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
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Button(action: {
                    Task { await viewModel.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
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
                .background(Theme.divider)

            // Content
            if let error = viewModel.error {
                errorView(error)
            } else if let usage = viewModel.webUsage {
                usageView(usage)
            } else {
                loadingView
            }

            // Version info
            if updateChecker.hasUpdate {
                updateBannerView
            } else if updateChecker.isUpToDate {
                upToDateView
            }

            Divider()
                .background(Theme.divider)

            // Footer
            footerView
        }
        .frame(width: 280)
        .background(Theme.background)
        .task {
            await viewModel.refreshIfNeeded()
            await updateChecker.checkForUpdate()
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
                .foregroundColor(Theme.textSecondary)
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
                .foregroundColor(Theme.textSecondary)
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
                .foregroundColor(Theme.textSecondary)

            Spacer()

            statusIndicatorView

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 10))
            .foregroundColor(Theme.textSecondary)
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
                        .foregroundColor(Theme.textSecondary)

                    if viewModel.isStatusLoading {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(viewModel.claudeStatus?.description ?? "View Claude status page")

            if !viewModel.isStatusLoading {
                Button(action: {
                    Task { await viewModel.refreshStatus() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Refresh status")
            }
        }
    }

    private var updateBannerView: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.blue)

            Button(action: { updateChecker.openChangelog() }) {
                Text(updateChecker.updateText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: { withAnimation { updateChecker.dismiss() } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }

    private var upToDateView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)

            Text(updateChecker.upToDateText)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

#Preview {
    ContentView()
        .environmentObject(UpdateChecker())
        .environmentObject(UsageViewModel())
}
