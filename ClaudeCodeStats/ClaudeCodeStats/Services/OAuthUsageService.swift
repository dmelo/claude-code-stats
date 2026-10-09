import Foundation
import Security

@MainActor
class OAuthUsageService {
    static let shared = OAuthUsageService(account: .default)

    // One instance per login, keyed by its Keychain service, so each keeps its
    // own token cache and sweep bookkeeping. The default account and an aimux
    // source profile share a service and therefore share an instance.
    private static var instances: [String: OAuthUsageService] = [shared.account.id: shared]

    static func service(for account: ClaudeAccount) -> OAuthUsageService {
        if let existing = instances[account.id] {
            existing.account = account
            return existing
        }
        let created = OAuthUsageService(account: account)
        instances[account.id] = created
        return created
    }

    // Updated on lookup so a source profile, which shares the default
    // instance, still reports its aimux name in messages.
    private(set) var account: ClaudeAccount
    private let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private var credentialsPath: String { account.credentialsPath }
    private var keychainService: String { account.keychainService }
    private var cachedCredential: Credential?
    // Outcome of the last sweep that turned up no usable credential, expired
    // stand-in included. Such a sweep costs a file read plus a `security`
    // subprocess against the CLI's item, and cachedCredential cannot absorb it, because its gate is isUsable and so never matches a
    // lapsed token. hasCredentials is evaluated inside SwiftUI bodies that re-run
    // on every redraw, so without this the all-expired and signed-out states both
    // mean unbounded keychain traffic. Reusing the outcome for a short window
    // bounds that while still picking up a rotation promptly.
    private var lastUnusableSweep: (credential: Credential?, at: Date)?
    private let unusableSweepReuseWindow: TimeInterval = 30
    private let session: URLSession

    // An OAuth access token plus the expiry the CLI recorded for it. Tracking
    // expiry lets us notice when the CLI has rotated the token and re-read the
    // live source instead of clinging to a stale cached copy.
    private struct Credential {
        let token: String
        let expiresAt: Date?
        /// When the CLI's Keychain item was last written, as of reading this
        /// token from it (nil for the file source). A later write means the CLI
        /// rotated or re-logged in — possibly into a different account — so a
        /// copy taken before it can't be trusted even while unexpired.
        var sourceModified: Date? = nil

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

    private init(account: ClaudeAccount) {
        self.account = account
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    var hasCredentials: Bool {
        readCredential() != nil
    }

    func fetchUsage() async throws -> WebUsageData {
        // Carry the whole credential, not just its string: whether we knew the
        // token was lapsed when we sent it is what lets us read a 429 correctly
        // below.
        dropCachesIfSourceChanged()
        guard let credential = readCredential() else {
            throw UsageError.noCredentials
        }

        guard let url = URL(string: usageURL) else {
            throw UsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")

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

        // 429 covers two unrelated conditions here. The endpoint has its own rate
        // limit (a long retry-after and no usage body), and it also answers a
        // rotated-away token with the same status and the same rate_limit_error
        // body — it never returns 401 for that, which is why the 401/403 branch
        // above can't catch it. The status alone therefore can't separate them,
        // but our own bookkeeping can: readCredential() hands back a lapsed token
        // only when no source has a live one, and such a request was doomed
        // before it was sent. Reporting that as a rate limit tells the user to
        // wait for something that cannot clear on its own — re-authenticating is
        // what actually fixes it.
        if httpResponse.statusCode == 429 {
            if !credential.isUsable {
                clearTokenCaches()
                throw UsageError.tokenExpired
            }
            // Genuinely throttled. Surface it distinctly so the UI keeps showing
            // the last known data and recovers on the next scheduled poll.
            throw UsageError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UsageError.invalidResponse
        }

        return try parseUsage(data)
    }

    // Returns the credential to authenticate with, or nil when no source holds a
    // token at all. The result can be a lapsed credential — see the last-resort
    // pass below — so callers that care must check isUsable rather than assume a
    // returned credential is live.
    private func readCredential() -> Credential? {
        // In-memory cache, but only while the token is still fresh.
        if let cached = cachedCredential, cached.isUsable {
            return cached
        }

        // A sweep that just came up empty stands in for repeating it; see
        // lastUnusableSweep. Its credential is nil when no source held a token at
        // all, which is as much a result worth reusing as an expired one.
        if let sweep = lastUnusableSweep,
           -sweep.at.timeIntervalSinceNow < unusableSweepReuseWindow {
            return sweep.credential
        }

        // Live file source (present on some setups). Authoritative and cheap to
        // read with no prompt, so it stays ahead of the keychain — but only while
        // it is usable. A CLI that rotates its keychain copy and stops rewriting
        // the file leaves a permanently expired token here, and taking it
        // unconditionally would pin us to it for good: the fresher keychain
        // source below is never reached, and because a rotated-away token answers
        // 429 rather than 401, the failure is indistinguishable from a real rate
        // limit, so nothing self-heals.
        let fileCredential = readCredentialFromFile()
        if let cred = fileCredential, cred.isUsable {
            adopt(cred)
            return cred
        }

        // Live keychain source owned by the Claude Code CLI. Re-reading here is
        // what picks up a token the CLI has rotated. It is read through
        // /usr/bin/security, which never prompts (see readCredentialFromKeychain),
        // so there is no on-disk copy to keep: the in-memory cache above is enough.
        // Date taken before the data: a write landing between the two reads then
        // looks newer than our copy and is picked up next time, not masked.
        let modifiedBeforeRead = cliItemModified()
        var keychainCredential = readCredentialFromKeychain(service: keychainService)
        keychainCredential?.sourceModified = modifiedBeforeRead
        if let cred = keychainCredential, cred.isUsable {
            adopt(cred)
            return cred
        }

        // Nothing is unexpired, so send the token that lapsed most recently
        // rather than claiming we have no credentials — signed in with a stale
        // token is not the same as signed out, and a request that fails tells the
        // user more than a false "not signed in" would.
        let expired: [Credential] = [fileCredential, keychainCredential]
            .compactMap { $0 }
        let fallback = expired.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) })
        lastUnusableSweep = (fallback, Date())
        return fallback
    }

    // Modification date of the CLI's Keychain item. An attributes-only query
    // never prompts, unlike reading the item's data, so this is cheap enough to
    // run before every fetch.
    private func cliItemModified() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    // A cached copy is superseded when the CLI has written its item since the
    // copy was taken. Unexpired isn't enough: logging a config dir into another
    // account leaves the old account's token valid for hours, and without this
    // check its usage keeps being shown under the new login. A copy with no date
    // (the file source) is treated as superseded once the item exists.
    private func isSuperseded(_ credential: Credential) -> Bool {
        guard let modified = cliItemModified() else { return false }
        guard let seen = credential.sourceModified else { return true }
        return modified > seen
    }

    private func dropCachesIfSourceChanged() {
        if let cached = cachedCredential, isSuperseded(cached) {
            cachedCredential = nil
        }
        lastUnusableSweep = nil
    }

    // Take a live credential into the in-memory cache. Any record of a sweep that
    // found nothing usable is stale the moment one does turn up.
    private func adopt(_ credential: Credential) {
        cachedCredential = credential
        lastUnusableSweep = nil
    }

    private func clearTokenCaches() {
        cachedCredential = nil
        lastUnusableSweep = nil
    }

    private func readCredentialFromFile() -> Credential? {
        guard let data = FileManager.default.contents(atPath: credentialsPath) else {
            return nil
        }
        return extractCredential(from: data)
    }

    // Claude Code writes its login with `security add-generic-password`, which
    // puts /usr/bin/security on the item's access list. Reading through the same
    // tool therefore never prompts. Reading through the Keychain API instead
    // makes macOS ask once per item for this app, and because the app is ad-hoc
    // signed it is identified by its exact binary hash, so "Always Allow" lapsed
    // with every build and every release. The API read stays as the fallback for
    // an item the tool can't read (one written some other way, say); it may
    // prompt, as before.
    private func readCredentialFromKeychain(service: String) -> Credential? {
        switch readViaSecurityTool(service: service) {
        case .found(let data):
            return extractCredential(from: data)
        case .notFound:
            return nil
        case .failed:
            break
        }

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

    private enum SecurityToolRead {
        case found(Data)
        case notFound
        case failed
    }

    // `security find-generic-password -w` prints the item's data and exits 0, or
    // exits 44 when no item has that service. Capped at a few seconds: a locked
    // keychain makes the tool wait on an unlock dialog, and this runs on the main
    // actor. The blob is well under a pipe buffer, so waiting for exit before
    // reading stdout can't deadlock.
    private func readViaSecurityTool(service: String) -> SecurityToolRead {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failed
        }
        guard exited.wait(timeout: .now() + 4) == .success else {
            process.terminate()
            return .failed
        }

        switch process.terminationStatus {
        case 0:
            return .found(stdout.fileHandleForReading.readDataToEndOfFile())
        case 44:
            return .notFound
        default:
            return .failed
        }
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
