import Foundation

// A weekly limit scoped to a specific model (e.g. "Fable"), shown alongside
// the overall session and all-models limits.
struct ScopedUsageLimit: Identifiable {
    let name: String
    let usage: Double
    let resetsAt: Date
    /// `resetsAt` as the API sent it — nil when it sent none and `resetsAt` is
    /// only a display fallback. The history log records this one.
    var reportedResetsAt: Date? = nil

    var id: String { name }
}

struct WebUsageData {
    /// nil when the account has no 5-hour window: verified Ultra accounts
    /// report `five_hour: null`. Decided per reading, not per plan, because an
    /// Ultra account keeps the window until Anthropic verifies it.
    let sessionUsage: Double?
    let sessionResetsAt: Date
    let weeklyUsage: Double
    let weeklyResetsAt: Date
    let scopedLimits: [ScopedUsageLimit]
    let lastUpdated: Date
    /// The reset times as the API sent them. The non-optional pair above falls
    /// back to now when a window has none, which is fine to display and wrong
    /// to log: it reads as a reset on every sample.
    var reportedSessionResetsAt: Date? = nil
    var reportedWeeklyResetsAt: Date? = nil

    /// A reading older than this is stale: readings are refreshed every few
    /// minutes, so one only gets this old while refreshing fails.
    static let staleAfter: TimeInterval = 15 * 60

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(lastUpdated) >= Self.staleAfter
    }

    /// "As of 3h ago" for a stale reading, else nil.
    func ageText(at now: Date) -> String? {
        guard isStale(at: now) else { return nil }
        let minutes = Int(now.timeIntervalSince(lastUpdated) / 60)
        if minutes < 60 { return "As of \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "As of \(hours)h ago" }
        return "As of \(hours / 24)d ago"
    }

    /// Whether a stale reading's window has reset since the reading was taken,
    /// so its figure no longer holds. Only once stale: a healthy account polls
    /// within minutes of any reset, and calling the window unknown for that gap
    /// would blink every ring dashed every five hours with nothing wrong.
    func hasReset(_ reportedResetsAt: Date?, at now: Date) -> Bool {
        guard let reportedResetsAt, isStale(at: now) else { return false }
        return reportedResetsAt > lastUpdated && reportedResetsAt <= now
    }

    /// A window's figure at `now`, or nil once it has reset since the reading.
    /// Not 0: the limits are shared across machines (and, for Codex, across the
    /// ChatGPT account's other surfaces), so usage since the reset can be
    /// anything until the next reading says.
    func usage(_ value: Double, reportedResetsAt: Date?, at now: Date) -> Double? {
        hasReset(reportedResetsAt, at: now) ? nil : value
    }
}

// What a model's tokens would have cost at API rates over a window.
struct ModelSpend: Identifiable {
    let model: String
    let cost: Double
    var provider: SpendProvider = .claude

    var id: String { model }
}

/// Which tool's tokens a cost came from. The spend card shows one combined
/// total and splits it by this.
enum SpendProvider: String {
    case claude
    case codex
}

extension Double {
    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    /// Formatted as US dollars for display, e.g. "$1,934.52".
    var usd: String {
        Self.usdFormatter.string(from: NSNumber(value: self)) ?? "$0.00"
    }

    private static let usdFloorFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        // Round down, never to nearest: these values are labeled a conservative
        // floor, so 160.7 must render "$160" and 0.6 must render "$0". Rounding up
        // would overstate the very thing the "floor" caption promises it won't.
        formatter.roundingMode = .down
        return formatter
    }()

    /// Floored to whole dollars, for conservative floor estimates where cents
    /// would be false precision, e.g. 160.7 → "$160", 0.6 → "$0".
    var usdFloor: String {
        Self.usdFloorFormatter.string(from: NSNumber(value: self)) ?? "$0"
    }

    private static let wholeFloorFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .down
        return formatter
    }()

    /// Floored to a whole grouped number with no currency symbol, e.g. 516 →
    /// "516", 1234 → "1,234". For the upper bound of a currency range whose lower
    /// bound already carries the symbol ("$166–516"). The symbol is never stripped
    /// by string surgery — `dropFirst()` on a formatted currency string breaks
    /// under non-en_US formats like "US$ 166" or "166 $".
    var wholeFloor: String {
        Self.wholeFloorFormatter.string(from: NSNumber(value: self)) ?? "0"
    }
}

// RTK (Rust Token Killer) proxies dev commands and filters their output before it
// reaches Claude Code's context, logging each command's raw vs. filtered token
// counts to a local SQLite history. This is that log summed over windows. "Saved"
// means tool-output tokens kept out of context — a fraction of total usage, not of
// the whole bill, and only for commands routed through RTK.
struct RTKSavings {
    let todaySaved: Int
    let weekSaved: Int
    let last30Saved: Int
    let lifetimeSaved: Int
    /// Raw pre-filter tokens across all routed commands — the denominator for the
    /// average reduction. This is what RTK calls "input": the command's full
    /// output before filtering, i.e. the input to RTK, not to the model.
    let lifetimeRaw: Int
    let commandCount: Int
    /// $ per million tokens used to value saved tokens — a representative input
    /// rate sourced from the spend price table (see
    /// `CostService.representativeInputRate`). The values below are a deliberate
    /// floor: saved tokens priced once at the input rate, so the true worth (with
    /// multi-turn re-billing) is higher.
    let inputRate: Double
    /// Multiplier applied to the floor for the optimistic end of the value range:
    /// the re-billing a saved token would have incurred had it stayed in context
    /// (a cache write plus the account's observed re-reads). See
    /// `CostService.contextRebillingCeiling`. 1.0 would collapse the range.
    let ceilingMultiplier: Double
    let lastUpdated: Date

    /// Share of routed command output RTK stripped, lifetime. Clamped to 0…1:
    /// the counts come from RTK's database, and malformed data (e.g. saved
    /// exceeding raw) must not drive the meter past full width or show a
    /// percentage outside 0–100%.
    var reduction: Double {
        guard lifetimeRaw > 0 else { return 0 }
        return min(1, max(0, Double(lifetimeSaved) / Double(lifetimeRaw)))
    }

    // API-equivalent value of the saved tokens per window, as a range. The floor
    // prices each token once at the input rate; the ceiling adds the context
    // re-billing it would have incurred unfiltered. Truth sits between.
    var todayFloor: Double { Double(todaySaved) / 1_000_000 * inputRate }
    var weekFloor: Double { Double(weekSaved) / 1_000_000 * inputRate }
    var last30Floor: Double { Double(last30Saved) / 1_000_000 * inputRate }
    var todayCeiling: Double { todayFloor * ceilingMultiplier }
    var weekCeiling: Double { weekFloor * ceilingMultiplier }
    var last30Ceiling: Double { last30Floor * ceilingMultiplier }
}

extension Int {
    /// Compact token count for display: 79_609_145 → "79.6M", 42_842 → "42.8K",
    /// 216 → "216". A count is shown at the largest unit whose one-decimal
    /// rounded value stays below 1000, so a near-threshold count like 999_950 —
    /// which "%.1f" would round to "1000.0K" — reads "1.0M" instead. The 0.99995
    /// cutoff is where n/1000 rounds up to 1000.0 (n/next-unit ≥ 0.99995).
    var tokensShort: String {
        let value = Double(self)
        let units: [(scale: Double, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K"),
        ]
        for unit in units where value.magnitude / unit.scale >= 0.99995 {
            return String(format: "%.1f%@", value / unit.scale, unit.suffix)
        }
        return "\(self)"
    }
}

// One day's total. Days with no activity are present with a zero cost so the
// chart shows a real gap rather than closing it up.
struct DailySpend: Identifiable {
    let date: Date
    var claude: Double = 0
    var codex: Double = 0

    var cost: Double { claude + codex }
    var id: Date { date }
}

/// One window's spend, split by tool.
struct SpendSplit {
    var claude: Double = 0
    var codex: Double = 0

    var total: Double { claude + codex }
}

// Spend is API-equivalent, not money charged: on a subscription these tokens are
// already paid for, so this measures what they'd have cost billed per-token.
struct SpendData {
    let today: SpendSplit
    let week: SpendSplit
    let last30: SpendSplit
    let last30ByModel: [ModelSpend]
    /// Rolling window ending today, oldest first.
    let daily: [DailySpend]
    let lastUpdated: Date

    /// Whether any Codex spend falls in the window. Without it the card looks
    /// exactly as it did before Codex was counted: no split lines, no legend.
    var hasCodex: Bool { last30.codex > 0 }
}

/// Cost by local day ("yyyy-MM-dd") and then by model display name — what each
/// spend scanner produces, and all the summary needs.
typealias SpendLedger = [String: [String: Double]]

enum SpendDay {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // Pinned, per Apple's guidance for fixed-format dates: left alone, the
        // formatter inherits the user's calendar, and "yyyy" under a Buddhist or
        // Japanese one renders 2026 as 2569 or 0008 — day keys would stop
        // matching the ones Calendar.current is compared against. The time zone
        // stays on the system's, since a day here means the user's local day.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func key(for date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        formatter.date(from: key)
    }
}

extension SpendData {
    /// Days of history the chart plots and the longest total covers.
    static let windowDays = 30

    /// Totals for today, the last 7 and the last `windowDays` days, plus the
    /// chart's days, from each tool's ledger. The window is rolling and shared
    /// with the chart, so the last-30-days total is exactly the sum of the bars.
    static func summarize(claude: SpendLedger, codex: SpendLedger,
                          windowDays: Int = windowDays, now: Date = Date()) -> SpendData {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) ?? today

        var todayTotal = SpendSplit()
        var weekTotal = SpendSplit()
        var windowTotal = SpendSplit()
        var byModel: [String: (cost: Double, provider: SpendProvider)] = [:]
        var byDay: [String: SpendSplit] = [:]

        for (provider, ledger) in [(SpendProvider.claude, claude), (.codex, codex)] {
            func add(_ cost: Double, to split: inout SpendSplit) {
                switch provider {
                case .claude: split.claude += cost
                case .codex: split.codex += cost
                }
            }
            for (day, models) in ledger {
                guard let date = SpendDay.date(from: day) else { continue }
                for (model, cost) in models {
                    add(cost, to: &byDay[day, default: SpendSplit()])
                    if date >= today { add(cost, to: &todayTotal) }
                    if date >= weekStart { add(cost, to: &weekTotal) }
                    if date >= windowStart {
                        add(cost, to: &windowTotal)
                        byModel[model, default: (0, provider)].cost += cost
                    }
                }
            }
        }

        // Walk the window day by day rather than reading back the keys present,
        // so a day with no activity yields a zero-height bar instead of being
        // dropped and letting its neighbours close the gap.
        var daily: [DailySpend] = []
        for offset in stride(from: -(windowDays - 1), through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let split = byDay[SpendDay.key(for: date)] ?? SpendSplit()
            daily.append(DailySpend(date: date, claude: split.claude, codex: split.codex))
        }

        return SpendData(
            today: todayTotal,
            week: weekTotal,
            last30: windowTotal,
            last30ByModel: byModel
                .map { ModelSpend(model: $0.key, cost: $0.value.cost, provider: $0.value.provider) }
                .sorted { $0.cost > $1.cost },
            daily: daily,
            lastUpdated: now
        )
    }
}

enum UsageError: Error, LocalizedError {
    case noCredentials
    case networkError(Error)
    case invalidResponse
    case tokenExpired
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No OAuth credentials found. Log in with Claude Code first."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from API."
        case .tokenExpired:
            return "OAuth token expired. Run 'claude' to re-authenticate."
        case .rateLimited:
            return "Usage data is temporarily rate-limited. Try again in a few minutes."
        }
    }
}
