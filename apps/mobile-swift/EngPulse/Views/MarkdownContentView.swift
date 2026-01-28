import SwiftUI

struct MarkdownContentView: View {
    private enum Layout {
        static let blockquoteBarWidth: CGFloat = 4
        static let tableCellCornerRadius: CGFloat = 8
        static let codeBlockCornerRadius: CGFloat = 12
    }

    let content: String
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        // Pre-process content to enforce blank lines around headers for correct parsing
        // 1. (?m) enables multi-line mode so ^ matches start of line
        // 2. Ensure newline before headers: `\n# Title` -> `\n\n# Title`
        // 3. Ensure newline after headers: `# Title\nText` -> `# Title\n\nText`
        let cleaned = content
            .replacingOccurrences(of: "(?m)([^\n])\n(#+ )", with: "$1\n\n$2", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^(#+ [^\n]+)\n([^\n])", with: "$1\n\n$2", options: .regularExpression)

        return VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(cleaned.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("# ") {
                    inlineMarkdown(String(trimmed.dropFirst(2)))
                        .font(.system(.title, design: .serif))
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .padding(.top, 12)
                } else if trimmed.hasPrefix("## ") {
                    inlineMarkdown(String(trimmed.dropFirst(3)))
                        .font(.system(.title2, design: .serif))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("### ") {
                    inlineMarkdown(String(trimmed.dropFirst(4)))
                        .font(.system(.title3, design: .serif))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("#### ") {
                    inlineMarkdown(String(trimmed.dropFirst(5)))
                        .font(.system(.headline, design: .serif))
                        .fontWeight(.bold)
                        .foregroundColor(.primary.opacity(0.9))
                        .padding(.top, 4)
                } else if trimmed.hasPrefix("##### ") {
                    inlineMarkdown(String(trimmed.dropFirst(6)))
                        .font(.system(.subheadline, design: .serif))
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
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
                        .padding(.vertical, 12)
                } else if !trimmed.isEmpty {
                    inlineMarkdown(trimmed)
                        .font(.body)
                        .lineSpacing(7) // Even airier
                        .foregroundColor(.primary.opacity(0.85)) // Slightly softer black/white
                        .fixedSize(horizontal: false, vertical: true) // Ensure text wraps properly
                }
            }
        }
    }

    // MARK: - Block Elements

    private func unorderedListView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                if cleanLine.hasPrefix("- ") || cleanLine.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .padding(.top, 8) // Visually align bullet with text
                        // Remove the bullet character and leading space
                        inlineMarkdown(String(cleanLine.dropFirst(2)))
                            .lineSpacing(4)
                    }
                    .padding(.leading, 4)
                } else if !cleanLine.isEmpty {
                    inlineMarkdown(cleanLine)
                        .padding(.leading, 19) // Indent continuation lines
                }
            }
        }
    }

    private func numberedListView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                if let dotIndex = cleanLine.firstIndex(of: "."),
                   cleanLine[cleanLine.startIndex..<dotIndex].allSatisfy({ $0.isNumber }) {
                    let textStart = cleanLine.index(after: dotIndex)
                    let itemText = String(cleanLine[textStart...]).trimmingCharacters(in: .whitespaces)
                    let number = String(cleanLine[..<dotIndex])
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(number).")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        inlineMarkdown(itemText)
                            .lineSpacing(4)
                    }
                } else if !cleanLine.isEmpty {
                    inlineMarkdown(cleanLine)
                        .padding(.leading, 32)
                }
            }
        }
    }

    private func blockquoteView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Capsule()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: Layout.blockquoteBarWidth)
            inlineMarkdown(text.replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression))
                .font(.system(.body, design: .serif)) // Serif for quotes looks elegant
                .foregroundColor(.secondary)
                .italic()
                .lineSpacing(4)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    func tableView(_ content: String) -> some View {
        let rows = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let dataRows = rows.filter { row in
            !row.contains("---") && !row.contains(":-")
        }
        
        // Semantic colors for table
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
                Text(cell)
                    .font(font)
                    .fontWeight(weight)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgColor)
                
                // Vertical divider
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
        
        let bg = colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.96)
        
        return ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .padding(16)
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
        // Use InterpretedSyntax.full to allow for more markdown features if possible,
        // but inlineOnlyPreservingWhitespace is safer for sticking to the manual block structure.
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
