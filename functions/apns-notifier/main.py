"""
APNs Notification Service for iOS Swift App

Handles:
1. APNs token registration (separate from FCM tokens)
2. Sending push notifications via Apple's APNs HTTP/2 API
"""
import functions_framework
from flask import jsonify, Request
from google.cloud import firestore
from google.cloud import secretmanager
from datetime import datetime, timezone
import jwt
import time
import httpx
import re
import os
import json
import logging
import sys


# Configure structured JSON logging for Cloud Functions
class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_obj = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "component": "apns-notifier",
        }
        if hasattr(record, "extra"):
            log_obj.update(record.extra)
        if record.exc_info:
            log_obj["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_obj)


logger = logging.getLogger("apns-notifier")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JSONFormatter())
logger.handlers = [handler]


def log_info(message: str, **kwargs):
    """Log info with structured data."""
    record = logger.makeRecord(
        "apns-notifier", logging.INFO, "", 0, message, (), None
    )
    record.extra = kwargs
    logger.handle(record)


def log_error(message: str, **kwargs):
    """Log error with structured data."""
    record = logger.makeRecord(
        "apns-notifier", logging.ERROR, "", 0, message, (), None
    )
    record.extra = kwargs
    logger.handle(record)

# Firestore collection for APNs tokens
APNS_TOKENS_COLLECTION = "apns_tokens"

# APNs endpoints
APNS_PRODUCTION = "https://api.push.apple.com"
APNS_SANDBOX = "https://api.sandbox.push.apple.com"

# App bundle ID (configurable for different environments)
BUNDLE_ID = os.environ.get('APNS_BUNDLE_ID', 'org.tsvetkov.EngPulseSwift')

# Secret Manager paths
PROJECT_ID = os.environ.get('GOOGLE_CLOUD_PROJECT', 'tsvet01')

# Lazy-loaded clients
_db = None
_apns_key = None
_apns_key_id = None
_apns_team_id = None


def get_db():
    """Lazy-load Firestore client."""
    global _db
    if _db is None:
        _db = firestore.Client()
    return _db


def get_apns_credentials():
    """Load APNs credentials from Secret Manager."""
    global _apns_key, _apns_key_id, _apns_team_id

    if _apns_key is not None:
        return _apns_key, _apns_key_id, _apns_team_id

    client = secretmanager.SecretManagerServiceClient()

    # Get the .p8 key content
    key_path = f"projects/{PROJECT_ID}/secrets/apns-auth-key/versions/latest"
    key_response = client.access_secret_version(request={"name": key_path})
    _apns_key = key_response.payload.data.decode("UTF-8")

    # Get Key ID
    key_id_path = f"projects/{PROJECT_ID}/secrets/apns-key-id/versions/latest"
    key_id_response = client.access_secret_version(request={"name": key_id_path})
    _apns_key_id = key_id_response.payload.data.decode("UTF-8").strip()

    # Get Team ID
    team_id_path = f"projects/{PROJECT_ID}/secrets/apns-team-id/versions/latest"
    team_id_response = client.access_secret_version(request={"name": team_id_path})
    _apns_team_id = team_id_response.payload.data.decode("UTF-8").strip()

    return _apns_key, _apns_key_id, _apns_team_id


def create_apns_jwt():
    """Create a JWT for APNs authentication."""
    auth_key, key_id, team_id = get_apns_credentials()

    token = jwt.encode(
        {
            "iss": team_id,
            "iat": int(time.time())
        },
        auth_key,
        algorithm="ES256",
        headers={
            "alg": "ES256",
            "kid": key_id
        }
    )
    return token


def is_valid_apns_token(token: str) -> bool:
    """Basic validation for APNs device token format."""
    if not token or not isinstance(token, str):
        return False
    # APNs tokens are 64 hex characters
    if len(token) != 64:
        return False
    # Should only contain hex characters
    if not re.match(r'^[a-fA-F0-9]+$', token):
        return False
    return True


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

        token = data.get("token", "").strip().lower()
        app_version = data.get("app_version", "").strip()
        sandbox = data.get("sandbox", False)

        # Validate token
        if not is_valid_apns_token(token):
            return (jsonify({"error": "Invalid APNs token format"}), 400, cors_headers)

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

        log_info("APNs token registered", sandbox=sandbox, app_version=app_version)

        return (jsonify({
            "success": True,
            "message": "APNs token registered successfully"
        }), 200, cors_headers)

    except Exception as e:
        log_error("Error registering APNs token", error=str(e))
        return (jsonify({"error": "Internal server error"}), 500, cors_headers)


def send_apns_notification(token: str, title: str, body: str, article_url: str, sandbox: bool = False) -> tuple[bool, str]:
    """
    Send a notification to a single APNs device.

    Returns:
        (success: bool, error_reason: str)
    """
    try:
        jwt_token = create_apns_jwt()

        endpoint = APNS_SANDBOX if sandbox else APNS_PRODUCTION
        url = f"{endpoint}/3/device/{token}"

        headers = {
            "authorization": f"bearer {jwt_token}",
            "apns-topic": BUNDLE_ID,
            "apns-push-type": "alert",
            "apns-priority": "10",
        }

        payload = {
            "aps": {
                "alert": {
                    "title": title,
                    "body": body,
                },
                "sound": "default",
                "badge": 1,
            },
            "article_url": article_url,
        }

        with httpx.Client(http2=True, timeout=10.0) as client:
            response = client.post(url, headers=headers, json=payload)

            if response.status_code == 200:
                return True, ""
            else:
                error_data = response.json() if response.content else {}
                reason = error_data.get("reason", f"HTTP {response.status_code}")
                return False, reason

    except Exception as e:
        return False, str(e)


def send_apns_notifications(title: str, body: str, article_url: str) -> int:
    """
    Send APNs push notifications to all registered iOS devices.

    Returns:
        Number of notifications sent successfully
    """
    try:
        db = get_db()
        tokens_ref = db.collection(APNS_TOKENS_COLLECTION).where("active", "==", True)
        docs = list(tokens_ref.stream())

        if not docs:
            log_info("No active APNs tokens found")
            return 0

        log_info("Sending APNs notifications", device_count=len(docs))
        success_count = 0

        for doc in docs:
            data = doc.to_dict()
            token = data.get("token")
            sandbox = data.get("sandbox", False)

            if not token:
                continue

            success, reason = send_apns_notification(
                token, title, body, article_url, sandbox
            )

            if success:
                success_count += 1
            else:
                log_error("Failed to send APNs", reason=reason)
                # Mark invalid tokens as inactive
                if reason in ("BadDeviceToken", "Unregistered", "ExpiredToken"):
                    try:
                        doc.reference.update({"active": False})
                        log_info("Marked APNs token as inactive")
                    except Exception as e:
                        log_error("Failed to deactivate APNs token", error=str(e))

        log_info("APNs notifications complete", success=success_count, total=len(docs))
        return success_count

    except Exception as e:
        log_error("Error sending APNs notifications", error=str(e))
        import traceback
        traceback.print_exc()
        return 0


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
    cors_headers = {"Access-Control-Allow-Origin": "*"}

    if request.method == "OPTIONS":
        return ("", 204, {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        })

    if request.method != "POST":
        return (jsonify({"error": "Method not allowed"}), 405, cors_headers)

    try:
        data = request.get_json(silent=True) or {}
        title = data.get("title", "Test Notification")
        body = data.get("body", "This is a test notification")
        article_url = data.get("article_url", "https://example.com")

        count = send_apns_notifications(title, body, article_url)

        return (jsonify({
            "success": True,
            "notifications_sent": count
        }), 200, cors_headers)

    except Exception as e:
        log_error("Error triggering APNs", error=str(e))
        return (jsonify({"error": str(e)}), 500, cors_headers)
