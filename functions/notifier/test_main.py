"""Tests for the notifier Cloud Function.

These tests import and test the ACTUAL production functions from main.py
to ensure tests catch any regressions in production code.
"""
import json
import pytest
from main import (
    sanitize_html,
    sanitize_filename,
    should_process_file,
    _strip_markdown,
    ALLOWED_TAGS,
    ALLOWED_ATTRS,
)


class TestHtmlSanitization:
    """Tests for HTML sanitization to prevent XSS."""

    def test_basic_markdown(self):
        """Test that basic markdown is converted correctly."""
        content = "# Hello World\n\nThis is a **bold** test."
        result = sanitize_html(content)
        assert "<h1>Hello World</h1>" in result
        assert "<strong>bold</strong>" in result

    def test_xss_script_tag_removed(self):
        """Test that script tags are removed (text content is kept but tags stripped)."""
        content = "Hello <script>alert('xss')</script> World"
        result = sanitize_html(content)
        assert "<script>" not in result
        assert "</script>" not in result
        assert "Hello" in result
        assert "World" in result

    def test_xss_javascript_url_removed(self):
        """Test that javascript: URLs are sanitized."""
        content = '[Click me](javascript:alert("xss"))'
        result = sanitize_html(content)
        assert "javascript:" not in result

    def test_xss_img_onerror_removed(self):
        """Test that img onerror is removed."""
        content = '<img src="x" onerror="alert(\'xss\')">'
        result = sanitize_html(content)
        assert "onerror" not in result
        assert "<img" not in result  # img not in allowed tags

    def test_safe_link_preserved(self):
        """Test that safe links are preserved."""
        content = "[Example](https://example.com)"
        result = sanitize_html(content)
        assert 'href="https://example.com"' in result

    def test_code_blocks_preserved(self):
        """Test that code blocks are preserved."""
        content = "```\ncode here\n```"
        result = sanitize_html(content)
        assert "<code>" in result

    def test_lists_preserved(self):
        """Test that lists are preserved."""
        content = "- Item 1\n- Item 2\n- Item 3"
        result = sanitize_html(content)
        assert "<ul>" in result
        assert "<li>" in result

    def test_allowed_tags_match_production(self):
        """Verify test uses same allowed tags as production."""
        expected_tags = ['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li',
                        'strong', 'em', 'a', 'br', 'hr', 'code', 'pre', 'blockquote']
        assert set(ALLOWED_TAGS) == set(expected_tags)
        assert ALLOWED_ATTRS == {'a': ['href']}


class TestFilenameSanitization:
    """Tests for filename sanitization."""

    def test_normal_filename(self):
        """Test that normal filenames pass through."""
        filename = "2024-12-18"
        result = sanitize_filename(filename)
        assert result == "2024-12-18"

    def test_malicious_filename(self):
        """Test that malicious characters are removed."""
        filename = "2024-12-18<script>alert('xss')</script>"
        result = sanitize_filename(filename)
        assert "<" not in result
        assert ">" not in result
        assert "'" not in result

    def test_path_traversal_blocked(self):
        """Test that path traversal is blocked."""
        filename = "../../../etc/passwd"
        result = sanitize_filename(filename)
        assert "/" not in result

    def test_spaces_preserved(self):
        """Test that spaces are preserved."""
        filename = "My Summary 2024"
        result = sanitize_filename(filename)
        assert result == "My Summary 2024"

    def test_unicode_removed(self):
        """Test that unicode characters are removed."""
        filename = "summary-2024🎉"
        result = sanitize_filename(filename)
        assert "🎉" not in result
        assert "summary-2024" in result


class TestFileFiltering:
    """Tests for file path filtering."""

    def test_valid_summary_file(self):
        """Test that valid summary files are processed."""
        assert should_process_file("summaries/2024-12-18.md")

    def test_non_summary_folder(self):
        """Test that files outside summaries/ are skipped."""
        assert not should_process_file("config/sources.json")
        assert not should_process_file("other/2024-12-18.md")

    def test_non_markdown_non_json_file(self):
        """Test that non-markdown, non-json files are skipped."""
        assert not should_process_file("summaries/image.png")
        assert not should_process_file("summaries/data.csv")

    def test_v3_json_file_accepted(self):
        """Test that V3 JSON summary files are processed."""
        assert should_process_file("summaries/v3/2026-04-01.json")
        assert should_process_file("summaries/2026-04-01.json")

    def test_nested_path(self):
        """Test that nested paths in summaries/ are handled."""
        assert should_process_file("summaries/archive/2024-12-18.md")

    def test_empty_filename(self):
        """Test empty filename is rejected."""
        assert not should_process_file("")

    def test_just_summaries_folder(self):
        """Test that folder itself is not processed."""
        assert not should_process_file("summaries/")


class TestStripMarkdown:
    """Tests for notification text cleaning."""

    def test_strips_bold(self):
        assert _strip_markdown("**bold text**") == "bold text"

    def test_strips_italic(self):
        assert _strip_markdown("*italic*") == "italic"

    def test_strips_inline_code(self):
        assert _strip_markdown("`@property`") == "@property"

    def test_strips_headings(self):
        assert _strip_markdown("# Title Here") == "Title Here"
        assert _strip_markdown("## Subtitle") == "Subtitle"

    def test_strips_bullet_lists(self):
        assert _strip_markdown("- item one") == "item one"
        assert _strip_markdown("* item two") == "item two"

    def test_strips_links(self):
        assert _strip_markdown("[click here](https://example.com)") == "click here"

    def test_strips_images(self):
        assert _strip_markdown("![alt](https://img.png)") == ""

    def test_strips_blockquotes(self):
        assert _strip_markdown("> quoted text") == "quoted text"

    def test_strips_code_blocks(self):
        result = _strip_markdown("```python\nprint('hello')\n```")
        assert "```" not in result
        assert "print" not in result

    def test_complex_notification_title(self):
        """Regression: raw markdown was appearing in push notification titles."""
        raw = "- **`@property`** — registering computed attributes"
        result = _strip_markdown(raw)
        assert "**" not in result
        assert "`" not in result
        assert "- " not in result
        assert "@property" in result

    def test_llm_preamble_not_used_as_title(self):
        """The title extractor should only pick # headings, not LLM preamble."""
        content = "Here is a compact, educational summary.\n\n# The Real Title\n\nBody text."
        # _strip_markdown just cleans text — title extraction is separate
        # But the cleaned content should not have markdown artifacts
        result = _strip_markdown(content)
        assert "#" not in result
        assert "The Real Title" in result


def test_render_insight_brief_html():
    from main import render_insight_brief_html
    content = json.dumps({
        "key_idea": "Test insight",
        "why_it_matters": "Because reasons",
        "what_to_change": "Try this",
        "deep_dive": "## Details\n\nSome **bold** text.",
        "meta": {"confidence": 0.9, "category": "general"}
    })
    html = render_insight_brief_html(content)
    assert "KEY IDEA" in html
    assert "Test insight" in html
    assert "WHY IT MATTERS" in html
    assert "WHAT TO CHANGE" in html
    assert "Details" in html


def test_render_insight_brief_html_no_action():
    from main import render_insight_brief_html
    content = json.dumps({
        "key_idea": "Insight",
        "why_it_matters": "Matters",
        "what_to_change": None,
        "deep_dive": "Deep content",
    })
    html = render_insight_brief_html(content)
    assert "KEY IDEA" in html
    assert "WHAT TO CHANGE" not in html


def test_render_insight_brief_html_fallback():
    from main import render_insight_brief_html
    html = render_insight_brief_html("# Regular markdown\n\nSome text")
    assert "Regular markdown" in html


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
