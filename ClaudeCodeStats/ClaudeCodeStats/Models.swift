import Foundation

struct WebUsageData {
    let sessionUsage: Double
    let sessionResetsAt: Date
    let weeklyUsage: Double
    let weeklyResetsAt: Date
    let lastUpdated: Date

    static var empty: WebUsageData {
        WebUsageData(
            sessionUsage: 0,
            sessionResetsAt: Date(),
            weeklyUsage: 0,
            weeklyResetsAt: Date(),
            lastUpdated: Date()
        )
    }
}

enum UsageError: Error, LocalizedError {
    case noCredentials
    case networkError(Error)
    case invalidResponse
    case tokenExpired

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
        }
    }
}
