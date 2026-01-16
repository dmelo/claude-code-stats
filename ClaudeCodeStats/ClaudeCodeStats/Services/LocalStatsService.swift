import Foundation

struct LocalStatsCache: Codable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let dailyModelTokens: [DailyModelTokens]
    let modelUsage: [String: ModelUsage]
    let totalSessions: Int
    let totalMessages: Int
    let firstSessionDate: String?

    struct DailyActivity: Codable {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    struct DailyModelTokens: Codable {
        let date: String
        let tokensByModel: [String: Int]
    }

    struct ModelUsage: Codable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
    }
}

struct LocalUsageData {
    let todayMessages: Int
    let todayTokens: Int
    let weekMessages: Int
    let weekTokens: Int
    let totalSessions: Int
    let totalMessages: Int
    let lastUpdated: Date
    let primaryModel: String

    var todayUsageEstimate: Double {
        // Rough estimate: assume ~2000 messages per session limit
        min(100, Double(todayMessages) / 20.0)
    }

    var weekUsageEstimate: Double {
        // Rough estimate based on typical weekly usage patterns
        min(100, Double(weekMessages) / 140.0)
    }
}

class LocalStatsService {
    static let shared = LocalStatsService()

    private var statsFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/stats-cache.json"
    }

    private init() {}

    func fetchLocalStats() throws -> LocalUsageData {
        let url = URL(fileURLWithPath: statsFilePath)

        guard FileManager.default.fileExists(atPath: statsFilePath) else {
            throw LocalStatsError.fileNotFound
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let stats = try decoder.decode(LocalStatsCache.self, from: data)

        return processStats(stats)
    }

    private func processStats(_ stats: LocalStatsCache) -> LocalUsageData {
        let today = dateString(from: Date())
        let weekAgo = dateString(from: Date().addingTimeInterval(-7 * 24 * 3600))

        // Today's stats
        let todayActivity = stats.dailyActivity.first { $0.date == today }
        let todayMessages = todayActivity?.messageCount ?? 0

        let todayTokens = stats.dailyModelTokens
            .first { $0.date == today }?
            .tokensByModel.values.reduce(0, +) ?? 0

        // This week's stats
        let weekActivities = stats.dailyActivity.filter { $0.date >= weekAgo }
        let weekMessages = weekActivities.reduce(0) { $0 + $1.messageCount }

        let weekTokens = stats.dailyModelTokens
            .filter { $0.date >= weekAgo }
            .flatMap { $0.tokensByModel.values }
            .reduce(0, +)

        // Find primary model
        let primaryModel = stats.modelUsage.max { $0.value.outputTokens < $1.value.outputTokens }?.key ?? "Unknown"
        let modelName = formatModelName(primaryModel)

        return LocalUsageData(
            todayMessages: todayMessages,
            todayTokens: todayTokens,
            weekMessages: weekMessages,
            weekTokens: weekTokens,
            totalSessions: stats.totalSessions,
            totalMessages: stats.totalMessages,
            lastUpdated: Date(),
            primaryModel: modelName
        )
    }

    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func formatModelName(_ model: String) -> String {
        if model.contains("opus") {
            return "Opus"
        } else if model.contains("sonnet") {
            return "Sonnet"
        } else if model.contains("haiku") {
            return "Haiku"
        }
        return model
    }
}

enum LocalStatsError: Error, LocalizedError {
    case fileNotFound
    case parsingError

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Stats file not found. Use Claude Code first."
        case .parsingError:
            return "Failed to parse stats file."
        }
    }
}
