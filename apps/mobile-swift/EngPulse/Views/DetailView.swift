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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(summary.source) • \(summary.date)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(summary.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Spacer()
            Text(summary.modelDisplayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(4)
        }
    }

    private var summarySection: some View {
        Text(summary.summarySnippet ?? "No preview available")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineSpacing(4)
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
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            markdownText(content)
                .font(.body)
                .lineSpacing(4)
        }
        .padding(.top, 8)
    }

    private func markdownText(_ content: String) -> Text {
        if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(content)
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
