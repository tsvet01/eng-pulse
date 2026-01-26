"""
Notifier Cloud Function

Handles:
1. GCS event notifications for new summary files
2. Email notifications via Gmail
3. FCM push notifications to mobile apps
4. APNs push notifications to iOS Swift app
"""
import functions_framework
import os
import smtplib
import time
import requests
import httpx
import jwt
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from google.cloud import storage
from google.cloud import firestore
from google.cloud import secretmanager
from google.auth.transport.requests import Request
import google.auth
import markdown
import bleach
import sys

# Add shared module to path for Cloud Functions deployment
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from shared.logging_config import CloudFunctionLogger

# Initialize logger
logger = CloudFunctionLogger("notifier")

# FCM HTTP v1 API endpoint
FCM_API_URL = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
PROJECT_ID = os.environ.get('GOOGLE_CLOUD_PROJECT', 'tsvet01')

# APNs configuration
APNS_TOKENS_COLLECTION = "apns_tokens"
APNS_PRODUCTION_URL = "https://api.push.apple.com"
APNS_SANDBOX_URL = "https://api.sandbox.push.apple.com"
BUNDLE_ID = os.environ.get('APNS_BUNDLE_ID', 'org.tsvetkov.EngPulseSwift')

# Lazy-loaded APNs credentials
_apns_key = None
_apns_key_id = None
_apns_team_id = None


def get_access_token():
    """Get OAuth2 access token for FCM API using application default credentials."""
    credentials, project = google.auth.default(
        scopes=['https://www.googleapis.com/auth/firebase.messaging']
    )
    credentials.refresh(Request())
    return credentials.token


# Allowed HTML tags for email content sanitization
ALLOWED_TAGS = ['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li',
                'strong', 'em', 'a', 'br', 'hr', 'code', 'pre', 'blockquote']
ALLOWED_ATTRS = {'a': ['href']}


def sanitize_html(content: str) -> str:
    """Convert markdown to HTML and sanitize to prevent XSS."""
    raw_html = markdown.markdown(content)
    return bleach.clean(
        raw_html,
        tags=ALLOWED_TAGS,
        attributes=ALLOWED_ATTRS,
        strip=True
    )


def sanitize_filename(filename: str) -> str:
    """Sanitize filename for email subject (allow only safe chars)."""
    return ''.join(c for c in filename if c.isalnum() or c in '-_. ')


def should_process_file(file_name: str) -> bool:
    """Check if file should be processed (summaries/*.md only)."""
    return file_name.startswith("summaries/") and file_name.endswith(".md")


def send_fcm_notification_http(token: str, title: str, body: str, article_url: str, access_token: str) -> tuple[bool, str]:
    """Send FCM notification using HTTP v1 API."""
    url = FCM_API_URL.format(project_id=PROJECT_ID)
    headers = {
        'Authorization': f'Bearer {access_token}',
        'Content-Type': 'application/json; UTF-8',
    }
    payload = {
        'message': {
            'token': token,
            'notification': {
                'title': title,
                'body': body,
            },
            'data': {
                'article_url': article_url,
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            },
        }
    }

    response = requests.post(url, headers=headers, json=payload, timeout=10)
    return response.status_code == 200, response.text


def send_fcm_notifications(title: str, body: str, article_url: str) -> int:
    """
    Send FCM push notifications to all registered devices.

    Args:
        title: Notification title
        body: Notification body (summary snippet)
        article_url: URL to the summary for deep linking

    Returns:
        Number of notifications sent successfully
    """
    try:
        # Get access token for FCM API
        access_token = get_access_token()
        logger.info("Got FCM access token")

        # Get all active FCM tokens from Firestore
        db = firestore.Client()
        tokens_ref = db.collection("fcm_tokens").where("active", "==", True)
        docs = tokens_ref.stream()

        tokens = []
        doc_ids = []
        for doc in docs:
            data = doc.to_dict()
            if data.get("token"):
                tokens.append(data["token"])
                doc_ids.append(doc.id)

        if not tokens:
            logger.info("No active FCM tokens found")
            return 0

        logger.info("Sending FCM notifications", device_count=len(tokens))
        success_count = 0

        for i, token in enumerate(tokens):
            success, response_text = send_fcm_notification_http(
                token, title, body, article_url, access_token
            )
            if success:
                success_count += 1
            else:
                logger.error("Failed to send FCM", device_index=i+1, error=response_text)
                # Mark invalid tokens as inactive
                if 'UNREGISTERED' in response_text or 'INVALID_ARGUMENT' in response_text:
                    try:
                        db.collection("fcm_tokens").document(doc_ids[i]).update({
                            "active": False
                        })
                        logger.info("Marked FCM token as inactive", token_id=doc_ids[i])
                    except Exception as e:
                        logger.error("Failed to deactivate FCM token", error=str(e))

        logger.info("FCM notifications complete", success=success_count, total=len(tokens))
        return success_count

    except Exception as e:
        logger.error("Error sending FCM notifications", error=str(e))
        import traceback
        traceback.print_exc()
        return 0


# ============ APNs Functions ============

def get_apns_credentials():
    """Load APNs credentials from Secret Manager."""
    global _apns_key, _apns_key_id, _apns_team_id

    if _apns_key is not None:
        return _apns_key, _apns_key_id, _apns_team_id

    try:
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
    except Exception as e:
        logger.error("Failed to load APNs credentials", error=str(e))
        return None, None, None


def create_apns_jwt():
    """Create a JWT for APNs authentication."""
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


def send_apns_notification(token: str, title: str, body: str, article_url: str, sandbox: bool = False):
    """Send a notification to a single APNs device."""
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
            else:
                error_data = response.json() if response.content else {}
                reason = error_data.get("reason", f"HTTP {response.status_code}")
                return False, reason

    except Exception as e:
        return False, str(e)


def send_apns_notifications(title: str, body: str, article_url: str) -> int:
    """Send APNs push notifications to all registered iOS devices."""
    try:
        db = firestore.Client()
        tokens_ref = db.collection(APNS_TOKENS_COLLECTION).where("active", "==", True)
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

            success, reason = send_apns_notification(token, title, body, article_url, sandbox)

            if success:
                success_count += 1
            else:
                logger.error("Failed to send APNs", reason=reason)
                if reason in ("BadDeviceToken", "Unregistered", "ExpiredToken"):
                    try:
                        doc.reference.update({"active": False})
                        logger.info("Marked APNs token as inactive")
                    except Exception as e:
                        logger.error("Failed to deactivate APNs token", error=str(e))

        logger.info("APNs notifications complete", success=success_count, total=len(docs))
        return success_count

    except Exception as e:
        logger.error("Error sending APNs notifications", error=str(e))
        import traceback
        traceback.print_exc()
        return 0


@functions_framework.cloud_event
def send_summary_email(cloud_event):
    data = cloud_event.data
    bucket_name = data["bucket"]
    file_name = data["name"]

    logger.info(
        "Processing GCS event",
        event_id=cloud_event["id"],
        event_type=cloud_event["type"],
        bucket=bucket_name,
        file=file_name,
    )

    # Only process files in 'summaries/' folder
    if not should_process_file(file_name):
        logger.info("Skipping non-summary file", file=file_name)
        return

    # Download content
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(file_name)
    content = blob.download_as_text()

    # Parse Markdown to HTML and sanitize to prevent XSS
    html_content = sanitize_html(content)

    # Send Email
    send_email(file_name, html_content)

    # Send FCM push notifications
    # Extract title from content (first line or heading)
    title = "Daily Engineering Briefing"
    lines = content.strip().split('\n')
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('#'):
            title = stripped.lstrip('#').strip()
            break
        elif stripped and not stripped.startswith('*'):
            title = stripped[:80] + ('...' if len(stripped) > 80 else '')
            break

    # Create snippet for notification body
    body = content[:150].replace('#', '').replace('*', '').strip()
    if len(content) > 150:
        body += '...'

    # Public URL for the summary
    article_url = f"https://storage.googleapis.com/{bucket_name}/{file_name}"

    send_fcm_notifications(title, body, article_url)

    # Also send APNs notifications to iOS Swift app users
    send_apns_notifications(title, body, article_url)


def send_email(subject_file, html_body):
    gmail_user = os.environ.get("GMAIL_USER")
    gmail_password = os.environ.get("GMAIL_APP_PASSWORD")
    dest_email = os.environ.get("DEST_EMAIL")

    if not all([gmail_user, gmail_password, dest_email]):
        raise ValueError("Missing environment variables (GMAIL_USER, GMAIL_APP_PASSWORD, DEST_EMAIL)")

    # Validate inputs
    if not subject_file or not isinstance(subject_file, str):
        raise ValueError("Invalid subject_file parameter")
    if not html_body or not isinstance(html_body, str):
        raise ValueError("Invalid html_body parameter")

    # Extract date safely from filename and sanitize for email subject
    filename = subject_file.split('/')[-1].replace('.md', '')
    safe_filename = sanitize_filename(filename)

    msg = MIMEMultipart("alternative")
    msg["Subject"] = f"SE Daily Briefing: {safe_filename}"
    msg["From"] = gmail_user
    msg["To"] = dest_email

    # Escape HTML in body to prevent XSS (content comes from markdown which is already processed)
    # Note: html_body is already converted from markdown, so we trust it but wrap safely
    full_html = f"""
    <html>
      <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
        <div style="max-width: 600px; margin: 0 auto; padding: 20px;">
          <h2 style="color: #2c3e50;">Your Daily Software Engineering Briefing</h2>
          <hr style="border: 0; border-top: 1px solid #eee;">
          {html_body}
          <hr style="border: 0; border-top: 1px solid #eee;">
          <p style="font-size: 12px; color: #999;">Sent by your Cloud Agent.</p>
        </div>
      </body>
    </html>
    """

    msg.attach(MIMEText(full_html, "html"))

    # Use context manager pattern to ensure connection is always closed
    with smtplib.SMTP("smtp.gmail.com", 587, timeout=30) as server:
        server.starttls()
        server.login(gmail_user, gmail_password)
        server.sendmail(gmail_user, dest_email, msg.as_string())
        logger.info("Email sent successfully", recipient=dest_email)
