import Foundation

// MARK: - CarPlay Content Builder
/// Pure helpers that shape article data for the CarPlay UI.
/// Kept free of CarPlay framework types so the logic is unit-testable.
struct CarPlayContentBuilder {

    struct CategoryGroup: Equatable {
        let category: Category
        let articles: [Summary]
    }

    /// Articles for the "Latest" tab: newest first (stable within a date),
    /// capped to CarPlay's list item limit.
    static func latestArticles(from summaries: [Summary], limit: Int) -> [Summary] {
        guard limit > 0 else { return [] }
        let sorted = summaries.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date {
                return lhs.element.date > rhs.element.date
            }
            return lhs.offset < rhs.offset
        }
        return sorted.prefix(limit).map(\.element)
    }

    /// Articles grouped by inferred category, in `Category.allCases` order.
    /// Empty categories are omitted.
    static func categoryGroups(from summaries: [Summary], limitPerCategory: Int) -> [CategoryGroup] {
        let sorted = latestArticles(from: summaries, limit: summaries.count)
        return Category.allCases.compactMap { category in
            let articles = sorted.filter { $0.category == category }.prefix(max(0, limitPerCategory))
            guard !articles.isEmpty else { return nil }
            return CategoryGroup(category: category, articles: Array(articles))
        }
    }

    /// Secondary line for an article row, e.g. "Thenewstack · 2025-12-27".
    static func detailText(for summary: Summary) -> String {
        let source = summary.source
        return source == "Unknown" ? summary.date : "\(source) · \(summary.date)"
    }
}
