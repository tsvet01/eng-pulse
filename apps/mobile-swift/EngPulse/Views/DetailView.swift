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

    private var isLoadingTTS: Bool {
        ttsService.state == .loading && ttsService.currentArticleUrl == summary.url
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

            // TTS Error Banner
            if let error = ttsService.errorMessage {
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

                    // Share button
                    if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share article")
                    }
                }
            }
        }
        .task {
            await loadFullContent()
        }
    }

    // MARK: - Sections

    private func fullContentSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Listen button - prominent CTA
            listenButton

            // Content
            markdownView(content)
                .font(.body)
        }
        .padding(.top, 8)
    }

    private var listenButton: some View {
        Button {
            toggleTTS()
        } label: {
            HStack(spacing: 12) {
                if isLoadingTTS {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : (isPaused ? "play.fill" : "headphones"))
                        .font(.title3)
                }

                Text(isLoadingTTS ? "Generating Audio..." : (isPlaying ? "Stop Listening" : (isPaused ? "Resume" : "Listen to Summary")))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: isPlaying ? [.red, .red.opacity(0.8)] : [.accentColor, .accentColor.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(isLoadingTTS)
        .accessibilityLabel(isLoadingTTS ? "Generating audio, please wait" : (isPlaying ? "Stop listening" : (isPaused ? "Resume listening" : "Listen to summary")))
        .accessibilityHint(isPlaying ? "Stops audio playback" : (isPaused ? "Continues from where you left off" : "Plays the summary as audio"))
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

    private func markdownView(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(content.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("# ") {
                    inlineMarkdown(String(trimmed.dropFirst(2)))
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("## ") {
                    inlineMarkdown(String(trimmed.dropFirst(3)))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("### ") {
                    inlineMarkdown(String(trimmed.dropFirst(4)))
                        .font(.headline)
                        .fontWeight(.semibold)
                        .padding(.top, 4)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    // Unordered list items
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(trimmed.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            let cleanLine = line.trimmingCharacters(in: .whitespaces)
                            if cleanLine.hasPrefix("- ") || cleanLine.hasPrefix("* ") {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .foregroundColor(.accentColor)
                                        .fontWeight(.bold)
                                    inlineMarkdown(String(cleanLine.dropFirst(2)))
                                }
                                .padding(.leading, 4)
                            } else if !cleanLine.isEmpty {
                                inlineMarkdown(cleanLine)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                } else if trimmed.first?.isNumber == true && trimmed.contains(". ") {
                    // Numbered list items
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(trimmed.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            let cleanLine = line.trimmingCharacters(in: .whitespaces)
                            if let dotIndex = cleanLine.firstIndex(of: "."),
                               cleanLine[cleanLine.startIndex..<dotIndex].allSatisfy({ $0.isNumber }) {
                                let textStart = cleanLine.index(after: dotIndex)
                                let text = String(cleanLine[textStart...]).trimmingCharacters(in: .whitespaces)
                                let number = String(cleanLine[..<dotIndex])
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(number).")
                                        .foregroundColor(.accentColor)
                                        .fontWeight(.medium)
                                        .frame(width: 24, alignment: .trailing)
                                    inlineMarkdown(text)
                                }
                            } else if !cleanLine.isEmpty {
                                inlineMarkdown(cleanLine)
                                    .padding(.leading, 32)
                            }
                        }
                    }
                } else if trimmed.hasPrefix(">") {
                    // Blockquote
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: 4)
                        inlineMarkdown(trimmed.replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression))
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                } else if trimmed.contains("|") && trimmed.contains("\n") {
                    // Table
                    tableView(trimmed)
                } else if trimmed.hasPrefix("```") {
                    // Code block
                    let code = trimmed
                        .replacingOccurrences(of: "^```\\w*\\n?", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\\n?```$", with: "", options: .regularExpression)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.caption, design: .monospaced))
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    // Horizontal rule
                    Divider()
                        .padding(.vertical, 8)
                } else if !trimmed.isEmpty {
                    inlineMarkdown(trimmed)
                        .lineSpacing(4)
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
                    if isLoadingTTS {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                }
                .disabled(isLoadingTTS)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                // Title
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(isLoadingTTS ? "Generating audio..." : (isPlaying ? "Playing..." : "Paused"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(summary.title), \(isLoadingTTS ? "generating audio" : (isPlaying ? "playing" : "paused"))")
                .accessibilityValue("\(Int(ttsService.progress * 100)) percent complete")

                Spacer()

                // Stop button
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
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func toggleTTS() {
        guard let content = fullContent else { return }
        if isPlaying {
            // Stop completely when showing "Stop Listening"
            ttsService.stop()
        } else {
            // Start or resume
            ttsService.togglePlayPause(content, articleUrl: summary.url)
        }
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
            var request = URLRequest(url: url)
            request.timeoutInterval = 30  // 30 second timeout
            let (data, _) = try await URLSession.shared.data(for: request)
            if let content = String(data: data, encoding: .utf8) {
                fullContent = content
            } else {
                loadingError = "Could not decode content"
            }
        } catch let error as URLError where error.code == .timedOut {
            loadingError = "Request timed out. Please try again."
        } catch {
            loadingError = "Unable to load content. Check your connection."
        }
    }
}

#Preview {
    NavigationStack {
        DetailView(summary: .preview)
    }
}
