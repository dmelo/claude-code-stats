import SwiftUI

// The latest reading for one account. `usage` survives a failed refresh so the
// popover can keep showing it under a banner; `needsLogin` says the reading can
// no longer be refreshed without the user re-authenticating that login.
struct AccountUsage {
    var usage: WebUsageData?
    var error: String?
    var needsLogin = false
}

// Something the app shows limits for: a Claude Code login, or Codex. Views only
// ever see an account's id, its name and its AccountUsage — which service fills
// that in is decided once, in UsageViewModel.refreshUsage(for:).
enum UsageAccount: Identifiable, Hashable {
    case claude(ClaudeAccount)
    case codex

    var id: String {
        switch self {
        case .claude(let account): return account.id
        case .codex: return "codex"
        }
    }

    /// The name per-profile menu bar preferences are stored under: the aimux
    /// profile name, or "codex". Nil for the plain no-aimux Claude login.
    var profileName: String? {
        switch self {
        case .claude(let account): return account.profileName
        case .codex: return "codex"
        }
    }

    /// The popover card's title.
    var displayName: String {
        switch self {
        case .claude(let account): return account.profileName ?? "Claude"
        case .codex: return "Codex"
        }
    }

    /// The Claude logins first, in aimux config order, then Codex when it is
    /// logged in with ChatGPT. Once shown, Codex stays while its login file
    /// exists: Codex rewrites the file when it refreshes, and one read landing
    /// mid-write would otherwise drop the account and its reading.
    static func discover(keepingCodex: Bool = false) -> [UsageAccount] {
        let codex = CodexTracking.isEnabled
            && (CodexUsageService.hasLogin || (keepingCodex && CodexUsageService.hasAuthFile))
        return AimuxService.discoverAccounts().map(UsageAccount.claude) + (codex ? [.codex] : [])
    }
}

/// The Settings switch for Codex. Off, the app makes no Codex request and
/// reads no Codex session log: no limits card, no rings, no spend.
enum CodexTracking {
    static let key = "trackCodex"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Whether Codex has been used on this Mac (a login file or a session-log
    /// folder), which is when Settings offers the switch.
    static var isDetected: Bool {
        CodexUsageService.hasAuthFile || CodexCostService.hasSessions
    }
}

@MainActor
class UsageViewModel: ObservableObject {
    // Every account being polled: one per aimux claude profile (exactly one,
    // the default ~/.claude login, when aimux isn't set up), then Codex.
    @Published private(set) var accounts: [UsageAccount] = UsageAccount.discover()
    @Published private(set) var usageByAccount: [String: AccountUsage] = [:]
    @Published var isLoading = false

    var isMultiAccount: Bool { accounts.count > 1 }

    /// The Claude logins alone: the ones with credentials to check and a
    /// command to re-authenticate.
    var claudeAccounts: [ClaudeAccount] {
        accounts.compactMap { if case .claude(let account) = $0 { return account } else { return nil } }
    }

    // The first account's reading, for the single-account popover.
    var webUsage: WebUsageData? {
        accounts.first.flatMap { usageByAccount[$0.id]?.usage }
    }

    var error: String? {
        accounts.first.flatMap { usageByAccount[$0.id]?.error }
    }

    /// Newest successful reading across accounts, for the footer. Keyed on any
    /// account, not the first, so one lapsed login doesn't freeze it at "Not
    /// yet updated" while the others refresh.
    var lastUpdated: Date? {
        accounts.compactMap { usageByAccount[$0.id]?.usage?.lastUpdated }.max()
    }

    /// Whether the logins being polled can be read. With aimux this is every
    /// profile's, not ~/.claude's — which may not be one of them at all.
    func hasCredentials(_ account: ClaudeAccount) -> Bool {
        OAuthUsageService.service(for: account).hasCredentials
    }

    var allAccountsHaveCredentials: Bool {
        claudeAccounts.allSatisfy(hasCredentials)
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
        rediscoverAccounts()

        // Concurrently: each account has its own token, service instance and
        // dictionary slot, and everything else they touch is main-actor state
        // updated between awaits, so the fetches can't trample each other. Serially,
        // an offline machine would wait out every account's retries in turn
        // (about a minute each) with the spinner held and spend/status queued.
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.refreshUsage(for: account) }
            }
        }
        lastRefreshAt = Date()

        // Also refresh status
        await refreshStatus()
        await refreshSpend()
        await refreshRTKSavings()
    }

    private func rediscoverAccounts() {
        let discovered = UsageAccount.discover(keepingCodex: accounts.contains(.codex))
        if discovered != accounts {
            accounts = discovered
            usageByAccount = usageByAccount.filter { key, _ in discovered.contains { $0.id == key } }
        }
    }

    /// Applies the Track Codex switch at once rather than at the next refresh:
    /// the card, rings and spend share appear or go together.
    func codexTrackingChanged() async {
        rediscoverAccounts()
        if accounts.contains(.codex) {
            await refreshCodexUsage()
        }
        await refreshSpend()
    }

    private func refreshUsage(for account: UsageAccount) async {
        switch account {
        case .claude(let claude): await refreshUsage(for: claude)
        case .codex: await refreshCodexUsage()
        }
    }

    // Same shape as a Claude login's refresh: keep the last reading through a
    // transient failure, and hide it once the login has lapsed. Only the
    // messages differ — Codex refreshes its own login when it runs.
    private func refreshCodexUsage() async {
        let id = UsageAccount.codex.id
        var entry = usageByAccount[id] ?? AccountUsage()
        // As for a Claude login: with no reading to fall back on, clear the old
        // error so the retry shows as loading rather than as a fresh failure.
        if entry.usage == nil {
            entry.error = nil
            usageByAccount[id] = entry
        }
        do {
            entry = AccountUsage(usage: try await CodexUsageService.shared.fetchUsage())
        } catch {
            switch error as? UsageError {
            case .tokenExpired:
                entry.needsLogin = true
                entry.error = "Codex login expired. Run 'codex' to refresh it."
            case .noCredentials:
                entry.needsLogin = true
                entry.error = "No Codex login found. Run 'codex login' to sign in with ChatGPT."
            default:
                if !entry.needsLogin {
                    entry.error = error.localizedDescription
                }
            }
        }
        usageByAccount[id] = entry
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
            UsageHistoryService.shared.record(usage, for: account)
        } catch {
            // Keep the last good data on screen. When it exists, ContentView
            // shows a subtle banner instead of replacing everything with an error.
            switch error as? UsageError {
            case .tokenExpired:
                entry.needsLogin = true
                entry.error = account.profileName == nil
                    ? error.localizedDescription
                    : "Login expired. Run '\(account.reauthCommand)' to refresh it."
            case .noCredentials:
                // Nothing readable at all: never logged in, or Keychain access
                // was denied. Re-running the CLI fixes only the first, so say both.
                entry.needsLogin = true
                entry.error = account.profileName == nil
                    ? error.localizedDescription
                    : "No login found. Run '\(account.reauthCommand)' to log in, or allow Keychain access if macOS asked."
            default:
                // A transient failure on top of a lapsed login keeps the login
                // message: it is still the thing the user has to act on, and
                // needsLogin is still hiding the rows it would otherwise explain.
                if !entry.needsLogin {
                    entry.error = error.localizedDescription
                }
            }
        }
        usageByAccount[account.id] = entry
    }

    // Spend reads the local transcripts, so it has no bearing on the usage
    // endpoint's rate limit and is safe to recompute on every refresh. The scan
    // is incremental after the first one.
    func refreshSpend() async {
        // Concurrently: separate actors over separate files.
        async let claude = CostService.shared.fetchLedger()
        async let codex: SpendLedger = CodexTracking.isEnabled ? await CodexCostService.shared.fetchLedger() : [:]
        spend = SpendData.summarize(claude: await claude, codex: await codex)
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
