import SwiftUI

struct DetailView: View {
    private enum Layout {
        static let playerBarHeight: CGFloat = 60
    }

    @StateObject private var viewModel: DetailViewModel
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var ttsService: TTSService
    @State private var showInfo = false

    init(summary: Summary, ttsService: TTSService, cacheService: CacheService? = nil) {
        _viewModel = StateObject(wrappedValue: DetailViewModel(summary: summary, ttsService: ttsService, cacheService: cacheService))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.isLoadingContent {
                        loadingSection
                    } else if let error = viewModel.loadingError {
                        errorSection(error)
                    } else if let content = viewModel.fullContent {
                        fullContentSection(content)
                    }

                    if ttsService.state != .stopped && ttsService.currentArticleUrl == viewModel.summary.url {
                        Color.clear.frame(height: Layout.playerBarHeight)
                    }
                }
                .padding(.horizontal, 20) // Increased horizontal padding for readability
                .padding(.top, 8)
            }

            if ttsService.state != .stopped && ttsService.currentArticleUrl == viewModel.summary.url {
                TTSPlayerBarView(
                    progress: ttsService.progress,
                    isPlaying: viewModel.isPlaying,
                    isPaused: viewModel.isPaused,
                    isLoading: viewModel.isLoadingTTS,
                    title: viewModel.summary.title,
                    onToggle: { viewModel.toggleTTS() },
                    onStop: { ttsService.stop() }
                )
            }

            if let error = ttsService.errorMessage {
                TTSErrorBanner(
                    message: error,
                    onDismiss: { ttsService.stop() }
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showInfo) { infoSheet }
        .task {
            await viewModel.loadFullContent()
        }
    }

    // MARK: - Sections

    private func fullContentSection(_ content: String) -> some View {
        MarkdownContentView(content: content)
            .padding(.top, 8)
    }

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Source", value: viewModel.summary.source)
                    LabeledContent("Date", value: viewModel.summary.date)
                    LabeledContent("Model", value: viewModel.summary.modelDisplayName)
                }

                if let originalUrl = viewModel.summary.originalUrl, let url = URL(string: originalUrl) {
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
                    await viewModel.loadFullContent()
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if viewModel.fullContent != nil {
                    Button {
                        viewModel.toggleTTS()
                    } label: {
                        if viewModel.isLoadingTTS {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : (viewModel.isPaused ? "play.fill" : "speaker.wave.2.fill"))
                        }
                    }
                    .disabled(viewModel.isLoadingTTS)
                    .accessibilityLabel(viewModel.isLoadingTTS ? "Generating audio" : (viewModel.isPlaying ? "Pause audio" : (viewModel.isPaused ? "Resume audio" : "Listen to summary")))
                }

                Button { showInfo = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Article info")

                if let originalUrl = viewModel.summary.originalUrl, let url = URL(string: originalUrl) {
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
        DetailView(summary: .preview, ttsService: TTSService(), cacheService: nil)
    }
}
