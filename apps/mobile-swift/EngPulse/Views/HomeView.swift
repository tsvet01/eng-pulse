import SwiftUI

// MARK: - HomeViewContent
struct HomeViewContent: View {
    @EnvironmentObject var summariesStore: AppState
    @EnvironmentObject private var ttsService: TTSService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var isSearchActive = false
    @FocusState private var searchFocused: Bool
    @Binding var navigationPath: NavigationPath

    var filteredSummaries: [Summary] {
        var result = summariesStore.summaries

        if !searchText.isEmpty {
            result = result.filter { summary in
                summary.title.localizedCaseInsensitiveContains(searchText) ||
                (summary.summarySnippet ?? "").localizedCaseInsensitiveContains(searchText) ||
                summary.source.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var body: some View {
        ZStack {
            if summariesStore.isLoading && summariesStore.summaries.isEmpty {
                SkeletonFeedView()
            } else if let error = summariesStore.errorMessage, summariesStore.summaries.isEmpty {
                ErrorView(message: error) {
                    Task { await summariesStore.refreshSummaries() }
                }
            } else if summariesStore.summaries.isEmpty {
                EmptyStateView()

            } else {
                summaryList
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Summary.self) { summary in
            DetailView(
                summary: summary,
                allSummaries: filteredSummaries.contains(summary) ? filteredSummaries : [],
                cacheService: summariesStore.cacheService,
                feedback: summariesStore.pilotFeedback
            )
        }
        .navigationDestination(for: String.self) { value in
            if value == "settings" {
                SettingsView()
            }
        }
        .refreshable {
            await summariesStore.refreshSummaries()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    PulseMark(size: 28)
                    Text("Eng Pulse")
                        .font(.system(.headline, design: .serif))
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            isSearchActive.toggle()
                            searchFocused = isSearchActive
                        }
                        if !isSearchActive { searchText = "" }
                    } label: {
                        Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                            .foregroundColor(Color.onSurfaceVariant)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(isSearchActive ? "Close search" : "Search")

                    NavigationLink(value: "settings") {
                        Image(systemName: "gearshape")
                            .foregroundColor(Color.onSurfaceVariant)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let chrome = libraryChrome {
                ActivePlaybackBar(
                    tts: ttsService,
                    chrome: chrome,
                    onToggle: { ttsService.togglePauseResume() },
                    onSecondary: openNowPlaying
                )
            }
        }
        .safeAreaInset(edge: .top) {
            if isSearchActive {
                TextField("Search summaries", text: $searchText)
                    .focused($searchFocused)
                    .font(.subheadline)
                    .padding(12)
                    .background(Color.containerLow)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.cardRadius)
                            .stroke(searchFocused ? Color.accentColor.opacity(0.4) : Color.outlineVariant.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(Color.surface)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var summaryList: some View {
        let summaries = filteredSummaries
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                feedHeader(count: summaries.count)

                if summariesStore.isOffline {
                    Label("Offline · Showing saved articles", systemImage: "icloud.slash")
                        .font(.subheadline)
                        .foregroundStyle(Color.onSurfaceVariant)
                        .padding(.vertical, 4)
                }

                if summaries.isEmpty {
                    ContentUnavailableView {
                        Label("No matching articles", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Try another title, topic, or publisher.")
                    } actions: {
                        Button("Clear search") {
                            searchText = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                } else {
                    ForEach(summaries) { summary in
                        NavigationLink(value: summary) {
                            SummaryCardView(summary: summary, isRated: hasFeedback(summary.url), playbackBadge: playbackBadge(for: summary.url))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.surface)
    }

    private func feedHeader(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your daily brief")
                    .font(.system(.largeTitle, design: .serif, weight: .bold))
                    .foregroundStyle(Color.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Text("Good ideas for better engineering.")
                    .font(.subheadline)
                    .foregroundStyle(Color.onSurfaceVariant)
            }

            resultCount(count)
        }
        .padding(.bottom, 6)
    }

    private func resultCount(_ count: Int) -> some View {
        Text("\(count) \(count == 1 ? "article" : "articles")")
            .font(.subheadline)
            .foregroundStyle(Color.onSurfaceVariant)
    }

    private func hasFeedback(_ url: String) -> Bool {
        guard PilotBuild.allowsLegacyServices else { return false }
        return [FeedbackKeys.selection(url), FeedbackKeys.summary(url)].contains {
            !(UserDefaults.standard.string(forKey: $0) ?? "").isEmpty
        }
    }

    private var playingSummary: Summary? {
        guard let url = ttsService.currentArticleUrl else { return nil }
        return summariesStore.summaries.first { $0.url == url }
    }

    private var libraryChrome: PlaybackChrome? {
        PlaybackChrome.forLibrary(
            playingURL: ttsService.currentArticleUrl,
            playingTitle: ttsService.currentArticleTitle,
            state: ttsService.state,
            canOpenArticle: playingSummary != nil
        )
    }

    private func playbackBadge(for url: String) -> String? {
        guard ttsService.currentArticleUrl == url else { return nil }
        switch ttsService.state {
        case .playing: return "PLAYING"
        case .loading: return "LOADING"
        case .paused: return "PAUSED"
        case .stopped: return nil
        }
    }

    private func openNowPlaying() {
        guard let summary = playingSummary else { return }
        navigationPath.append(summary)
    }
}

// MARK: - Summary Card
struct SummaryCardView: View {
    let summary: Summary
    var isRated: Bool = false
    var playbackBadge: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: summary.isInsightBrief ? "text.alignleft" : "doc.text")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(summary.source)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)

            }
            .font(.caption)
            .foregroundStyle(Color.onSurfaceVariant)

            Text(summary.title)
                .font(.system(.title3, design: .serif, weight: .semibold))
                .foregroundStyle(Color.onSurface)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)

            if let snippet = summary.cleanSnippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(Color.onSurfaceVariant)
                    .lineSpacing(3)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }

            HStack(spacing: 8) {
                Text(summary.displayDate, format: .dateTime.month(.abbreviated).day().year())
                Spacer(minLength: 0)
                if let playbackBadge {
                    Label(playbackBadge == "LOADING" ? "Preparing audio" : playbackBadge.capitalized,
                          systemImage: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                } else if isRated {
                    Label("Rated", systemImage: "checkmark.circle")
                }
                Image(systemName: "arrow.right")
                    .accessibilityHidden(true)
            }
            .font(.caption)
            .foregroundStyle(Color.onSurfaceVariant)
            .padding(.top, 2)
        }
        .padding(DesignTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.containerLow, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius)
                .strokeBorder(Color.outlineVariant.opacity(0.3), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Loading View
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .accessibilityLabel("Loading")
            Text("Loading summaries...")
                .foregroundColor(.onSurfaceVariant)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading summaries, please wait")
    }
}

// MARK: - Error View
struct ErrorView: View {
    let message: String
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            Text("Something went wrong")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again", action: retryAction)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Attempts to reload the summaries")
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "newspaper")
                .font(.system(size: 48))
                .foregroundColor(.onSurfaceVariant)
                .accessibilityHidden(true)

            Text("No summaries yet")
                .font(.headline)

            Text("Check back later for the latest engineering insights.")
                .font(.subheadline)
                .foregroundColor(.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No summaries yet. Check back later for the latest engineering insights.")
    }
}

#Preview {
    NavigationStack {
        HomeViewContent(navigationPath: .constant(NavigationPath()))
    }
    .environmentObject(AppState())
    .environmentObject(TTSService())
}
