import XCTest
@testable import EngPulse

final class CarPlayContentBuilderTests: XCTestCase {

    private func summary(
        date: String,
        title: String,
        url: String? = nil,
        originalUrl: String? = nil
    ) -> Summary {
        Summary(
            date: date,
            url: url ?? "https://example.com/\(date)/\(title.hashValue)",
            title: title,
            originalUrl: originalUrl
        )
    }

    // MARK: - latestArticles

    func testLatestArticlesSortsNewestFirst() {
        let summaries = [
            summary(date: "2026-07-01", title: "Old"),
            summary(date: "2026-07-15", title: "New"),
            summary(date: "2026-07-10", title: "Middle")
        ]
        let result = CarPlayContentBuilder.latestArticles(from: summaries, limit: 10)
        XCTAssertEqual(result.map(\.title), ["New", "Middle", "Old"])
    }

    func testLatestArticlesPreservesOrderWithinSameDate() {
        let summaries = [
            summary(date: "2026-07-15", title: "First"),
            summary(date: "2026-07-15", title: "Second"),
            summary(date: "2026-07-15", title: "Third")
        ]
        let result = CarPlayContentBuilder.latestArticles(from: summaries, limit: 10)
        XCTAssertEqual(result.map(\.title), ["First", "Second", "Third"])
    }

    func testLatestArticlesRespectsLimit() {
        let summaries = (1...9).map { summary(date: "2026-07-0\($0)", title: "Article \($0)") }
        let result = CarPlayContentBuilder.latestArticles(from: summaries, limit: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first?.title, "Article 9")
    }

    func testLatestArticlesWithZeroLimitIsEmpty() {
        let summaries = [summary(date: "2026-07-15", title: "Only")]
        XCTAssertTrue(CarPlayContentBuilder.latestArticles(from: summaries, limit: 0).isEmpty)
    }

    func testLatestArticlesWithEmptyInputIsEmpty() {
        XCTAssertTrue(CarPlayContentBuilder.latestArticles(from: [], limit: 10).isEmpty)
    }

    // MARK: - categoryGroups

    func testCategoryGroupsOmitsEmptyCategories() {
        // "Rust" → engineering per Summary.category keyword inference
        let summaries = [summary(date: "2026-07-15", title: "Rust ownership explained")]
        let groups = CarPlayContentBuilder.categoryGroups(from: summaries, limitPerCategory: 10)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.category, .engineering)
    }

    func testCategoryGroupsSplitsByCategory() {
        let summaries = [
            summary(date: "2026-07-15", title: "Rust ownership explained"),
            summary(date: "2026-07-14", title: "LLM prompting techniques"),
            summary(date: "2026-07-13", title: "Notes on burnout")
        ]
        let groups = CarPlayContentBuilder.categoryGroups(from: summaries, limitPerCategory: 10)
        XCTAssertEqual(groups.map(\.category), [.engineering, .ai, .general])
        XCTAssertTrue(groups.allSatisfy { $0.articles.count == 1 })
    }

    func testCategoryGroupsArticlesAreNewestFirst() {
        let summaries = [
            summary(date: "2026-07-01", title: "Rust borrow checker"),
            summary(date: "2026-07-15", title: "Rust async patterns")
        ]
        let groups = CarPlayContentBuilder.categoryGroups(from: summaries, limitPerCategory: 10)
        XCTAssertEqual(groups.first?.articles.map(\.title), ["Rust async patterns", "Rust borrow checker"])
    }

    func testCategoryGroupsRespectsPerCategoryLimit() {
        let summaries = (1...5).map { summary(date: "2026-07-0\($0)", title: "Rust tip \($0)") }
        let groups = CarPlayContentBuilder.categoryGroups(from: summaries, limitPerCategory: 2)
        XCTAssertEqual(groups.first?.articles.count, 2)
    }

    // MARK: - detailText

    func testDetailTextIncludesSourceAndDate() {
        let article = summary(
            date: "2026-07-15",
            title: "Anything",
            originalUrl: "https://www.thenewstack.io/some-article"
        )
        XCTAssertEqual(CarPlayContentBuilder.detailText(for: article), "Thenewstack · 2026-07-15")
    }

    func testDetailTextFallsBackToDateWhenSourceUnknown() {
        let article = summary(date: "2026-07-15", title: "Anything")
        XCTAssertEqual(CarPlayContentBuilder.detailText(for: article), "2026-07-15")
    }
}
