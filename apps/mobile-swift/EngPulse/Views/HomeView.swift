import SwiftUI

// Model filter options
enum ModelFilter: String, CaseIterable {
    case all = "All"
    case gemini = "Gemini"
    case claude = "Claude"
    case gpt = "GPT"

    func matches(_ modelString: String?) -> Bool {
        guard self != .all else { return true }
        guard let model = modelString?.lowercased() else { return false }
        switch self {
        case .all: return true // Unreachable but required for exhaustive switch
        case .gemini: return model.contains("gemini")
        case .claude: return model.contains("claude")
        case .gpt: return model.contains("gpt") || model.contains("openai")
        }
    }
}

// MARK: - HomeView (standalone with own NavigationStack)
struct HomeView: View {
    var body: some View {
        NavigationStack {
            HomeViewContent(navigationPath: .constant(NavigationPath()))
        }
    }
}

// MARK: - HomeViewContent (for use with external NavigationStack)
struct HomeViewContent: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @AppStorage("selectedModelFilter") private var selectedFilter: String = ModelFilter.all.rawValue
    @Binding var navigationPath: NavigationPath

    private var modelFilter: ModelFilter {
        ModelFilter(rawValue: selectedFilter) ?? .all
    }

    var filteredSummaries: [Summary] {
        var result = appState.summaries

        // Apply model filter
        if modelFilter != .all {
            result = result.filter { modelFilter.matches($0.model) }
        }

        // Apply search filter
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
            if appState.isLoading && appState.summaries.isEmpty {
                LoadingView()
            } else if let error = appState.errorMessage, appState.summaries.isEmpty {
                ErrorView(message: error) {
                    Task { await appState.refreshSummaries() }
                }
            } else if appState.summaries.isEmpty {
                EmptyStateView()
            } else {
                summaryList
            }
        }
        .navigationTitle("Eng Pulse")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Summary.self) { summary in
            DetailView(summary: summary)
        }
        .searchable(text: $searchText, prompt: "Search summaries")
        .refreshable {
            await appState.refreshSummaries()
        }
        .toolbar {
            if appState.isOffline {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.slash")
                        Text("Cached")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                }
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
        VStack(alignment: .leading, spacing: 6) {
            // Source and date
            HStack {
                Text(summary.source)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("·")
                    .foregroundColor(.secondary)

                Text(summary.displayDate, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Title
            Text(summary.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)

            // Summary preview
            if let snippet = summary.summarySnippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Loading View
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading summaries...")
                .foregroundColor(.secondary)
        }
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

            Text("Something went wrong")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again", action: retryAction)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "newspaper")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No summaries yet")
                .font(.headline)

            Text("Check back later for the latest engineering insights.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

#Preview {
    HomeView()
        .environmentObject({
            let state = AppState()
            return state
        }())
}
