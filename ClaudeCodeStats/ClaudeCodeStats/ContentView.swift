import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var viewModel: UsageViewModel
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var showingSettings = false
    @State private var isSpinning = false

    private static let lastUpdatedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Group {
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
        // MenuBarExtra(.window) sizes the popover to whatever it shows first
        // (always the taller main view) and won't shrink it when we swap to the
        // compact Settings view — stranding Settings, centered, in an oversized
        // panel with empty space above and below (issue #25). Measure the live
        // content height and nudge the panel to match it on every swap.
        .background(
            GeometryReader { proxy in
                WindowFitter(targetHeight: proxy.size.height)
            }
        )
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)

                Text("Claude Code Stats")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

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

            // Content — data-first: a transient refresh failure shows a subtle
            // banner above the last known usage rather than wiping it.
            if let usage = viewModel.webUsage {
                if let error = viewModel.error {
                    staleBanner(error)
                }
                usageView(usage)
            } else if let error = viewModel.error {
                errorView(error)
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

            ForEach(usage.scopedLimits) { limit in
                UsageCardView(
                    title: "Weekly Limit (\(limit.name))",
                    usage: limit.usage,
                    resetsAt: limit.resetsAt
                )
            }

            // Absent only until the first transcript scan finishes. The limits
            // above come from the API and shouldn't wait on it.
            if let spend = viewModel.spend {
                SpendCardView(spend: spend)
            }

            // Only present when RTK is installed and has logged commands.
            if let rtk = viewModel.rtkSavings {
                RTKSavingsCardView(savings: rtk)
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

    private func staleBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)

            Text(message)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
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

            if !OAuthUsageService.shared.hasCredentials {
                Button("How to fix") {
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
            TimelineView(.everyMinute) { context in
                Text(lastUpdatedString(at: context.date))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
            }

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

    private func lastUpdatedString(at now: Date) -> String {
        guard let lastUpdated = viewModel.webUsage?.lastUpdated else {
            return "Not yet updated"
        }

        let interval = now.timeIntervalSince(lastUpdated)
        if interval < 60 {
            return "Updated just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "Updated \(minutes)m ago"
        } else {
            return "Updated at \(Self.lastUpdatedTimeFormatter.string(from: lastUpdated))"
        }
    }
}

/// Resizes the hosting MenuBarExtra panel to a target content height, keeping
/// its top edge anchored under the menu bar. Works around MenuBarExtra(.window)
/// not shrinking its panel when the SwiftUI content becomes shorter (e.g. main
/// view → Settings). `targetHeight` comes from a GeometryReader measuring the
/// live content, so it reflects the ideal height of whichever view is showing.
private struct WindowFitter: NSViewRepresentable {
    var targetHeight: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let height = targetHeight
        guard height > 1 else { return }
        // Defer to the next runloop tick so the panel exists and AppKit has
        // finished the current layout pass before we override the frame.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let frame = window.frame
            guard abs(frame.height - height) > 0.5 else { return }
            window.setFrame(
                NSRect(x: frame.origin.x,
                       y: frame.maxY - height,
                       width: frame.width,
                       height: height),
                display: true
            )
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(UpdateChecker())
        .environmentObject(UsageViewModel())
}
