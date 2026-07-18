import Foundation

// MARK: - CarPlay Content Builder
/// Pure helpers that shape article data for the CarPlay UI.
/// Kept free of CarPlay framework types so the logic is unit-testable.
struct CarPlayContentBuilder {

    struct CategoryGroup: Equatable {
        let category: Category
        let articles: [Summary]
        /// Real category size before capping to CarPlay's list limit.
        let totalCount: Int
    }

    /// Newest first, stable within a date (preserves manifest order).
    static func sortedNewestFirst(_ summaries: [Summary]) -> [Summary] {
        summaries.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date {
                return lhs.element.date > rhs.element.date
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Articles for the "Latest" tab, capped to CarPlay's list item limit.
    static func latestArticles(from summaries: [Summary], limit: Int) -> [Summary] {
        Array(sortedNewestFirst(summaries).prefix(max(0, limit)))
    }

    /// Articles grouped by inferred category, in `Category.allCases` order.
    /// Empty categories are omitted; each summary's category is inferred once.
    static func categoryGroups(from summaries: [Summary], limitPerCategory: Int) -> [CategoryGroup] {
        let grouped = Dictionary(grouping: sortedNewestFirst(summaries), by: \.category)
        return Category.allCases.compactMap { category in
            guard let articles = grouped[category], !articles.isEmpty else { return nil }
            return CategoryGroup(
                category: category,
                articles: Array(articles.prefix(max(0, limitPerCategory))),
                totalCount: articles.count
            )
        }
    }

    /// Secondary line for an article row, e.g. "Thenewstack · Jul 15".
    static func detailText(for summary: Summary) -> String {
        let source = summary.source
        let date = summary.shortDisplayDate
        return source == "Unknown" ? date : "\(source) · \(date)"
    }
}
