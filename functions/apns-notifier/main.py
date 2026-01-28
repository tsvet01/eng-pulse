"""
APNs Notification Service for iOS Swift App

Handles:
1. APNs token registration (separate from FCM tokens)
2. Sending push notifications via Apple's APNs HTTP/2 API
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
from shared.apns_utils import send_apns_notifications, APNS_TOKENS_COLLECTION

# Initialize logger
logger = CloudFunctionLogger("apns-notifier")


@functions_framework.http
def register_apns_token(request: Request):
    """
    HTTP endpoint to register an APNs token.

    POST /register-apns-token
    Body: {
        "token": "apns_device_token_hex_string",
        "app_version": "1.0.0" (optional),
        "sandbox": false (optional, defaults to false for production)
    }
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

        token = data.get("token", "").strip().lower()
        app_version = data.get("app_version", "").strip()
        sandbox = data.get("sandbox", False)

        # Validate token using shared validator
        if not TokenValidator.is_valid_apns_token(token):
            return error_response("Invalid APNs token format")

        # Store in Firestore
        db = get_db()
        doc_ref = db.collection(APNS_TOKENS_COLLECTION).document(token)

        now = datetime.now(timezone.utc)
        doc_ref.set({
            "token": token,
            "platform": "ios",
            "app_version": app_version if app_version else None,
            "sandbox": sandbox,
            "registered_at": now,
            "last_seen": now,
            "active": True,
        }, merge=True)

        logger.info("APNs token registered", sandbox=sandbox, app_version=app_version)

        return json_response({
            "success": True,
            "message": "APNs token registered successfully"
        })

    except Exception as e:
        logger.error("Error registering APNs token", error=str(e))
        return error_response("Internal server error", 500)


@functions_framework.http
def trigger_apns_notification(request: Request):
    """
    Manual trigger for APNs notifications (for testing).

    POST /trigger-apns
    Body: {
        "title": "Notification title",
        "body": "Notification body",
        "article_url": "https://..."
    }
    """
    if request.method == "OPTIONS":
        return handle_cors_preflight()

    if request.method != "POST":
        return error_response("Method not allowed", 405)

    try:
        data = request.get_json(silent=True) or {}
        title = data.get("title", "Test Notification")
        body = data.get("body", "This is a test notification")
        article_url = data.get("article_url", "https://example.com")

        count = send_apns_notifications(title, body, article_url)

        return json_response({
            "success": True,
            "notifications_sent": count
        })

    except Exception as e:
        logger.error("Error triggering APNs", error=str(e))
        return error_response(str(e), 500)
