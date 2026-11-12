import Foundation

// Codex's 5-hour and weekly limits, fetched live from the usage endpoint in the
// Codex CLI's own backend client, with the ChatGPT login Codex keeps in
// `$CODEX_HOME/auth.json` (~/.codex by default). The limits belong to the
// ChatGPT account and are shared with its other surfaces (Work, Workspace
// Agents, ChatGPT for Excel), so no local record of Codex turns can stand in for
// this: usage from another machine or another surface never reaches it.
//
// The login is only ever read. Codex refreshes its own token when it runs, and
// a refresh here would rotate the token out from under it — the same rule as
// the Claude logins. An access token lasts about ten days, so a machine that
// hasn't run Codex in that long shows "run codex" instead of limits.
//
// The response, trimmed to what is read here:
//
//   {"plan_type":"plus","rate_limit":{
//     "primary_window":{"used_percent":17,"limit_window_seconds":18000,"reset_at":1794437332},
//     "secondary_window":{"used_percent":6,"limit_window_seconds":604800,"reset_at":1794997808}}}
actor CodexUsageService {
    static let shared = CodexUsageService()

    // Codex picks "/wham/usage" for a base URL under /backend-api, which is
    // where its ChatGPT login points ("/api/codex/usage" is for other bases).
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    /// `$CODEX_HOME/auth.json`, else ~/.codex/auth.json. The variable only
    /// reaches the app when it is in the launch environment — a shell export
    /// does not reach an app opened from Finder or as a login item; `launchctl
    /// setenv CODEX_HOME …` does.
    nonisolated static var authPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.codex"
        if codexHome == "~" || codexHome.hasPrefix("~/") { codexHome = home + codexHome.dropFirst() }
        return codexHome + "/auth.json"
    }

    /// Codex appears only where it is logged in with ChatGPT. An API key login
    /// has no plan limits to show.
    nonisolated static var hasLogin: Bool {
        readLogin() != nil
    }

    /// Whether the login file exists at all, readable or not. Keeps Codex on
    /// screen through a moment when Codex is rewriting the file mid-refresh.
    nonisolated static var hasAuthFile: Bool {
        FileManager.default.fileExists(atPath: authPath)
    }

    private struct Login {
        let accessToken: String
        /// Sent as `ChatGPT-Account-Id` when present.
        let accountID: String?
        let expiresAt: Date?
    }

    private struct AuthFile: Decodable {
        let tokens: Tokens?
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?
        }
    }

    private nonisolated static func readLogin() -> Login? {
        guard let data = FileManager.default.contents(atPath: authPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let tokens = (try? decoder.decode(AuthFile.self, from: data))?.tokens,
              let token = tokens.accessToken, !token.isEmpty else { return nil }
        let account = tokens.accountId.flatMap { $0.isEmpty ? nil : $0 }
        return Login(accessToken: token, accountID: account, expiresAt: expiry(of: token))
    }

    /// The `exp` claim of a JWT, without verifying it: it only decides whether
    /// a request is worth sending.
    private nonisolated static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    func fetchUsage() async throws -> WebUsageData {
        // Read on every fetch: Codex rewrites the file when it refreshes.
        guard let login = Self.readLogin() else { throw UsageError.noCredentials }
        if let expiresAt = login.expiresAt, expiresAt <= Date() { throw UsageError.tokenExpired }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = login.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            let session = self.session
            (data, response) = try await OAuthUsageService.withRetry {
                try await session.data(for: request)
            }
        } catch {
            throw UsageError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        // Only a 401 is read as a bad token. A 403 can also be a bot check or a
        // refused account, which running codex can't fix, so it stays an
        // ordinary failure and the last reading stays on screen.
        case 401: throw UsageError.tokenExpired
        case 429: throw UsageError.rateLimited
        default: throw UsageError.invalidResponse
        }
        guard let usage = Self.parse(data, at: Date()) else { throw UsageError.invalidResponse }
        return usage
    }

    private struct Response: Decodable {
        let rateLimit: RateLimit?

        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let limitWindowSeconds: Int?
            let resetAt: Double?
        }
    }

    /// Windows are matched by length, not by primary/secondary: Codex's own
    /// session logs show some models reporting only a weekly window, as primary.
    /// By range rather than exact seconds (18000 and 604800 today), so a window
    /// a few seconds off, or a plan with a different length, still lands: under
    /// a day is the session window, a day or more is weekly.
    static func parse(_ data: Data, at now: Date) -> WebUsageData? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let limits = (try? decoder.decode(Response.self, from: data))?.rateLimit else { return nil }

        let windows = [limits.primaryWindow, limits.secondaryWindow].compactMap { $0 }
        func window(_ lengths: Range<Int>) -> (usage: Double, resetsAt: Date?)? {
            guard let match = windows.first(where: { lengths.contains($0.limitWindowSeconds ?? -1) }),
                  let used = match.usedPercent else { return nil }
            return (used, match.resetAt.map { Date(timeIntervalSince1970: $0) })
        }
        // The card has no shape for a reading without a weekly window.
        guard let weekly = window(86400..<Int.max) else { return nil }
        let session = window(1..<86400)

        return WebUsageData(
            sessionUsage: session?.usage,
            sessionResetsAt: session?.resetsAt ?? now,
            weeklyUsage: weekly.usage,
            weeklyResetsAt: weekly.resetsAt ?? now,
            scopedLimits: [],
            lastUpdated: now,
            reportedSessionResetsAt: session?.resetsAt,
            reportedWeeklyResetsAt: weekly.resetsAt
        )
    }
}
