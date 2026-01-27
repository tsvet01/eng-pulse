"""Shared logging infrastructure for Google Cloud Functions.

Provides structured JSON logging compatible with Google Cloud Logging,
enabling consistent log formatting and analysis across all Cloud Functions.
"""
import logging
import json
import sys
from typing import Any


class JSONFormatter(logging.Formatter):
    """JSON formatter for Cloud Functions structured logging.

    Formats log records as JSON objects compatible with Cloud Logging,
    enabling structured log analysis and filtering in Google Cloud Console.
    """

    def __init__(self, component: str):
        """Initialize formatter with component name.

        Args:
            component: Name of the cloud function (e.g., 'apns-notifier')
        """
        super().__init__()
        self.component = component

    def format(self, record: logging.LogRecord) -> str:
        """Format log record as JSON string.

        Args:
            record: Log record to format

        Returns:
            JSON-formatted log string
        """
        log_obj = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "component": self.component,
        }

        # Add any extra fields from the record
        if hasattr(record, "extra"):
            log_obj.update(record.extra)

        # Add exception information if present
        if record.exc_info:
            log_obj["exception"] = self.formatException(record.exc_info)

        return json.dumps(log_obj)


class CloudFunctionLogger:
    """Structured logger for Google Cloud Functions.

    Provides convenient methods for logging with structured data that
    integrates seamlessly with Google Cloud Logging.

    Example:
        logger = CloudFunctionLogger("my-function")
        logger.info("User registered", user_id=123, platform="ios")
        logger.error("Database error", error=str(e), query=sql)
    """

    def __init__(self, component: str):
        """Initialize logger for a Cloud Function.

        Args:
            component: Name of the cloud function
        """
        self.component = component
        self.logger = self._setup_logger()

    def _setup_logger(self) -> logging.Logger:
        """Configure logger with JSON formatter for Cloud Logging."""
        logger = logging.getLogger(self.component)
        logger.setLevel(logging.INFO)

        # Remove existing handlers to avoid duplicates
        logger.handlers = []

        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(JSONFormatter(self.component))
        logger.addHandler(handler)

        return logger

    def info(self, message: str, **kwargs: Any) -> None:
        """Log info message with structured data.

        Args:
            message: Human-readable log message
            **kwargs: Additional structured data fields
        """
        record = self.logger.makeRecord(
            self.component, logging.INFO, "", 0, message, (), None
        )
        record.extra = kwargs
        self.logger.handle(record)

    def error(self, message: str, **kwargs: Any) -> None:
        """Log error message with structured data.

        Args:
            message: Human-readable error message
            **kwargs: Additional structured data fields (e.g., error, traceback)
        """
        record = self.logger.makeRecord(
            self.component, logging.ERROR, "", 0, message, (), None
        )
        record.extra = kwargs
        self.logger.handle(record)

    def warning(self, message: str, **kwargs: Any) -> None:
        """Log warning message with structured data.

        Args:
            message: Human-readable warning message
            **kwargs: Additional structured data fields
        """
        record = self.logger.makeRecord(
            self.component, logging.WARNING, "", 0, message, (), None
        )
        record.extra = kwargs
        self.logger.handle(record)
