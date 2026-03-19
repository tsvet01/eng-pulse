import SwiftUI

struct DetailView: View {
    let summary: Summary
    let cacheService: CacheService?

    @EnvironmentObject private var ttsService: TTSService
    @Environment(\.openURL) private var openURL
    @State private var fullContent: String?
    @State private var isLoadingContent = false
    @State private var loadingError: String?
    @State private var showInfo = false
    @State private var selectionFeedback: String = ""
    @State private var summaryFeedback: String = ""

    init(summary: Summary, cacheService: CacheService? = nil) {
        self.summary = summary
        self.cacheService = cacheService
        _selectionFeedback = State(initialValue: UserDefaults.standard.string(forKey: Self.feedbackKey("selection", summary.url)) ?? "")
        _summaryFeedback = State(initialValue: UserDefaults.standard.string(forKey: Self.feedbackKey("summary", summary.url)) ?? "")
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
                if isLoadingContent {
                    loadingSection
                } else if let error = loadingError {
                    errorSection(error)
                } else if let content = fullContent {
                    fullContentSection(content)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let error = ttsService.errorMessage {
                    TTSErrorBanner(
                        message: error,
                        onDismiss: { ttsService.stop() }
                    )
                }
                if ttsService.state != .stopped && ttsService.currentArticleUrl == summary.url {
                    TTSPlayerBarView(
                        progress: ttsService.progress,
                        isPlaying: isPlaying,
                        isPaused: isPaused,
                        isLoading: isLoadingTTS,
                        title: summary.title,
                        onToggle: { toggleTTS() },
                        onStop: { ttsService.stop() }
                    )
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showInfo) { infoSheet }
        .task {
            await loadFullContent()
        }
    }

    // MARK: - Content Loading

    private func loadFullContent() async {
        loadingError = nil

        // Phase 1: Show cached content instantly
        if let cacheService = cacheService,
           let cached = await cacheService.getCachedContent(for: summary.url) {
            fullContent = cached
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
        ttsService.togglePlayPause(content, articleUrl: summary.url)
    }

    // MARK: - Sections

    private func fullContentSection(_ content: String) -> some View {
        MarkdownContentView(content: content)
            .padding(.top, 4)
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
                        .foregroundColor(.secondary)
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
        .presentationDetents([.medium])
    }

    private var loadingSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .accessibilityLabel("Loading")
            Text("Loading full summary...")
                .font(.subheadline)
                .foregroundColor(.secondary)
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
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    await loadFullContent()
                }
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

    // MARK: - Aspect Feedback

    private static func feedbackKey(_ aspect: String, _ url: String) -> String {
        "feedback_\(aspect)_\(url)"
    }

    private func rateAspect(aspect: String, type: String) {
        let current = aspect == "selection" ? selectionFeedback : summaryFeedback
        let newValue = current == type ? "" : type

        if aspect == "selection" { selectionFeedback = newValue }
        else { summaryFeedback = newValue }
        UserDefaults.standard.set(newValue, forKey: Self.feedbackKey(aspect, summary.url))

        // Send "clear" when toggling off so server removes the field
        let val = newValue.isEmpty ? "clear" : newValue
        Task {
            await FeedbackService.shared.submitFeedback(
                summaryURL: summary.url,
                selectionFeedback: aspect == "selection" ? val : nil,
                summaryFeedback: aspect == "summary" ? val : nil,
                promptVersion: summary.promptVersion
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if fullContent != nil {
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
                    .disabled(isLoadingTTS)
                    .accessibilityLabel(isLoadingTTS ? "Generating audio" : (isPlaying ? "Pause audio" : (isPaused ? "Resume audio" : "Listen to summary")))
                }

                Menu {
                    Section("Article Pick") {
                        Button { rateAspect(aspect: "selection", type: "up") } label: {
                            Label(selectionFeedback == "up" ? "Liked (tap to clear)" : "Good pick",
                                  systemImage: selectionFeedback == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }
                        Button { rateAspect(aspect: "selection", type: "down") } label: {
                            Label(selectionFeedback == "down" ? "Disliked (tap to clear)" : "Not interesting",
                                  systemImage: selectionFeedback == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        }
                    }
                    Section("Summary Quality") {
                        Button { rateAspect(aspect: "summary", type: "up") } label: {
                            Label(summaryFeedback == "up" ? "Liked (tap to clear)" : "Well written",
                                  systemImage: summaryFeedback == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }
                        Button { rateAspect(aspect: "summary", type: "down") } label: {
                            Label(summaryFeedback == "down" ? "Disliked (tap to clear)" : "Could be better",
                                  systemImage: summaryFeedback == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        }
                    }
                } label: {
                    let hasAny = !selectionFeedback.isEmpty || !summaryFeedback.isEmpty
                    Image(systemName: hasAny ? "hand.thumbsup.circle.fill" : "hand.thumbsup.circle")
                        .foregroundColor(hasAny ? .green : .secondary)
                }
                .accessibilityLabel("Rate this article")

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
        DetailView(summary: .preview)
    }
    .environmentObject(TTSService())
}
