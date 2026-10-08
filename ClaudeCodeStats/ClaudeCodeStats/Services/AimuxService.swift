import Foundation
import CryptoKit

// One Claude Code login the app polls limits for. Without aimux there is exactly
// one, the default config dir; with aimux there is one per claude profile.
struct ClaudeAccount: Identifiable, Hashable {
    /// The aimux profile name, or nil for the plain no-aimux setup.
    let profileName: String?
    let configDir: String
    /// The Keychain service Claude Code stores this config dir's OAuth blob
    /// under. Claude Code leaves the name bare when CLAUDE_CONFIG_DIR is unset and
    /// otherwise suffixes the first 8 hex of sha256(NFC config dir). aimux unsets
    /// CLAUDE_CONFIG_DIR for its source profile only, so `is_source` — not the
    /// path — decides the suffix: a source at ~/.claude-main still uses the bare
    /// name. A wrong name here reads exactly like "not logged in".
    let keychainService: String

    var id: String { keychainService }
    var credentialsPath: String { "\(configDir)/.credentials.json" }

    /// What a user types to refresh this login when its token lapses.
    var reauthCommand: String {
        profileName.map { "aimux run \($0)" } ?? "claude"
    }

    static let keychainBase = "Claude Code-credentials"

    static var `default`: ClaudeAccount {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeAccount(profileName: nil, configDir: "\(home)/.claude", keychainService: keychainBase)
    }

    static func keychainService(configDir: String, isSource: Bool) -> String {
        guard !isSource else { return keychainBase }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(keychainBase)-\(hex.prefix(8))"
    }
}

// Reads the aimux profile list from ~/.aimux/config.yaml. Only the claude
// profiles matter here; codex ones have no Claude limits to show.
enum AimuxService {
    static var configPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.aimux/config.yaml"
    }

    /// The accounts to poll: every aimux claude profile, in config order, or the
    /// single default account when aimux is absent or lists no claude profile.
    static func discoverAccounts() -> [ClaudeAccount] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return [.default]
        }
        let accounts = parseProfiles(text)
        return accounts.isEmpty ? [.default] : accounts
    }

    // A deliberately narrow reader for the one block we need, not a YAML parser:
    //
    //   profiles:
    //     main:
    //       cli: claude
    //       path: /Users/x/.claude
    //       is_source: true
    //
    // Profile names sit one indent level under `profiles:`, their fields one level
    // deeper; the block ends at the next top-level key.
    static func parseProfiles(_ text: String) -> [ClaudeAccount] {
        var entries: [(name: String, fields: [String: String])] = []
        var inProfiles = false
        var profileIndent: Int?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = line.prefix(while: { $0 == " " }).count

            if indent == 0 {
                inProfiles = trimmed == "profiles:"
                profileIndent = nil
                continue
            }
            guard inProfiles else { continue }

            if profileIndent == nil { profileIndent = indent }
            if indent == profileIndent, trimmed.hasSuffix(":") {
                entries.append((String(trimmed.dropLast()), [:]))
            } else if indent > (profileIndent ?? 0), !entries.isEmpty,
                      let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                entries[entries.count - 1].fields[key] = value
            }
        }

        return entries.compactMap { entry in
            guard entry.fields["cli"] == "claude", let path = entry.fields["path"] else { return nil }
            let dir = expandHome(path)
            let isSource = entry.fields["is_source"] == "true"
            return ClaudeAccount(
                profileName: entry.name,
                configDir: dir,
                keychainService: ClaudeAccount.keychainService(configDir: dir, isSource: isSource)
            )
        }
    }

    private static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }
}

// Per-profile menu bar preferences, kept as plain strings so @AppStorage can
// hold them: a list of hidden profile names, and a name → short-label map.
// Hidden rather than shown, so a profile added to aimux later appears by default.
enum ProfilePreferences {
    static let hiddenKey = "hiddenMenuBarProfiles"
    static let labelsKey = "menuBarProfileLabels"

    static func hidden(from raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    static func encodeHidden(_ names: Set<String>) -> String {
        names.sorted().joined(separator: "\n")
    }

    static func labels(from raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func encodeLabels(_ labels: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(labels) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The label drawn in the menu bar: the user's short label when set,
    /// otherwise the aimux profile name.
    static func label(for account: ClaudeAccount, in labels: [String: String]) -> String {
        guard let name = account.profileName else { return "" }
        let custom = labels[name]?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? name : custom
    }
}
