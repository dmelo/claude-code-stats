import Foundation
import SQLite3

/// Reads RTK's (Rust Token Killer) command-savings history and rolls it up into
/// the windows the UI shows.
///
/// RTK is an optional external tool; its absence is the normal case, so a missing
/// database yields `nil` and the card simply doesn't render. An `actor` for
/// symmetry with `CostService` and to keep the SQLite work off the main thread,
/// though the query is a single cheap aggregate pass rather than a corpus scan.
actor RTKSavingsService {
    static let shared = RTKSavingsService()

    /// SQLITE_TRANSIENT tells SQLite to copy bound text immediately, so the Swift
    /// `String` backing it needn't outlive the bind call. The SQLite3 module
    /// doesn't surface the macro, so it's reconstructed here.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let dbPath: String

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dbPath = appSupport.appendingPathComponent("rtk/history.db").path
    }

    /// Whether RTK's history database exists at all — a cheap install check.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// Rolls up saved tokens over today / last 7 days / last 30 days plus a
    /// lifetime total. Returns `nil` when RTK isn't installed, the database can't
    /// be read, or it holds no commands yet — all of which just hide the card.
    func fetch() async -> RTKSavings? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        // Opened read-write despite only ever issuing SELECTs — counter-intuitive,
        // but required. RTK's db is WAL-mode, and a WAL read needs the `-shm`
        // shared-memory file; a pure SQLITE_OPEN_READONLY connection cannot create
        // it, so `prepare` fails with SQLITE_CANTOPEN whenever RTK has checkpointed
        // and no `-shm` is on disk. Read-write lets SQLite establish the shm and
        // return consistent, current data. We own the file (the app is
        // unsandboxed), and WAL readers don't block RTK's concurrent writes.
        // `immutable=1` would also open it, but is documented undefined behaviour
        // against a file another process is actively modifying — which RTK is.
        let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        // Register close before the guard so the handle is released on every path
        // in one place. open_v2 allocates a connection to close even when it fails
        // (except on OOM, where it sets nil and sqlite3_close(nil) is a no-op), so
        // this also covers the failure return.
        defer { sqlite3_close(db) }
        guard openResult == SQLITE_OK else { return nil }
        // Wait out a transient writer lock rather than failing the whole refresh.
        sqlite3_busy_timeout(db, 2000)

        let (today, week, last30) = Self.windowBoundaries()

        // Timestamps are stored as UTC ISO8601 with a `+00:00` suffix and
        // microsecond precision. Comparing the first 19 characters
        // ("YYYY-MM-DDTHH:MM:SS") against a UTC-to-the-second boundary keeps the
        // comparison lexicographic-equals-chronological without tripping over the
        // fractional part or the offset spelling. One table pass, three windows
        // via CASE, so the whole card is a single query.
        let sql = """
        SELECT
          COALESCE(SUM(CASE WHEN substr(timestamp, 1, 19) >= ?1 THEN saved_tokens ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN substr(timestamp, 1, 19) >= ?2 THEN saved_tokens ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN substr(timestamp, 1, 19) >= ?3 THEN saved_tokens ELSE 0 END), 0),
          COALESCE(SUM(saved_tokens), 0),
          COALESCE(SUM(input_tokens), 0),
          COUNT(*)
        FROM commands;
        """

        var stmt: OpaquePointer?
        // Register finalize before the guard so cleanup covers every exit,
        // including the prepare-failure return. (SQLite already nulls *ppStmt on
        // prepare failure, so that path can't actually leak, and
        // sqlite3_finalize(nil) is a no-op — this just doesn't rely on it.)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }

        sqlite3_bind_text(stmt, 1, today, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, week, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, last30, -1, Self.transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        // RTK installed but nothing logged yet: no card until there's data.
        let count = Int(sqlite3_column_int64(stmt, 5))
        guard count > 0 else { return nil }

        // Spend is refreshed before this in the view model, so CostService has
        // already scanned and its observed re-read ratio is ready.
        let ceilingMultiplier = await CostService.shared.contextRebillingCeiling()

        // Clamp to ≥ 0: the counts come from RTK's external database, and a
        // corrupt or negative value must not surface as negative tokens or dollars
        // (mirrors the reduction clamp in RTKSavings).
        func nonNegative(_ column: Int32) -> Int { max(0, Int(sqlite3_column_int64(stmt, column))) }

        return RTKSavings(
            todaySaved: nonNegative(0),
            weekSaved: nonNegative(1),
            last30Saved: nonNegative(2),
            lifetimeSaved: nonNegative(3),
            lifetimeRaw: nonNegative(4),
            commandCount: count,
            inputRate: CostService.representativeInputRate(),
            ceilingMultiplier: ceilingMultiplier,
            lastUpdated: Date()
        )
    }

    // MARK: - Window boundaries

    /// Boundaries are computed in the user's local calendar (a "day" here means
    /// their local day, not the UTC day RTK stamps) and rendered as
    /// UTC-to-the-second strings to compare against the stored timestamps. Mirrors
    /// CostService's windows: "last 7 days" is today plus the six days before it,
    /// "last 30 days" today plus the 29 before it.
    private static func windowBoundaries() -> (today: String, week: String, last30: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let last30 = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        return (boundary(today), boundary(week), boundary(last30))
    }

    private static let boundaryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static func boundary(_ date: Date) -> String {
        boundaryFormatter.string(from: date)
    }
}
