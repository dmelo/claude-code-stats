import Foundation

// Claude Code's transcripts record token counts but never a cost, so spend is
// always derived here from a price table. Rates are US dollars per million
// tokens.
private struct Rate {
    let input: Double
    let output: Double
}

private struct ModelPrice {
    let display: String
    let standard: Rate
    /// A promotional rate and the first instant it no longer applies —
    /// exclusive, so the bound is the midnight *after* the last promotional day.
    /// Entries are priced at the rate in effect on the day they ran, so a past
    /// entry keeps the promotional rate once it lapses and later ones fall back
    /// to `standard` on their own.
    let intro: (rate: Rate, until: Date)?

    init(display: String, standard: Rate, intro: (rate: Rate, until: Date)? = nil) {
        self.display = display
        self.standard = standard
        self.intro = intro
    }

    func rate(on date: Date) -> Rate {
        if let intro, date < intro.until { return intro.rate }
        return standard
    }
}

/// Sonnet 5's introductory pricing runs through 2026-08-31, so the standard rate
/// takes over at the following midnight.
private let sonnet5IntroEnds: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 1
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
}()

// Matched by prefix, not equality: some models appear in transcripts with a date
// suffix (claude-haiku-4-5-20251001) and others bare (claude-opus-4-8). A model
// missing from this table is skipped, which is also how the synthetic entries
// Claude Code writes for local errors ("<synthetic>") stay out of the total.
private let priceTable: [(prefix: String, price: ModelPrice)] = [
    ("claude-opus-4-8", ModelPrice(display: "Opus 4.8", standard: Rate(input: 5, output: 25))),
    ("claude-opus-4-7", ModelPrice(display: "Opus 4.7", standard: Rate(input: 5, output: 25))),
    ("claude-opus-4-6", ModelPrice(display: "Opus 4.6", standard: Rate(input: 5, output: 25))),
    ("claude-fable-5", ModelPrice(display: "Fable 5", standard: Rate(input: 10, output: 50))),
    ("claude-sonnet-5", ModelPrice(
        display: "Sonnet 5",
        standard: Rate(input: 3, output: 15),
        intro: (Rate(input: 2, output: 10), sonnet5IntroEnds)
    )),
    ("claude-sonnet-4-6", ModelPrice(display: "Sonnet 4.6", standard: Rate(input: 3, output: 15))),
    ("claude-haiku-4-5", ModelPrice(display: "Haiku 4.5", standard: Rate(input: 1, output: 5))),
]

private func price(for model: String) -> ModelPrice? {
    priceTable.first { model.hasPrefix($0.prefix) }?.price
}

// Cache-read and cache-write tokens bill at a multiple of the model's input
// rate. The two write tiers are priced differently and a single transcript entry
// can use either, so they have to be read separately from the `cache_creation`
// object — collapsing them into one multiplier misprices every entry.
private let cacheReadMultiplier = 0.10
private let cacheWrite5mMultiplier = 1.25
private let cacheWrite1hMultiplier = 2.00

/// Day rollups older than this are dropped from the cache. Must exceed the
/// longest window we report (month-to-date, and the chart) with room to spare.
private let retentionDays = 100

/// Days of history the chart plots, counting back from today.
private let chartWindowDays = 30

/// Bump to discard cached rollups and re-scan every transcript from scratch.
///
/// Required for any change to `priceTable`, the cost formula, or parsing. Costs
/// are computed once when an entry is first scanned, and a scan advances a
/// transcript's offset whether or not its entries parsed — so without a bump,
/// repricing is ignored and a parsing fix never sees the bytes it was meant to
/// handle.
///
/// 6: began accumulating `establishedTokens`/`cacheReadTokens` for the RTK
/// savings ceiling. A warm cache only advances these from newly-appended bytes,
/// so the corpus-wide ratio needs one full re-scan to be representative.
/// 7: count those totals once per unique entry instead of per scanned copy, so a
/// whole-file re-read (the shrink path) can't inflate them; re-scan to rebuild.
private let cacheVersion = 7

private struct EntryCost: Codable {
    let model: String
    let cost: Double
}

private struct DayRollup: Codable {
    /// Entry hash to its cost. Keyed by hash rather than aggregated into a
    /// running total because an entry's cost can be revised upward by a later
    /// copy — see `ingest`.
    var entries: [String: EntryCost] = [:]
}

private struct CostCache: Codable {
    var version = cacheVersion
    /// Transcript path to the byte offset already consumed. Transcripts are
    /// append-only, so a later scan resumes here instead of re-reading the file.
    var offsets: [String: UInt64] = [:]
    var days: [String: DayRollup] = [:]
    /// Corpus-wide running totals for the re-read ratio ρ = reads / established,
    /// which feeds the RTK savings ceiling. "Established" is fresh input plus
    /// cache writes (a token entering context once); "read" is cache re-reads.
    /// Counted once per unique entry (see `ingest`): streamed copies and whole-file
    /// re-reads revisit the same entry, and re-adding its tokens would skew the
    /// ratio. Not pruned: a lifetime ratio is what the ceiling wants, and it stays
    /// stable as history ages out.
    var establishedTokens: UInt64 = 0
    var cacheReadTokens: UInt64 = 0
}

/// FNV-1a. Swift's `Hasher` is seeded per-process, so its values can't be
/// persisted; this needs to be stable across launches to survive in the cache.
private func entryHash(_ string: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 36)
}

/// Computes API-equivalent spend from the Claude Code transcripts on disk.
///
/// An actor because a scan is heavy (~1 GB on a cold start) and must stay off
/// the main thread, and because the cache it mutates can't tolerate two
/// concurrent scans.
actor CostService {
    static let shared = CostService()

    /// A representative input rate ($ per million tokens) for valuing tokens whose
    /// source model isn't recorded — e.g. RTK's saved tool-output tokens, which
    /// carry no model. Uses Opus 4.8's input rate (the dominant coding model),
    /// drawn from the same price table as spend so the two can't drift. A `static`
    /// on the actor, hence nonisolated and callable synchronously. Deliberately
    /// conservative: it ignores both pricier models and the multi-turn re-billing
    /// that inflates a tool result's true cost, so figures built on it are floors.
    static func representativeInputRate() -> Double {
        price(for: "claude-opus-4-8")?.rate(on: Date()).input ?? 5
    }

    private let fileManager = FileManager.default
    private let storageURL: URL
    private var cache: CostCache
    /// Entry hash to the day it was filed under. A streamed entry's copies carry
    /// slightly different timestamps and can straddle local midnight, so the day
    /// is pinned on first sight rather than recomputed per copy — otherwise the
    /// two copies land in different days and neither can supersede the other.
    /// Derived from `cache`, so it is rebuilt on load rather than persisted.
    private var entryDay: [String: String] = [:]
    /// Whether `cache` has changed since it was last written. Most refreshes
    /// find nothing new — transcripts are resumed from their byte offsets and
    /// read zero bytes — and rewriting the whole cache anyway costs an atomic
    /// multi-megabyte write every few minutes for no benefit.
    private var isDirty = false

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClaudeCodeStats")
        storageURL = appDir.appendingPathComponent("cost_cache.json")
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)

        let loaded = (try? JSONDecoder().decode(CostCache.self, from: Data(contentsOf: storageURL)))
            .flatMap { $0.version == cacheVersion ? $0 : nil }
        cache = loaded ?? CostCache()
        for (day, rollup) in cache.days {
            for key in rollup.entries.keys { entryDay[key] = day }
        }
    }

    func fetchSpend() -> SpendData {
        for path in transcriptPaths() {
            scan(path: path)
        }
        prune()
        // Most refreshes find nothing new, and the cache is rewritten whole.
        // Stays dirty if the write fails, so the next refresh retries it instead
        // of dropping this session's work on the floor.
        if isDirty {
            isDirty = !persist()
        }
        return summarize()
    }

    // MARK: - Scanning

    private func transcriptPaths() -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let roots: [String]
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            roots = [configured]
        } else {
            roots = ["\(home)/.claude", "\(home)/.config/claude"]
        }

        // Sorted because `ingest` pins an entry's day the first time it sees it,
        // and the enumerator's order isn't guaranteed. An entry whose copies
        // straddle local midnight could otherwise be filed under either day
        // depending on which transcript happened to be read first — a decision
        // the cache then keeps. Copies can be minutes apart, so the window is
        // real even though no entry currently spans two days.
        return roots.flatMap { root -> [String] in
            let projects = "\(root)/projects"
            guard let walker = fileManager.enumerator(atPath: projects) else { return [] }
            return walker.compactMap { entry in
                guard let name = entry as? String, name.hasSuffix(".jsonl") else { return nil }
                return "\(projects)/\(name)"
            }
        }
        .sorted()
    }

    private func scan(path: String) {
        let start = cache.offsets[path] ?? 0
        guard let size = try? fileManager.attributesOfItem(atPath: path)[.size] as? UInt64 else { return }
        // A file that shrank was rewritten; re-read it whole. Entries already
        // counted are recognised by hash, so this can't double-count.
        let offset = size < start ? 0 : start
        guard size > offset else { return }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Stop at the last newline: a trailing fragment means Claude Code is
        // mid-write, and re-reading it next scan is cheaper than mis-parsing it.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]

        for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            ingest(line: line)
        }
        cache.offsets[path] = offset + UInt64(complete.count)
        isDirty = true
    }

    private static let assistantMarker = Data("\"assistant\"".utf8)

    // Claude Code writes fractional seconds (2026-07-16T13:53:13.937Z), which
    // ISO8601DateFormatter's default option set rejects outright — it returns
    // nil rather than degrading. Both variants are kept so an entry without them
    // still parses. Static because building a formatter per line dominated the
    // scan's runtime.
    private static let timestampFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    private static func parseTimestamp(_ value: String) -> Date? {
        for formatter in timestampFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func ingest(line: Data.SubSequence) {
        // Most lines are user turns, attachments and tool results. A substring
        // test costs far less than parsing the JSON to discover that.
        guard line.range(of: Self.assistantMarker) != nil else { return }

        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let modelPrice = price(for: model),
              let timestamp = object["timestamp"] as? String,
              let date = Self.parseTimestamp(timestamp)
        else { return }

        // Claude Code re-writes an assistant entry as its response streams, so
        // one message lands in the transcript several times under the same id:
        // output_tokens grows with each copy while the input and cache counts
        // stay fixed. Sessions that resume or fork then copy those entries into
        // further transcripts. Both effects collapse into one rule — keep the
        // costliest copy of each entry — which is what the last, complete write
        // always is. Counting every copy instead would overstate spend roughly
        // threefold; keeping whichever copy happened to be read first would
        // understate output tokens by about a third and vary with scan order.
        // An entry with no id can't be recognised as a repeat of one already
        // counted, and repeats are the norm rather than the exception here — so
        // counting an unidentifiable entry risks inflating it severalfold, while
        // dropping it costs at most that one entry. Every assistant entry on
        // record carries an id; requestId is the near-universal tiebreak.
        guard let id = message["id"] as? String, !id.isEmpty else { return }
        let requestID = object["requestId"] as? String ?? ""
        let key = entryHash("\(id):\(requestID)")

        let day = entryDay[key] ?? Self.dayKey(for: date)
        var rollup = cache.days[day] ?? DayRollup()
        let cost = cost(usage: usage, price: modelPrice, on: date)
        // Ratio inputs, counted once per entry — only the first time it's ever
        // seen, while entryDay has no record of it yet. Later streamed copies and
        // whole-file re-reads (the shrink path) revisit the same entry, and adding
        // their tokens again would skew ρ; the cost dedup below guards cost the
        // same way. isDirty is set by the scan that produced this line.
        if entryDay[key] == nil {
            accumulateReReadStats(usage: usage)
        }
        if let existing = rollup.entries[key], existing.cost >= cost { return }

        rollup.entries[key] = EntryCost(model: modelPrice.display, cost: cost)
        cache.days[day] = rollup
        entryDay[key] = day
        isDirty = true
    }

    /// Reads only the top-level usage counters. The sibling `iterations` array
    /// repeats the same tokens broken down per model turn — summing both would
    /// count every entry twice.
    private func cost(usage: [String: Any], price: ModelPrice, on date: Date) -> Double {
        let rate = price.rate(on: date)
        let input = rate.input / 1_000_000
        let output = rate.output / 1_000_000

        func tokens(_ dict: [String: Any], _ key: String) -> Double {
            (dict[key] as? NSNumber)?.doubleValue ?? 0
        }

        var total = tokens(usage, "input_tokens") * input
        total += tokens(usage, "output_tokens") * output
        total += tokens(usage, "cache_read_input_tokens") * input * cacheReadMultiplier

        if let creation = usage["cache_creation"] as? [String: Any] {
            total += tokens(creation, "ephemeral_5m_input_tokens") * input * cacheWrite5mMultiplier
            total += tokens(creation, "ephemeral_1h_input_tokens") * input * cacheWrite1hMultiplier
        } else {
            // Older transcripts predate the per-tier split and only report a
            // total. Assume the cheaper tier rather than overstate the cost.
            total += tokens(usage, "cache_creation_input_tokens") * input * cacheWrite5mMultiplier
        }
        return total
    }

    /// Adds this entry's tokens to the corpus re-read totals. "Established" is
    /// fresh input plus cache writes (a token entering context once); "read" is
    /// the cache re-reads it accrues on later turns. Mirrors the token fields
    /// `cost` prices, so the two stay in step.
    private func accumulateReReadStats(usage: [String: Any]) {
        func tokens(_ dict: [String: Any], _ key: String) -> UInt64 {
            (dict[key] as? NSNumber)?.uint64Value ?? 0
        }

        var established = tokens(usage, "input_tokens")
        if let creation = usage["cache_creation"] as? [String: Any] {
            established += tokens(creation, "ephemeral_5m_input_tokens")
            established += tokens(creation, "ephemeral_1h_input_tokens")
        } else {
            established += tokens(usage, "cache_creation_input_tokens")
        }
        cache.establishedTokens += established
        cache.cacheReadTokens += tokens(usage, "cache_read_input_tokens")
    }

    /// The multiple of the input rate a tool-output token would have cost had RTK
    /// *not* filtered it from context: a cache write (`cacheWrite5mMultiplier`)
    /// plus this account's observed re-reads (`cacheReadMultiplier × ρ`). The RTK
    /// card's floor prices saved tokens at 1× input; this is the ceiling. ρ is a
    /// corpus average, so it's inflated by always-present tokens (the system
    /// prompt is re-read every turn) — fitting for an optimistic upper bound.
    /// Falls back to a bare cache write when nothing has been scanned yet.
    func contextRebillingCeiling() -> Double {
        guard cache.establishedTokens > 0 else { return cacheWrite5mMultiplier }
        let rho = Double(cache.cacheReadTokens) / Double(cache.establishedTokens)
        return cacheWrite5mMultiplier + cacheReadMultiplier * rho
    }

    // MARK: - Aggregation

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Pinned, per Apple's guidance for fixed-format dates: left alone, the
        // formatter inherits the user's calendar, and "yyyy" under a Buddhist or
        // Japanese one renders 2026 as 2569 or 0008 — day keys would stop
        // matching the ones Calendar.current is compared against. The time zone
        // stays on the system's, since a day here means the user's local day.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func summarize() -> SpendData {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today

        var todayTotal = 0.0
        var weekTotal = 0.0
        var monthTotal = 0.0
        var monthByModel: [String: Double] = [:]
        var totalByDay: [String: Double] = [:]

        for (day, rollup) in cache.days {
            guard let date = Self.dayFormatter.date(from: day) else { continue }

            for entry in rollup.entries.values {
                totalByDay[day, default: 0] += entry.cost
                if date >= today { todayTotal += entry.cost }
                if date >= weekStart { weekTotal += entry.cost }
                if date >= monthStart {
                    monthTotal += entry.cost
                    monthByModel[entry.model, default: 0] += entry.cost
                }
            }
        }

        // Walk the window day by day rather than reading back the keys present
        // in the cache, so a day with no activity yields a zero-height bar
        // instead of being dropped and letting its neighbours close the gap.
        var daily: [DailySpend] = []
        for offset in stride(from: -(chartWindowDays - 1), through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            daily.append(DailySpend(date: date, cost: totalByDay[Self.dayKey(for: date)] ?? 0))
        }

        return SpendData(
            today: todayTotal,
            week: weekTotal,
            month: monthTotal,
            monthByModel: monthByModel
                .map { ModelSpend(model: $0.key, cost: $0.value) }
                .sorted { $0.cost > $1.cost },
            daily: daily,
            lastUpdated: Date()
        )
    }

    // MARK: - Persistence

    private func prune() {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: Date()))
        else { return }

        for (day, rollup) in cache.days {
            guard let date = Self.dayFormatter.date(from: day), date < cutoff else { continue }
            for key in rollup.entries.keys { entryDay[key] = nil }
            cache.days[day] = nil
            isDirty = true
        }
        // Transcripts Claude Code has since deleted would otherwise keep their
        // offsets forever.
        let offsetsBefore = cache.offsets.count
        cache.offsets = cache.offsets.filter { fileManager.fileExists(atPath: $0.key) }
        if cache.offsets.count != offsetsBefore { isDirty = true }
    }

    /// Returns whether the cache reached disk, so the caller can keep it dirty
    /// and retry rather than assume a swallowed failure was a success.
    private func persist() -> Bool {
        do {
            try JSONEncoder().encode(cache).write(to: storageURL, options: .atomic)
            return true
        } catch {
            // Non-critical: a failed write only costs a re-scan next launch.
            print("CostService: failed to write cache: \(error)")
            return false
        }
    }
}
