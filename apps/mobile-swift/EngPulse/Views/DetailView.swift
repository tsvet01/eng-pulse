import SwiftUI

// MARK: - Feedback Keys (centralized)

enum FeedbackKeys {
    static func selection(_ url: String) -> String { "feedback_selection_\(url)" }
    static func summary(_ url: String) -> String { "feedback_summary_\(url)" }
}

// MARK: - FeedbackWidget

struct FeedbackWidget: View {
    let summaryUrl: String
    let promptVersion: String?
    @State private var selectionFeedback: String
    @State private var summaryFeedback: String

    init(summaryUrl: String, promptVersion: String?) {
        self.summaryUrl = summaryUrl
        self.promptVersion = promptVersion
        _selectionFeedback = State(initialValue: UserDefaults.standard.string(forKey: FeedbackKeys.selection(summaryUrl)) ?? "")
        _summaryFeedback = State(initialValue: UserDefaults.standard.string(forKey: FeedbackKeys.summary(summaryUrl)) ?? "")
    }

    var body: some View {
        VStack(spacing: 16) {
            feedbackRow(label: "Article Pick", current: selectionFeedback) { type in rate(aspect: "selection", type: type) }
            feedbackRow(label: "Summary Quality", current: summaryFeedback) { type in rate(aspect: "summary", type: type) }
        }
        .padding(DesignTokens.cardPadding)
        .background(Color.container)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
    }

    @ViewBuilder
    private func feedbackRow(label: String, current: String, onRate: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.onSurface)
            Spacer()
            HStack(spacing: 12) {
                Button { onRate("up") } label: {
                    Image(systemName: current == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.title3)
                        .foregroundColor(current == "up" ? .green : .onSurfaceVariant)
                }
                Button { onRate("down") } label: {
                    Image(systemName: current == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.title3)
                        .foregroundColor(current == "down" ? .red : .onSurfaceVariant)
                }
            }
        }
    }

    private func rate(aspect: String, type: String) {
        let current = aspect == "selection" ? selectionFeedback : summaryFeedback
        let newValue = current == type ? "" : type
        if aspect == "selection" { selectionFeedback = newValue }
        else { summaryFeedback = newValue }
        let key = aspect == "selection" ? FeedbackKeys.selection(summaryUrl) : FeedbackKeys.summary(summaryUrl)
        UserDefaults.standard.set(newValue, forKey: key)
        let val: String? = newValue.isEmpty ? nil : newValue
        Task {
            await FeedbackService.shared.submitFeedback(
                summaryURL: summaryUrl,
                selectionFeedback: aspect == "selection" ? val : nil,
                summaryFeedback: aspect == "summary" ? val : nil,
                promptVersion: promptVersion
            )
        }
    }
}

// MARK: - ArticleNavigation

struct ArticleNavigation: View {
    let allSummaries: [Summary]
    let currentIndex: Int

    var body: some View {
        if allSummaries.count > 1 {
            HStack {
                if currentIndex > 0 {
                    NavigationLink(value: allSummaries[currentIndex - 1]) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.caption)
                            Text(allSummaries[currentIndex - 1].title).font(.caption).lineLimit(1)
                        }
                        .foregroundColor(.onSurfaceVariant)
                    }
                }
                Spacer()
                if currentIndex < allSummaries.count - 1 {
                    NavigationLink(value: allSummaries[currentIndex + 1]) {
                        HStack(spacing: 4) {
                            Text(allSummaries[currentIndex + 1].title).font(.caption).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .foregroundColor(.onSurfaceVariant)
                    }
                }
            }
            .padding(DesignTokens.cardPadding)
        }
    }
}

// MARK: - DetailView

struct DetailView: View {
    let summary: Summary
    let allSummaries: [Summary]
    let currentIndex: Int
    let cacheService: CacheService?

    @EnvironmentObject private var ttsService: TTSService
    @Environment(\.openURL) private var openURL
    @State private var fullContent: String?
    @State private var isLoadingContent = false
    @State private var loadingError: String?
    @State private var showInfo = false
    @State private var loadTask: Task<Void, Never>?
    @State private var insightBrief: InsightBrief?
    @State private var savedPosition: TimeInterval?

    init(summary: Summary, allSummaries: [Summary] = [], cacheService: CacheService? = nil) {
        self.summary = summary
        self.allSummaries = allSummaries
        self.currentIndex = allSummaries.firstIndex(of: summary) ?? 0
        self.cacheService = cacheService
    }

    // MARK: - TTS State

    private var isPlaying: Bool {
        ttsService.state == .playing && ttsService.currentArticleUrl == summary.url
    }

    private var isPaused: Bool {
        ttsService.state == .paused && ttsService.currentArticleUrl == summary.url
    }

    private var isLoadingTTS: Bool {
        ttsService.state == .loading && ttsService.currentArticleUrl == summary.url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Metadata badges
                metadataBadges

                if isLoadingContent {
                    loadingSection
                } else if let error = loadingError {
                    errorSection(error)
                } else if let content = fullContent {
                    fullContentSection(content)
                }

                if fullContent != nil || loadingError != nil {
                    FeedbackWidget(summaryUrl: summary.url, promptVersion: summary.promptVersion)
                        .padding(.top, DesignTokens.sectionSpacing)

                    ArticleNavigation(allSummaries: allSummaries, currentIndex: currentIndex)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .background(Color.surface)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let error = ttsService.errorMessage {
                    TTSErrorBanner(
                        message: error,
                        onDismiss: { ttsService.stop() }
                    )
                }
                if ttsService.currentArticleUrl == summary.url {
                    TTSPlayerBarView(
                        progress: ttsService.progress,
                        isPlaying: isPlaying,
                        isPaused: isPaused,
                        isLoading: isLoadingTTS,
                        title: summary.title,
                        currentTime: ttsService.currentTimeFormatted,
                        duration: ttsService.durationFormatted,
                        onToggle: { toggleTTS() },
                        onStop: { ttsService.stop() },
                        onSkipBack: { ttsService.skipBackward() },
                        onSkipForward: { ttsService.skipForward() }
                    )
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showInfo) { infoSheet }
        .task {
            loadTask = Task { await loadFullContent() }
            savedPosition = ttsService.getSavedPosition(for: summary.url)
            await loadTask?.value
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    // MARK: - Metadata Badges

    private var metadataBadges: some View {
        HStack(spacing: 8) {
            if let model = summary.model {
                Label(model, systemImage: "sparkles")
                    .font(.caption2).fontWeight(.medium)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
            Text(summary.source)
                .font(.caption2).foregroundColor(.onSurfaceVariant)
            if let score = summary.evalScore {
                Label(String(format: "%.0f%%", score * 100), systemImage: "chart.bar.fill")
                    .font(.caption2).fontWeight(.medium)
                    .foregroundColor(.tertiaryAccent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.tertiaryAccent.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Content Loading

    private func loadFullContent() async {
        loadingError = nil

        // Phase 1: Show cached content instantly
        if let cacheService = cacheService,
           let cached = await cacheService.getCachedContent(for: summary.url) {
            fullContent = cached
            if summary.isInsightBrief,
               let jsonData = cached.data(using: .utf8),
               let brief = try? JSONDecoder().decode(InsightBrief.self, from: jsonData) {
                insightBrief = brief
            }
            isLoadingContent = false
            return
        }

        // Phase 2: Fetch fresh from network
        if fullContent == nil { isLoadingContent = true }
        defer { isLoadingContent = false }

        guard let url = URL(string: summary.url) else {
            if fullContent == nil { loadingError = "Invalid URL" }
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            if let content = String(data: data, encoding: .utf8) {
                fullContent = content
                if summary.isInsightBrief,
                   let jsonData = content.data(using: .utf8),
                   let brief = try? JSONDecoder().decode(InsightBrief.self, from: jsonData) {
                    insightBrief = brief
                }
                if let cacheService = cacheService {
                    try? await cacheService.cacheContent(content, for: summary.url)
                }
            } else if fullContent == nil {
                loadingError = "Could not decode content"
            }
        } catch {
            if fullContent == nil {
                if let error = error as? URLError, error.code == .timedOut {
                    loadingError = "Request timed out. Please try again."
                } else {
                    loadingError = "Unable to load content. Check your connection."
                }
            }
        }
    }

    private func toggleTTS() {
        guard let content = fullContent else { return }
        ttsService.togglePlayPause(content, articleUrl: summary.url, articleTitle: summary.title)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Sections

    private func fullContentSection(_ content: String) -> some View {
        Group {
            if let brief = insightBrief {
                InsightBriefView(brief: brief)
            } else if summary.isInsightBrief {
                // V3 article but JSON decode failed — show a fallback
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.onSurfaceVariant)
                    Text("Unable to parse this brief")
                        .font(.subheadline)
                        .foregroundColor(.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                MarkdownContentView(content: content)
                    .padding(.top, 4)
            }
        }
    }

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Source", value: summary.source)
                    LabeledContent("Date", value: summary.date)
                    LabeledContent("Summarized by", value: summary.modelDisplayName)
                    LabeledContent("Prompt", value: summary.isBeta ? "Beta (v2)" : "Production")
                    if let selectedBy = summary.selectedBy {
                        LabeledContent("Selected by", value: selectedBy)
                    }
                    if let score = summary.evalScore {
                        let displayScore = max(score * 5, 1.0)
                        Label(
                            String(format: "%.1f/5", displayScore),
                            systemImage: "star.fill"
                        )
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                    }
                }

                if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                    Section {
                        Button {
                            openURL(url)
                        } label: {
                            Label("See Original", systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showInfo = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var loadingSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .accessibilityLabel("Loading")
            Text("Loading full summary...")
                .font(.subheadline)
                .foregroundColor(.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }

    private func errorSection(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text("Unable to load summary")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("Check your internet connection and try again.")
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Button {
                loadTask?.cancel()
                loadTask = Task { await loadFullContent() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if let pos = savedPosition, (ttsService.state == .stopped || ttsService.currentArticleUrl != summary.url) {
                    Button {
                        toggleTTS()
                        savedPosition = nil
                    } label: {
                        Text("Resume \(formatTime(pos))")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)
                    }
                }

                Button {
                    toggleTTS()
                } label: {
                    if isLoadingTTS {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : (isPaused ? "play.fill" : "speaker.wave.2.fill"))
                    }
                }
                .disabled(fullContent == nil || isLoadingTTS)
                .accessibilityLabel(isLoadingTTS ? "Generating audio" : (isPlaying ? "Pause audio" : (isPaused ? "Resume audio" : "Listen to summary")))

                Button { showInfo = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Article info")

                if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share article")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        DetailView(summary: .preview, allSummaries: Summary.previewList)
    }
    .environmentObject(TTSService())
}
