import Foundation

struct UsageSnapshot: Codable {
    let timestamp: Date
    let sessionUsage: Double
    let weeklyUsage: Double
    let sonnetUsage: Double?
}

@MainActor
class UsageHistoryService {
    static let shared = UsageHistoryService()

    private let fileManager = FileManager.default
    private var snapshots: [UsageSnapshot] = []
    private let storageURL: URL

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClaudeCodeStats")
        storageURL = appDir.appendingPathComponent("usage_history.json")

        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        snapshots = (try? loadFromDisk()) ?? []
    }

    func record(_ usage: WebUsageData) {
        // Deduplicate: skip if last snapshot is less than 60 seconds old
        if let last = snapshots.last,
           Date().timeIntervalSince(last.timestamp) < 60 {
            return
        }

        let snapshot = UsageSnapshot(
            timestamp: Date(),
            sessionUsage: usage.sessionUsage,
            weeklyUsage: usage.weeklyUsage,
            sonnetUsage: usage.sonnetUsage
        )
        snapshots.append(snapshot)
        do {
            try writeToDisk()
        } catch {
            print("UsageHistoryService: Failed to write to disk: \(error)")
        }
    }

    func loadHistory() -> [UsageSnapshot] {
        return snapshots
    }

    private func loadFromDisk() throws -> [UsageSnapshot] {
        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([UsageSnapshot].self, from: data)
    }

    private func writeToDisk() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(snapshots)
        try data.write(to: storageURL, options: .atomic)
    }
}
