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

    nonisolated static var authPath: String {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return codexHome + "/auth.json"
    }

    /// Codex appears only where it has been logged in to with ChatGPT. An API
    /// key login has no plan limits to show.
    nonisolated static var isInstalled: Bool {
        readLogin() != nil
    }

    private struct Login {
        let accessToken: String
        let accountID: String
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
              let token = tokens.accessToken, !token.isEmpty,
              let account = tokens.accountId, !account.isEmpty else { return nil }
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
        request.setValue(login.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw UsageError.tokenExpired
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

    private static let sessionWindowSeconds = 5 * 3600
    private static let weeklyWindowSeconds = 7 * 86400

    /// Windows are matched by length, not by primary/secondary: Codex's own
    /// session logs show some models reporting only a weekly window, as primary.
    static func parse(_ data: Data, at now: Date) -> WebUsageData? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let limits = (try? decoder.decode(Response.self, from: data))?.rateLimit else { return nil }

        let windows = [limits.primaryWindow, limits.secondaryWindow].compactMap { $0 }
        func window(seconds: Int) -> (usage: Double, resetsAt: Date?)? {
            guard let match = windows.first(where: { $0.limitWindowSeconds == seconds }),
                  let used = match.usedPercent else { return nil }
            return (used, match.resetAt.map { Date(timeIntervalSince1970: $0) })
        }
        // The card has no shape for a reading without a weekly window.
        guard let weekly = window(seconds: weeklyWindowSeconds) else { return nil }
        let session = window(seconds: sessionWindowSeconds)

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
