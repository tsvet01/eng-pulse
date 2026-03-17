import Foundation

// MARK: - Summary Model
struct Summary: Identifiable, Codable, Equatable, Hashable {
    // Use URL as unique ID since it's guaranteed unique per summary
    var id: String { url }
    let date: String
    let url: String
    let title: String
    let summarySnippet: String?
    let originalUrl: String?
    let model: String?
    let selectedBy: String?
    let promptVersion: String?
    let evalScore: Double?

    enum CodingKeys: String, CodingKey {
        case date, url, title
        case summarySnippet = "summary_snippet"
        case originalUrl = "original_url"
        case model
        case selectedBy = "selected_by"
        case promptVersion = "prompt_version"
        case evalScore = "eval_score"
    }

    init(date: String, url: String, title: String, summarySnippet: String? = nil,
         originalUrl: String? = nil, model: String? = nil, selectedBy: String? = nil,
         promptVersion: String? = nil, evalScore: Double? = nil) {
        self.date = date
        self.url = url
        self.title = title
        self.summarySnippet = summarySnippet
        self.originalUrl = originalUrl
        self.model = model
        self.selectedBy = selectedBy
        self.promptVersion = promptVersion
        self.evalScore = evalScore
    }

    // Cached date formatter for performance
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // Computed properties for UI
    var displayDate: Date {
        Self.dateFormatter.date(from: date) ?? Date()
    }

    var source: String {
        guard let urlString = originalUrl,
              let url = URL(string: urlString),
              let host = url.host else {
            return "Unknown"
        }
        // Extract domain name without www
        return host.replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: ".").first?.capitalized ?? host
    }

    static let betaVersion = "v2"

    var isBeta: Bool { promptVersion == Self.betaVersion }

    /// Snippet with markdown syntax stripped for clean list display.
    var cleanSnippet: String? {
        guard let snippet = summarySnippet else { return nil }
        return snippet
            .replacingOccurrences(of: "#{1,6}\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\*\\*\\*(.*?)\\*\\*\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "__(.*?)__", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\*(.*?)\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "_(.*?)_", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "~~(.*?)~~", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "^[-*]\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var modelDisplayName: String {
        guard let model = model else { return "Unknown" }
        // Show full model ID (e.g. "claude-opus-4-6", "gemini-3.1-pro-preview")
        return model
    }

    var category: Category {
        // Infer category from title/content
        let titleLower = title.lowercased()
        if titleLower.contains("rust") || titleLower.contains("api") ||
           titleLower.contains("tcp") || titleLower.contains("dns") ||
           titleLower.contains("code") || titleLower.contains("wasm") {
            return .engineering
        }
        if titleLower.contains("ai") || titleLower.contains("llm") ||
           titleLower.contains("model") || titleLower.contains("agent") {
            return .ai
        }
        if titleLower.contains("architecture") || titleLower.contains("design") ||
           titleLower.contains("platform") {
            return .architecture
        }
        return .general
    }
}

// MARK: - Category
enum Category: String, Codable, CaseIterable {
    case engineering
    case ai
    case architecture
    case general

    var displayName: String {
        switch self {
        case .engineering: return "Engineering"
        case .ai: return "AI/ML"
        case .architecture: return "Architecture"
        case .general: return "General"
        }
    }

    var iconName: String {
        switch self {
        case .engineering: return "hammer.fill"
        case .ai: return "brain.head.profile"
        case .architecture: return "building.2.fill"
        case .general: return "doc.text.fill"
        }
    }
}

// MARK: - Preview Data
extension Summary {
    static let preview = Summary(
        date: "2025-12-27",
        url: "https://storage.googleapis.com/tsvet01-agent-brain/summaries/gemini/2025-12-27.md",
        title: "The 3 a.m. Call That Changed The Way I Design APIs",
        summarySnippet: "The guiding principle of reliable API design is simple...",
        originalUrl: "https://thenewstack.io/the-3-a-m-call-that-changed-the-way-i-design-apis/",
        model: "gemini-3.1-pro-preview",
        selectedBy: "gemini-3.1-pro-preview"
    )

    static let previewList: [Summary] = [
        .preview,
        Summary(
            date: "2025-12-26",
            url: "https://storage.googleapis.com/tsvet01-agent-brain/summaries/gemini/2025-12-26.md",
            title: "Package managers keep using Git as a database",
            summarySnippet: "Using Git as a database never works out...",
            originalUrl: "https://nesbitt.io/2025/12/24/package-managers-keep-using-git-as-a-database.html",
            model: "gemini-3.1-pro-preview",
            selectedBy: "gemini-3.1-pro-preview"
        )
    ]
}
