import SwiftUI

struct MarkdownContentView: View {
    private enum Layout {
        static let blockquoteBarWidth: CGFloat = 4
        static let tableCellCornerRadius: CGFloat = 6
    }

    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(content.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("# ") {
                    inlineMarkdown(String(trimmed.dropFirst(2)))
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("## ") {
                    inlineMarkdown(String(trimmed.dropFirst(3)))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("### ") {
                    inlineMarkdown(String(trimmed.dropFirst(4)))
                        .font(.headline)
                        .fontWeight(.semibold)
                        .padding(.top, 4)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    unorderedListView(trimmed)
                } else if trimmed.first?.isNumber == true && trimmed.contains(". ") {
                    numberedListView(trimmed)
                } else if trimmed.hasPrefix(">") {
                    blockquoteView(trimmed)
                } else if trimmed.contains("|") && trimmed.contains("\n") {
                    tableView(trimmed)
                } else if trimmed.hasPrefix("```") {
                    codeBlockView(trimmed)
                } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    Divider()
                        .padding(.vertical, 8)
                } else if !trimmed.isEmpty {
                    inlineMarkdown(trimmed)
                        .lineSpacing(4)
                }
            }
        }
    }

    // MARK: - Block Elements

    private func unorderedListView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                if cleanLine.hasPrefix("- ") || cleanLine.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundColor(.accentColor)
                            .fontWeight(.bold)
                        inlineMarkdown(String(cleanLine.dropFirst(2)))
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
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(number).")
                            .foregroundColor(.accentColor)
                            .fontWeight(.medium)
                            .frame(width: 24, alignment: .trailing)
                        inlineMarkdown(itemText)
                    }
                } else if !cleanLine.isEmpty {
                    inlineMarkdown(cleanLine)
                        .padding(.leading, 32)
                }
            }
        }
    }

    private func blockquoteView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: Layout.blockquoteBarWidth)
            inlineMarkdown(text.replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression))
                .foregroundColor(.secondary)
                .italic()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    func tableView(_ content: String) -> some View {
        let rows = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let dataRows = rows.filter { row in
            !row.contains("---") && !row.contains(":-")
        }
        let headerColor = Color(.systemGray5)
        let cellColor = Color(.systemGray6)
        let borderColor = Color(.systemGray4)
        let cornerRadius = Layout.tableCellCornerRadius

        return VStack(spacing: 0) {
            ForEach(Array(dataRows.enumerated()), id: \.offset) { rowIndex, row in
                tableRowView(
                    row: row,
                    isHeader: rowIndex == 0,
                    headerColor: headerColor,
                    cellColor: cellColor
                )
                if rowIndex < dataRows.count - 1 {
                    Divider()
                }
            }
        }
        .cornerRadius(cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderColor, lineWidth: 0.5)
        )
    }

    private func tableRowView(row: String, isHeader: Bool, headerColor: Color, cellColor: Color) -> some View {
        let cells = row.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let bgColor = isHeader ? headerColor : cellColor
        let weight: Font.Weight = isHeader ? .semibold : .regular

        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(.caption)
                    .fontWeight(weight)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgColor)
            }
        }
    }

    private func codeBlockView(_ text: String) -> some View {
        let code = text
            .replacingOccurrences(of: "^```\\w*\\n?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\n?```$", with: "", options: .regularExpression)
        return ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Inline Markdown

    func inlineMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
