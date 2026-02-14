import SwiftUI

@MainActor
class UsageViewModel: ObservableObject {
    @Published var webUsage: WebUsageData?
    @Published var error: String?
    @Published var isLoading = false

    // Status properties
    @Published var claudeStatus: ClaudeStatus?
    @Published var isStatusLoading = false

    private var refreshTimer: Timer?

    var backgroundRefreshEnabled: Bool = false {
        didSet {
            guard backgroundRefreshEnabled != oldValue else { return }
            if backgroundRefreshEnabled {
                startAutoRefresh()
            } else {
                refreshTimer?.invalidate()
                refreshTimer = nil
            }
        }
    }

    init() {
        Task {
            await refresh()
        }
    }

    var statusColor: Color {
        claudeStatus?.color ?? .gray
    }

    var statusText: String {
        claudeStatus?.displayText ?? "Status"
    }

    func refresh() async {
        isLoading = true
        error = nil

        do {
            webUsage = try await WebSessionService.shared.fetchUsage()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false

        // Also refresh status
        await refreshStatus()
    }

    func refreshStatus() async {
        guard !isStatusLoading else { return }
        isStatusLoading = true
        defer { isStatusLoading = false }
        do {
            claudeStatus = try await StatusService.shared.fetchStatus()
        } catch {
            // Silently fail - status is non-critical; keep last known status
        }
    }

    func refreshIfNeeded() async {
        // Only auto-refresh if no data or more than 1 minute since last update
        if let lastUpdated = webUsage?.lastUpdated {
            let elapsed = Date().timeIntervalSince(lastUpdated)
            if elapsed < 60 {
                // Still refresh status if we haven't fetched it yet
                if claudeStatus == nil {
                    await refreshStatus()
                }
                return
            }
        }
        await refresh()
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
