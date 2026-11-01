import SwiftUI

struct PilotPreferencesSettingsLink: View {
    @ObservedObject var model: PilotPreferencesModel

    var body: some View {
        NavigationLink {
            PilotPreferencesView(model: model)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your interests")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.onSurface)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Color.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.onSurfaceVariant)
                    .accessibilityHidden(true)
            }
            .padding(DesignTokens.cardPadding)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color.containerLow, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("preferences.open")
    }

    private var summary: String {
        if model.needsReload { return "Review saved interests" }
        if model.hasChanges { return "Unsaved changes" }
        guard let saved = model.saved else { return "Choose topics and technical depth" }
        let names = saved.topics.filter { saved.preferences.interests.contains($0.id) }.map(\.name)
        if !names.isEmpty { return names.joined(separator: " · ") }
        if !saved.preferences.excludedTopics.isEmpty { return "\(saved.preferences.excludedTopics.count) topics to avoid" }
        return "No preferred topics yet"
    }
}

struct PilotPreferencesView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: PilotPreferencesModel
    @State private var showsAvoidedTopics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.sectionSpacing) {
                Text("Choose topics you enjoy and how technical you like them.")
                    .font(.subheadline)
                    .foregroundStyle(Color.onSurfaceVariant)

                if let saved = model.saved {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeading("More of this", detail: "\(model.draft.interests.count) selected")
                        ForEach(saved.topics) { topic in topicCard(topic) }
                    }
                    avoidedTopics(saved.topics)
                } else if model.errorMessage == nil {
                    ProgressView("Loading interests")
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(DesignTokens.cardPadding)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.surface)
        .navigationTitle("Your interests")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .task { await model.load() }
    }

    private var editingDisabled: Bool { model.isBusy || model.needsReload }
    private var onAccent: Color { .adaptive(dark: Color.Dark.onPrimary, light: Color.Light.onPrimary) }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
        return layout {
            Text(title).font(.headline).foregroundStyle(Color.onSurface)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(detail).font(.caption).foregroundStyle(Color.onSurfaceVariant)
        }
    }

    private func topicCard(_ topic: PilotTopic) -> some View {
        let selected = model.choice(for: topic.id) == .interested
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                model.setChoice(selected ? .neutral : .interested, topic: topic.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: topic.symbolName)
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.onSurface)
                        Text(topic.description).font(.caption).foregroundStyle(Color.onSurfaceVariant)
                        if model.choice(for: topic.id) == .excluded {
                            Text("In Topics to avoid").font(.caption).foregroundStyle(Color.tertiaryAccent)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    selectionMark(selected)
                }
                .padding(16)
                .frame(minHeight: 72)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(editingDisabled)
            .accessibilityLabel("\(topic.name). \(topic.description)")
            .accessibilityValue(selected ? "Selected" : model.choice(for: topic.id) == .excluded ? "Avoided" : "Not selected")
            .accessibilityHint(selected ? "Remove from your interests" : "Add to your interests")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("preferences.\(topic.id)")

            if selected {
                depthChoices(for: topic)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Color.containerLow, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    private func depthChoices(for topic: PilotTopic) -> some View {
        let current = model.draft.depthByTopic[topic.id]
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Technical depth").font(.caption).foregroundStyle(Color.onSurfaceVariant)
            LazyVGrid(columns: columns, spacing: 8) {
                depthButton(nil, topic: topic.id, selected: current == nil)
                ForEach(PilotTechnicalDepth.allCases, id: \.self) { depth in
                    depthButton(depth, topic: topic.id, selected: current == depth)
                }
            }
            Text(current?.explanation ?? "A mix of accessible and detailed articles.")
                .font(.caption)
                .foregroundStyle(Color.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(editingDisabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(topic.name) technical depth")
    }

    private func depthButton(_ depth: PilotTechnicalDepth?, topic: String, selected: Bool) -> some View {
        Button {
            model.setDepth(depth, topic: topic)
        } label: {
            Text(depth?.rawValue.capitalized ?? "Any depth")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? onAccent : Color.onSurface)
                .background(selected ? Color.accentColor : Color.container, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("preferences.\(topic).depth.\(depth?.rawValue ?? "any")")
    }

    private func avoidedTopics(_ topics: [PilotTopic]) -> some View {
        VStack(spacing: 12) {
            Divider()
            DisclosureGroup(isExpanded: $showsAvoidedTopics) {
                VStack(spacing: 0) {
                    ForEach(topics) { topic in
                        let selected = model.choice(for: topic.id) == .excluded
                        Button {
                            model.setChoice(selected ? .neutral : .excluded, topic: topic.id)
                        } label: {
                            HStack(spacing: 12) {
                                Text(topic.name)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.onSurface)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                selectionMark(selected)
                            }
                            .padding(.vertical, 12)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(editingDisabled)
                        .accessibilityValue(selected ? "Avoided" : "Not avoided")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("preferences.avoid.\(topic.id)")
                        if topic.id != topics.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background(Color.containerLow, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
                .padding(.top, 12)
            } label: {
                sectionHeading("Topics to avoid", detail: model.draft.excludedTopics.isEmpty ? "Optional" : "\(model.draft.excludedTopics.count)")
                    .frame(minHeight: 44)
            }
            .tint(.onSurfaceVariant)
        }
    }

    private func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Color.accentColor : Color.outlineVariant)
            .accessibilityHidden(true)
    }

    private var saveBar: some View {
        VStack(spacing: 10) {
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(Color.onSurfaceVariant)
                    .accessibilityIdentifier("preferences.error")
                Button(model.needsReload ? "Reload saved interests" : "Try again") {
                    Task { await model.load(discardDraft: true) }
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .disabled(model.isBusy)
                .accessibilityIdentifier("preferences.reload")
            } else {
                Text(model.savedMessage ?? (model.hasChanges ? "Unsaved changes" : "Personal daily picks are coming soon."))
                    .font(.caption)
                    .foregroundStyle(Color.onSurfaceVariant)
                    .accessibilityIdentifier("preferences.status")
            }
            Button {
                Task { await model.save() }
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy { ProgressView().tint(Color.onSurfaceVariant) }
                    Text(model.isBusy ? "Updating interests…" : "Save interests")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(canSave ? onAccent : Color.onSurfaceVariant)
                .background(canSave ? Color.accentColor : Color.container, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityIdentifier("preferences.save")
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DesignTokens.cardPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(Color.containerLow)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSave: Bool { model.hasChanges && !editingDisabled }
}

private extension PilotTopic {
    var symbolName: String {
        switch id {
        case "cpu_performance": return "cpu"
        case "data": return "externaldrive"
        case "platform": return "square.3.layers.3d"
        case "reliability": return "waveform.path.ecg"
        case "security": return "lock.shield"
        case "ai_ml": return "sparkles"
        case "engineering_leadership": return "person.2"
        default: return "tag"
        }
    }
}

private extension PilotTechnicalDepth {
    var explanation: String {
        switch self {
        case .introductory: return "Foundations, context and clear explanations."
        case .intermediate: return "Working knowledge, with more technical detail."
        case .advanced: return "Deep technical detail and specialist knowledge."
        }
    }
}
