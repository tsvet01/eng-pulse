"""
FCM Token Registration Cloud Function

Provides HTTP endpoints for mobile apps to register their FCM tokens.
Tokens are stored in Firestore for push notification targeting.
"""
import functions_framework
from flask import jsonify, Request
from google.cloud import firestore
from datetime import datetime, timezone
import re
import json
import logging
import sys


# Configure structured JSON logging for Cloud Functions
class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_obj = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "component": "fcm-tokens",
        }
        if hasattr(record, "extra"):
            log_obj.update(record.extra)
        if record.exc_info:
            log_obj["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_obj)


logger = logging.getLogger("fcm-tokens")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JSONFormatter())
logger.handlers = [handler]


def log_info(message: str, **kwargs):
    """Log info with structured data."""
    record = logger.makeRecord(
        "fcm-tokens", logging.INFO, "", 0, message, (), None
    )
    record.extra = kwargs
    logger.handle(record)


def log_error(message: str, **kwargs):
    """Log error with structured data."""
    record = logger.makeRecord(
        "fcm-tokens", logging.ERROR, "", 0, message, (), None
    )
    record.extra = kwargs
    logger.handle(record)

# Firestore collection for FCM tokens
TOKENS_COLLECTION = "fcm_tokens"

# Initialize Firestore client (lazy loaded)
_db = None


def get_db():
    """Lazy-load Firestore client."""
    global _db
    if _db is None:
        _db = firestore.Client()
    return _db


def is_valid_fcm_token(token: str) -> bool:
    """Basic validation for FCM token format."""
    if not token or not isinstance(token, str):
        return False
    # FCM tokens are typically 152-163 characters, using 100-300 for safety margin
    if len(token) < 100 or len(token) > 300:
        return False
    # Should only contain safe characters (alphanumeric, underscore, colon, hyphen)
    if not re.match(r'^[A-Za-z0-9_:\-]+$', token):
        return False
    return True


def is_valid_platform(platform: str) -> bool:
    """Validate platform string."""
    return platform in ("ios", "android", "web")


@functions_framework.http
def register_token(request: Request):
    """
    HTTP endpoint to register an FCM token.

    POST /register-token
    Body: {
        "token": "fcm_token_string",
        "platform": "ios" | "android" | "web",
        "app_version": "1.0.0" (optional)
    }

    Returns:
        200: {"success": true, "message": "Token registered"}
        400: {"error": "Invalid request"}
        405: {"error": "Method not allowed"}
    """
    # Handle CORS preflight
    if request.method == "OPTIONS":
        headers = {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Max-Age": "3600",
        }
        return ("", 204, headers)

    # CORS headers for actual request
    cors_headers = {"Access-Control-Allow-Origin": "*"}

    if request.method != "POST":
        return (jsonify({"error": "Method not allowed"}), 405, cors_headers)

    try:
        data = request.get_json(silent=True)
        if not data:
            return (jsonify({"error": "Invalid JSON body"}), 400, cors_headers)

        token = data.get("token", "").strip()
        platform = data.get("platform", "").strip().lower()
        app_version = data.get("app_version", "").strip()

        # Validate token
        if not is_valid_fcm_token(token):
            return (jsonify({"error": "Invalid FCM token format"}), 400, cors_headers)

        # Validate platform
        if not is_valid_platform(platform):
            return (jsonify({"error": "Invalid platform. Must be ios, android, or web"}), 400, cors_headers)

        # Store in Firestore
        db = get_db()
        doc_ref = db.collection(TOKENS_COLLECTION).document(token)

        now = datetime.now(timezone.utc)
        doc_ref.set({
            "token": token,
            "platform": platform,
            "app_version": app_version if app_version else None,
            "registered_at": now,
            "last_seen": now,
            "active": True,
        }, merge=True)

        log_info("FCM token registered", platform=platform, app_version=app_version)

        return (jsonify({
            "success": True,
            "message": "Token registered successfully"
        }), 200, cors_headers)

    except Exception as e:
        log_error("Error registering FCM token", error=str(e))
        return (jsonify({"error": "Internal server error"}), 500, cors_headers)


@functions_framework.http
def unregister_token(request: Request):
    """
    HTTP endpoint to unregister an FCM token.

    POST /unregister-token
    Body: {"token": "fcm_token_string"}

    Returns:
        200: {"success": true, "message": "Token unregistered"}
        400: {"error": "Invalid request"}
    """
    # Handle CORS preflight
    if request.method == "OPTIONS":
        headers = {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Max-Age": "3600",
        }
        return ("", 204, headers)

    cors_headers = {"Access-Control-Allow-Origin": "*"}

    if request.method != "POST":
        return (jsonify({"error": "Method not allowed"}), 405, cors_headers)

    try:
        data = request.get_json(silent=True)
        if not data:
            return (jsonify({"error": "Invalid JSON body"}), 400, cors_headers)

        token = data.get("token", "").strip()

        if not is_valid_fcm_token(token):
            return (jsonify({"error": "Invalid FCM token format"}), 400, cors_headers)

        # Mark as inactive in Firestore (soft delete)
        # Use set with merge=True to avoid exception if document doesn't exist
        db = get_db()
        doc_ref = db.collection(TOKENS_COLLECTION).document(token)
        doc_ref.set({
            "active": False,
            "unregistered_at": datetime.now(timezone.utc),
        }, merge=True)

        log_info("FCM token unregistered")

        return (jsonify({
            "success": True,
            "message": "Token unregistered successfully"
        }), 200, cors_headers)

    except Exception as e:
        log_error("Error unregistering FCM token", error=str(e))
        return (jsonify({"error": "Internal server error"}), 500, cors_headers)
