import SwiftUI

struct DetailView: View {
    let summary: Summary
    @State private var fullContent: String?
    @State private var isLoadingContent = false
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

                    // Summary
                    summarySection

                    Divider()

                    // Actions
                    actionsSection

                    // Full Content (if loaded)
                    if let content = fullContent {
                        fullContentSection(content)
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

    private var summarySection: some View {
        Text(summary.summarySnippet ?? "No preview available")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineSpacing(4)
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                Button {
                    openURL(url)
                } label: {
                    Label("Read Original Article", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                if let url = URL(string: summary.url) {
                    openURL(url)
                }
            } label: {
                Label("View Full Summary", systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
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
        defer { isLoadingContent = false }

        guard let url = URL(string: summary.url) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let content = String(data: data, encoding: .utf8) {
                fullContent = content
            }
        } catch {
            print("Failed to load content: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        DetailView(summary: .preview)
    }
}
