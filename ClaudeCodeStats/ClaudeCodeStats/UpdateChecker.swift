import SwiftUI

@MainActor
class UpdateChecker: ObservableObject {
    @Published var installedVersion: String?
    @Published var latestVersion: String?
    @AppStorage("dismissedUpdateVersion") var dismissedVersion: String = ""

    private var timer: Timer?
    private var lastCheckDate: Date?

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
        return "Claude Code v\(installed) \u{2192} v\(latest) available"
    }

    var upToDateText: String {
        guard let installed = installedVersion else { return "" }
        return "Claude Code v\(installed) \u{2014} up to date"
    }

    init() {
        startHourlyCheck()
        Task {
            await checkForUpdate()
        }
    }

    func checkForUpdate() async {
        if let last = lastCheckDate, Date().timeIntervalSince(last) < 1800 {
            return
        }

        async let installedResult: String? = {
            try? await VersionService.shared.fetchInstalledVersion()
        }()
        async let latestResult: String? = {
            try? await VersionService.shared.fetchLatestVersion()
        }()

        let (installed, latest) = await (installedResult, latestResult)
        if let installed { self.installedVersion = installed }
        if let latest { self.latestVersion = latest }

        lastCheckDate = Date()
    }

    func dismiss() {
        if let latest = latestVersion {
            dismissedVersion = latest
        }
    }

    func openChangelog() {
        if let version = latestVersion ?? installedVersion,
           let url = URL(string: "https://github.com/anthropics/claude-code/releases/tag/v\(version)") {
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
