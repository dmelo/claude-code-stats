import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case unhandledError(status: OSStatus)
    case jsonParsingError

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Claude Code credentials not found. Please log in to Claude Code first."
        case .unexpectedData:
            return "Unexpected credential data format."
        case .unhandledError(let status):
            return "Keychain error: \(status)"
        case .jsonParsingError:
            return "Failed to parse credentials JSON."
        }
    }
}

struct ClaudeCredentials: Codable {
    let claudeAiOauth: OAuthCredentials?

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth = "claudeAiOauth"
    }
}

struct OAuthCredentials: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: String?
}

class KeychainService {
    static let shared = KeychainService()
    private let serviceName = "Claude Code-credentials"

    private init() {}

    func getAccessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }

        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw KeychainError.jsonParsingError
        }

        let credentials = try JSONDecoder().decode(ClaudeCredentials.self, from: jsonData)

        guard let oauth = credentials.claudeAiOauth else {
            throw KeychainError.itemNotFound
        }

        return oauth.accessToken
    }
}
