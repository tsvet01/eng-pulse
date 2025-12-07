import functions_framework
import os
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from google.cloud import storage
import markdown

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

    # Parse Markdown to HTML
    html_content = markdown.markdown(content)

    # Send Email
    send_email(file_name, html_content)

def send_email(subject_file, html_body):
    gmail_user = os.environ.get("GMAIL_USER")
    gmail_password = os.environ.get("GMAIL_APP_PASSWORD")
    dest_email = os.environ.get("DEST_EMAIL")

    if not all([gmail_user, gmail_password, dest_email]):
        print("Error: Missing environment variables (GMAIL_USER, GMAIL_APP_PASSWORD, DEST_EMAIL).")
        return

    msg = MIMEMultipart("alternative")
    msg["Subject"] = f"SE Daily Briefing: {subject_file.split('/')[-1].replace('.md', '')}"
    msg["From"] = gmail_user
    msg["To"] = dest_email

    # Add HTML body
    # Wrap in a simple HTML template for better look
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

    try:
        server = smtplib.SMTP("smtp.gmail.com", 587)
        server.starttls()
        server.login(gmail_user, gmail_password)
        server.sendmail(gmail_user, dest_email, msg.as_string())
        server.quit()
        print(f"Email sent successfully to {dest_email}")
    except Exception as e:
        print(f"Failed to send email: {e}")
