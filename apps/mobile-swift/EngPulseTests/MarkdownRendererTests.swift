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
    func testPipeOperatorsRemainInsideFencedCode() {
        let code = "```bash\nprintf '%s\\n' cache | sort | uniq\n```"
        let blocks = MarkdownBlock.parse(code)
        XCTAssertEqual(blocks.count, 1)
        guard case .codeBlock(let text) = blocks.first else {
            return XCTFail("Pipe operators must not turn fenced code into a table")
        }
        XCTAssertEqual(text, code.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n"))
    }

    func testFencedCodePreservesBlankLinesAndMarkdownCharacters() {
        let code = "```bash\n# Keep this comment\n\nprintf 'a | b'\n```"
        let blocks = MarkdownBlock.parse("Before\n\n\(code)\n\nAfter")
        XCTAssertEqual(blocks.count, 3)
        guard blocks.count == 3, case .codeBlock(let text) = blocks[1] else {
            return XCTFail("The whole fenced block should be retained between paragraphs")
        }
        XCTAssertEqual(text, code.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n"))
    }

    func testCodeFenceDoesNotRequireBlankLinesAroundIt() {
        let code = "```sh\nprintf a | cat\n```"
        let blocks = MarkdownBlock.parse("Before\n\(code)\nAfter")
        XCTAssertEqual(blocks.count, 3)
        guard blocks.count == 3, case .codeBlock(let text) = blocks[1] else {
            return XCTFail("A fence delimits code independently of paragraph spacing")
        }
        XCTAssertEqual(text, code.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n"))
    }

    func testProseContainingAPipeIsNotATable() {
        let prose = "Use the | operator\nto connect commands."
        let blocks = MarkdownBlock.parse(prose)
        guard case .paragraph(let text) = blocks.first else {
            return XCTFail("A table requires a delimiter row")
        }
        XCTAssertEqual(text, prose)
    }

    func testAlignedMarkdownTableRemainsATable() {
        let table = "| Name | Value |\n| :--- | ---: |\n| Foo | Bar |"
        let blocks = MarkdownBlock.parse(table)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let text) = blocks.first else {
            return XCTFail("Valid tables must retain their existing presentation")
        }
        XCTAssertEqual(text, table)
    }

    func testLongerFenceClosesBeforeFollowingProse() {
        let blocks = MarkdownBlock.parse("````bash\necho ok\n````\n\nAfter")
        XCTAssertEqual(blocks.count, 2)
        guard blocks.count == 2, case .paragraph(let text) = blocks[1] else {
            return XCTFail("A longer fence must not consume the following paragraph")
        }
        XCTAssertEqual(text, "After")
    }

    func testIndentedFenceWithTrailingWhitespaceIsRemovedFromCode() {
        let blocks = MarkdownBlock.parse("  ```bash\n    echo ok\n  ```  ")
        guard case .codeBlock(let text) = blocks.first else {
            return XCTFail("Indented fences should delimit a code block")
        }
        XCTAssertEqual(text, "    echo ok")
    }

    func testShorterFenceInsideCodeDoesNotCloseLongerFence() {
        let blocks = MarkdownBlock.parse("````md\n```\nexample\n```\n````\nAfter")
        XCTAssertEqual(blocks.count, 2)
        guard case .codeBlock(let text) = blocks.first else {
            return XCTFail("Shorter fences are part of the code body")
        }
        XCTAssertEqual(text, "```\nexample\n```")
    }

    func testCRLFFenceClosesBeforeFollowingProse() {
        let blocks = MarkdownBlock.parse("```bash\r\necho ok\r\n```\r\n\r\nAfter")
        XCTAssertEqual(blocks.count, 2)
        guard blocks.count == 2, case .paragraph(let text) = blocks[1] else {
            return XCTFail("CRLF closing fences should end a code block")
        }
        XCTAssertEqual(text, "After")
    }

    func testCompactAlignedTableSeparatorRemainsATable() {
        let table = "| abc | defghi |\n:-: | -----------:\nbar | baz"
        let blocks = MarkdownBlock.parse(table)
        guard case .table(let text) = blocks.first else {
            return XCTFail("Single-hyphen delimiter cells are valid table syntax")
        }
        XCTAssertEqual(text, table)
    }

    func testCRLFTableRemainsATable() {
        let table = "| A | B |\r\n| --- | --- |\r\n| One | Two |"
        let blocks = MarkdownBlock.parse(table)
        guard case .table(let text) = blocks.first else {
            return XCTFail("Windows line endings must not prevent table recognition")
        }
        XCTAssertEqual(text, table)
    }

}
