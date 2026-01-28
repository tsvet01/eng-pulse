"""Tests for shared logging configuration."""
import json
import logging
from unittest.mock import patch
from io import StringIO
from shared.logging_config import CloudFunctionLogger, JSONFormatter


class TestJSONFormatter:
    """Tests for JSONFormatter."""

    def test_json_format_output(self):
        formatter = JSONFormatter("test-component")
        record = logging.LogRecord(
            "test", logging.INFO, "", 0, "Test message", (), None
        )
        output = formatter.format(record)
        parsed = json.loads(output)
        assert parsed["severity"] == "INFO"
        assert parsed["message"] == "Test message"
        assert parsed["component"] == "test-component"

    def test_severity_levels(self):
        formatter = JSONFormatter("test")
        for level, expected in [
            (logging.DEBUG, "DEBUG"),
            (logging.INFO, "INFO"),
            (logging.WARNING, "WARNING"),
            (logging.ERROR, "ERROR"),
            (logging.CRITICAL, "CRITICAL"),
        ]:
            record = logging.LogRecord(
                "test", level, "", 0, "msg", (), None)
            output = formatter.format(record)
            parsed = json.loads(output)
            assert parsed["severity"] == expected

    def test_extra_kwargs_included(self):
        formatter = JSONFormatter("test")
        record = logging.LogRecord(
            "test", logging.INFO, "", 0, "msg", (), None)
        record.extra = {"user_id": 123, "platform": "ios"}
        output = formatter.format(record)
        parsed = json.loads(output)
        assert parsed["user_id"] == 123
        assert parsed["platform"] == "ios"

    def test_exception_info_included(self):
        formatter = JSONFormatter("test")
        try:
            raise ValueError("test error")
        except ValueError:
            import sys
            exc_info = sys.exc_info()
        record = logging.LogRecord(
            "test", logging.ERROR, "", 0, "error occurred",
            (), exc_info)
        output = formatter.format(record)
        parsed = json.loads(output)
        assert "exception" in parsed
        assert "ValueError" in parsed["exception"]


class TestCloudFunctionLogger:
    """Tests for CloudFunctionLogger."""

    def _make_logger_with_capture(self, component):
        """Create logger with a StringIO stream for capture."""
        stream = StringIO()
        cloud_logger = CloudFunctionLogger(component)
        # Replace the handler's stream with our capture stream
        for handler in cloud_logger.logger.handlers:
            handler.stream = stream
        return cloud_logger, stream

    def test_info_logging(self):
        cloud_logger, stream = self._make_logger_with_capture("test-fn")
        cloud_logger.info("Hello", key="value")
        output = stream.getvalue()
        parsed = json.loads(output.strip())
        assert parsed["severity"] == "INFO"
        assert parsed["message"] == "Hello"
        assert parsed["key"] == "value"

    def test_error_logging(self):
        cloud_logger, stream = self._make_logger_with_capture("test-fn")
        cloud_logger.error("Bad thing", error="details")
        output = stream.getvalue()
        parsed = json.loads(output.strip())
        assert parsed["severity"] == "ERROR"
        assert parsed["error"] == "details"

    def test_warning_logging(self):
        cloud_logger, stream = self._make_logger_with_capture("test-fn")
        cloud_logger.warning("Caution", code=42)
        output = stream.getvalue()
        parsed = json.loads(output.strip())
        assert parsed["severity"] == "WARNING"
        assert parsed["code"] == 42

    def test_component_name(self):
        cloud_logger, stream = self._make_logger_with_capture(
            "my-function")
        cloud_logger.info("test")
        output = stream.getvalue()
        parsed = json.loads(output.strip())
        assert parsed["component"] == "my-function"
