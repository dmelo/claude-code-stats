import SwiftUI

struct SettingsView: View {
    @Binding var isPresented: Bool
    @AppStorage("showSessionInMenuBar") private var showSession = false
    @AppStorage("showWeeklyInMenuBar") private var showWeekly = false

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            Divider()
                .background(Theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    authStatusSection
                    menuBarDisplaySection
                    versionRow
                }
                .padding(12)
            }
        }
        .frame(width: 280)
        .background(Theme.background)
    }

    private var settingsHeader: some View {
        HStack {
            Button(action: { isPresented = false }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.plain)

            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var authStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authentication")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            HStack(spacing: 8) {
                Circle()
                    .fill(OAuthUsageService.shared.hasCredentials ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(OAuthUsageService.shared.hasCredentials
                     ? "Authenticated via Claude Code"
                     : "Not authenticated")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            if !OAuthUsageService.shared.hasCredentials {
                Text("Run 'claude' in your terminal to log in. Credentials are detected automatically.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .padding(8)
                    .background(Theme.inputBackground)
                    .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    private var menuBarDisplaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu Bar Display")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            Toggle("Show session usage", isOn: $showSession)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .toggleStyle(.switch)
                .controlSize(.mini)

            Toggle("Show weekly usage", isOn: $showWeekly)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    private var versionRow: some View {
        HStack {
            Spacer()

            Text("v\(appVersion)")
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

#Preview {
    SettingsView(isPresented: .constant(true))
}
