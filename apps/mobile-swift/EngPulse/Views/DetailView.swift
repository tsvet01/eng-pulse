import SwiftUI

// MARK: - Feedback Keys (centralized)

enum FeedbackKeys {
    static func selection(_ url: String) -> String { "feedback_selection_\(url)" }
    static func summary(_ url: String) -> String { "feedback_summary_\(url)" }
}

// MARK: - FeedbackWidget

struct FeedbackWidget: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Was this useful?")
                .font(.headline)
                .foregroundStyle(Color.onSurface)
                .padding(.bottom, 4)
            feedbackRow(label: "Article Pick", current: selectionFeedback) { type in rate(aspect: "selection", type: type) }
            feedbackRow(label: "Summary Quality", current: summaryFeedback) { type in rate(aspect: "summary", type: type) }
        }
        .padding(DesignTokens.cardPadding)
        .background(Color.container)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
    }

    @ViewBuilder
    private func feedbackRow(label: String, current: String, onRate: @escaping (String) -> Void) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
        layout {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.onSurface)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            HStack(spacing: 12) {
                Button { onRate("up") } label: {
                    Image(systemName: current == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.title3)
                        .foregroundColor(current == "up" ? .accentColor : .onSurfaceVariant)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(current == "up" ? Color.accentColor.opacity(0.1) : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Helpful \(label)")
                .accessibilityAddTraits(current == "up" ? [.isSelected] : [])
                Button { onRate("down") } label: {
                    Image(systemName: current == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.title3)
                        .foregroundColor(current == "down" ? .accentColor : .onSurfaceVariant)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(current == "down" ? Color.accentColor.opacity(0.1) : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unhelpful \(label)")
                .accessibilityAddTraits(current == "down" ? [.isSelected] : [])
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
    let feedback: PilotFeedbackModel?

    @EnvironmentObject private var ttsService: TTSService
    @Environment(\.openURL) private var openURL
    @State private var fullContent: String?
    @State private var isLoadingContent = false
    @State private var loadingError: String?
    @State private var showInfo = false
    @State private var loadTask: Task<Void, Never>?
    @State private var insightBrief: InsightBrief?
    @State private var savedPosition: TimeInterval?

    init(summary: Summary, allSummaries: [Summary] = [], cacheService: CacheService? = nil, feedback: PilotFeedbackModel? = nil) {
        self.summary = summary
        self.allSummaries = allSummaries
        self.currentIndex = allSummaries.firstIndex(of: summary) ?? 0
        self.cacheService = cacheService
        self.feedback = feedback
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

    /// Another article's session is still running on this screen.
    private var anotherArticleIsActive: Bool {
        ttsService.state != .stopped && ttsService.currentArticleUrl != summary.url
    }

    private var playbackChrome: PlaybackChrome? {
        PlaybackChrome.forArticle(
            onScreenURL: summary.url,
            onScreenTitle: summary.title,
            playingURL: ttsService.currentArticleUrl,
            playingTitle: ttsService.currentArticleTitle,
            state: ttsService.state,
            canStartOnScreenArticle: fullContent != nil
        )
    }

    private var listenAccessibilityLabel: String {
        if isLoadingTTS { return "Generating audio" }
        if isPlaying { return "Pause audio" }
        if isPaused { return "Resume audio" }
        if anotherArticleIsActive { return "Play this article" }
        return "Listen to summary"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                articleHeader

                if isLoadingContent {
                    loadingSection
                } else if let error = loadingError {
                    errorSection(error)
                } else if let content = fullContent {
                    fullContentSection(content)
                }

                if fullContent != nil {
                    if let feedback {
                        PilotFeedbackView(model: feedback, date: summary.date)
                            .padding(.top, DesignTokens.sectionSpacing)
                    }
                    if PilotBuild.allowsLegacyServices {
                        FeedbackWidget(summaryUrl: summary.url, promptVersion: summary.promptVersion)
                            .padding(.top, DesignTokens.sectionSpacing)
                    }
                }

                if fullContent != nil || loadingError != nil {
                    ArticleNavigation(allSummaries: allSummaries, currentIndex: currentIndex)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
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
                if let chrome = playbackChrome {
                    ActivePlaybackBar(
                        tts: ttsService,
                        chrome: chrome,
                        onToggle: {
                            if ttsService.state == .stopped {
                                toggleTTS()
                            } else {
                                ttsService.togglePauseResume()
                            }
                        },
                        onSecondary: { toggleTTS() }
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

    // MARK: - Article Header

    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Label(summary.source, systemImage: "doc.text")
                    Text(summary.displayDate, format: .dateTime.month(.abbreviated).day().year())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(summary.source, systemImage: "doc.text")
                    Text(summary.displayDate, format: .dateTime.month(.abbreviated).day().year())
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.onSurfaceVariant)

            // Legacy Markdown already supplies its own headline. Structured
            // briefs contain sections only, so give them an article heading.
            if summary.isInsightBrief || fullContent == nil {
                Text(summary.title)
                    .font(.system(.largeTitle, design: .serif, weight: .bold))
                    .foregroundStyle(Color.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { articleActions }
                VStack(alignment: .leading, spacing: 8) { articleActions }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var articleActions: some View {
        Button(action: toggleTTS) {
            Label(isLoadingTTS ? "Preparing audio…" : (isPlaying ? "Pause" : (isPaused ? "Resume" : (anotherArticleIsActive ? "Play this article" : "Listen"))),
                  systemImage: isPlaying ? "pause.fill" : "headphones")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(fullContent == nil || isLoadingTTS)
        .opacity(fullContent == nil ? 0.5 : 1)
        .accessibilityLabel(listenAccessibilityLabel)

        if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
            Link(destination: url) {
                Label("Read original", systemImage: "arrow.up.right")
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
        }
    }

    // MARK: - Content Loading

    private func setContent(_ content: String) {
        fullContent = content
        if summary.isInsightBrief, let brief = InsightBrief.decode(from: content) {
            insightBrief = brief
        }
    }

    private func loadFullContent() async {
        loadingError = nil
        let cache = cacheService ?? CacheService()

        if fullContent == nil { isLoadingContent = true }
        defer { isLoadingContent = false }

        do {
            let content = try await ArticleContentLoader.load(summary, cacheService: cache)
            guard !Task.isCancelled else { return }
            setContent(content)
        } catch {
            guard !Task.isCancelled, fullContent == nil else { return }
            if let error = error as? URLError, error.code == .timedOut {
                loadingError = "Request timed out. Please try again."
            } else if let error = error as? ArticleContentLoader.LoadError {
                loadingError = error.localizedDescription
            } else {
                loadingError = "Unable to load content. Check your connection."
            }
        }
    }

    private func toggleTTS() {
        guard let content = fullContent else { return }
        // Passed as an autoclosure — the speech text (and its JSON decode for
        // insight briefs) is only built when playback actually starts, not on
        // pause/resume taps.
        ttsService.togglePlayPause(
            SpeechTextBuilder.speechText(for: summary, content: content),
            articleUrl: summary.url,
            articleTitle: summary.title
        )
        // Starting playback consumes the persisted resume position, so drop the
        // cached offer — otherwise a stale "Resume m:ss" reappears after finish.
        savedPosition = nil
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
                    LabeledContent("Format", value: "Insight Brief")
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
            Text(error)
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
            HStack(spacing: 0) {
                if let pos = savedPosition, (ttsService.state == .stopped || ttsService.currentArticleUrl != summary.url) {
                    Button {
                        toggleTTS()
                    } label: {
                        Text("Resume \(pos.mmss)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)
                    }
                }

                Button { showInfo = true } label: {
                    Image(systemName: "info.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Article info")

                if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(minWidth: 44, minHeight: 44)
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
