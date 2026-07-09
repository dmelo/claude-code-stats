import Foundation
import Security

@MainActor
class OAuthUsageService {
    static let shared = OAuthUsageService()

    private let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private let credentialsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/.credentials.json"
    }()
    private let keychainService = "Claude Code-credentials"
    private let appKeychainService = "ClaudeCodeStats-credentials"
    private let appKeychainAccount = "oauth-token"
    private var cachedCredential: Credential?
    private let session: URLSession

    // An OAuth access token plus the expiry the CLI recorded for it. Tracking
    // expiry lets us notice when the CLI has rotated the token and re-read the
    // live source instead of clinging to a stale cached copy.
    private struct Credential {
        let token: String
        let expiresAt: Date?

        // Treat a token as usable until shortly before it expires, so we never
        // send one that's about to lapse (a rotated-away token returns 429, not
        // 401, so we can't rely on a failed request to tell us it's stale). The
        // 5-minute cushion absorbs clock skew between us and the server.
        // Unknown expiry = usable.
        var isUsable: Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow > 300
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    var hasCredentials: Bool {
        readAccessToken() != nil
    }

    func fetchUsage() async throws -> WebUsageData {
        guard let token = readAccessToken() else {
            throw UsageError.noCredentials
        }

        guard let url = URL(string: usageURL) else {
            throw UsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withRetry {
                try await session.data(for: request)
            }
        } catch {
            throw UsageError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            clearTokenCaches()
            throw UsageError.tokenExpired
        }

        // The usage endpoint has its own rate limit (HTTP 429 with a long
        // retry-after and no usage body). Surface it distinctly so the UI keeps
        // showing the last known data and recovers on the next scheduled poll.
        if httpResponse.statusCode == 429 {
            throw UsageError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UsageError.invalidResponse
        }

        return try parseUsage(data)
    }

    private func readAccessToken() -> String? {
        // In-memory cache, but only while the token is still fresh.
        if let cached = cachedCredential, cached.isUsable {
            return cached.token
        }

        // Live file source (present on some setups), authoritative when readable.
        if let cred = readCredentialFromFile(), cred.isUsable {
            cachedCredential = cred
            return cred.token
        }

        // App-owned keychain cache — avoids repeated permission prompts on the
        // CLI's item. Trust it only while unexpired; a token that has rotated out
        // is skipped so we fall through and re-read the live source below.
        if let cred = readCredentialFromAppKeychain(), cred.isUsable {
            cachedCredential = cred
            return cred.token
        }

        // Live keychain source owned by the Claude Code CLI. Re-reading here is
        // what picks up a token the CLI has rotated; cache the result (in the new
        // format, with expiry) so we don't prompt on every fetch.
        if let cred = readCredentialFromKeychain(service: keychainService) {
            saveCredentialToAppKeychain(cred)
            cachedCredential = cred
            return cred.token
        }

        return nil
    }

    private func clearTokenCaches() {
        cachedCredential = nil
        deleteAppKeychainItem()
    }

    private func readCredentialFromFile() -> Credential? {
        guard let data = FileManager.default.contents(atPath: credentialsPath) else {
            return nil
        }
        return extractCredential(from: data)
    }

    // The app keychain stores our own {accessToken, expiresAt} JSON so we can
    // tell when a cached token has rotated out. A value written by an older build
    // (a bare token string) won't parse and is treated as absent — so the app
    // transparently re-reads the live source and re-caches in the new format.
    private func readCredentialFromAppKeychain() -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appKeychainService,
            kSecAttrAccount as String: appKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return decodeCachedCredential(from: data)
    }

    private func readCredentialFromKeychain(service: String) -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return extractCredential(from: data)
    }

    private func saveCredentialToAppKeychain(_ credential: Credential) {
        var payload: [String: Any] = ["accessToken": credential.token]
        if let expiresAt = credential.expiresAt {
            payload["expiresAt"] = expiresAt.timeIntervalSince1970
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        // Delete existing item first (if any)
        deleteAppKeychainItem()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appKeychainService,
            kSecAttrAccount as String: appKeychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("OAuthUsageService: Failed to cache credential in app keychain (status: \(status))")
        }
    }

    private func deleteAppKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appKeychainService,
            kSecAttrAccount as String: appKeychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("OAuthUsageService: Failed to delete app keychain item (status: \(status))")
        }
    }

    // Parses the {accessToken, expiresAt} JSON this app writes to its own keychain.
    private func decodeCachedCredential(from data: Data) -> Credential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        let expiresAt = (json["expiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Credential(token: token, expiresAt: expiresAt)
    }

    // Parses the Claude Code credential blob (claudeAiOauth.accessToken/expiresAt).
    private func extractCredential(from data: Data) -> Credential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        // expiresAt is epoch milliseconds.
        let expiresAt = (oauth["expiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credential(token: token, expiresAt: expiresAt)
    }

    // Shape of the /api/oauth/usage JSON response (only the fields we consume).
    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }

        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        struct Limit: Decodable {
            let kind: String
            let percent: Double?
            let resetsAt: String?
            let scope: Scope?

            enum CodingKeys: String, CodingKey {
                case kind, percent, scope
                case resetsAt = "resets_at"
            }

            struct Scope: Decodable {
                let model: Model?

                struct Model: Decodable {
                    let displayName: String?

                    enum CodingKeys: String, CodingKey {
                        case displayName = "display_name"
                    }
                }
            }
        }
    }

    private func parseUsage(_ data: Data) throws -> WebUsageData {
        guard let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            throw UsageError.invalidResponse
        }

        // Weekly limits scoped to a specific model (e.g. Fable) live only in the
        // `limits` array — render each as its own card.
        let scopedLimits: [ScopedUsageLimit] = (decoded.limits ?? []).compactMap { limit in
            guard limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.displayName, !name.isEmpty else {
                return nil
            }
            return ScopedUsageLimit(
                name: name,
                usage: limit.percent ?? 0,
                resetsAt: parseDate(limit.resetsAt) ?? Date()
            )
        }

        return WebUsageData(
            sessionUsage: decoded.fiveHour?.utilization ?? 0,
            sessionResetsAt: parseDate(decoded.fiveHour?.resetsAt) ?? Date(),
            weeklyUsage: decoded.sevenDay?.utilization ?? 0,
            weeklyResetsAt: parseDate(decoded.sevenDay?.resetsAt) ?? Date(),
            scopedLimits: scopedLimits,
            lastUpdated: Date()
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return Self.isoFormatter.date(from: string)
            ?? Self.isoFormatterNoFraction.date(from: string)
    }

    private func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.5,
        _ operation: () async throws -> T
    ) async throws -> T {
        var delay = initialDelay
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch let error as URLError where Self.isTransientNetworkError(error) {
                guard attempt < maxAttempts else { throw error }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 3
            }
        }
        throw URLError(.unknown)
    }

    private static func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed,
             .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
