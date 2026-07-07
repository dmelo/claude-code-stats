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
    private var cachedToken: String?
    private let session: URLSession

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

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UsageError.invalidResponse
        }

        return try parseUsage(data)
    }

    private func readAccessToken() -> String? {
        if let token = cachedToken {
            return token
        }
        if let token = readTokenFromFile() {
            cachedToken = token
            return token
        }
        if let token = readTokenFromAppKeychain() {
            cachedToken = token
            return token
        }
        if let token = readTokenFromKeychain(service: keychainService) {
            saveTokenToAppKeychain(token)
            cachedToken = token
            return token
        }
        return nil
    }

    private func clearTokenCaches() {
        cachedToken = nil
        deleteAppKeychainItem()
    }

    private func readTokenFromFile() -> String? {
        guard let data = FileManager.default.contents(atPath: credentialsPath),
              let token = extractToken(from: data) else {
            return nil
        }
        return token
    }

    // App keychain stores the raw token string, not the JSON credential blob
    private func readTokenFromAppKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appKeychainService,
            kSecAttrAccount as String: appKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func readTokenFromKeychain(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = extractToken(from: data) else {
            return nil
        }
        return token
    }

    private func saveTokenToAppKeychain(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

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
            NSLog("OAuthUsageService: Failed to cache token in app keychain (status: \(status))")
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

    private func extractToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
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
