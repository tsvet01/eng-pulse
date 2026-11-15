import SwiftUI

struct SettingsSection<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            headerLayout {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.onSurface)
            }
            .padding(.bottom, 4)
            content()
        }
        .padding(DesignTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.containerLow)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
    }
}

struct SettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ttsService: TTSService
    @Environment(\.openURL) private var openURL
    @AppStorage("ttsSpeechRate") private var speechRate: Double = 0.55
    @AppStorage("ttsPitch") private var pitch: Double = 1.0
    @AppStorage("ttsVoice") private var selectedVoice: String = Neural2Voice.maleJ.rawValue

    @State private var showClearCacheAlert = false
    @State private var readCount: Int = 0
    @State private var cacheSize: String = "—"

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.sectionSpacing) {

                // Listening
                SettingsSection(title: "Listening", icon: "waveform") {
                    VStack(alignment: .leading, spacing: 4) {
                        adaptiveRow {
                            Text("Speech Rate")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Text(rateLabel)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.accentColor)
                        }
                        Slider(value: $speechRate, in: 0.25...0.75, step: 0.05)
                            .tint(.accentColor)
                            .accessibilityLabel("Speech rate")
                            .accessibilityValue(rateLabel)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        adaptiveRow {
                            Text("Voice Pitch")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Text(pitchLabel)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.accentColor)
                        }
                        Slider(value: $pitch, in: 0.5...1.5, step: 0.1)
                            .tint(.accentColor)
                            .accessibilityLabel("Voice pitch")
                            .accessibilityValue(pitchLabel)
                    }
                }

                if PilotBuild.allowsLegacyServices {
                // Notification delivery is controlled by iOS; the former local
                // toggle and delivery-time value did not update a subscription.
                SettingsSection(title: "Notifications", icon: "bell") {
                    Text("Manage alerts, sounds, and badges in iOS Settings.")
                        .font(.subheadline)
                        .foregroundStyle(Color.onSurfaceVariant)
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("Open notification settings", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                }

                // Archive
                SettingsSection(title: "Archive", icon: "archivebox") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your feedback")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            Text("\(readCount) articles rated")
                                .font(.caption)
                                .foregroundColor(.onSurfaceVariant)
                        }
                        Spacer()
                    }
                }

                } else if let model = AppServices.shared.pilotAccountModel,
                          case .admitted(_, let user) = model.phase {
                    if let push = model.push { PilotPushSettings(model: push) }
                    SettingsSection(title: "Account", icon: "person.crop.circle") {
                        Text(user.email).font(.subheadline)
                        Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                            .accessibilityIdentifier("pilot.signOut")
                    }
                }

                if let context = AppServices.shared.pilotReader {
                    PilotPreferencesSettingsLink(model: context.preferences).id(context.id)
                }

                // Infrastructure
                SettingsSection(title: "Storage", icon: "externaldrive") {
                    adaptiveRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local Storage")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            Text(cacheSize)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.onSurfaceVariant)
                        }
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Button {
                            showClearCacheAlert = true
                        } label: {
                            Text("Clear Cache")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.tertiaryAccent)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .background(Color.tertiaryAccent.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // About
                SettingsSection(title: "About", icon: "info.circle") {
                    VStack(spacing: 8) {
                        PulseMark(size: 56)
                        Text("Eng Pulse")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .fontDesign(.serif)
                            .foregroundColor(.onSurface)
                        Text("v\(appVersion)")
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundColor(.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, DesignTokens.cardPadding)
            .padding(.vertical, DesignTokens.sectionSpacing)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color.surface)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .task {
            if PilotBuild.allowsLegacyServices { loadReadCount() }
            await loadCacheSize()
        }
        .alert("Clear Cache?", isPresented: $showClearCacheAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                clearCache()
            }
        } message: {
            Text("This will remove all downloaded articles. You'll need internet to read them again.")
        }
    }

    private var adaptiveRow: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
    }

    // MARK: - Computed helpers

    private func loadReadCount() {
        let prefixes = ["feedback_selection_", "feedback_summary_"]
        let urls = UserDefaults.standard.dictionaryRepresentation().compactMap { key, value -> String? in
            guard let feedback = value as? String, !feedback.isEmpty,
                  let prefix = prefixes.first(where: { key.hasPrefix($0) }) else { return nil }
            return String(key.dropFirst(prefix.count))
        }
        readCount = Set(urls).count
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var rateLabel: String {
        speechRate < 0.35 ? "Slow" : speechRate > 0.65 ? "Fast" : "Normal"
    }

    private var pitchLabel: String {
        pitch < 0.7 ? "Low" : pitch > 1.3 ? "High" : "Normal"
    }

    private func loadCacheSize() async {
        cacheSize = await appState.formattedCacheSize()
    }

    private func clearCache() {
        Task {
            await appState.clearCache()
            await loadCacheSize()
        }
    }
}

private struct PilotPushSettings: View {
    @ObservedObject var model: PilotPushModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsSection(title: "Push notifications", icon: "bell") {
            switch model.status {
            case .unavailable:
                Text("Connect to verify your pilot access before registering this iPhone.")
            case .off:
                Text("Receive pilot notifications on this iPhone. Registration does not change your daily delivery preferences.")
                registerButton
            case .connecting:
                Text("Connecting this iPhone…")
                disconnectButton
            case .ready:
                Label("This iPhone is registered", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("pilot.push.registered")
                disconnectButton
            case .disconnecting:
                Text("Disconnecting this iPhone…")
            case .denied:
                Text("Allow notifications in iOS Settings, then register this iPhone.")
                Button("Open notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                registerButton
            case .failed(let message):
                Text(message)
                registerButton
                disconnectButton
            }
        }
        .font(.subheadline)
    }

    private var registerButton: some View {
        Button("Register this iPhone") { Task { await model.enable() } }
            .accessibilityIdentifier("pilot.push.register")
    }

    private var disconnectButton: some View {
        Button("Disconnect this iPhone", role: .destructive) { Task { await model.disable() } }
            .accessibilityIdentifier("pilot.push.disconnect")
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(TTSService())
}
