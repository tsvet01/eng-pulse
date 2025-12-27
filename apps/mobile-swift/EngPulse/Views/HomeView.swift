import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""

    var filteredSummaries: [Summary] {
        if searchText.isEmpty {
            return appState.summaries
        }
        return appState.summaries.filter { summary in
            summary.title.localizedCaseInsensitiveContains(searchText) ||
            (summary.summarySnippet ?? "").localizedCaseInsensitiveContains(searchText) ||
            summary.source.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
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
            .searchable(text: $searchText, prompt: "Search summaries")
            .refreshable {
                await appState.refreshSummaries()
            }
            .toolbar {
                if appState.isOffline {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Label("Offline", systemImage: "wifi.slash")
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    private var summaryList: some View {
        List(filteredSummaries) { summary in
            NavigationLink(destination: DetailView(summary: summary)) {
                SummaryCardView(summary: summary)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .listStyle(.plain)
    }
}

// MARK: - Summary Card
struct SummaryCardView: View {
    let summary: Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with source and model
            HStack {
                Text(summary.source)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                Label(summary.modelDisplayName, systemImage: summary.category.iconName)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(8)
            }

            // Title
            Text(summary.title)
                .font(.headline)
                .lineLimit(2)

            // Summary preview
            if let snippet = summary.summarySnippet {
                Text(snippet)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }

            // Footer with date
            HStack {
                Text(summary.displayDate, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text(summary.date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
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
