import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ttsService: TTSService
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("dailyBriefingTime") private var dailyBriefingTime = "08:00"
    @AppStorage("ttsSpeechRate") private var speechRate: Double = 0.55
    @AppStorage("ttsPitch") private var pitch: Double = 1.0
    @AppStorage("ttsVoice") private var selectedVoice: String = Neural2Voice.maleJ.rawValue

    @AppStorage("selectedModelFilter") private var selectedFilter: String = ModelFilter.all.rawValue
    @State private var showClearCacheAlert = false

    var body: some View {
        List {
                // Feed Filter Section
                Section {
                    Picker("Source", selection: $selectedFilter) {
                        ForEach(ModelFilter.allCases, id: \.rawValue) { filter in
                            Text(filter.rawValue).tag(filter.rawValue)
                        }
                    }
                } header: {
                    Text("Feed")
                } footer: {
                    Text("Filter articles by AI model source.")
                }

                // Listening Section
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Speech Rate")
                            Spacer()
                            Text(speechRateLabel)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $speechRate, in: 0.25...0.75, step: 0.05)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Pitch")
                            Spacer()
                            Text(pitchLabel)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $pitch, in: 0.5...1.5, step: 0.1)
                    }

                    if !ttsService.isUsingLocalTTS {
                        Picker("Voice", selection: $selectedVoice) {
                            ForEach(Neural2Voice.allCases) { voice in
                                Text(voice.displayName).tag(voice.rawValue)
                            }
                        }
                    }
                } header: {
                    Text("Listening")
                } footer: {
                    if ttsService.isUsingLocalTTS {
                        Text("Using device speech synthesis. Add a Google Cloud TTS API key in Secrets.xcconfig for Neural2 voices.")
                    } else {
                        Text("Uses Google Cloud Neural2 voices for natural-sounding speech.")
                    }
                }

                // Notifications Section
                Section {
                    Toggle("Daily Briefings", isOn: $notificationsEnabled)

                    if notificationsEnabled {
                        HStack {
                            Text("Briefing Time")
                            Spacer()
                            Text(dailyBriefingTime)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Receive a daily summary of the latest engineering articles.")
                }

                // Cache Section
                Section {
                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Clear cached summaries and content to free up space.")
                }
                .alert("Clear Cache?", isPresented: $showClearCacheAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear", role: .destructive) {
                        clearCache()
                    }
                } message: {
                    Text("This will remove all downloaded articles. You'll need internet to read them again.")
                }

                // About Section
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .foregroundColor(.secondary)
                    }

                    if let url = URL(string: "https://github.com/tsvet01/eng-pulse") {
                        Link(destination: url) {
                            HStack {
                                Text("Source Code")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("About")
                }
            }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var speechRateLabel: String {
        if speechRate < 0.4 { return "Slow" }
        if speechRate > 0.6 { return "Fast" }
        return "Normal"
    }

    private var pitchLabel: String {
        if pitch < 0.8 { return "Low" }
        if pitch > 1.2 { return "High" }
        return "Normal"
    }

    private func clearCache() {
        Task {
            await appState.clearCache()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(TTSService())
}
