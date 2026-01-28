import XCTest
@testable import EngPulse

final class TextCleanerTests: XCTestCase {

    // MARK: - Empty & No-op Cases

    func testEmptyString() {
        XCTAssertEqual(TextCleaner.cleanForSpeech(""), "")
    }

    func testPlainTextPassesThrough() {
        let text = "This is plain text with no markdown."
        XCTAssertEqual(TextCleaner.cleanForSpeech(text), text)
    }

    // MARK: - Headings

    func testRemovesH1() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("# Heading"), "Heading")
    }

    func testRemovesH3() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("### Sub Heading"), "Sub Heading")
    }

    func testRemovesH6() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("###### Deep"), "Deep")
    }

    // MARK: - Bold & Italic

    func testRemovesBold() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("This is **bold** text"), "This is bold text")
    }

    func testRemovesItalic() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("This is *italic* text"), "This is italic text")
    }

    func testRemovesUnderscoreBold() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("This is __bold__ text"), "This is bold text")
    }

    func testRemovesUnderscoreItalic() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("This is _italic_ text"), "This is italic text")
    }

    // MARK: - Code

    func testRemovesInlineCode() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("Use `print()` here"), "Use print() here")
    }

    func testRemovesCodeBlocks() {
        let input = "Before\n```swift\nlet x = 1\n```\nAfter"
        let result = TextCleaner.cleanForSpeech(input)
        XCTAssertFalse(result.contains("let x = 1"))
        XCTAssertTrue(result.contains("Before"))
        XCTAssertTrue(result.contains("After"))
    }

    // MARK: - Links & Images

    func testRemovesLinksKeepsText() {
        XCTAssertEqual(
            TextCleaner.cleanForSpeech("Click [here](https://example.com) now"),
            "Click here now"
        )
    }

    func testRemovesImages() {
        let result = TextCleaner.cleanForSpeech("See ![alt text](image.png) below")
        XCTAssertFalse(result.contains("alt text"))
        XCTAssertFalse(result.contains("image.png"))
    }

    // MARK: - HTML

    func testRemovesHTMLTags() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("Hello <b>world</b>"), "Hello world")
    }

    // MARK: - Horizontal Rules

    func testRemovesHorizontalRule() {
        let input = "Above\n---\nBelow"
        let result = TextCleaner.cleanForSpeech(input)
        XCTAssertTrue(result.contains("Above"))
        XCTAssertTrue(result.contains("Below"))
        XCTAssertFalse(result.contains("---"))
    }

    // MARK: - Lists

    func testRemovesUnorderedListMarkers() {
        let input = "- Item one\n- Item two"
        let result = TextCleaner.cleanForSpeech(input)
        XCTAssertTrue(result.contains("Item one"))
        XCTAssertFalse(result.hasPrefix("-"))
    }

    func testRemovesOrderedListMarkers() {
        let input = "1. First\n2. Second"
        let result = TextCleaner.cleanForSpeech(input)
        XCTAssertTrue(result.contains("First"))
        XCTAssertFalse(result.contains("1."))
    }

    // MARK: - Blockquotes

    func testRemovesBlockquoteMarkers() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("> Quoted text"), "Quoted text")
    }

    // MARK: - Whitespace Normalization

    func testNormalizesMultipleNewlines() {
        let input = "Paragraph one\n\n\n\n\nParagraph two"
        let result = TextCleaner.cleanForSpeech(input)
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    func testNormalizesMultipleSpaces() {
        let result = TextCleaner.cleanForSpeech("Too   many   spaces")
        XCTAssertEqual(result, "Too many spaces")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(TextCleaner.cleanForSpeech("  hello  "), "hello")
    }

    // MARK: - Complex / Nested

    func testComplexMarkdown() {
        let input = """
        # Title

        This is **bold** and *italic* text with a [link](https://example.com).

        > A blockquote

        - List item 1
        - List item 2

        ```
        code block
        ```

        Done.
        """
        let result = TextCleaner.cleanForSpeech(input)
        XCTAssertTrue(result.contains("Title"))
        XCTAssertTrue(result.contains("bold"))
        XCTAssertTrue(result.contains("italic"))
        XCTAssertTrue(result.contains("link"))
        XCTAssertTrue(result.contains("A blockquote"))
        XCTAssertTrue(result.contains("List item 1"))
        XCTAssertFalse(result.contains("```"))
        XCTAssertFalse(result.contains("code block"))
        XCTAssertTrue(result.contains("Done."))
    }
}
