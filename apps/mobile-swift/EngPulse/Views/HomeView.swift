import SwiftUI

// MARK: - HomeViewContent
struct HomeViewContent: View {
    @EnvironmentObject var summariesStore: AppState
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
                allSummaries: summariesStore.summaries,
                cacheService: summariesStore.cacheService
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
                Text("Eng Pulse")
                    .font(.headline)
                    .fontDesign(.serif)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if summariesStore.isOffline {
                        Image(systemName: "icloud.slash")
                            .foregroundColor(Color.tertiaryAccent)
                    }

                    Button {
                        withAnimation {
                            isSearchActive.toggle()
                            searchFocused = isSearchActive
                        }
                        if !isSearchActive { searchText = "" }
                    } label: {
                        Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                            .foregroundColor(Color.onSurfaceVariant)
                    }
                    .accessibilityLabel(isSearchActive ? "Close search" : "Search")

                    NavigationLink(value: "settings") {
                        Image(systemName: "gearshape")
                            .foregroundColor(Color.onSurfaceVariant)
                    }
                    .accessibilityLabel("Settings")
                }
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
        List(filteredSummaries) { summary in
            NavigationLink(value: summary) {
                SummaryCardView(summary: summary, isRead: isArticleRead(summary.url))
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.surface)
    }

    private func isArticleRead(_ url: String) -> Bool {
        UserDefaults.standard.string(forKey: FeedbackKeys.selection(url)) != nil ||
        UserDefaults.standard.string(forKey: FeedbackKeys.summary(url)) != nil
    }
}

// MARK: - Summary Card
struct SummaryCardView: View {
    let summary: Summary
    var isRead: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Metadata row
            HStack(spacing: 6) {
                Text(summary.displayDate, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundColor(Color.onSurfaceVariant)

                Text(summary.source)
                    .font(.caption2)
                    .foregroundColor(Color.onSurfaceVariant)

                Spacer()

                if isRead {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("READ")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }
            }

            // Title
            Text(summary.title)
                .font(.headline)
                .fontDesign(.serif)
                .lineLimit(2)
                .opacity(isRead ? 0.6 : 1.0)

            // Snippet
            if let snippet = summary.cleanSnippet {
                Text(snippet)
                    .font(.subheadline)
                    .foregroundColor(Color.onSurfaceVariant)
                    .lineLimit(2)
            }
        }
        .padding(DesignTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isRead ? Color.containerLow.opacity(0.6) : Color.container)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
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
