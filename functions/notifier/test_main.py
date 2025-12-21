"""Tests for the notifier Cloud Function.

These tests import and test the ACTUAL production functions from main.py
to ensure tests catch any regressions in production code.
"""
import pytest
from main import (
    sanitize_html,
    sanitize_filename,
    should_process_file,
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

    def test_non_markdown_file(self):
        """Test that non-markdown files are skipped."""
        assert not should_process_file("summaries/data.json")
        assert not should_process_file("summaries/image.png")

    def test_nested_path(self):
        """Test that nested paths in summaries/ are handled."""
        assert should_process_file("summaries/archive/2024-12-18.md")

    def test_empty_filename(self):
        """Test empty filename is rejected."""
        assert not should_process_file("")

    def test_just_summaries_folder(self):
        """Test that folder itself is not processed."""
        assert not should_process_file("summaries/")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
