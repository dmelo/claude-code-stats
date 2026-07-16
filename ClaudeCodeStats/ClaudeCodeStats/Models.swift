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
