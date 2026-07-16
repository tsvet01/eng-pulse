import Foundation

// MARK: - Speech Text Builder
/// Builds the text that gets spoken for an article. Insight-brief articles
/// store JSON, so their fields are composed into readable prose instead of
/// speaking the raw payload. Plain markdown passes through (TextCleaner
/// strips markdown later in the TTS pipeline).
struct SpeechTextBuilder {
    static func speechText(for summary: Summary, content: String) -> String {
        guard summary.isInsightBrief,
              let data = content.data(using: .utf8),
              let brief = try? JSONDecoder().decode(InsightBrief.self, from: data) else {
            return content
        }

        var parts = [brief.keyIdea, brief.whyItMatters]
        if let change = brief.whatToChange, !change.isEmpty {
            parts.append(change)
        }
        parts.append(brief.deepDive)
        return parts.joined(separator: "\n\n")
    }
}
