import SwiftUI

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("dailyBriefingTime") private var dailyBriefingTime = "08:00"
    @AppStorage("selectedModel") private var selectedModel = "gemini-2.0-flash"

    var body: some View {
        NavigationStack {
            List {
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
                        Text("Gemini 2.0 Flash").tag("gemini-2.0-flash")
                        Text("Gemini 1.5 Pro").tag("gemini-1.5-pro")
                        Text("Gemini 1.5 Flash").tag("gemini-1.5-flash")
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

                    Link(destination: URL(string: "https://github.com/anthropics/agent-gemini")!) {
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
