import SwiftUI

struct DetailView: View {
    let summary: Summary
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
            if let originalUrl = summary.originalUrl, let url = URL(string: originalUrl) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            await loadFullContent()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Source and date on one line
            HStack {
                Text(summary.source)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("•")
                    .foregroundColor(.secondary)
                Text(summary.date)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(summary.modelDisplayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(6)
            }

            Text(summary.title)
                .font(.headline)
                .fontWeight(.semibold)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)

            Text(summary.summarySnippet ?? "No preview available")
                .font(.body)
                .foregroundColor(.secondary)
                .lineSpacing(4)
        }
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
