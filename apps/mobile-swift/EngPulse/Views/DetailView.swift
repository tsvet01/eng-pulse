import SwiftUI

struct DetailView: View {
    private enum Layout {
        static let playerBarHeight: CGFloat = 60
        static let buttonVerticalPadding: CGFloat = 14
        static let playerControlPadding: CGFloat = 10
        static let progressBarHeight: CGFloat = 2
        static let buttonCornerRadius: CGFloat = 12
    }

    @StateObject private var viewModel: DetailViewModel
    @Environment(\.openURL) private var openURL
    @ObservedObject private var ttsService = TTSService.shared

    init(summary: Summary) {
        _viewModel = StateObject(wrappedValue: DetailViewModel(summary: summary))
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

                    Divider()
                    footerSection

                    if ttsService.state != .stopped && ttsService.currentArticleUrl == viewModel.summary.url {
                        Color.clear.frame(height: Layout.playerBarHeight)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            if ttsService.state != .stopped && ttsService.currentArticleUrl == viewModel.summary.url {
                ttsPlayerBar
            }

            if let error = ttsService.errorMessage {
                ttsErrorBanner(error)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            await viewModel.loadFullContent()
        }
    }

    // MARK: - Sections

    private func fullContentSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            listenButton
            MarkdownContentView(content: content)
                .font(.body)
        }
        .padding(.top, 8)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(viewModel.summary.source) • \(viewModel.summary.date) • \(viewModel.summary.modelDisplayName)")
                .font(.caption2)
                .foregroundColor(.secondary)

            if let originalUrl = viewModel.summary.originalUrl, let url = URL(string: originalUrl) {
                Button {
                    openURL(url)
                } label: {
                    Text("See Original")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    private var listenButton: some View {
        Button {
            viewModel.toggleTTS()
        } label: {
            HStack(spacing: 12) {
                if viewModel.isLoadingTTS {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: viewModel.isPlaying ? "stop.fill" : (viewModel.isPaused ? "play.fill" : "headphones"))
                        .font(.title3)
                }

                Text(viewModel.isLoadingTTS ? "Generating Audio..." : (viewModel.isPlaying ? "Stop Listening" : (viewModel.isPaused ? "Resume" : "Listen to Summary")))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.buttonVerticalPadding)
            .background(
                LinearGradient(
                    colors: viewModel.isPlaying ? [.red, .red.opacity(0.8)] : [.accentColor, .accentColor.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(Layout.buttonCornerRadius)
        }
        .disabled(viewModel.isLoadingTTS)
        .accessibilityLabel(viewModel.isLoadingTTS ? "Generating audio, please wait" : (viewModel.isPlaying ? "Stop listening" : (viewModel.isPaused ? "Resume listening" : "Listen to summary")))
        .accessibilityHint(viewModel.isPlaying ? "Stops audio playback" : (viewModel.isPaused ? "Continues from where you left off" : "Plays the summary as audio"))
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

    // MARK: - TTS Player Bar

    private var ttsPlayerBar: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * ttsService.progress)
            }
            .frame(height: Layout.progressBarHeight)

            HStack(spacing: 16) {
                Button {
                    viewModel.toggleTTS()
                } label: {
                    if viewModel.isLoadingTTS {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                }
                .disabled(viewModel.isLoadingTTS)
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.summary.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(viewModel.isLoadingTTS ? "Generating audio..." : (viewModel.isPlaying ? "Playing..." : "Paused"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(viewModel.summary.title), \(viewModel.isLoadingTTS ? "generating audio" : (viewModel.isPlaying ? "playing" : "paused"))")
                .accessibilityValue("\(Int(ttsService.progress * 100)) percent complete")

                Spacer()

                Button {
                    ttsService.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("Stop playback")
            }
            .padding(.horizontal)
            .padding(.vertical, Layout.playerControlPadding)
        }
        .background(.ultraThinMaterial)
    }

    private func ttsErrorBanner(_ error: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.caption)
                Spacer()
                Button {
                    ttsService.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
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
        DetailView(summary: .preview)
    }
}
