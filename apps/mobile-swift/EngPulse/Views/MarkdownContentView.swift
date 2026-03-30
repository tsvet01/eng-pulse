import SwiftUI

// MARK: - Pre-parsed block model
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case unorderedList(text: String)
    case numberedList(text: String)
    case blockquote(text: String)
    case table(text: String)
    case codeBlock(text: String)
    case divider

    static func parse(_ content: String) -> [MarkdownBlock] {
        let cleaned = content
            .replacingOccurrences(of: "(?m)([^\n])\n(#+ )", with: "$1\n\n$2", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^(#+ [^\n]+)\n([^\n])", with: "$1\n\n$2", options: .regularExpression)

        return cleaned.components(separatedBy: "\n\n").compactMap { paragraph in
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("##### ") {
                return .heading(level: 5, text: String(trimmed.dropFirst(6)))
            } else if trimmed.hasPrefix("#### ") {
                return .heading(level: 4, text: String(trimmed.dropFirst(5)))
            } else if trimmed.hasPrefix("### ") {
                return .heading(level: 3, text: String(trimmed.dropFirst(4)))
            } else if trimmed.hasPrefix("## ") {
                return .heading(level: 2, text: String(trimmed.dropFirst(3)))
            } else if trimmed.hasPrefix("# ") {
                return .heading(level: 1, text: String(trimmed.dropFirst(2)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return .unorderedList(text: trimmed)
            } else if trimmed.first?.isNumber == true && trimmed.contains(". ") {
                return .numberedList(text: trimmed)
            } else if trimmed.hasPrefix(">") {
                return .blockquote(text: trimmed)
            } else if trimmed.contains("|") && trimmed.contains("\n") {
                return .table(text: trimmed)
            } else if trimmed.hasPrefix("```") {
                return .codeBlock(text: trimmed)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                return .divider
            } else {
                return .paragraph(text: trimmed)
            }
        }
    }
}

struct MarkdownContentView: View {
    private enum Layout {
        static let blockquoteBarWidth: CGFloat = 4
        static let tableCellCornerRadius: CGFloat = 8
        static let codeBlockCornerRadius: CGFloat = 12
    }

    let blocks: [MarkdownBlock]
    @Environment(\.colorScheme) var colorScheme

    init(content: String) {
        self.blocks = MarkdownBlock.parse(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.body)
                .lineSpacing(5)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let text):
            unorderedListView(text)
        case .numberedList(let text):
            numberedListView(text)
        case .blockquote(let text):
            blockquoteView(text)
        case .table(let text):
            tableView(text)
        case .codeBlock(let text):
            codeBlockView(text)
        case .divider:
            Divider().padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        switch level {
        case 1:
            inlineMarkdown(text)
                .font(.system(.title, design: .serif))
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .padding(.top, 16)
                .padding(.bottom, 2)
        case 2:
            inlineMarkdown(text)
                .font(.system(.title2, design: .serif))
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .padding(.top, 14)
                .padding(.bottom, 2)
        case 3:
            inlineMarkdown(text)
                .font(.system(.title3, design: .serif))
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .padding(.top, 10)
                .padding(.bottom, 2)
        case 4:
            inlineMarkdown(text)
                .font(.system(.headline, design: .serif))
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .padding(.top, 8)
                .padding(.bottom, 2)
        default:
            inlineMarkdown(text)
                .font(.system(.subheadline, design: .serif))
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 2)
        }
    }

    // MARK: - Block Elements

    private func unorderedListView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                if cleanLine.hasPrefix("- ") || cleanLine.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 4, height: 4)
                            .padding(.top, 7)
                            .accessibilityHidden(true)
                        inlineMarkdown(String(cleanLine.dropFirst(2)))
                            .lineSpacing(3)
                    }
                    .padding(.leading, 4)
                } else if !cleanLine.isEmpty {
                    inlineMarkdown(cleanLine)
                        .padding(.leading, 16)
                }
            }
        }
    }

    private func numberedListView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                if let dotIndex = cleanLine.firstIndex(of: "."),
                   cleanLine[cleanLine.startIndex..<dotIndex].allSatisfy({ $0.isNumber }) {
                    let textStart = cleanLine.index(after: dotIndex)
                    let itemText = String(cleanLine[textStart...]).trimmingCharacters(in: .whitespaces)
                    let number = String(cleanLine[..<dotIndex])
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(number).")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        inlineMarkdown(itemText)
                            .lineSpacing(3)
                    }
                } else if !cleanLine.isEmpty {
                    inlineMarkdown(cleanLine)
                        .padding(.leading, 28)
                }
            }
        }
    }

    private func blockquoteView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: Layout.blockquoteBarWidth)
            inlineMarkdown(text.replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression))
                .font(.system(.body, design: .serif))
                .foregroundColor(.secondary)
                .italic()
                .lineSpacing(3)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    func tableView(_ content: String) -> some View {
        let rows = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let dataRows = rows.filter { row in
            !row.contains("---") && !row.contains(":-")
        }

        let headerBg = Color.secondary.opacity(0.1)
        let cellBg = Color.clear
        let borderColor = Color.secondary.opacity(0.2)
        let cornerRadius = Layout.tableCellCornerRadius

        return VStack(spacing: 0) {
            ForEach(Array(dataRows.enumerated()), id: \.offset) { rowIndex, row in
                tableRowView(
                    row: row,
                    isHeader: rowIndex == 0,
                    headerBg: headerBg,
                    cellBg: cellBg
                )
                if rowIndex < dataRows.count - 1 {
                    Divider()
                        .overlay(borderColor)
                }
            }
        }
        .cornerRadius(cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func tableRowView(row: String, isHeader: Bool, headerBg: Color, cellBg: Color) -> some View {
        let cells = row.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let bgColor = isHeader ? headerBg : cellBg
        let weight: Font.Weight = isHeader ? .semibold : .regular
        let font: Font = isHeader ? .caption : .caption2

        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                inlineMarkdown(cell)
                    .font(font)
                    .fontWeight(weight)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgColor)

                if index < cells.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 1)
                }
            }
        }
    }

    private func codeBlockView(_ text: String) -> some View {
        let code = text
            .replacingOccurrences(of: "^```\\w*\\n?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\n?```$", with: "", options: .regularExpression)

        let bg = colorScheme == .dark ? Color.Dark.surfaceContainerHigh : Color.Light.surfaceContainerHigh

        return ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(colorScheme == .dark ? Color.Dark.onSurface : Color.Light.onSurface)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .cornerRadius(Layout.codeBlockCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: Layout.codeBlockCornerRadius)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Inline Markdown

    func inlineMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
