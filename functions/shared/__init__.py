"""Shared infrastructure for Google Cloud Functions.

APNs utilities are not eagerly imported to avoid loading httpx, jwt, and
secretmanager dependencies in functions that don't need them (e.g. fcm-tokens).
Import directly from shared.apns_utils when needed.
"""
from .logging_config import CloudFunctionLogger
from .http_utils import cors_headers, handle_cors_preflight, json_response, error_response
from .validation import TokenValidator
from .firestore_utils import get_db, reset_db

__all__ = [
    "CloudFunctionLogger",
    "cors_headers",
    "handle_cors_preflight",
    "json_response",
    "error_response",
    "TokenValidator",
    "get_db",
    "reset_db",
]
