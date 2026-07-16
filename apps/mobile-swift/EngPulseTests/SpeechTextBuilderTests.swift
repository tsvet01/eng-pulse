import XCTest
@testable import EngPulse

final class SpeechTextBuilderTests: XCTestCase {

    private func summary(format: String? = nil) -> Summary {
        Summary(
            date: "2026-07-15",
            url: "https://example.com/article.md",
            title: "Test Article",
            format: format
        )
    }

    func testPlainMarkdownPassesThrough() {
        let content = "# Heading\n\nSome **markdown** body."
        XCTAssertEqual(SpeechTextBuilder.speechText(for: summary(), content: content), content)
    }

    func testInsightBriefComposesFields() {
        let json = """
        {
            "key_idea": "Idea.",
            "why_it_matters": "It matters.",
            "what_to_change": "Change this.",
            "deep_dive": "Deep dive text."
        }
        """
        let result = SpeechTextBuilder.speechText(for: summary(format: "insight-brief-v3"), content: json)
        XCTAssertEqual(result, "Idea.\n\nIt matters.\n\nChange this.\n\nDeep dive text.")
    }

    func testInsightBriefSkipsMissingWhatToChange() {
        let json = """
        {
            "key_idea": "Idea.",
            "why_it_matters": "It matters.",
            "deep_dive": "Deep dive text."
        }
        """
        let result = SpeechTextBuilder.speechText(for: summary(format: "insight-brief-v3"), content: json)
        XCTAssertEqual(result, "Idea.\n\nIt matters.\n\nDeep dive text.")
    }

    func testInsightBriefWithInvalidJSONFallsBackToRawContent() {
        let content = "not valid json"
        let result = SpeechTextBuilder.speechText(for: summary(format: "insight-brief-v3"), content: content)
        XCTAssertEqual(result, content)
    }

    func testNonBriefFormatIgnoresJSONContent() {
        let json = """
        {"key_idea": "Idea.", "why_it_matters": "M.", "deep_dive": "D."}
        """
        XCTAssertEqual(SpeechTextBuilder.speechText(for: summary(), content: json), json)
    }
}
