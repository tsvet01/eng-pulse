import SwiftUI

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("dailyBriefingTime") private var dailyBriefingTime = "08:00"
    @AppStorage("ttsSpeechRate") private var speechRate: Double = 0.5
    @AppStorage("ttsPitch") private var pitch: Double = 1.0

    @State private var showClearCacheAlert = false

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
