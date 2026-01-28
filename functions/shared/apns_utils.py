"""Shared APNs utilities for Google Cloud Functions.

Provides APNs credential loading, JWT creation, and notification sending
shared across notifier and apns-notifier functions.
"""
import os
import time
import jwt
import httpx
from google.cloud import secretmanager
from .logging_config import CloudFunctionLogger

logger = CloudFunctionLogger("apns-utils")

APNS_TOKENS_COLLECTION = "apns_tokens"
APNS_PRODUCTION_URL = os.environ.get(
    'APNS_PRODUCTION_URL', 'https://api.push.apple.com')
APNS_SANDBOX_URL = os.environ.get(
    'APNS_SANDBOX_URL', 'https://api.sandbox.push.apple.com')
BUNDLE_ID = os.environ.get('APNS_BUNDLE_ID', 'org.tsvetkov.EngPulseSwift')
PROJECT_ID = os.environ.get('GOOGLE_CLOUD_PROJECT', 'tsvet01')

_apns_key = None
_apns_key_id = None
_apns_team_id = None


def get_apns_credentials():
    """Load APNs credentials from Secret Manager.

    Returns:
        Tuple of (auth_key, key_id, team_id) or (None, None, None) on error.
    """
    global _apns_key, _apns_key_id, _apns_team_id

    if _apns_key is not None:
        return _apns_key, _apns_key_id, _apns_team_id

    try:
        client = secretmanager.SecretManagerServiceClient()

        key_path = f"projects/{PROJECT_ID}/secrets/apns-auth-key/versions/latest"
        key_response = client.access_secret_version(
            request={"name": key_path})
        _apns_key = key_response.payload.data.decode("UTF-8")

        key_id_path = f"projects/{PROJECT_ID}/secrets/apns-key-id/versions/latest"
        key_id_response = client.access_secret_version(
            request={"name": key_id_path})
        _apns_key_id = key_id_response.payload.data.decode("UTF-8").strip()

        team_id_path = f"projects/{PROJECT_ID}/secrets/apns-team-id/versions/latest"
        team_id_response = client.access_secret_version(
            request={"name": team_id_path})
        _apns_team_id = team_id_response.payload.data.decode("UTF-8").strip()

        return _apns_key, _apns_key_id, _apns_team_id
    except Exception as e:
        logger.error("Failed to load APNs credentials", error=str(e))
        return None, None, None


def reset_apns_credentials():
    """Clear the cached APNs credentials (for testing)."""
    global _apns_key, _apns_key_id, _apns_team_id
    _apns_key = None
    _apns_key_id = None
    _apns_team_id = None


def create_apns_jwt():
    """Create a JWT for APNs authentication.

    Returns:
        JWT token string, or None if credentials are unavailable.
    """
    auth_key, key_id, team_id = get_apns_credentials()
    if not all([auth_key, key_id, team_id]):
        return None

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


def send_apns_notification(
    token: str, title: str, body: str,
    article_url: str, sandbox: bool = False
):
    """Send a notification to a single APNs device.

    Returns:
        Tuple of (success: bool, error_reason: str)
    """
    try:
        jwt_token = create_apns_jwt()
        if not jwt_token:
            return False, "No APNs credentials"

        endpoint = APNS_SANDBOX_URL if sandbox else APNS_PRODUCTION_URL
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
            try:
                error_data = response.json() if response.content else {}
                reason = error_data.get("reason", f"HTTP {response.status_code}")
            except (ValueError, TypeError):
                reason = f"HTTP {response.status_code}"
            return False, reason

    except Exception as e:
        return False, str(e)


def send_apns_notifications(
    title: str, body: str, article_url: str, db=None
) -> int:
    """Send APNs push notifications to all registered iOS devices.

    Args:
        title: Notification title
        body: Notification body
        article_url: URL to the summary
        db: Optional Firestore client (for dependency injection in tests)

    Returns:
        Number of notifications sent successfully
    """
    try:
        if db is None:
            from .firestore_utils import get_db
            db = get_db()

        tokens_ref = db.collection(
            APNS_TOKENS_COLLECTION).where("active", "==", True)
        docs = list(tokens_ref.stream())

        if not docs:
            logger.info("No active APNs tokens found")
            return 0

        logger.info("Sending APNs notifications", device_count=len(docs))
        success_count = 0

        for doc in docs:
            data = doc.to_dict()
            token = data.get("token")
            sandbox = data.get("sandbox", False)

            if not token:
                continue

            success, reason = send_apns_notification(
                token, title, body, article_url, sandbox)

            if success:
                success_count += 1
            else:
                logger.error("Failed to send APNs", reason=reason)
                if reason in (
                    "BadDeviceToken", "Unregistered", "ExpiredToken"
                ):
                    try:
                        doc.reference.update({"active": False})
                        logger.info("Marked APNs token as inactive")
                    except Exception as e:
                        logger.error(
                            "Failed to deactivate APNs token",
                            error=str(e))

        logger.info(
            "APNs notifications complete",
            success=success_count, total=len(docs))
        return success_count

    except Exception as e:
        import traceback
        logger.error("Error sending APNs notifications", error=str(e),
                     traceback=traceback.format_exc())
        return 0
