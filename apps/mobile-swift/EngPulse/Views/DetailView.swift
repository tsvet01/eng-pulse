import SwiftUI

struct DetailView: View {
    let summary: Summary
    @State private var fullContent: String?
    @State private var isLoadingContent = false
    @State private var loadingError: String?
    @Environment(\.openURL) private var openURL
    @ObservedObject private var ttsService = TTSService.shared

    private var isPlaying: Bool {
        ttsService.state == .playing && ttsService.currentArticleUrl == summary.url
    }

    private var isPaused: Bool {
        ttsService.state == .paused && ttsService.currentArticleUrl == summary.url
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    headerSection

                    Divider()

                    // Full Content (loading, error, or content)
                    if isLoadingContent {
                        loadingSection
                    } else if let error = loadingError {
                        errorSection(error)
                    } else if let content = fullContent {
                        fullContentSection(content)
                    }

                    // See Original link at bottom
                    if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                        Divider()
                        Button {
                            openURL(url)
                        } label: {
                            HStack {
                                Text("See Original")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }

                    // Bottom padding for player bar
                    if ttsService.state != .stopped && ttsService.currentArticleUrl == summary.url {
                        Color.clear.frame(height: 60)
                    }
                }
                .padding()
            }

            // TTS Player Bar
            if ttsService.state != .stopped && ttsService.currentArticleUrl == summary.url {
                ttsPlayerBar
            }
        }
        .navigationTitle("Article")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    // Listen button
                    if fullContent != nil {
                        Button {
                            toggleTTS()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : (isPaused ? "play.fill" : "speaker.wave.2.fill"))
                        }
                    }

                    // Share button
                    if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task {
            await loadFullContent()
        }
        .onDisappear {
            // Don't stop TTS when navigating away - let it continue
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(summary.source) • \(summary.date)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(summary.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Spacer()
            Text(summary.modelDisplayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(4)
        }
    }

    private func fullContentSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full Summary")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            markdownText(content)
                .font(.body)
                .lineSpacing(4)
        }
        .padding(.top, 8)
    }

    private var loadingSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading full summary...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func errorSection(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Failed to load content")
                .font(.subheadline)
                .fontWeight(.medium)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    await loadFullContent()
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func markdownText(_ content: String) -> Text {
        if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(content)
    }

    // MARK: - TTS Player Bar

    private var ttsPlayerBar: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * ttsService.progress)
            }
            .frame(height: 2)

            HStack(spacing: 16) {
                // Play/Pause button
                Button {
                    toggleTTS()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }

                // Title
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(isPlaying ? "Playing..." : "Paused")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Stop button
                Button {
                    ttsService.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func toggleTTS() {
        guard let content = fullContent else { return }
        ttsService.togglePlayPause(content, articleUrl: summary.url)
    }

    private func loadFullContent() async {
        isLoadingContent = true
        loadingError = nil
        defer { isLoadingContent = false }

        guard let url = URL(string: summary.url) else {
            loadingError = "Invalid URL"
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let content = String(data: data, encoding: .utf8) {
                fullContent = content
            } else {
                loadingError = "Could not decode content"
            }
        } catch {
            loadingError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        DetailView(summary: .preview)
    }
}
