import functions_framework
import os
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from google.cloud import storage
from google.cloud import firestore
import firebase_admin
from firebase_admin import credentials, messaging
import markdown
import bleach

# Initialize Firebase Admin SDK (uses default credentials in Cloud Functions)
_firebase_app = None


def get_firebase_app():
    """Lazy-load Firebase Admin app."""
    global _firebase_app
    if _firebase_app is None:
        _firebase_app = firebase_admin.initialize_app()
    return _firebase_app

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
        # Initialize Firebase if not already done
        get_firebase_app()

        # Get all active FCM tokens from Firestore
        db = firestore.Client()
        tokens_ref = db.collection("fcm_tokens").where("active", "==", True)
        docs = tokens_ref.stream()

        tokens = []
        for doc in docs:
            data = doc.to_dict()
            if data.get("token"):
                tokens.append(data["token"])

        if not tokens:
            print("No active FCM tokens found")
            return 0

        print(f"Sending FCM to {len(tokens)} devices")

        # Batch send (FCM supports up to 500 per request)
        batch_size = 500
        success_count = 0

        for i in range(0, len(tokens), batch_size):
            batch_tokens = tokens[i:i + batch_size]

            message = messaging.MulticastMessage(
                notification=messaging.Notification(
                    title=title,
                    body=body,
                ),
                data={
                    "article_url": article_url,
                    "click_action": "FLUTTER_NOTIFICATION_CLICK",
                },
                tokens=batch_tokens,
            )

            response = messaging.send_each_for_multicast(message)
            success_count += response.success_count

            # Handle failed tokens (mark as inactive)
            if response.failure_count > 0:
                for idx, send_response in enumerate(response.responses):
                    if not send_response.success:
                        failed_token = batch_tokens[idx]
                        error = send_response.exception
                        print(f"Failed to send to token: {error}")

                        # Mark token as inactive if it's invalid
                        if hasattr(error, 'code') and error.code in (
                            'messaging/invalid-registration-token',
                            'messaging/registration-token-not-registered'
                        ):
                            try:
                                db.collection("fcm_tokens").document(failed_token).update({
                                    "active": False
                                })
                            except Exception as e:
                                print(f"Failed to deactivate token: {e}")

        print(f"FCM notifications sent: {success_count}/{len(tokens)}")
        return success_count

    except Exception as e:
        print(f"Error sending FCM notifications: {e}")
        return 0


@functions_framework.cloud_event
def send_summary_email(cloud_event):
    data = cloud_event.data
    bucket_name = data["bucket"]
    file_name = data["name"]

    print(f"Event ID: {cloud_event['id']}")
    print(f"Event Type: {cloud_event['type']}")
    print(f"Bucket: {bucket_name}")
    print(f"File: {file_name}")

    # Only process files in 'summaries/' folder
    if not should_process_file(file_name):
        print("Not a summary file. Skipping.")
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
        print(f"Email sent successfully to {dest_email}")
