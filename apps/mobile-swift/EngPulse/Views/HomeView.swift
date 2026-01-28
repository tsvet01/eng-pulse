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
    @EnvironmentObject var summariesStore: AppState
    @EnvironmentObject var ttsService: TTSService
    @State private var searchText = ""
    @AppStorage("selectedModelFilter") private var selectedFilter: String = ModelFilter.all.rawValue
    @Binding var navigationPath: NavigationPath

    private var modelFilter: ModelFilter {
        ModelFilter(rawValue: selectedFilter) ?? .all
    }

    var filteredSummaries: [Summary] {
        var result = summariesStore.summaries

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
        .navigationTitle("Eng Pulse")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Summary.self) { summary in
            DetailView(summary: summary, ttsService: ttsService)
        }
        .searchable(text: $searchText, prompt: "Search summaries")
        .refreshable {
            await summariesStore.refreshSummaries()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    ForEach(ModelFilter.allCases, id: \.rawValue) { filter in
                        Button {
                            selectedFilter = filter.rawValue
                        } label: {
                            if selectedFilter == filter.rawValue {
                                Label(filter.rawValue, systemImage: "checkmark")
                            } else {
                                Text(filter.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                        if modelFilter != .all {
                            Text(modelFilter.rawValue)
                                .font(.caption)
                        }
                    }
                }
            }

            if summariesStore.isOffline {
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
    HomeView()
        .environmentObject({
            let state = AppState()
            return state
        }())
}
