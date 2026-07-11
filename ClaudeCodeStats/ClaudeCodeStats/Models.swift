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
