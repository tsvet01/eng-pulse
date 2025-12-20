# Notifier

Python Cloud Function that sends email notifications when new summaries are published.

> Part of [Eng Pulse](../../README.md) - see root README for system overview.

## What It Does

1. **Triggers** on GCS object creation in the bucket
2. **Filters** to only process files in `summaries/` folder ending with `.md`
3. **Downloads** the markdown content
4. **Converts** markdown to HTML with sanitization (XSS protection)
5. **Sends** styled email to configured recipient

## Usage

### Local Testing

```bash
# Install dependencies
pip install -r requirements.txt

# Set environment variables
export GMAIL_USER=your-email@gmail.com
export GMAIL_APP_PASSWORD=your-app-password
export DEST_EMAIL=recipient@example.com
```

### Deployment

```bash
./deploy.sh
```

## Configuration

### Environment Variables / Secrets

In production, credentials are stored in GCP Secret Manager. For local development, use environment variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `GMAIL_USER` | Yes | Gmail address to send from |
| `GMAIL_APP_PASSWORD` | Yes | Gmail app-specific password |
| `DEST_EMAIL` | Yes | Email recipient address |

### Gmail App Password

1. Enable 2FA on your Google account
2. Go to [App Passwords](https://myaccount.google.com/apppasswords)
3. Generate a new app password for "Mail"
4. Use this password (not your regular password)

## Trigger Configuration

The function triggers on GCS object finalization:

```yaml
trigger-event: google.cloud.storage.object.v1.finalized
trigger-resource: projects/_/buckets/BUCKET_NAME
```

Only processes files matching:
- Path starts with `summaries/`
- File ends with `.md`

## Email Template

```html
<html>
  <body style="font-family: Arial, sans-serif;">
    <div style="max-width: 600px; margin: 0 auto;">
      <h2>Your Daily Software Engineering Briefing</h2>
      <hr>
      {markdown_converted_to_html}
      <hr>
      <p>Sent by your Cloud Agent.</p>
    </div>
  </body>
</html>
```

## Dependencies

```
functions-framework==3.5.0
google-cloud-storage==2.14.0
markdown==3.5.2
bleach==6.1.0
```

### Security

- **HTML Sanitization**: Uses `bleach` to sanitize markdown-generated HTML, preventing XSS attacks
- **Input Validation**: Validates all inputs before processing
- **SMTP Timeout**: 30-second timeout prevents hanging connections

## Error Handling

- **Missing credentials**: Logs error, function returns without sending
- **SMTP failure**: Logs error, exception propagated
- **Non-summary files**: Silently skipped (returns early)

## Logging

Uses Python's print statements which appear in Cloud Function logs:

```
Event ID: 12345
Event Type: google.cloud.storage.object.v1.finalized
Bucket: my-bucket
File: summaries/2024-01-15.md
Email sent successfully to recipient@example.com
```
