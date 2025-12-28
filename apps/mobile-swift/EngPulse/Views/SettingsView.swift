import SwiftUI

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("dailyBriefingTime") private var dailyBriefingTime = "08:00"
    @AppStorage("selectedModel") private var selectedModel = "claude-opus-4-5"
    @AppStorage("ttsSpeechRate") private var speechRate: Double = 0.5
    @AppStorage("ttsPitch") private var pitch: Double = 1.0

    var body: some View {
        NavigationStack {
            List {
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
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Adjust text-to-speech voice settings for article reading.")
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

                // AI Model Section
                Section {
                    Picker("AI Model", selection: $selectedModel) {
                        Text("Claude Opus 4.5").tag("claude-opus-4-5")
                        Text("Claude Sonnet 4").tag("claude-sonnet-4")
                        Text("Gemini 2.0 Flash").tag("gemini-2.0-flash")
                        Text("Gemini 1.5 Pro").tag("gemini-1.5-pro")
                        Text("GPT-5.2").tag("gpt-5.2")
                    }
                } header: {
                    Text("AI Settings")
                } footer: {
                    Text("Choose the AI model used for generating summaries.")
                }

                // Cache Section
                Section {
                    Button(role: .destructive) {
                        clearCache()
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Clear cached summaries and content to free up space.")
                }

                // About Section
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/tsvet01/eng-pulse")!) {
                        HStack {
                            Text("Source Code")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
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
        // Clear cache implementation
        Task {
            await CacheService().clearAll()
        }
    }
}

#Preview {
    SettingsView()
}
