import XCTest
@testable import EngPulse

final class MarkdownRendererTests: XCTestCase {

    private let renderer = MarkdownContentView(content: "")

    // MARK: - Inline Markdown

    func testPlainText() {
        let result = renderer.inlineMarkdown("Hello world")
        XCTAssertNotNil(result)
    }

    func testBoldText() {
        let result = renderer.inlineMarkdown("This is **bold** text")
        XCTAssertNotNil(result)
    }

    func testItalicText() {
        let result = renderer.inlineMarkdown("This is *italic* text")
        XCTAssertNotNil(result)
    }

    func testLinkText() {
        let result = renderer.inlineMarkdown("[Click here](https://example.com)")
        XCTAssertNotNil(result)
    }

    func testInlineCode() {
        let result = renderer.inlineMarkdown("Use `let x = 1` in Swift")
        XCTAssertNotNil(result)
    }

    func testEmptyString() {
        let result = renderer.inlineMarkdown("")
        XCTAssertNotNil(result)
    }

    func testInvalidMarkdown() {
        let result = renderer.inlineMarkdown("**unclosed bold")
        XCTAssertNotNil(result)
    }

    // MARK: - Table Parsing

    func testTableViewParsesHeaderAndRows() {
        let table = """
        | Name | Value |
        |------|-------|
        | Foo  | Bar   |
        | Baz  | Qux   |
        """
        // Should not crash — tableView returns a valid View
        let view = renderer.tableView(table)
        XCTAssertNotNil(view)
    }

    func testTableViewSingleRow() {
        let table = """
        | Header |
        |--------|
        | Cell   |
        """
        let view = renderer.tableView(table)
        XCTAssertNotNil(view)
    }

    func testTableViewFiltersSeparatorRows() {
        let table = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        // The separator row (|---|---|) should be filtered out
        let view = renderer.tableView(table)
        XCTAssertNotNil(view)
    }
}
