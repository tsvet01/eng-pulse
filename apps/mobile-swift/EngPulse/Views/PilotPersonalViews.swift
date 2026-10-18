import SwiftUI

struct PilotFeedbackView: View {
    @EnvironmentObject private var state: PilotPersonalState
    let date: String

    var body: some View {
        SettingsSection(title: "Your feedback", icon: "hand.thumbsup") {
            ratingRow("Article choice", aspect: .selection)
            ratingRow("Brief quality", aspect: .brief)
            if state.hasPending(date: date) {
                Text(state.isFlushing ? "Syncing your ratings…" : "Saved on this device · waiting to sync")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = state.feedbackErrors[date] {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if state.feedbackErrors[date] != nil || state.hasPending(date: date) {
                Button("Retry") {
                    Task {
                        await state.flush()
                        await state.refreshFeedback(date: date)
                    }
                }
                .disabled(state.isFlushing)
            }
        }
        .disabled(!state.isActive)
        .task(id: date) {
            await state.refreshFeedback(date: date)
            await state.flush()
        }
    }

    private func ratingRow(_ title: String, aspect: PilotFeedbackAspect) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            ratingButton(title, aspect: aspect, value: 1)
            ratingButton(title, aspect: aspect, value: -1)
        }
    }

    private func ratingButton(_ title: String, aspect: PilotFeedbackAspect, value: Int) -> some View {
        let selected = state.feedback[date]?.value(for: aspect) == value
        let symbol = value == 1 ? "hand.thumbsup" : "hand.thumbsdown"
        return Button {
            Task { await state.rate(date: date, aspect: aspect, value: selected ? nil : value) }
        } label: {
            Image(systemName: selected ? "\(symbol).fill" : symbol)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(selected ? Color.accentColor : Color.onSurfaceVariant)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value == 1 ? "helpful" : "not helpful")")
        .accessibilityValue(selected ? "Selected. Tap to remove." : "Not selected")
    }
}

struct PilotNotificationSettings: View {
    @EnvironmentObject private var state: PilotPersonalState

    var body: some View {
        SettingsSection(title: "Pilot notifications", icon: "bell.badge") {
            Text("Pilot notifications aren't available yet. These preferences will apply when delivery launches; existing daily emails are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if state.preferences != nil {
                Toggle("Email", isOn: preference(\.notifyEmail))
                    .disabled(state.isSavingPreferences || state.preferencesError != nil || !state.isActive)
                Toggle("Push notifications", isOn: preference(\.notifyPush))
                    .disabled(state.isSavingPreferences || state.preferencesError != nil || !state.isActive)
            }
            if state.isSavingPreferences { ProgressView().accessibilityLabel("Updating preferences") }
            if let error = state.preferencesError {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Reload preferences") { Task { await state.loadPreferences() } }
                    .disabled(state.isSavingPreferences)
            }
        }
        .task { await state.loadPreferences() }
    }

    private func preference(_ keyPath: WritableKeyPath<PilotNotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { state.preferences?[keyPath: keyPath] ?? false }, set: { value in
            guard !state.isSavingPreferences, state.preferencesError == nil,
                  var preferences = state.preferences else { return }
            preferences[keyPath: keyPath] = value
            Task { await state.savePreferences(preferences) }
        })
    }
}
