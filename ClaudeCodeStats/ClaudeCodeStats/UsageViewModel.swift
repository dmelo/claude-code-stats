import SwiftUI

@MainActor
class UsageViewModel: ObservableObject {
    @Published var webUsage: WebUsageData?
    @Published var error: String?
    @Published var isLoading = false

    // Status properties
    @Published var claudeStatus: ClaudeStatus?
    @Published var isStatusLoading = false

    // API-equivalent spend, computed from the local transcripts
    @Published var spend: SpendData?

    private var refreshTimer: Timer?

    var backgroundRefreshEnabled: Bool = false {
        didSet {
            guard backgroundRefreshEnabled != oldValue else { return }
            if backgroundRefreshEnabled {
                Task { await refresh() }
                startAutoRefresh()
            } else {
                refreshTimer?.invalidate()
                refreshTimer = nil
            }
        }
    }

    init() {
        Task {
            await refresh()
        }
    }

    var statusColor: Color {
        claudeStatus?.color ?? .gray
    }

    var statusText: String {
        claudeStatus?.displayText ?? "Status"
    }

    func refresh() async {
        // Single-flight: skip if a refresh is already running. refresh() is async
        // on the MainActor, so it can be re-entered across an await (e.g. the
        // auto-timer racing a manual tap, or the launch init racing the rings
        // toggle). Overlapping fetches waste the endpoint's tight rate-limit
        // budget and let a slower response clobber a newer one. defer guarantees
        // isLoading is cleared on every exit, including cancellation.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // With no data to fall back on, clear a prior error so a retry shows the
        // loading state instead of freezing on the old error. When data exists we
        // keep the error so the stale banner stays put during the retry.
        if webUsage == nil {
            error = nil
        }

        do {
            let usage = try await OAuthUsageService.shared.fetchUsage()
            webUsage = usage
            error = nil
            UsageHistoryService.shared.record(usage)
        } catch {
            // Keep the last good data on screen. When webUsage exists, ContentView
            // shows a subtle banner instead of replacing everything with an error.
            self.error = error.localizedDescription
        }

        // Also refresh status
        await refreshStatus()
        await refreshSpend()
    }

    // Spend reads the local transcripts, so it has no bearing on the usage
    // endpoint's rate limit and is safe to recompute on every refresh. The scan
    // is incremental after the first one.
    func refreshSpend() async {
        spend = await CostService.shared.fetchSpend()
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
