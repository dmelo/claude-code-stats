import Foundation

// A weekly limit scoped to a specific model (e.g. "Fable"), shown alongside
// the overall session and all-models limits.
struct ScopedUsageLimit: Identifiable {
    let name: String
    let usage: Double
    let resetsAt: Date

    var id: String { name }
}

struct WebUsageData {
    let sessionUsage: Double
    let sessionResetsAt: Date
    let weeklyUsage: Double
    let weeklyResetsAt: Date
    let scopedLimits: [ScopedUsageLimit]
    let lastUpdated: Date

    static var empty: WebUsageData {
        WebUsageData(
            sessionUsage: 0,
            sessionResetsAt: Date(),
            weeklyUsage: 0,
            weeklyResetsAt: Date(),
            scopedLimits: [],
            lastUpdated: Date()
        )
    }
}

// What a model's tokens would have cost at API rates over a window.
struct ModelSpend: Identifiable {
    let model: String
    let cost: Double

    var id: String { model }
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

    private static let usdWholeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// Rounded to whole dollars, for floor estimates where cents would be false
    /// precision, e.g. 160.4 → "$160", 0.21 → "$0".
    var usdWhole: String {
        Self.usdWholeFormatter.string(from: NSNumber(value: self)) ?? "$0"
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
    let monthSaved: Int
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
    let lastUpdated: Date

    /// Share of routed command output RTK stripped, lifetime. Clamped to 0…1:
    /// the counts come from RTK's database, and malformed data (e.g. saved
    /// exceeding raw) must not drive the meter past full width or show a
    /// percentage outside 0–100%.
    var reduction: Double {
        guard lifetimeRaw > 0 else { return 0 }
        return min(1, max(0, Double(lifetimeSaved) / Double(lifetimeRaw)))
    }

    // API-equivalent value of the saved tokens per window — floor estimates.
    var todayValue: Double { Double(todaySaved) / 1_000_000 * inputRate }
    var weekValue: Double { Double(weekSaved) / 1_000_000 * inputRate }
    var monthValue: Double { Double(monthSaved) / 1_000_000 * inputRate }
}

extension Int {
    /// Compact token count for display: 79_609_145 → "79.6M", 42_842 → "42.8K",
    /// 216 → "216".
    var tokensShort: String {
        let value = Double(self)
        switch value.magnitude {
        case 1_000_000_000...:
            return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", value / 1_000)
        default:
            return "\(self)"
        }
    }
}

// One day's total. Days with no activity are present with a zero cost so the
// chart shows a real gap rather than closing it up.
struct DailySpend: Identifiable {
    let date: Date
    let cost: Double

    var id: Date { date }
}

// Spend is API-equivalent, not money charged: on a subscription these tokens are
// already paid for, so this measures what they'd have cost billed per-token.
struct SpendData {
    let today: Double
    let week: Double
    let month: Double
    let monthByModel: [ModelSpend]
    /// Rolling window ending today, oldest first.
    let daily: [DailySpend]
    let lastUpdated: Date
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
