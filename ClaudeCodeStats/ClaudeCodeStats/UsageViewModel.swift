import SwiftUI

// The latest reading for one account. `usage` survives a failed refresh so the
// popover can keep showing it under a banner; `needsLogin` says the reading can
// no longer be refreshed without the user re-authenticating that login.
struct AccountUsage {
    var usage: WebUsageData?
    var error: String?
    var needsLogin = false
}

@MainActor
class UsageViewModel: ObservableObject {
    // Every login being polled, in aimux config order. Exactly one (the default
    // ~/.claude login) when aimux isn't set up.
    @Published private(set) var accounts: [ClaudeAccount] = AimuxService.discoverAccounts()
    @Published private(set) var usageByAccount: [String: AccountUsage] = [:]
    @Published var isLoading = false

    var isMultiAccount: Bool { accounts.count > 1 }

    // The first account's reading. The single-account popover, the footer's
    // "updated" time and the refresh throttle all read these.
    var webUsage: WebUsageData? {
        accounts.first.flatMap { usageByAccount[$0.id]?.usage }
    }

    var error: String? {
        accounts.first.flatMap { usageByAccount[$0.id]?.error }
    }

    // When the last full pass over the accounts finished. The popover-open
    // throttle keys on this rather than on any reading's timestamp: an account
    // whose login has lapsed never produces a reading, and keying on readings
    // would re-poll every healthy account each time the popover opens.
    private var lastRefreshAt: Date?

    // Status properties
    @Published var claudeStatus: ClaudeStatus?
    @Published var isStatusLoading = false

    // API-equivalent spend, computed from the local transcripts
    @Published var spend: SpendData?

    // RTK token savings, read from RTK's local history db. Stays nil when RTK
    // isn't installed, which keeps the card off the popover entirely.
    @Published var rtkSavings: RTKSavings?

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
        claudeStatus?.color ?? Theme.textSecondary
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

        // Pick up profiles added to or removed from aimux since the last pass.
        let discovered = AimuxService.discoverAccounts()
        if discovered != accounts {
            accounts = discovered
            usageByAccount = usageByAccount.filter { key, _ in discovered.contains { $0.id == key } }
        }

        // One account at a time: each has its own token and its own budget on
        // the endpoint, and serial requests keep a slow one from racing another.
        for account in accounts {
            await refreshUsage(for: account)
        }
        lastRefreshAt = Date()

        // Also refresh status
        await refreshStatus()
        await refreshSpend()
        await refreshRTKSavings()
    }

    private func refreshUsage(for account: ClaudeAccount) async {
        var entry = usageByAccount[account.id] ?? AccountUsage()
        // With no data to fall back on, clear a prior error so a retry shows the
        // loading state instead of freezing on the old error. When data exists we
        // keep the error so the stale banner stays put during the retry.
        if entry.usage == nil {
            entry.error = nil
            usageByAccount[account.id] = entry
        }

        do {
            let usage = try await OAuthUsageService.service(for: account).fetchUsage()
            entry = AccountUsage(usage: usage)
            // The history file predates multiple accounts and holds one series;
            // keep it fed by the first account only rather than interleaving.
            if account == accounts.first {
                UsageHistoryService.shared.record(usage)
            }
        } catch {
            // Keep the last good data on screen. When it exists, ContentView
            // shows a subtle banner instead of replacing everything with an error.
            switch error as? UsageError {
            case .tokenExpired, .noCredentials:
                entry.needsLogin = true
                entry.error = account.profileName == nil
                    ? error.localizedDescription
                    : "Login expired. Run '\(account.reauthCommand)' to refresh it."
            default:
                entry.error = error.localizedDescription
            }
        }
        usageByAccount[account.id] = entry
    }

    // Spend reads the local transcripts, so it has no bearing on the usage
    // endpoint's rate limit and is safe to recompute on every refresh. The scan
    // is incremental after the first one.
    func refreshSpend() async {
        spend = await CostService.shared.fetchSpend()
    }

    // RTK savings come from RTK's own local SQLite log, independent of the usage
    // endpoint. If RTK is gone entirely the card is cleared so it self-hides;
    // otherwise the last-good value is kept on a nil fetch so a transient db lock
    // doesn't blink the card away. It first appears once RTK has logged a command.
    func refreshRTKSavings() async {
        if let latest = await RTKSavingsService.shared.fetch() {
            rtkSavings = latest
        } else if !(await RTKSavingsService.shared.isInstalled) {
            // fetch() returned nil: clear the card only when RTK is actually gone.
            // Re-checking install state *after* the fetch (rather than gating
            // before it) closes the window where RTK is removed between the check
            // and the fetch; a nil while still installed is a transient read
            // failure, so the last-good value stays put.
            rtkSavings = nil
        }
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
        // Only auto-refresh if never refreshed or more than 1 minute since the last pass
        if let lastUpdated = lastRefreshAt {
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
