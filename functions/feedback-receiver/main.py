import json
import os
import sys
import functions_framework
import firebase_admin
from datetime import datetime, timezone
from google.cloud import storage
from firebase_admin import auth

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from shared.http_utils import handle_cors_preflight, json_response, error_response
from shared.logging_config import CloudFunctionLogger

logger = CloudFunctionLogger("feedback-receiver")

# Initialize Firebase Admin (guard against warm-start re-init)
if not firebase_admin._apps:
    firebase_admin.initialize_app()

BUCKET_NAME = os.environ.get("FEEDBACK_BUCKET_NAME", "tsvet01-agent-brain")


def _verify_token(request):
    """Extract and verify Firebase ID token from Authorization header."""
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return None, error_response("Missing or invalid Authorization header", 401)

    token = auth_header[7:]
    try:
        decoded = auth.verify_id_token(token)
        return decoded["uid"], None
    except (auth.InvalidIdTokenError, auth.ExpiredIdTokenError, auth.RevokedIdTokenError) as e:
        logger.error("Token verification failed", error=str(e))
        return None, error_response("Invalid token", 401)
    except Exception as e:
        logger.error("Unexpected auth error", error=str(e))
        return None, error_response("Authentication error", 500)


def _load_feedback(bucket, date_str):
    """Load existing feedback for a date, or empty list if not found."""
    blob = bucket.blob(f"feedback/{date_str}.json")
    try:
        data = blob.download_as_text()
        return json.loads(data)
    except Exception:
        return []


def _upsert_feedback(entries, uid, summary_url, feedback, prompt_version,
                     selection_feedback=None, summary_feedback=None):
    """Upsert feedback entry by uid + summary_url."""
    now = datetime.now(timezone.utc).isoformat()
    for entry in entries:
        if entry["uid"] == uid and entry["summary_url"] == summary_url:
            if feedback is not None:
                entry["feedback"] = feedback
            if selection_feedback is not None:
                entry["selection_feedback"] = selection_feedback
            if summary_feedback is not None:
                entry["summary_feedback"] = summary_feedback
            entry["prompt_version"] = prompt_version
            entry["timestamp"] = now
            return entries

    new_entry = {
        "summary_url": summary_url,
        "prompt_version": prompt_version,
        "uid": uid,
        "timestamp": now,
    }
    if feedback is not None:
        new_entry["feedback"] = feedback
    if selection_feedback is not None:
        new_entry["selection_feedback"] = selection_feedback
    if summary_feedback is not None:
        new_entry["summary_feedback"] = summary_feedback
    entries.append(new_entry)
    return entries


@functions_framework.http
def receive_feedback(request):
    """HTTP endpoint to receive and store user feedback."""
    # Handle CORS preflight
    if request.method == "OPTIONS":
        return handle_cors_preflight()

    if request.method != "POST":
        return error_response("Method not allowed", 405)

    # Verify Firebase auth token
    uid, err = _verify_token(request)
    if err:
        return err

    # Parse request body
    body = request.get_json(force=True)
    if body is None:
        return error_response("Invalid JSON body", 400)

    summary_url = body.get("summary_url")
    feedback = body.get("feedback")
    selection_feedback = body.get("selection_feedback")
    summary_feedback = body.get("summary_feedback")
    prompt_version = body.get("prompt_version")

    if not summary_url:
        return error_response("summary_url required", 400)

    valid = ("up", "down")
    if feedback is None and selection_feedback is None and summary_feedback is None:
        return error_response("at least one feedback field required", 400)
    if (feedback is not None and feedback not in valid) or \
       (selection_feedback is not None and selection_feedback not in valid) or \
       (summary_feedback is not None and summary_feedback not in valid):
        return error_response("feedback values must be 'up' or 'down'", 400)

    # Derive date server-side
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # Load, upsert, save
    client = storage.Client()
    bucket = client.bucket(BUCKET_NAME)

    entries = _load_feedback(bucket, date_str)
    entries = _upsert_feedback(entries, uid, summary_url, feedback, prompt_version,
                               selection_feedback, summary_feedback)

    blob = bucket.blob(f"feedback/{date_str}.json")
    blob.upload_from_string(
        json.dumps(entries, indent=2),
        content_type="application/json",
    )

    logger.info("Feedback recorded", uid=uid[:8], url=summary_url,
                feedback=feedback, selection=selection_feedback, summary=summary_feedback)
    return json_response({"status": "ok"})
