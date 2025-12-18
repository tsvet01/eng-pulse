import functions_framework
import os
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from google.cloud import storage
import markdown
import bleach

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
    if not file_name.startswith("summaries/") or not file_name.endswith(".md"):
        print("Not a summary file. Skipping.")
        return

    # Download content
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(file_name)
    content = blob.download_as_text()

    # Parse Markdown to HTML and sanitize to prevent XSS
    raw_html = markdown.markdown(content)
    # Allow only safe HTML tags for email content
    html_content = bleach.clean(
        raw_html,
        tags=['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li',
              'strong', 'em', 'a', 'br', 'hr', 'code', 'pre', 'blockquote'],
        attributes={'a': ['href']},
        strip=True
    )

    # Send Email
    send_email(file_name, html_content)

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

    # Extract date safely from filename
    filename = subject_file.split('/')[-1].replace('.md', '')
    # Sanitize filename for email subject (allow only safe chars)
    safe_filename = ''.join(c for c in filename if c.isalnum() or c in '-_. ')

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
