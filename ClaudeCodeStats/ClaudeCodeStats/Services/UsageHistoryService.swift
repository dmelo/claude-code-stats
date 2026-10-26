import Foundation

/// One usage reading for one account, as appended to the history log.
struct UsageSnapshot: Codable {
    let timestamp: Date
    /// The aimux profile name, or "default" for the plain no-aimux login.
    let account: String
    /// The account's Keychain service, which identifies the config dir the
    /// reading came from, not the Claude login inside it: a `/login` to another
    /// account in the same dir keeps the same ID, and the plain no-aimux login
    /// shares the bare one with aimux's source profile.
    let accountID: String
    /// The API's figure, or 0 when it reported none. An absent window is
    /// absent whole, so a missing reset time beside it marks that 0 as a fill.
    let sessionUsage: Double
    /// Absent when the API reported no reset time for the window.
    let sessionResetsAt: Date?
    let weeklyUsage: Double
    let weeklyResetsAt: Date?
    /// Absent on lines written before scoped limits were logged.
    let scopedLimits: [ScopedLimitSnapshot]?
}

/// A per-model weekly limit (e.g. Fable) within a snapshot.
struct ScopedLimitSnapshot: Codable {
    let name: String
    let usage: Double
    let resetsAt: Date?
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
        // Deduplicate: skip if this process recorded the account under 60 seconds
        // ago. Kept in memory only, so a relaunch can log one sample early.
        if let last = lastRecorded[account.id], now.timeIntervalSince(last) < 60 {
            return
        }

        let snapshot = UsageSnapshot(
            timestamp: now,
            account: account.profileName ?? "default",
            accountID: account.id,
            sessionUsage: usage.sessionUsage,
            sessionResetsAt: usage.reportedSessionResetsAt,
            weeklyUsage: usage.weeklyUsage,
            weeklyResetsAt: usage.reportedWeeklyResetsAt,
            scopedLimits: usage.scopedLimits.map {
                ScopedLimitSnapshot(name: $0.name, usage: $0.usage, resetsAt: $0.reportedResetsAt)
            }
        )
        do {
            try append(snapshot)
            lastRecorded[account.id] = now
        } catch {
            print("UsageHistoryService: Failed to write to disk: \(error)")
        }
    }

    private func append(_ snapshot: UsageSnapshot) throws {
        var line = try encoder.encode(snapshot)
        line.append(UInt8(ascii: "\n"))
        // O_APPEND makes the kernel place every write at the current end, so two
        // running copies of the app (an installed build beside a dev build) can't
        // land on the same offset and overwrite each other's lines. O_CREAT
        // creates the file on first use and never truncates an existing one.
        let fd = open(storageURL.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        // A write cut short (the app killed mid-line) leaves no trailing newline.
        // Start on a fresh line, or this sample is glued onto the torn one and
        // lost with it.
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) {
                line.insert(UInt8(ascii: "\n"), at: 0)
            }
        }
        try handle.write(contentsOf: line)
    }
}
