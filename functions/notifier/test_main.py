"""Tests for the notifier Cloud Function."""
import pytest
import markdown
import bleach


class TestHtmlSanitization:
    """Tests for HTML sanitization to prevent XSS."""

    ALLOWED_TAGS = ['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li',
                    'strong', 'em', 'a', 'br', 'hr', 'code', 'pre', 'blockquote']
    ALLOWED_ATTRS = {'a': ['href']}

    def sanitize(self, content: str) -> str:
        """Sanitize markdown content like the notifier does."""
        raw_html = markdown.markdown(content)
        return bleach.clean(
            raw_html,
            tags=self.ALLOWED_TAGS,
            attributes=self.ALLOWED_ATTRS,
            strip=True
        )

    def test_basic_markdown(self):
        """Test that basic markdown is converted correctly."""
        content = "# Hello World\n\nThis is a **bold** test."
        result = self.sanitize(content)
        assert "<h1>Hello World</h1>" in result
        assert "<strong>bold</strong>" in result

    def test_xss_script_tag_removed(self):
        """Test that script tags are removed (text content is kept but tags stripped)."""
        content = "Hello <script>alert('xss')</script> World"
        result = self.sanitize(content)
        assert "<script>" not in result
        assert "</script>" not in result
        assert "Hello" in result
        assert "World" in result

    def test_xss_onclick_removed(self):
        """Test that onclick attributes are removed."""
        content = '[Click me](javascript:alert("xss"))'
        result = self.sanitize(content)
        assert "javascript:" not in result

    def test_xss_img_onerror_removed(self):
        """Test that img onerror is removed."""
        content = '<img src="x" onerror="alert(\'xss\')">'
        result = self.sanitize(content)
        assert "onerror" not in result
        assert "<img" not in result  # img not in allowed tags

    def test_safe_link_preserved(self):
        """Test that safe links are preserved."""
        content = "[Example](https://example.com)"
        result = self.sanitize(content)
        assert 'href="https://example.com"' in result

    def test_code_blocks_preserved(self):
        """Test that code blocks are preserved."""
        content = "```\ncode here\n```"
        result = self.sanitize(content)
        assert "<code>" in result or "code here" in result

    def test_lists_preserved(self):
        """Test that lists are preserved."""
        content = "- Item 1\n- Item 2\n- Item 3"
        result = self.sanitize(content)
        assert "<ul>" in result
        assert "<li>" in result


class TestFilenameSanitization:
    """Tests for filename sanitization."""

    def sanitize_filename(self, filename: str) -> str:
        """Sanitize filename like the notifier does."""
        return ''.join(c for c in filename if c.isalnum() or c in '-_. ')

    def test_normal_filename(self):
        """Test that normal filenames pass through."""
        filename = "2024-12-18"
        result = self.sanitize_filename(filename)
        assert result == "2024-12-18"

    def test_malicious_filename(self):
        """Test that malicious characters are removed."""
        filename = "2024-12-18<script>alert('xss')</script>"
        result = self.sanitize_filename(filename)
        assert "<" not in result
        assert ">" not in result
        assert "script" in result  # letters are allowed

    def test_path_traversal_blocked(self):
        """Test that path traversal is blocked."""
        filename = "../../../etc/passwd"
        result = self.sanitize_filename(filename)
        assert "/" not in result

    def test_spaces_preserved(self):
        """Test that spaces are preserved."""
        filename = "My Summary 2024"
        result = self.sanitize_filename(filename)
        assert result == "My Summary 2024"


class TestFileFiltering:
    """Tests for file path filtering."""

    def should_process(self, file_name: str) -> bool:
        """Check if file should be processed like the notifier does."""
        return file_name.startswith("summaries/") and file_name.endswith(".md")

    def test_valid_summary_file(self):
        """Test that valid summary files are processed."""
        assert self.should_process("summaries/2024-12-18.md")

    def test_non_summary_folder(self):
        """Test that files outside summaries/ are skipped."""
        assert not self.should_process("config/sources.json")
        assert not self.should_process("other/2024-12-18.md")

    def test_non_markdown_file(self):
        """Test that non-markdown files are skipped."""
        assert not self.should_process("summaries/data.json")
        assert not self.should_process("summaries/image.png")

    def test_nested_path(self):
        """Test that nested paths are handled."""
        # summaries/subdir/file.md should work
        assert self.should_process("summaries/archive/2024-12-18.md")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
