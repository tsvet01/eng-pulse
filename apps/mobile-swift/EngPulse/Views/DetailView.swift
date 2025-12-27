import SwiftUI

struct DetailView: View {
    let summary: Summary
    @State private var showFullContent = false
    @State private var fullContent: String?
    @State private var isLoadingContent = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                Divider()

                // Summary
                summarySection

                // Key Points
                if !summary.keyPoints.isEmpty {
                    keyPointsSection
                }

                Divider()

                // Actions
                actionsSection

                // Full Content (if loaded)
                if let content = fullContent {
                    fullContentSection(content)
                }
            }
            .padding()
        }
        .navigationTitle("Article")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: URL(string: summary.url)!) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(summary.source, systemImage: "newspaper")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text(summary.publishedAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(summary.title)
                .font(.title2)
                .fontWeight(.bold)

            HStack(spacing: 16) {
                Label(summary.category.displayName, systemImage: summary.category.iconName)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(8)

                Label("\(summary.readTimeMinutes) min read", systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.headline)

            Text(summary.summary)
                .font(.body)
                .foregroundColor(.secondary)
                .lineSpacing(4)
        }
    }

    private var keyPointsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Key Points")
                .font(.headline)

            ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor)
                        .clipShape(Circle())

                    Text(point)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            Button {
                openURL(URL(string: summary.url)!)
            } label: {
                Label("Read Original Article", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { await loadFullContent() }
            } label: {
                if isLoadingContent {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Load Full Content", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingContent || fullContent != nil)
        }
    }

    private func fullContentSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full Content")
                .font(.headline)

            Text(content)
                .font(.body)
                .lineSpacing(6)
        }
        .padding(.top)
    }

    // MARK: - Actions

    private func loadFullContent() async {
        isLoadingContent = true
        defer { isLoadingContent = false }

        // Simulate loading full content
        // In a real app, this would call an API
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            fullContent = "Full article content would be loaded here from the API. This is a placeholder demonstrating the async loading pattern in SwiftUI."
        } catch {
            // Handle cancellation
        }
    }
}

#Preview {
    NavigationStack {
        DetailView(summary: .preview)
    }
}
