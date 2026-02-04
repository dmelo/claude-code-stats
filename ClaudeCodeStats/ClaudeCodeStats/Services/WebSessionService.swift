import Foundation

// MARK: - Claude Status API

struct ClaudeStatusResponse: Codable {
    let status: ClaudeStatus
}

struct ClaudeStatus: Codable {
    let indicator: String  // "none", "minor", "major", "critical"
    let description: String
}

enum StatusIndicator: String {
    case operational = "none"
    case minor = "minor"
    case major = "major"
    case critical = "critical"
    case unknown = "unknown"

    var displayText: String {
        switch self {
        case .operational: return "Operational"
        case .minor: return "Minor Issue"
        case .major: return "Major Outage"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }
}

class StatusService {
    static let shared = StatusService()
    private let statusURL = "https://status.claude.com/api/v2/status.json"

    private init() {}

    func fetchStatus() async throws -> ClaudeStatus {
        guard let url = URL(string: statusURL) else {
            throw URLError(.badURL)
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(ClaudeStatusResponse.self, from: data)
        return response.status
    }
}

// MARK: - Usage API

struct Organization: Codable {
    let uuid: String
    let name: String
}

struct WebUsageResponse: Codable {
    let fiveHour: WebUsageWindow?
    let sevenDay: WebUsageWindow?
    let sevenDayOpus: WebUsageWindow?
    let sevenDaySonnet: WebUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

struct WebUsageWindow: Codable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct WebUsageData {
    let sessionUsage: Double
    let sessionResetsAt: Date
    let weeklyUsage: Double
    let weeklyResetsAt: Date
    let sonnetUsage: Double?
    let sonnetResetsAt: Date?
    let lastUpdated: Date

    static var empty: WebUsageData {
        WebUsageData(
            sessionUsage: 0,
            sessionResetsAt: Date(),
            weeklyUsage: 0,
            weeklyResetsAt: Date(),
            sonnetUsage: nil,
            sonnetResetsAt: nil,
            lastUpdated: Date()
        )
    }
}

enum WebSessionError: Error, LocalizedError {
    case noSessionKey
    case networkError(Error)
    case invalidResponse
    case unauthorized
    case noOrganization
    case decodingError(Error)
    case cloudflareChallenge

    var errorDescription: String? {
        switch self {
        case .noSessionKey:
            return "No session key. Tap ⚙️ to configure."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from claude.ai"
        case .unauthorized:
            return "Session expired. Update your cookie."
        case .noOrganization:
            return "Could not find organization."
        case .decodingError:
            return "Failed to parse usage data."
        case .cloudflareChallenge:
            return "Blocked by Cloudflare. Visit claude.ai in browser, then refresh."
        }
    }
}

class WebSessionService {
    static let shared = WebSessionService()
    private let baseURL = "https://claude.ai/api"
    private let sessionKeyKey = "claudeSessionKey"
    private let fullCookiesKey = "claudeFullCookies"
    private let orgIdKey = "claudeOrgId"
    private let deviceIdKey = "claudeDeviceId"
    private let anonymousIdKey = "claudeAnonymousId"

    private init() {}

    /// Persistent device ID (generated once, reused)
    var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        let newId = UUID().uuidString.lowercased()
        UserDefaults.standard.set(newId, forKey: deviceIdKey)
        return newId
    }

    /// Persistent anonymous ID (generated once, reused)
    var anonymousId: String {
        if let existing = UserDefaults.standard.string(forKey: anonymousIdKey) {
            return existing
        }
        let newId = "claudeai.v1.\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(newId, forKey: anonymousIdKey)
        return newId
    }

    var sessionKey: String? {
        get { UserDefaults.standard.string(forKey: sessionKeyKey) }
        set { UserDefaults.standard.set(newValue, forKey: sessionKeyKey) }
    }

    /// Full cookie string from browser (includes cf_clearance for Cloudflare bypass)
    var fullCookies: String? {
        get { UserDefaults.standard.string(forKey: fullCookiesKey) }
        set { UserDefaults.standard.set(newValue, forKey: fullCookiesKey) }
    }

    var organizationId: String? {
        get { UserDefaults.standard.string(forKey: orgIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: orgIdKey) }
    }

    var hasSessionKey: Bool {
        guard let key = sessionKey else { return false }
        return !key.isEmpty
    }

    /// Returns the cookie string to use - combines fullCookies with sessionKey if needed
    var effectiveCookies: String? {
        if let full = fullCookies, !full.isEmpty {
            // If full cookies already contains sessionKey, use as-is
            if full.contains("sessionKey=") {
                return full
            }
            // Otherwise, prepend sessionKey if we have it
            if let key = sessionKey, !key.isEmpty {
                return "sessionKey=\(key); \(full)"
            }
            return full
        }
        if let key = sessionKey, !key.isEmpty {
            return "sessionKey=\(key)"
        }
        return nil
    }

    func fetchUsage() async throws -> WebUsageData {
        guard let cookies = effectiveCookies else {
            throw WebSessionError.noSessionKey
        }

        // Get or fetch organization ID
        let orgId: String
        if let existingOrgId = organizationId {
            orgId = existingOrgId
        } else {
            orgId = try await fetchOrganizationId(cookies: cookies)
            organizationId = orgId
        }

        // Fetch usage
        return try await fetchUsageForOrg(orgId: orgId, cookies: cookies)
    }

    private func fetchOrganizationId(cookies: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/organizations") else {
            throw WebSessionError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        configureRequest(&request, cookies: cookies)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSessionError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw WebSessionError.unauthorized
        }

        let organizations = try JSONDecoder().decode([Organization].self, from: data)

        guard let firstOrg = organizations.first else {
            throw WebSessionError.noOrganization
        }

        return firstOrg.uuid
    }

    private func fetchUsageForOrg(orgId: String, cookies: String) async throws -> WebUsageData {
        guard let url = URL(string: "\(baseURL)/organizations/\(orgId)/usage") else {
            throw WebSessionError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        configureRequest(&request, cookies: cookies)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WebSessionError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSessionError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            // Clear cached org ID on auth failure
            organizationId = nil
            throw WebSessionError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebSessionError.invalidResponse
        }

        // Check for Cloudflare challenge (returns HTML instead of JSON)
        if let htmlString = String(data: data, encoding: .utf8),
           htmlString.contains("Just a moment") || htmlString.contains("cf_clearance") {
            throw WebSessionError.cloudflareChallenge
        }

        do {
            let usageResponse = try JSONDecoder().decode(WebUsageResponse.self, from: data)
            return parseResponse(usageResponse)
        } catch {
            // If decoding fails, check if it's HTML (Cloudflare challenge)
            if let responseString = String(data: data, encoding: .utf8) {
                if responseString.contains("<!DOCTYPE html>") || responseString.contains("Just a moment") {
                    throw WebSessionError.cloudflareChallenge
                }
                // Log first 200 chars for debugging
                print("API Response: \(String(responseString.prefix(200)))")
            }
            throw WebSessionError.decodingError(error)
        }
    }

    private func configureRequest(_ request: inout URLRequest, cookies: String) {
        // Core headers
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")

        // Browser identification
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("\"Google Chrome\";v=\"143\", \"Chromium\";v=\"143\", \"Not A(Brand\";v=\"24\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("\"macOS\"", forHTTPHeaderField: "sec-ch-ua-platform")

        // Fetch metadata
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")

        // Anthropic client headers (mimics real web app)
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
        request.setValue(deviceId, forHTTPHeaderField: "anthropic-device-id")
        request.setValue(anonymousId, forHTTPHeaderField: "anthropic-anonymous-id")

        // Page context
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")

        // Additional browser headers
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    }

    private func parseResponse(_ response: WebUsageResponse) -> WebUsageData {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Fallback formatter without fractional seconds
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        func parseDate(_ string: String) -> Date {
            dateFormatter.date(from: string) ?? fallbackFormatter.date(from: string) ?? Date()
        }

        let sessionResetsAt = response.fiveHour?.resetsAt.flatMap { parseDate($0) } ?? Date()
        let weeklyResetsAt = response.sevenDay?.resetsAt.flatMap { parseDate($0) } ?? Date()
        let sonnetResetsAt = response.sevenDaySonnet?.resetsAt.flatMap { parseDate($0) }

        return WebUsageData(
            sessionUsage: response.fiveHour?.utilization ?? 0,
            sessionResetsAt: sessionResetsAt,
            weeklyUsage: response.sevenDay?.utilization ?? 0,
            weeklyResetsAt: weeklyResetsAt,
            sonnetUsage: response.sevenDaySonnet?.utilization,
            sonnetResetsAt: sonnetResetsAt,
            lastUpdated: Date()
        )
    }

    func clearSession() {
        sessionKey = nil
        fullCookies = nil
        organizationId = nil
    }
}
