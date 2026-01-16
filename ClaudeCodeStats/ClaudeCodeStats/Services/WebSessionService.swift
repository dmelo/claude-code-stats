import Foundation

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
    let resetsAt: String

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
        }
    }
}

class WebSessionService {
    static let shared = WebSessionService()
    private let baseURL = "https://claude.ai/api"
    private let sessionKeyKey = "claudeSessionKey"
    private let orgIdKey = "claudeOrgId"

    private init() {}

    var sessionKey: String? {
        get { UserDefaults.standard.string(forKey: sessionKeyKey) }
        set { UserDefaults.standard.set(newValue, forKey: sessionKeyKey) }
    }

    var organizationId: String? {
        get { UserDefaults.standard.string(forKey: orgIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: orgIdKey) }
    }

    var hasSessionKey: Bool {
        guard let key = sessionKey else { return false }
        return !key.isEmpty
    }

    func fetchUsage() async throws -> WebUsageData {
        guard let sessionKey = sessionKey, !sessionKey.isEmpty else {
            throw WebSessionError.noSessionKey
        }

        // Get or fetch organization ID
        let orgId: String
        if let existingOrgId = organizationId {
            orgId = existingOrgId
        } else {
            orgId = try await fetchOrganizationId(sessionKey: sessionKey)
            organizationId = orgId
        }

        // Fetch usage
        return try await fetchUsageForOrg(orgId: orgId, sessionKey: sessionKey)
    }

    private func fetchOrganizationId(sessionKey: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/organizations") else {
            throw WebSessionError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        configureRequest(&request, sessionKey: sessionKey)

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

    private func fetchUsageForOrg(orgId: String, sessionKey: String) async throws -> WebUsageData {
        guard let url = URL(string: "\(baseURL)/organizations/\(orgId)/usage") else {
            throw WebSessionError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        configureRequest(&request, sessionKey: sessionKey)

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

        do {
            let usageResponse = try JSONDecoder().decode(WebUsageResponse.self, from: data)
            return parseResponse(usageResponse)
        } catch {
            throw WebSessionError.decodingError(error)
        }
    }

    private func configureRequest(_ request: inout URLRequest, sessionKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
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

        let sessionResetsAt = response.fiveHour.map { parseDate($0.resetsAt) } ?? Date()
        let weeklyResetsAt = response.sevenDay.map { parseDate($0.resetsAt) } ?? Date()
        let sonnetResetsAt = response.sevenDaySonnet.map { parseDate($0.resetsAt) }

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
        organizationId = nil
    }
}
