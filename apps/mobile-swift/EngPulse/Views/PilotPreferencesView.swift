import SwiftUI

struct PilotPreferencesView: View {
    @ObservedObject var model: PilotPreferencesModel

    var body: some View {
        SettingsSection(title: "Your interests", icon: "slider.horizontal.3") {
            Text("Choose what you’d like to read. Personal daily picks are coming soon.")
                .font(.subheadline).foregroundStyle(Color.onSurfaceVariant)
            if let saved = model.saved {
                ForEach(saved.topics) { topic in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(topic.name).font(.subheadline.weight(.medium))
                        Text(topic.description).font(.caption).foregroundStyle(Color.onSurfaceVariant)
                        Picker(topic.name, selection: Binding(get: { model.choice(for: topic.id) },
                            set: { model.setChoice($0, topic: topic.id) })) {
                            Text("No preference").tag(PilotTopicChoice.neutral)
                            Text("More like this").tag(PilotTopicChoice.interested)
                            Text("Avoid").tag(PilotTopicChoice.excluded)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("preferences.\(topic.id)")
                        if model.choice(for: topic.id) == .interested {
                            Picker("Technical depth", selection: Binding(get: { model.draft.depthByTopic[topic.id] },
                                set: { model.setDepth($0, topic: topic.id) })) {
                                Text("Any depth").tag(nil as PilotTechnicalDepth?)
                                ForEach(PilotTechnicalDepth.allCases, id: \.self) { depth in
                                    Text(depth.rawValue.capitalized).tag(Optional(depth))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .disabled(model.isBusy || model.needsReload)
                    Divider()
                }
                Button("Save interests") { Task { await model.save() } }
                    .disabled(!model.hasChanges || model.isBusy || model.needsReload)
                    .accessibilityIdentifier("preferences.save")
            }
            if model.isBusy { ProgressView().accessibilityLabel("Updating interests") }
            if let message = model.savedMessage {
                Text(message).font(.caption).foregroundStyle(Color.onSurfaceVariant)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(Color.onSurfaceVariant)
                Button(model.needsReload ? "Reload saved interests" : "Try again") { Task { await model.load(discardDraft: true) } }
                    .disabled(model.isBusy)
            }
        }
        .task { await model.load() }
    }
}
