import SwiftUI

struct InsightBriefView: View {
    let brief: InsightBrief

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.sectionSpacing) {
            // Key Idea
            SectionCard(
                icon: "bolt.fill",
                label: "KEY IDEA",
                accentColor: .accentColor
            ) {
                Text(brief.keyIdea)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .fontDesign(.serif)
                    .foregroundColor(.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Why It Matters
            SectionCard(
                icon: "target",
                label: "WHY IT MATTERS",
                accentColor: .onSurfaceVariant
            ) {
                Text(brief.whyItMatters)
                    .font(.body)
                    .foregroundColor(.onSurface)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // What To Change (optional)
            if let action = brief.whatToChange {
                SectionCard(
                    icon: "wrench.and.screwdriver.fill",
                    label: "WHAT TO CHANGE",
                    accentColor: .tertiaryAccent
                ) {
                    Text(action)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Deep Dive
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.book.closed.fill")
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                    Text("DEEP DIVE")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.onSurfaceVariant)
                        .tracking(1)
                }
                .padding(.top, 4)

                MarkdownContentView(content: brief.deepDive)
            }
        }
    }
}

// MARK: - Section Card

struct SectionCard<Content: View>: View {
    let icon: String
    let label: String
    let accentColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(accentColor)
                Text(label)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(accentColor)
                    .tracking(1)
            }
            content()
        }
        .padding(DesignTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.container)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
    }
}
