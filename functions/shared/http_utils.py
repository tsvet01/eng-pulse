"""Shared HTTP utilities for Google Cloud Functions.

Provides common CORS handling and response formatting utilities
to ensure consistent API behavior across all Cloud Functions.
"""
from flask import jsonify
from typing import Any, Dict, Tuple

# Standard CORS headers for API responses
CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "3600",
}


def cors_headers() -> Dict[str, str]:
    """Return standard CORS headers for regular responses.

    Returns:
        Dictionary with Access-Control-Allow-Origin header
    """
    return {"Access-Control-Allow-Origin": "*"}


def handle_cors_preflight() -> Tuple[str, int, Dict[str, str]]:
    """Handle CORS preflight OPTIONS request.

    Returns:
        Empty response tuple with 204 status and full CORS headers
    """
    return ("", 204, CORS_HEADERS)


def json_response(
    data: Dict[str, Any],
    status: int = 200
) -> Tuple[Any, int, Dict[str, str]]:
    """Create a JSON response with CORS headers.

    Args:
        data: Dictionary to serialize as JSON
        status: HTTP status code (default: 200)

    Returns:
        Tuple of (JSON response, status, headers)
    """
    return (jsonify(data), status, cors_headers())


def error_response(
    message: str,
    status: int = 400
) -> Tuple[Any, int, Dict[str, str]]:
    """Create an error JSON response with CORS headers.

    Args:
        message: Error message to return
        status: HTTP status code (default: 400)

    Returns:
        Tuple of (JSON error response, status, headers)
    """
    return (jsonify({"error": message}), status, cors_headers())
