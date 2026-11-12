import Foundation

// API-equivalent spend for Codex, from the session logs Codex writes. Spend is a
// sum of turns that happened, so local logs are the right source — unlike for
// Codex's limits, which belong to the ChatGPT account and move with use the logs
// never see. A turn is recorded on the machine that ran it, so another machine's
// spend only needs its logs mirrored in.
//
// `turn_context` events say which model is in use, and current Codex writes a
// `token_usage_record` per model response with that response's usage:
//
//   {"timestamp":"…","type":"turn_context","payload":{"model":"gpt-6-astra",…}}
//   {"timestamp":"…","type":"token_usage_record","payload":{"response_id":"resp_…",
//     "usage":{"input_tokens":…,"cached_input_tokens":…,"output_tokens":…},…}}
//
// Older logs have no records, only `token_count` events carrying the session's
// running total and the last request's usage. There a turn is priced where the
// total moves (it repeats unchanged for, say, a rate-limit update), and the
// change equals `last_token_usage`. But a compaction request never enters that
// total, so a log is priced from its records from the first one on, and from
// `token_count` only before it. (In every log checked, a session's first record
// comes before its first `token_count`.) Priced from records, spend matches
// `ccusage codex` to the cent; from `token_count` alone it was about 3% low.
// `input_tokens` includes the cached ones and `output_tokens` includes
// reasoning, as OpenAI bills them.
//
// A session is one file, named after its id. It can move — Codex archives it
// to `archived_sessions`, a mirror folder can be renamed — so state is per path,
// but each session id counts once. Forked sessions weren't in the logs this was
// checked against; if a fork copies its parent's records, they count twice.

private struct CodexPrice {
    let display: String
    /// $ per million tokens.
    let input: Double
    let cachedInput: Double
    let output: Double
}

// Standard-tier rates from OpenAI's API pricing, checked 2026-11-11: the
// gpt-6 rows from developers.openai.com/api/docs/pricing, the rest from each
// model's page there (older models are no longer on the main table). Matched
// exactly, not by prefix — OpenAI's ids nest ("gpt-5.5" is a prefix of
// "gpt-5.5-pro"), and an unknown model is skipped rather than mispriced.
//
// Two surcharges are left out on purpose. Prompts over 272K input tokens cost
// more on several of these models, but the logs this was checked against
// record a context window of about 258K, and their largest request was 242K
// input tokens. Revisit if a model with a larger window turns up. And the Fast tier
// costs more: Codex records a thread's tier (`thread_settings.service_tier`), but
// every log checked says "default", so the Fast rates aren't implemented and a
// Fast turn is priced at standard. Models OpenAI publishes no price for (gpt-reserve) and local
// models (served through Codex's other providers) are skipped.
private let codexPrices: [String: CodexPrice] = [
    "gpt-6-astra": CodexPrice(display: "GPT-6 Astra", input: 10, cachedInput: 1.00, output: 50),
    "gpt-6.1-sol": CodexPrice(display: "GPT-6.1 Sol", input: 2, cachedInput: 0.10, output: 10),
    "gpt-6.1-terra": CodexPrice(display: "GPT-6.1 Terra", input: 1, cachedInput: 0.05, output: 5),
    "gpt-6-luna": CodexPrice(display: "GPT-6 Luna", input: 0.10, cachedInput: 0.01, output: 0.50),
    "gpt-5.6-luna": CodexPrice(display: "GPT-5.6 Luna", input: 0.20, cachedInput: 0.02, output: 1.20),
    "gpt-5.5": CodexPrice(display: "GPT-5.5", input: 5, cachedInput: 0.50, output: 30),
    "gpt-5.4": CodexPrice(display: "GPT-5.4", input: 2.50, cachedInput: 0.25, output: 15),
    "gpt-5.3-codex": CodexPrice(display: "GPT-5.3-Codex", input: 1.75, cachedInput: 0.175, output: 14),
    "gpt-5-codex": CodexPrice(display: "GPT-5-Codex", input: 1.25, cachedInput: 0.125, output: 10),
]

/// Bump to discard the cache and re-read every session log. Required for any
/// change to the price table or the parsing, for the same reason as
/// CostService's: costs are priced when a turn is first read.
private let codexCacheVersion = 2

/// How much of a file's start is kept to recognise it: the first line names
/// the session, so a different file at the same path differs here.
private let headLength = 256

/// Unread logs are read this much at a time. A Codex session log can pass
/// 500 MB, too much to load at once inside a menu bar app.
private let chunkSize = 8 << 20

private struct TokenTotals: Codable, Equatable {
    var input: Int = 0
    var cached: Int = 0
    var output: Int = 0
}

/// What has been read of one session log. Costs are kept per file rather than
/// pooled so that a file read again from the start replaces its own share
/// instead of adding to it.
private struct FileState: Codable {
    var offset: UInt64 = 0
    /// The file's first bytes, to tell a replaced file from a grown one.
    var head: Data?
    var lastTotal: TokenTotals?
    /// Set at the file's first `token_usage_record`; from then on its
    /// `token_count` events are not priced.
    var hasRecords = false
    var model: String?
    var days: SpendLedger = [:]
}

private struct CodexCostCache: Codable {
    var version = codexCacheVersion
    var files: [String: FileState] = [:]
}

actor CodexCostService {
    static let shared = CodexCostService()

    private let fileManager = FileManager.default
    private let storageURL: URL
    private var cache: CodexCostCache
    private var isDirty = false

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClaudeCodeStats")
        storageURL = appDir.appendingPathComponent("codex_cost_cache.json")
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        let loaded = (try? JSONDecoder().decode(CodexCostCache.self, from: Data(contentsOf: storageURL)))
            .flatMap { $0.version == codexCacheVersion ? $0 : nil }
        cache = loaded ?? CodexCostCache()
    }

    /// Codex's spend by day and model, after reading whatever the session logs
    /// gained since the last call. Empty when Codex has never run here.
    func fetchLedger() -> SpendLedger {
        let paths = sessionPaths()
        for path in paths {
            scan(path: path)
        }
        prune(keeping: Set(paths))
        if isDirty {
            isDirty = !persist()
        }
        // One state per session id: a session that moved (archived, or its
        // mirror folder renamed) leaves its old path's days behind until they
        // age out. The copy read furthest wins.
        var sessions: [String: FileState] = [:]
        for (path, state) in cache.files {
            let id = Self.sessionID(path)
            if let other = sessions[id], other.offset >= state.offset { continue }
            sessions[id] = state
        }
        var ledger: SpendLedger = [:]
        for state in sessions.values {
            for (day, models) in state.days {
                for (model, cost) in models {
                    ledger[day, default: [:]][model, default: 0] += cost
                }
            }
        }
        return ledger
    }

    // MARK: - Scanning

    /// Where Codex writes (`$CODEX_HOME/sessions`, ~/.codex by default), where
    /// it moves archived sessions (`archived_sessions`), and
    /// ~/.config/codex/sessions, which Codex never reads: other machines'
    /// sessions mirrored there, one subfolder per machine, are counted
    /// without Codex here ever listing them as its own.
    nonisolated static var sessionRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let codexHome = CodexUsageService.codexHome
        var seen = Set<String>()
        return ["\(codexHome)/sessions", "\(codexHome)/archived_sessions", "\(home)/.config/codex/sessions"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .filter { seen.insert($0).inserted }
    }

    /// Whether any session-log folder exists, for deciding whether Codex is
    /// on this Mac at all.
    nonisolated static var hasSessions: Bool {
        sessionRoots.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func sessionPaths() -> [String] {
        Self.sessionRoots.flatMap { root -> [String] in
            guard let walker = fileManager.enumerator(atPath: root) else { return [] }
            return walker.compactMap { entry in
                guard let name = entry as? String, name.hasSuffix(".jsonl") else { return nil }
                return "\(root)/\(name)"
            }
        }
    }

    /// The session id at the end of a log's name
    /// (`rollout-<time>-<uuid>.jsonl`), else the path itself.
    private static func sessionID(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        let id = String(name.suffix(36))
        return UUID(uuidString: id) != nil ? id.lowercased() : path
    }

    private func scan(path: String) {
        var state = cache.files[path] ?? FileState()
        guard let size = try? fileManager.attributesOfItem(atPath: path)[.size] as? UInt64 else { return }
        guard size != state.offset,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        // A file that shrank, or whose start changed, was replaced: drop what
        // it contributed and read it again from the start.
        // (A head stored while the file was shorter than headLength is a prefix
        // of the grown file's.)
        let head = (try? handle.read(upToCount: headLength)) ?? Data()
        if size < state.offset || state.head.map({ !head.starts(with: $0) }) == true {
            state = FileState()
        }
        state.head = head

        guard (try? handle.seek(toOffset: state.offset)) != nil else { return }
        let newline = UInt8(ascii: "\n")
        var pending = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            // Stop at the last newline: a trailing fragment is either cut by
            // the chunk or Codex mid-write, and waits for the next read.
            guard let lastNewline = pending.lastIndex(of: newline) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            for line in complete.split(separator: newline, omittingEmptySubsequences: true) {
                ingest(line: line, into: &state)
            }
            state.offset += UInt64(complete.count)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        cache.files[path] = state
        isDirty = true
    }

    private static let turnContextMarker = Data("\"turn_context\"".utf8)
    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let recordMarker = Data("\"token_usage_record\"".utf8)

    private static let timestampFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    private func ingest(line: Data.SubSequence, into state: inout FileState) {
        // Most lines are messages and tool output; a substring test is far
        // cheaper than parsing them to find out.
        guard line.range(of: Self.turnContextMarker) != nil
                || line.range(of: Self.recordMarker) != nil
                || (!state.hasRecords && line.range(of: Self.tokenCountMarker) != nil),
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }

        let usage: TokenTotals
        switch object["type"] as? String {
        case "turn_context":
            if let model = payload["model"] as? String { state.model = model }
            return
        case "token_usage_record":
            guard let recorded = Self.totals(payload["usage"]) else { return }
            state.hasRecords = true
            usage = recorded
        default:
            guard !state.hasRecords,
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = Self.totals(info["total_token_usage"]),
                  let last = Self.totals(info["last_token_usage"]) else { return }
            // A repeat of the previous total is the same turn reported again.
            guard total != state.lastTotal else { return }
            state.lastTotal = total
            usage = last
        }

        guard let model = state.model, let price = codexPrices[model],
              let timestamp = object["timestamp"] as? String,
              let date = Self.timestampFormatters.lazy.compactMap({ $0.date(from: timestamp) }).first
        else { return }
        let last = usage
        let uncached = Double(max(0, last.input - last.cached))
        let cost = (uncached * price.input
            + Double(last.cached) * price.cachedInput
            + Double(last.output) * price.output) / 1_000_000
        state.days[SpendDay.key(for: date), default: [:]][price.display, default: 0] += cost
    }

    private static func totals(_ value: Any?) -> TokenTotals? {
        guard let usage = value as? [String: Any] else { return nil }
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return TokenTotals(input: count("input_tokens"), cached: count("cached_input_tokens"),
                           output: count("output_tokens"))
    }

    // MARK: - Persistence

    /// Drops day rollups past retention, and the state of a log that no longer
    /// exists once none of its days are left: a mirror prunes old files, and
    /// their spend should outlive them for as long as it is shown.
    private func prune(keeping scanned: Set<String>) {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -SpendData.retentionDays,
                                         to: calendar.startOfDay(for: Date())) else { return }
        for (path, var state) in cache.files {
            let kept = state.days.filter { day, _ in (SpendDay.date(from: day) ?? .distantPast) >= cutoff }
            if kept.count != state.days.count {
                state.days = kept
                cache.files[path] = state
                isDirty = true
            }
            if !scanned.contains(path), !fileManager.fileExists(atPath: path), kept.isEmpty {
                cache.files[path] = nil
                isDirty = true
            }
        }
    }

    private func persist() -> Bool {
        do {
            try JSONEncoder().encode(cache).write(to: storageURL, options: .atomic)
            return true
        } catch {
            print("CodexCostService: failed to write cache: \(error)")
            return false
        }
    }
}
