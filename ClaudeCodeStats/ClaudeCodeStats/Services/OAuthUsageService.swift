import Foundation

class OAuthUsageService {
    static let shared = OAuthUsageService()

    private let apiURL = "https://api.anthropic.com/v1/messages"
    private let credentialsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/.credentials.json"
    }()

    private init() {}

    var hasCredentials: Bool {
        readAccessToken() != nil
    }

    func fetchUsage() async throws -> WebUsageData {
        guard let token = readAccessToken() else {
            throw UsageError.noCredentials
        }

        guard let url = URL(string: apiURL) else {
            throw UsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw UsageError.tokenExpired
        }

        // 2xx and 429 both carry valid rate-limit headers
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 else {
            throw UsageError.invalidResponse
        }

        return parseHeaders(httpResponse)
    }

    private func readAccessToken() -> String? {
        guard let data = FileManager.default.contents(atPath: credentialsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func parseHeaders(_ response: HTTPURLResponse) -> WebUsageData {
        let headers = response.allHeaderFields

        let sessionUtilization = headerDouble(headers, key: "anthropic-ratelimit-unified-5h-utilization")
        let sessionReset = headerDate(headers, key: "anthropic-ratelimit-unified-5h-reset")
        let weeklyUtilization = headerDouble(headers, key: "anthropic-ratelimit-unified-7d-utilization")
        let weeklyReset = headerDate(headers, key: "anthropic-ratelimit-unified-7d-reset")

        return WebUsageData(
            sessionUsage: sessionUtilization * 100,
            sessionResetsAt: sessionReset ?? Date(),
            weeklyUsage: weeklyUtilization * 100,
            weeklyResetsAt: weeklyReset ?? Date(),
            lastUpdated: Date()
        )
    }

    private func headerDouble(_ headers: [AnyHashable: Any], key: String) -> Double {
        if let value = headers[key] as? String, let num = Double(value) {
            return num
        }
        return 0
    }

    private func headerDate(_ headers: [AnyHashable: Any], key: String) -> Date? {
        if let value = headers[key] as? String, let timestamp = TimeInterval(value) {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }
}
