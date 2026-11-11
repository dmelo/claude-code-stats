import Foundation

// Codex's limits, read from the session logs Codex writes rather than from an
// API. Every turn appends a `token_count` event carrying the account's rate
// limits as of that turn, so a reading is only as fresh as the last Codex turn
// on this machine: its `lastUpdated` is that turn's time, not when it was read.
//
// The event, trimmed to what is read here:
//
//   {"timestamp":"2026-10-23T11:45:55.123Z","type":"event_msg","payload":{
//     "type":"token_count","rate_limits":{"limit_id":"codex",
//       "primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1792773964},
//       "secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1793295423}}}}
actor CodexUsageService {
    static let shared = CodexUsageService()

    /// Where Codex writes its sessions: `$CODEX_HOME/sessions`, ~/.codex by default.
    nonisolated static var sessionsDir: URL {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
    }

    /// Codex appears only on a machine that has run it.
    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: sessionsDir.path)
    }

    private struct SessionFile {
        let path: String
        let modified: Date
    }

    // The last reading in each file, keyed by path, with the modification date
    // it was read at: an unchanged file isn't read again. A nil reading records
    // that the file holds none.
    private var readings: [String: (modified: Date, reading: WebUsageData?)] = [:]

    private init() {}

    /// The newest reading in any session file, or nil when none holds one.
    func latestReading() -> WebUsageData? {
        let files = sessionFiles()
        readings = readings.filter { path, _ in files.contains { $0.path == path } }
        // Newest file first: the last file written holds the last turn. A
        // session on a local model carries no limits, so older files are the
        // fallback rather than an empty result.
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            if let reading = reading(in: file) { return reading }
        }
        return nil
    }

    private func sessionFiles() -> [SessionFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: Self.sessionsDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [SessionFile] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            files.append(SessionFile(path: url.path, modified: modified))
        }
        return files
    }

    private func reading(in file: SessionFile) -> WebUsageData? {
        if let cached = readings[file.path], cached.modified == file.modified {
            return cached.reading
        }
        let reading = Self.lastReading(atPath: file.path)
        readings[file.path] = (file.modified, reading)
        return reading
    }

    /// Scans backwards a chunk at a time: the reading wanted is near the end,
    /// and a long session runs to tens of megabytes.
    private static func lastReading(atPath path: String) -> WebUsageData? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard var offset = try? handle.seekToEnd() else { return nil }

        let chunkSize: UInt64 = 256 * 1024
        // The start of a line whose beginning lies in a chunk not read yet.
        var carry = Data()
        while offset > 0 {
            let start = offset > chunkSize ? offset - chunkSize : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(offset - start)) else { return nil }
            offset = start

            var lines = (chunk + carry).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // Only the first line can be cut off, and only when there is more
            // file before this chunk.
            carry = start > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() {
                if let reading = parse(Data(line)) { return reading }
            }
        }
        return nil
    }

    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let sessionWindowMinutes = 300
    private static let weeklyWindowMinutes = 10080

    private struct Event: Decodable {
        let timestamp: String
        let payload: Payload

        struct Payload: Decodable {
            let type: String
            let rateLimits: RateLimits?
        }

        struct RateLimits: Decodable {
            let limitId: String?
            let primary: Window?
            let secondary: Window?
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let windowMinutes: Int?
            let resetsAt: Double?
        }
    }

    /// A reading from one line, or nil when the line holds none. Only the
    /// `codex` limit counts (older Codex wrote no `limit_id`); `premium` and
    /// sessions on local models report every window null.
    ///
    /// Windows are matched by length, not position: `primary` is usually the
    /// 5-hour window, but some models report only a weekly one there.
    static func parse(_ line: Data) -> WebUsageData? {
        guard line.range(of: tokenCountMarker) != nil else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let event = try? decoder.decode(Event.self, from: line),
              event.payload.type == "token_count",
              let limits = event.payload.rateLimits,
              (limits.limitId ?? "codex") == "codex",
              let taken = parseDate(event.timestamp) else { return nil }

        let windows = [limits.primary, limits.secondary].compactMap { $0 }
        func window(minutes: Int) -> (usage: Double, resetsAt: Date?)? {
            guard let match = windows.first(where: { $0.windowMinutes == minutes }),
                  let used = match.usedPercent else { return nil }
            return (used, match.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
        // Every reading seen so far (Plus plan) carries a weekly window, and the
        // card has no shape for one without it, so such a line is skipped.
        guard let weekly = window(minutes: weeklyWindowMinutes) else { return nil }
        let session = window(minutes: sessionWindowMinutes)

        return WebUsageData(
            sessionUsage: session?.usage,
            sessionResetsAt: session?.resetsAt ?? taken,
            weeklyUsage: weekly.usage,
            weeklyResetsAt: weekly.resetsAt ?? taken,
            scopedLimits: [],
            lastUpdated: taken,
            reportedSessionResetsAt: session?.resetsAt,
            reportedWeeklyResetsAt: weekly.resetsAt
        )
    }

    private static let timestampFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return [fractional, whole]
    }()

    private static func parseDate(_ string: String) -> Date? {
        timestampFormatters.lazy.compactMap { $0.date(from: string) }.first
    }
}
