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
                VStack(alignment: .leading, spacing: 12) {
                    // Full Content (loading, error, or content)
                    if isLoadingContent {
                        loadingSection
                    } else if let error = loadingError {
                        errorSection(error)
                    } else if let content = fullContent {
                        fullContentSection(content)
                    }

                    // Footer with metadata and original link
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(summary.source) • \(summary.date) • \(summary.modelDisplayName)")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                            Button {
                                openURL(url)
                            } label: {
                                Text("See Original")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }

                    // Bottom padding for player bar
                    if ttsService.state != .stopped && ttsService.currentArticleUrl == summary.url {
                        Color.clear.frame(height: 60)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // TTS Player Bar
            if ttsService.state != .stopped && ttsService.currentArticleUrl == summary.url {
                ttsPlayerBar
            }
        }
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

    private func fullContentSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            markdownView(content)
                .font(.body)
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

    private func markdownView(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(content.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("# ") {
                    Text(trimmed.dropFirst(2))
                        .font(.title3)
                        .fontWeight(.bold)
                } else if trimmed.hasPrefix("## ") {
                    Text(trimmed.dropFirst(3))
                        .font(.headline)
                        .fontWeight(.semibold)
                } else if trimmed.hasPrefix("### ") {
                    Text(trimmed.dropFirst(4))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    // List items
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(trimmed.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            let cleanLine = line.trimmingCharacters(in: .whitespaces)
                            if cleanLine.hasPrefix("- ") || cleanLine.hasPrefix("* ") {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    inlineMarkdown(String(cleanLine.dropFirst(2)))
                                }
                            } else if !cleanLine.isEmpty {
                                inlineMarkdown(cleanLine)
                            }
                        }
                    }
                } else if trimmed.hasPrefix(">") {
                    // Blockquote
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.4))
                            .frame(width: 3)
                        inlineMarkdown(trimmed.replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression))
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    .padding(.vertical, 4)
                } else if trimmed.contains("|") && trimmed.contains("\n") {
                    // Table
                    tableView(trimmed)
                } else if trimmed.hasPrefix("```") {
                    // Code block
                    let code = trimmed
                        .replacingOccurrences(of: "^```\\w*\\n?", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\\n?```$", with: "", options: .regularExpression)
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                } else if !trimmed.isEmpty {
                    inlineMarkdown(trimmed)
                }
            }
        }
    }

    private func tableView(_ content: String) -> some View {
        let rows = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let dataRows = rows.filter { !$0.contains("---") && !$0.contains(":-") }

        return VStack(spacing: 0) {
            ForEach(Array(dataRows.enumerated()), id: \.offset) { rowIndex, row in
                let cells = row.components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                HStack(spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowIndex == 0 ? Color(.systemGray5) : Color(.systemGray6).opacity(0.5))
                            .fontWeight(rowIndex == 0 ? .semibold : .regular)
                    }
                }
                if rowIndex < dataRows.count - 1 {
                    Divider()
                }
            }
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
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
