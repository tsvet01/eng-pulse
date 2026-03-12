import SwiftUI

// Model filter options
enum ModelFilter: String, CaseIterable {
    case all = "All"
    case gemini = "Gemini"
    case claude = "Claude"
    case gpt = "GPT"

    func matches(_ modelString: String?) -> Bool {
        if self == .all { return true }
        guard let model = modelString?.lowercased() else { return false }
        return switch self {
        case .all: true
        case .gemini: model.contains("gemini")
        case .claude: model.contains("claude")
        case .gpt: model.contains("gpt") || model.contains("openai")
        }
    }
}

// MARK: - HomeViewContent
struct HomeViewContent: View {
    @EnvironmentObject var summariesStore: AppState
    @State private var searchText = ""
    @State private var isSearchActive = false
    @FocusState private var searchFocused: Bool
    @AppStorage("selectedModelFilter") private var selectedFilter: String = ModelFilter.all.rawValue
    @Binding var navigationPath: NavigationPath

    private var modelFilter: ModelFilter {
        ModelFilter(rawValue: selectedFilter) ?? .all
    }

    var filteredSummaries: [Summary] {
        var result = summariesStore.summaries

        if modelFilter != .all {
            result = result.filter { modelFilter.matches($0.model) }
        }

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
                LoadingView()
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
            DetailView(summary: summary, cacheService: summariesStore.cacheService)
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
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if summariesStore.isOffline {
                        Image(systemName: "icloud.slash")
                            .foregroundColor(.orange)
                    }

                    Button {
                        withAnimation {
                            isSearchActive.toggle()
                            searchFocused = isSearchActive
                        }
                        if !isSearchActive { searchText = "" }
                    } label: {
                        Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                    }
                    .accessibilityLabel(isSearchActive ? "Close search" : "Search")

                    NavigationLink(value: "settings") {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if isSearchActive {
                TextField("Search summaries", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(.bar)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var summaryList: some View {
        List(filteredSummaries) { summary in
            NavigationLink(value: summary) {
                SummaryCardView(summary: summary)
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Summary Card
struct SummaryCardView: View {
    let summary: Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.displayDate, format: .dateTime.month(.abbreviated).day())
                .font(.caption2)
                .foregroundColor(.secondary)

            Text(summary.title)
                .font(.body)
                .fontWeight(.semibold)
                .lineLimit(2)

            if let snippet = summary.summarySnippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
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
                .foregroundColor(.secondary)
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
                .foregroundColor(.secondary)
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
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Text("No summaries yet")
                .font(.headline)

            Text("Check back later for the latest engineering insights.")
                .font(.subheadline)
                .foregroundColor(.secondary)
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
