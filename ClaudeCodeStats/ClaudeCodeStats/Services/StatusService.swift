import Foundation
import SwiftUI

struct ClaudeStatusResponse: Codable {
    let status: ClaudeStatus
}

struct ClaudeStatus: Codable {
    let indicator: String  // "none", "minor", "major", "critical"
    let description: String

    // "major" and "critical" share the top step. Four hues in a 6pt dot was
    // already more than the eye can separate — orange and yellow especially —
    // and `displayText` sits right next to it saying which one it is.
    var color: Color {
        switch indicator {
        case "none": return Theme.statusOK
        case "minor": return Theme.statusWarning
        case "major", "critical": return Theme.statusCritical
        default: return Theme.textSecondary
        }
    }

    var displayText: String {
        switch indicator {
        case "none": return "Operational"
        case "minor": return "Degraded"
        case "major": return "Outage"
        case "critical": return "Critical"
        default: return "Unknown"
        }
    }
}

class StatusService {
    static let shared = StatusService()
    private let statusURL = "https://status.claude.com/api/v2/status.json"
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration)
    }

    func fetchStatus() async throws -> ClaudeStatus {
        guard let url = URL(string: statusURL) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(ClaudeStatusResponse.self, from: data)
        return decoded.status
    }
}
