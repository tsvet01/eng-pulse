import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .fontDesign(.serif)
                    .foregroundColor(.onSurface)
            }
            .padding(.bottom, 4)
            content()
        }
        .padding(DesignTokens.cardPadding)
        .background(Color.container)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ttsService: TTSService
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("dailyBriefingTime") private var dailyBriefingTime = "08:00"
    @AppStorage("ttsSpeechRate") private var speechRate: Double = 0.55
    @AppStorage("ttsPitch") private var pitch: Double = 1.0
    @AppStorage("ttsVoice") private var selectedVoice: String = Neural2Voice.maleJ.rawValue

    @AppStorage("selectedModelFilter") private var selectedFilter: String = ModelFilter.all.rawValue
    @AppStorage("promptVersionFilter") private var promptVersionFilter: String = "production"
    @State private var showClearCacheAlert = false
    @State private var readCount: Int = 0
    @State private var cacheSize: String = "—"

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.sectionSpacing) {

                // Intelligence
                SettingsSection(title: "Intelligence", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Model Filter")
                            .font(.caption)
                            .foregroundColor(.onSurfaceVariant)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ModelFilter.allCases, id: \.rawValue) { filter in
                                    let selected = selectedFilter == filter.rawValue
                                    Button {
                                        selectedFilter = filter.rawValue
                                    } label: {
                                        Text(filter.rawValue)
                                            .font(.subheadline)
                                            .foregroundColor(selected ? .accentColor : .onSurfaceVariant)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(selected ? Color.accentColor.opacity(0.2) : Color.containerHigh)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Divider()
                        .background(Color.outlineVariant)
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Prompt Version")
                            .font(.caption)
                            .foregroundColor(.onSurfaceVariant)
                        HStack(spacing: 8) {
                            ForEach([("v1", "production"), ("v2", "beta"), ("Both", "both")], id: \.1) { label, value in
                                let selected = promptVersionFilter == value
                                Button {
                                    promptVersionFilter = value
                                } label: {
                                    Text(label)
                                        .font(.subheadline)
                                        .foregroundColor(selected ? .accentColor : .onSurfaceVariant)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(selected ? Color.accentColor.opacity(0.2) : Color.containerHigh)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Listening
                SettingsSection(title: "Listening", icon: "waveform") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Speech Rate")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            Spacer()
                            Text(rateLabel)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.accentColor)
                        }
                        Slider(value: $speechRate, in: 0.25...0.75, step: 0.05)
                            .tint(.accentColor)
                    }

                    Divider()
                        .background(Color.outlineVariant)
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Voice Pitch")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            Spacer()
                            Text(pitchLabel)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.accentColor)
                        }
                        Slider(value: $pitch, in: 0.5...1.5, step: 0.1)
                            .tint(.accentColor)
                    }
                }

                // Notifications
                SettingsSection(title: "Notifications", icon: "bell.badge") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $notificationsEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Daily Briefing")
                                    .font(.subheadline)
                                    .foregroundColor(.onSurface)
                                Text("Receive a daily summary of top engineering articles.")
                                    .font(.caption)
                                    .foregroundColor(.onSurfaceVariant)
                            }
                        }
                        .tint(.accentColor)
                        .onChange(of: notificationsEnabled) { _, newValue in
                            if newValue {
                                NotificationService.shared.subscribeToTopic("daily_briefings")
                            } else {
                                NotificationService.shared.unsubscribeFromTopic("daily_briefings")
                            }
                        }
                    }

                    if notificationsEnabled {
                        Divider()
                            .background(Color.outlineVariant)
                            .padding(.vertical, 4)

                        HStack {
                            Text("Delivery Time")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            Spacer()
                            Text(dailyBriefingTime)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.accentColor)
                        }
                    }
                }

                // Archive
                SettingsSection(title: "Archive", icon: "archivebox") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reading History")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            Text("\(readCount) articles read")
                                .font(.caption)
                                .foregroundColor(.onSurfaceVariant)
                        }
                        Spacer()
                    }
                }

                // Infrastructure
                SettingsSection(title: "Infrastructure", icon: "externaldrive") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local Storage")
                                .font(.subheadline)
                                .foregroundColor(.onSurface)
                            Text(cacheSize)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.onSurfaceVariant)
                        }
                        Spacer()
                        Button {
                            showClearCacheAlert = true
                        } label: {
                            Text("Clear Cache")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // About
                SettingsSection(title: "About", icon: "info.circle") {
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.largeTitle)
                            .foregroundColor(.accentColor)
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
        }
        .background(Color.surface)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .task {
            loadReadCount()
            loadCacheSize()
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

    // MARK: - Computed helpers

    private func loadReadCount() {
        readCount = UserDefaults.standard.dictionaryRepresentation()
            .keys.filter { $0.hasPrefix("feedback_selection_") }
            .count
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

    private func loadCacheSize() {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            cacheSize = "Unknown"
            return
        }
        let engPulseCache = cachesURL.appendingPathComponent("EngPulse")
        guard let enumerator = FileManager.default.enumerator(
            at: engPulseCache,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { cacheSize = "0 MB"; return }
        var totalBytes: Int = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += size
            }
        }
        let mb = Double(totalBytes) / 1_048_576
        cacheSize = String(format: "%.1f MB", mb)
    }

    private func clearCache() {
        Task {
            await appState.clearCache()
            loadCacheSize()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(TTSService())
}
