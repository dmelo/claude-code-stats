import SwiftUI

struct SettingsView: View {
    @Binding var isPresented: Bool
    @State private var sessionKey: String = ""
    @State private var fullCookies: String = ""
    @State private var showingInstructions = false
    @State private var showingAdvanced = false

    private var backgroundColor: Color {
        Color(red: 26/255, green: 26/255, blue: 26/255)
    }

    private var cardBackground: Color {
        Color(red: 42/255, green: 42/255, blue: 42/255)
    }

    private var textSecondary: Color {
        Color(red: 138/255, green: 138/255, blue: 138/255)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { isPresented = false }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color(red: 58/255, green: 58/255, blue: 58/255))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Session Key Section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Session Cookie")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)

                            Spacer()

                            Button("How to get this?") {
                                showingInstructions.toggle()
                            }
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                            .buttonStyle(.plain)
                        }

                        SecureField("Paste sessionKey here", text: $sessionKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(cardBackground)
                            .cornerRadius(6)
                            .foregroundColor(.white)

                        if showingInstructions {
                            instructionsView
                        }

                        HStack {
                            Button("Save") {
                                WebSessionService.shared.sessionKey = sessionKey
                                isPresented = false
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(6)
                            .buttonStyle(.plain)

                            if WebSessionService.shared.hasSessionKey {
                                Button("Clear") {
                                    WebSessionService.shared.sessionKey = nil
                                    sessionKey = ""
                                }
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(12)
                    .background(cardBackground)
                    .cornerRadius(8)

                    // Advanced Section (Full Cookies)
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: { showingAdvanced.toggle() }) {
                            HStack {
                                Text("Cloudflare Bypass")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)

                                Spacer()

                                Image(systemName: showingAdvanced ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(textSecondary)
                            }
                        }
                        .buttonStyle(.plain)

                        if showingAdvanced {
                            Text("If you see 'Blocked by Cloudflare', paste the full cookie string from your browser:")
                                .font(.system(size: 10))
                                .foregroundColor(textSecondary)

                            TextField("Paste full cookie string", text: $fullCookies, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(3...5)
                                .padding(8)
                                .background(Color(red: 35/255, green: 35/255, blue: 35/255))
                                .cornerRadius(6)
                                .foregroundColor(.white)

                            advancedInstructionsView

                            HStack {
                                Button("Save Cookies") {
                                    WebSessionService.shared.fullCookies = fullCookies
                                    WebSessionService.shared.organizationId = nil
                                    isPresented = false
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.orange)
                                .cornerRadius(6)
                                .buttonStyle(.plain)

                                if WebSessionService.shared.fullCookies != nil {
                                    Button("Clear") {
                                        WebSessionService.shared.fullCookies = nil
                                        fullCookies = ""
                                    }
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(cardBackground)
                    .cornerRadius(8)

                    // Status
                    HStack {
                        Circle()
                            .fill(WebSessionService.shared.hasSessionKey ? Color.green : Color.red)
                            .frame(width: 8, height: 8)

                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundColor(textSecondary)

                        Spacer()

                        Text("v\(appVersion)")
                            .font(.system(size: 10))
                            .foregroundColor(textSecondary)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 280)
        .background(backgroundColor)
        .onAppear {
            sessionKey = WebSessionService.shared.sessionKey ?? ""
            fullCookies = WebSessionService.shared.fullCookies ?? ""
        }
    }

    private var statusText: String {
        if WebSessionService.shared.fullCookies != nil {
            return "Using full cookies (Cloudflare bypass)"
        } else if WebSessionService.shared.hasSessionKey {
            return "Session configured"
        } else {
            return "No session configured"
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var instructionsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To get your session cookie:")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)

            Group {
                Text("1. Open claude.ai in your browser")
                Text("2. Open Developer Tools (Cmd+Option+I)")
                Text("3. Go to Application → Cookies → claude.ai")
                Text("4. Find 'sessionKey' and copy its value")
            }
            .font(.system(size: 10))
            .foregroundColor(textSecondary)

            Text("⚠️ Keep this private - it grants access to your account")
                .font(.system(size: 10))
                .foregroundColor(.orange)
                .padding(.top, 4)
        }
        .padding(10)
        .background(Color(red: 35/255, green: 35/255, blue: 35/255))
        .cornerRadius(6)
    }

    private var advancedInstructionsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How to get full cookies:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)

            Group {
                Text("1. Open claude.ai/settings/usage")
                Text("2. DevTools → Network tab → Refresh")
                Text("3. Click any request → Headers tab")
                Text("4. Copy entire 'Cookie:' value")
            }
            .font(.system(size: 9))
            .foregroundColor(textSecondary)
        }
        .padding(8)
        .background(Color(red: 35/255, green: 35/255, blue: 35/255))
        .cornerRadius(6)
    }
}

#Preview {
    SettingsView(isPresented: .constant(true))
}
