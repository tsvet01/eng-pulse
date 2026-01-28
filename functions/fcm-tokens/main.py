"""
FCM Token Registration Cloud Function

Provides HTTP endpoints for mobile apps to register their FCM tokens.
Tokens are stored in Firestore for push notification targeting.
"""
import functions_framework
from flask import Request
from datetime import datetime, timezone
import os
import sys

# Add shared module to path for Cloud Functions deployment
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from shared.logging_config import CloudFunctionLogger
from shared.http_utils import handle_cors_preflight, json_response, error_response
from shared.validation import TokenValidator
from shared.firestore_utils import get_db

# Initialize logger
logger = CloudFunctionLogger("fcm-tokens")

# Firestore collection for FCM tokens
FCM_TOKENS_COLLECTION = "fcm_tokens"


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
        return handle_cors_preflight()

    if request.method != "POST":
        return error_response("Method not allowed", 405)

    try:
        data = request.get_json(silent=True)
        if not data:
            return error_response("Invalid JSON body")

        token = data.get("token", "").strip()
        platform = data.get("platform", "").strip().lower()
        app_version = data.get("app_version", "").strip()

        # Validate token using shared validator
        if not TokenValidator.is_valid_fcm_token(token):
            return error_response("Invalid FCM token format")

        # Validate platform using shared validator
        if not TokenValidator.is_valid_platform(platform):
            return error_response("Invalid platform. Must be ios, android, or web")

        # Store in Firestore
        db = get_db()
        doc_ref = db.collection(FCM_TOKENS_COLLECTION).document(token)

        now = datetime.now(timezone.utc)
        doc_ref.set({
            "token": token,
            "platform": platform,
            "app_version": app_version if app_version else None,
            "registered_at": now,
            "last_seen": now,
            "active": True,
        }, merge=True)

        logger.info("FCM token registered", platform=platform, app_version=app_version)

        return json_response({
            "success": True,
            "message": "Token registered successfully"
        })

    except Exception as e:
        logger.error("Error registering FCM token", error=str(e))
        return error_response("Internal server error", 500)


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
        return handle_cors_preflight()

    if request.method != "POST":
        return error_response("Method not allowed", 405)

    try:
        data = request.get_json(silent=True)
        if not data:
            return error_response("Invalid JSON body")

        token = data.get("token", "").strip()

        if not TokenValidator.is_valid_fcm_token(token):
            return error_response("Invalid FCM token format")

        # Mark as inactive in Firestore (soft delete)
        # Use set with merge=True to avoid exception if document doesn't exist
        db = get_db()
        doc_ref = db.collection(FCM_TOKENS_COLLECTION).document(token)
        doc_ref.set({
            "active": False,
            "unregistered_at": datetime.now(timezone.utc),
        }, merge=True)

        logger.info("FCM token unregistered")

        return json_response({
            "success": True,
            "message": "Token unregistered successfully"
        })

    except Exception as e:
        logger.error("Error unregistering FCM token", error=str(e))
        return error_response("Internal server error", 500)
