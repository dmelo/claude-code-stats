import Foundation

struct UsageResponse: Codable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct UsageWindow: Codable {
    let utilization: Double
    let resetsAt: Date

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct UsageData {
    let sessionUsage: Double
    let sessionResetsAt: Date
    let weeklyUsage: Double
    let weeklyResetsAt: Date
    let lastUpdated: Date

    init(from response: UsageResponse) {
        self.sessionUsage = response.fiveHour.utilization
        self.sessionResetsAt = response.fiveHour.resetsAt
        self.weeklyUsage = response.sevenDay.utilization
        self.weeklyResetsAt = response.sevenDay.resetsAt
        self.lastUpdated = Date()
    }

    static var placeholder: UsageData {
        UsageData(
            sessionUsage: 0,
            sessionResetsAt: Date().addingTimeInterval(3600 * 5),
            weeklyUsage: 0,
            weeklyResetsAt: Date().addingTimeInterval(3600 * 24 * 7),
            lastUpdated: Date()
        )
    }

    private init(sessionUsage: Double, sessionResetsAt: Date, weeklyUsage: Double, weeklyResetsAt: Date, lastUpdated: Date) {
        self.sessionUsage = sessionUsage
        self.sessionResetsAt = sessionResetsAt
        self.weeklyUsage = weeklyUsage
        self.weeklyResetsAt = weeklyResetsAt
        self.lastUpdated = lastUpdated
    }
}
