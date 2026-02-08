import Foundation

// MARK: - GitHub API Response

private struct GitHubRelease: Codable {
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

// MARK: - VersionService

class VersionService {
    static let shared = VersionService()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration)
    }

    func fetchInstalledVersion() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-li", "-c", "claude --version"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                continuation.resume(throwing: VersionError.parseError)
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                continuation.resume(throwing: VersionError.parseError)
                return
            }

            // Extract semver pattern from output (e.g. "1.0.30" from "claude 1.0.30" or just "1.0.30")
            let pattern = #"(\d+\.\d+\.\d+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) else {
                continuation.resume(throwing: VersionError.parseError)
                return
            }

            continuation.resume(returning: String(output[range]))
        }
    }

    func fetchLatestVersion() async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/anthropics/claude-code/releases/latest") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeCodeStats/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        // Strip leading "v" if present (e.g. "v1.0.30" -> "1.0.30")
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return version
    }
}

enum VersionError: Error {
    case parseError
}
