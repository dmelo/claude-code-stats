import Foundation

// API-equivalent spend for Codex, from the session logs Codex writes. Spend is a
// sum of turns that happened, so local logs are the right source — unlike for
// Codex's limits, which belong to the ChatGPT account and move with use the logs
// never see. A turn is recorded on the machine that ran it, so another machine's
// spend only needs its logs mirrored in.
//
// Each turn appends a `token_count` event carrying the session's running total
// and the last request's usage; `turn_context` events say which model is in use:
//
//   {"timestamp":"…","type":"turn_context","payload":{"model":"gpt-6-astra",…}}
//   {"timestamp":"…","type":"event_msg","payload":{"type":"token_count","info":{
//     "total_token_usage":{"input_tokens":…,"cached_input_tokens":…,"output_tokens":…},
//     "last_token_usage":{…same fields…}}}}
//
// `token_count` repeats with an unchanged total (a rate-limit update, say), so a
// turn is priced only where the total moves — and wherever it moves, the change
// equals `last_token_usage` exactly (checked on every event of two machines'
// logs). `input_tokens` includes the cached ones and `output_tokens` includes
// reasoning, as OpenAI bills them.
//
// No session appears in more than one file, and no event is copied between
// files, so unlike Claude Code's transcripts there is nothing to dedupe across
// files.

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
// costs more, but Codex records no service tier, so every turn is priced at
// standard. Models OpenAI publishes no price for (gpt-reserve) and local
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
private let codexCacheVersion = 1

/// Matches CostService's: day rollups older than this are dropped.
private let codexRetentionDays = 100

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
    var lastTotal: TokenTotals?
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
        var ledger: SpendLedger = [:]
        for state in cache.files.values {
            for (day, models) in state.days {
                for (model, cost) in models {
                    ledger[day, default: [:]][model, default: 0] += cost
                }
            }
        }
        return ledger
    }

    // MARK: - Scanning

    /// Where Codex writes (`$CODEX_HOME/sessions`, ~/.codex by default) and
    /// ~/.config/codex/sessions, which Codex never reads: other machines'
    /// sessions mirrored there, one subfolder per machine, are counted
    /// without Codex here ever listing them as its own.
    private func sessionPaths() -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.codex"
        var seen = Set<String>()
        let roots = ["\(codexHome)/sessions", "\(home)/.config/codex/sessions"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .filter { seen.insert($0).inserted }
        return roots.flatMap { root -> [String] in
            guard let walker = fileManager.enumerator(atPath: root) else { return [] }
            return walker.compactMap { entry in
                guard let name = entry as? String, name.hasSuffix(".jsonl") else { return nil }
                return "\(root)/\(name)"
            }
        }
    }

    private func scan(path: String) {
        var state = cache.files[path] ?? FileState()
        guard let size = try? fileManager.attributesOfItem(atPath: path)[.size] as? UInt64 else { return }
        // A file that shrank was rewritten: drop what it contributed and read
        // it again from the start.
        if size < state.offset { state = FileState() }
        guard size > state.offset,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty,
              // Stop at the last newline: a trailing fragment is Codex mid-write.
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]

        for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            ingest(line: line, into: &state)
        }
        state.offset += UInt64(complete.count)
        cache.files[path] = state
        isDirty = true
    }

    private static let turnContextMarker = Data("\"turn_context\"".utf8)
    private static let tokenCountMarker = Data("\"token_count\"".utf8)

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
        let isContext = line.range(of: Self.turnContextMarker) != nil
        guard isContext || line.range(of: Self.tokenCountMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }

        if object["type"] as? String == "turn_context" {
            if let model = payload["model"] as? String { state.model = model }
            return
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = Self.totals(info["total_token_usage"]),
              let last = Self.totals(info["last_token_usage"]) else { return }
        // A repeat of the previous total is the same turn reported again.
        guard total != state.lastTotal else { return }
        state.lastTotal = total

        guard let model = state.model, let price = codexPrices[model],
              let timestamp = object["timestamp"] as? String,
              let date = Self.timestampFormatters.lazy.compactMap({ $0.date(from: timestamp) }).first
        else { return }
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
        guard let cutoff = calendar.date(byAdding: .day, value: -codexRetentionDays,
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
