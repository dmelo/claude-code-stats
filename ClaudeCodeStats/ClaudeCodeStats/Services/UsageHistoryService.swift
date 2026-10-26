import Foundation

/// One usage reading for one account, as appended to the history log.
struct UsageSnapshot: Codable {
    let timestamp: Date
    /// The aimux profile name, or "default" for the plain no-aimux login.
    let account: String
    /// The account's Keychain service, which is what tells logins apart: two
    /// profiles never share one, while a profile name says nothing about which
    /// login sat behind it before a rename.
    let accountID: String
    let sessionUsage: Double
    let sessionResetsAt: Date
    let weeklyUsage: Double
    let weeklyResetsAt: Date
}

// Appends every account's readings to a JSON Lines log, one snapshot per line.
//
// The log replaces usage_history.json, which held a single series fed by the
// first account only and was rewritten whole on every sample. That file is left
// in place and no longer written: its samples carry no account, so folding them
// into this log would mean guessing which login each one came from.
@MainActor
class UsageHistoryService {
    static let shared = UsageHistoryService()

    private let fileManager = FileManager.default
    private let storageURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    // Per account, so a refresh that polls several accounts within the same
    // second records each of them rather than only the first.
    private var lastRecorded: [String: Date] = [:]

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClaudeCodeStats")
        storageURL = appDir.appendingPathComponent("usage_history.jsonl")

        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
    }

    func record(_ usage: WebUsageData, for account: ClaudeAccount) {
        let now = Date()
        // Deduplicate: skip if this account's last snapshot is less than 60 seconds old
        if let last = lastRecorded[account.id], now.timeIntervalSince(last) < 60 {
            return
        }

        let snapshot = UsageSnapshot(
            timestamp: now,
            account: account.profileName ?? "default",
            accountID: account.id,
            sessionUsage: usage.sessionUsage,
            sessionResetsAt: usage.sessionResetsAt,
            weeklyUsage: usage.weeklyUsage,
            weeklyResetsAt: usage.weeklyResetsAt
        )
        do {
            try append(snapshot)
            lastRecorded[account.id] = now
        } catch {
            print("UsageHistoryService: Failed to write to disk: \(error)")
        }
    }

    func loadHistory() -> [UsageSnapshot] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Line by line, so a line cut short by a crash mid-write costs only itself.
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(UsageSnapshot.self, from: Data($0))
        }
    }

    private func append(_ snapshot: UsageSnapshot) throws {
        var line = try encoder.encode(snapshot)
        line.append(UInt8(ascii: "\n"))
        // Only a missing file is created here. Any other failure to open must
        // throw, or a write would replace the whole history with one line.
        guard fileManager.fileExists(atPath: storageURL.path) else {
            try line.write(to: storageURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: storageURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
