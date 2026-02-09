import Foundation

struct Organization: Codable {
    let uuid: String
    let name: String
}

struct WebUsageResponse: Codable {
    let fiveHour: WebUsageWindow?
    let sevenDay: WebUsageWindow?
    let sevenDayOpus: WebUsageWindow?
    let sevenDaySonnet: WebUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

struct WebUsageWindow: Codable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct WebUsageData {
    let sessionUsage: Double
    let sessionResetsAt: Date
    let weeklyUsage: Double
    let weeklyResetsAt: Date
    let sonnetUsage: Double?
    let sonnetResetsAt: Date?
    let lastUpdated: Date

    static var empty: WebUsageData {
        WebUsageData(
            sessionUsage: 0,
            sessionResetsAt: Date(),
            weeklyUsage: 0,
            weeklyResetsAt: Date(),
            sonnetUsage: nil,
            sonnetResetsAt: nil,
            lastUpdated: Date()
        )
    }
}

enum WebSessionError: Error, LocalizedError {
    case noSessionKey
    case networkError(Error)
    case invalidResponse
    case unauthorized
    case noOrganization
    case decodingError(Error)
    case cloudflareChallenge

    var errorDescription: String? {
        switch self {
        case .noSessionKey:
            return "No session key. Tap \u{2699}\u{FE0F} to configure."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from claude.ai"
        case .unauthorized:
            return "Session expired. Update your cookie."
        case .noOrganization:
            return "Could not find organization."
        case .decodingError:
            return "Failed to parse usage data."
        case .cloudflareChallenge:
            return "Blocked by Cloudflare. Visit claude.ai in browser, then refresh."
        }
    }
}
