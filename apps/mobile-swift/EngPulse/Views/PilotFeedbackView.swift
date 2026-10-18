import SwiftUI

struct PilotFeedbackView: View {
    @ObservedObject var model: PilotFeedbackModel
    let date: String
    @State private var actionError: String?

    private var record: PilotFeedbackRecord { model.record(for: date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your feedback").font(.headline)
            feedbackRow(.selection, title: "Article relevance", detail: "Was this article useful to you?")
            feedbackRow(.brief, title: "Summary quality", detail: "Was the summary clear and accurate?")
            if !record.conflicts.isEmpty {
                Text("Changed on another device. Review the saved rating, then choose again.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top) {
                Text(status).font(.caption).foregroundStyle(Color.onSurfaceVariant)
                    .accessibilityIdentifier("feedback.status")
                Spacer(minLength: 8)
                if model.errors[date] != nil || actionError != nil {
                    Button("Retry") {
                        actionError = nil
                        Task { await model.refresh(date: date) }
                    }
                    .disabled(model.isSyncing || !model.isActive)
                    .accessibilityIdentifier("feedback.retry")
                }
            }
        }
        .foregroundStyle(Color.onSurface)
        .padding(DesignTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.container)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        .task(id: date) {
            await model.refresh(date: date)
            while !Task.isCancelled && model.isActive {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !record.pending.isEmpty { await model.synchronize() }
            }
        }
    }

    private var status: String {
        if let actionError { return actionError }
        if model.isSyncing { return "Syncing feedback…" }
        if let error = model.errors[date] { return error }
        if !record.pending.isEmpty { return "Saved on this device — waiting to sync." }
        if record.snapshot.selection.revision > 0 || record.snapshot.brief.revision > 0 {
            return "Saved to your account."
        }
        return "Your ratings help improve future picks and summaries."
    }

    private func feedbackRow(_ aspect: PilotFeedbackAspect, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(Color.onSurfaceVariant)
            HStack(spacing: 12) {
                ratingButton(aspect, value: 1, title: title, symbol: "hand.thumbsup", label: "Useful")
                ratingButton(aspect, value: -1, title: title, symbol: "hand.thumbsdown", label: "Not useful")
                Spacer()
                if record.displayed(aspect) != nil {
                    Button("Undo") { rate(nil, aspect: aspect) }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Undo \(title.lowercased()) rating")
                        .accessibilityIdentifier("feedback.\(aspect.rawValue).clear")
                }
            }
            .disabled(model.isSyncing || !model.isActive)
        }
    }

    private func ratingButton(_ aspect: PilotFeedbackAspect, value: Int, title: String, symbol: String, label: String)
        -> some View
    {
        let selected = record.displayed(aspect) == value
        return Button {
            rate(selected ? nil : value, aspect: aspect)
        } label: {
            Image(systemName: symbol + (selected ? ".fill" : ""))
                .font(.title3)
                .foregroundStyle(selected ? (value == 1 ? Color.green : Color.red) : Color.onSurfaceVariant)
                .frame(minWidth: 44, minHeight: 44)
                .background(selected ? Color.onSurface.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(title): \(aspect == .brief ? (value == 1 ? "Good summary" : "Needs improvement") : label)"
        )
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "Tap to undo your rating" : "Save this rating to your account")
        .accessibilityIdentifier("feedback.\(aspect.rawValue).\(value == 1 ? "up" : "down")")
    }

    private func rate(_ value: Int?, aspect: PilotFeedbackAspect) {
        do {
            try model.set(value: value, aspect: aspect, date: date)
            actionError = nil
            Task { await model.synchronize() }
        } catch {
            actionError = "Couldn’t save this rating on your device. Please try your choice again."
        }
    }
}
