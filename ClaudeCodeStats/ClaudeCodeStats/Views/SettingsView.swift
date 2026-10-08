import SwiftUI

struct SettingsView: View {
    @Binding var isPresented: Bool
    @AppStorage("showSessionInMenuBar") private var showSession = false
    @AppStorage("showWeeklyInMenuBar") private var showWeekly = false
    @AppStorage("showFableInMenuBar") private var showFable = false
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @AppStorage(ProfilePreferences.hiddenKey) private var hiddenProfilesRaw = ""
    @AppStorage(ProfilePreferences.labelsKey) private var profileLabelsRaw = ""
    @State private var accounts = AimuxService.discoverAccounts()

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            Divider()
                .background(Theme.divider)

            // A plain VStack, not a ScrollView: inside MenuBarExtra(.window) a
            // ScrollView reports an indefinite fitting height, so the popover
            // keeps the taller main-view height while the scroll content
            // collapses and clips (issue #25). The settings content is short
            // enough to always fit, so let it size the window naturally.
            VStack(alignment: .leading, spacing: 16) {
                authStatusSection
                appearanceSection
                menuBarDisplaySection
                if accounts.count > 1 {
                    profilesSection
                }
                versionRow
            }
            .padding(12)
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
                    .fill(OAuthUsageService.shared.hasCredentials ? Theme.statusOK : Theme.statusCritical)
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

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            // Named for VoiceOver even though the heading above already says it
            // visually — labelsHidden() only suppresses the on-screen label, so
            // an empty string would leave the control unannounced.
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Text("Auto follows the system setting.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
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

            Toggle("Show Fable usage", isOn: $showFable)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    // One row per aimux profile: whether it gets rings in the menu bar, and the
    // short label drawn before them. An empty label falls back to the profile
    // name. The popover always lists every profile.
    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("aimux Profiles")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            ForEach(accounts) { account in
                if let name = account.profileName {
                    profileRow(name)
                }
            }

            Text("Label is what the menu bar shows before the rings. Leave it empty to use the profile name.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
    }

    private func profileRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Toggle(name, isOn: visibilityBinding(for: name))
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .toggleStyle(.switch)
                .controlSize(.mini)

            Spacer()

            TextField(name, text: labelBinding(for: name))
                .font(.system(size: 11))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 80)
                .accessibilityLabel("Menu bar label for \(name)")
        }
    }

    private func visibilityBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { !ProfilePreferences.hidden(from: hiddenProfilesRaw).contains(name) },
            set: { visible in
                var hidden = ProfilePreferences.hidden(from: hiddenProfilesRaw)
                if visible { hidden.remove(name) } else { hidden.insert(name) }
                hiddenProfilesRaw = ProfilePreferences.encodeHidden(hidden)
            }
        )
    }

    private func labelBinding(for name: String) -> Binding<String> {
        Binding(
            get: { ProfilePreferences.labels(from: profileLabelsRaw)[name] ?? "" },
            set: { label in
                var labels = ProfilePreferences.labels(from: profileLabelsRaw)
                labels[name] = label.isEmpty ? nil : label
                profileLabelsRaw = ProfilePreferences.encodeLabels(labels)
            }
        )
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
