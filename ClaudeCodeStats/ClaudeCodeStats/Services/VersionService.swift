import Foundation
import SwiftUI

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
            process.arguments = ["-l", "-c", "claude --version"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.waitUntilExit()

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

// MARK: - UpdateChecker

@MainActor
class UpdateChecker: ObservableObject {
    @Published var installedVersion: String?
    @Published var latestVersion: String?
    @AppStorage("dismissedUpdateVersion") var dismissedVersion: String = ""

    private var timer: Timer?

    var hasChecked: Bool {
        installedVersion != nil && latestVersion != nil
    }

    var hasUpdate: Bool {
        guard let installed = installedVersion,
              let latest = latestVersion,
              latest != dismissedVersion else {
            return false
        }
        return isVersion(latest, newerThan: installed)
    }

    var isUpToDate: Bool {
        guard let installed = installedVersion,
              let latest = latestVersion else {
            return false
        }
        return !isVersion(latest, newerThan: installed)
    }

    var updateText: String {
        guard let installed = installedVersion, let latest = latestVersion else {
            return ""
        }
        return "Claude Code v\(installed) → v\(latest) available"
    }

    var upToDateText: String {
        guard let installed = installedVersion else { return "" }
        return "Claude Code v\(installed) — up to date"
    }

    init() {
        startHourlyCheck()
    }

    func checkForUpdate() async {
        do {
            async let installed = VersionService.shared.fetchInstalledVersion()
            async let latest = VersionService.shared.fetchLatestVersion()
            let (installedResult, latestResult) = try await (installed, latest)
            self.installedVersion = installedResult
            self.latestVersion = latestResult
        } catch {
            // Silently fail — version check is non-critical
        }
    }

    func dismiss() {
        if let latest = latestVersion {
            dismissedVersion = latest
        }
    }

    func openChangelog() {
        if let url = URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func startHourlyCheck() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdate()
            }
        }
    }

    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va > vb { return true }
            if va < vb { return false }
        }
        return false
    }

    deinit {
        timer?.invalidate()
    }
}
