# Feedback Upload & Display Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upload user feedback (thumbs up/down) from the Swift app to GCS via a Cloud Function and display both eval scores and user feedback in the UI.

**Architecture:** A new Python Cloud Function (`feedback-receiver`) accepts POST requests with a Firebase ID token, verifies the token, and upserts feedback into `feedback/{date}.json` in GCS. The Swift app adds Firebase SDK (first external dependency), signs in anonymously on launch, and POSTs feedback on each thumbs tap. Local UserDefaults storage is retained for instant UI state.

**Tech Stack:** Python 3.11 (Cloud Function), Firebase Admin SDK, Firebase Auth (Swift via SPM), Google Cloud Storage

---

## File Structure

### New Files
- `functions/feedback-receiver/main.py` — Cloud Function HTTP endpoint
- `functions/feedback-receiver/requirements.txt` — Python dependencies
- `apps/mobile-swift/EngPulse/Services/FeedbackService.swift` — uploads feedback to Cloud Function
- `apps/mobile-swift/EngPulse/GoogleService-Info.plist` — Firebase config (generated from Firebase Console)

### Modified Files
- `apps/mobile-swift/EngPulse/EngPulseApp.swift` — add `FirebaseApp.configure()` in AppDelegate
- `apps/mobile-swift/EngPulse/Views/DetailView.swift` — call FeedbackService on thumbs tap
- `.github/workflows/deploy.yml` — deploy feedback-receiver function
- `.github/workflows/ci.yml` — add feedback-receiver tests

---

## Chunk 1: Cloud Function

### Task 1: Create feedback-receiver Cloud Function

**Files:**
- Create: `functions/feedback-receiver/main.py`
- Create: `functions/feedback-receiver/requirements.txt`
- Modify: `functions/shared/http_utils.py` (add `Authorization` to CORS allowed headers)
- Reference: `functions/shared/logging_config.py` (logging pattern)

- [ ] **Step 1: Create requirements.txt**

```
functions-framework==3.5.0
google-cloud-storage==2.18.0
google-auth==2.36.0
firebase-admin>=6.3.0
```

- [ ] **Step 2: Add `Authorization` to CORS allowed headers**

In `functions/shared/http_utils.py`, update `CORS_HEADERS` to include `Authorization`:

```python
"Access-Control-Allow-Headers": "Content-Type, Authorization",
```

- [ ] **Step 3: Write the Cloud Function**

Create `functions/feedback-receiver/main.py`:

```python
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

BUCKET_NAME = "tsvet01-agent-brain"


def _verify_token(request):
    """Extract and verify Firebase ID token from Authorization header."""
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return None, error_response("Missing or invalid Authorization header", 401)

    token = auth_header[7:]
    try:
        decoded = auth.verify_id_token(token)
        return decoded["uid"], None
    except Exception as e:
        logger.error(f"Token verification failed: {e}")
        return None, error_response("Invalid token", 401)


def _load_feedback(bucket, date_str):
    """Load existing feedback for a date, or empty list if not found."""
    blob = bucket.blob(f"feedback/{date_str}.json")
    try:
        data = blob.download_as_text()
        return json.loads(data)
    except Exception:
        return []


def _upsert_feedback(entries, uid, summary_url, feedback, prompt_version):
    """Upsert feedback entry by uid + summary_url."""
    now = datetime.now(timezone.utc).isoformat()
    for entry in entries:
        if entry["uid"] == uid and entry["summary_url"] == summary_url:
            entry["feedback"] = feedback
            entry["prompt_version"] = prompt_version
            entry["timestamp"] = now
            return entries

    entries.append({
        "summary_url": summary_url,
        "feedback": feedback,
        "prompt_version": prompt_version,
        "uid": uid,
        "timestamp": now,
    })
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
    try:
        body = request.get_json(force=True)
    except Exception:
        return error_response("Invalid JSON body", 400)

    summary_url = body.get("summary_url")
    feedback = body.get("feedback")
    prompt_version = body.get("prompt_version")

    if not summary_url or feedback not in ("up", "down"):
        return error_response("summary_url required, feedback must be 'up' or 'down'", 400)

    # Derive date server-side
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # Load, upsert, save
    client = storage.Client()
    bucket = client.bucket(BUCKET_NAME)

    entries = _load_feedback(bucket, date_str)
    entries = _upsert_feedback(entries, uid, summary_url, feedback, prompt_version)

    blob = bucket.blob(f"feedback/{date_str}.json")
    blob.upload_from_string(
        json.dumps(entries, indent=2),
        content_type="application/json",
    )

    logger.info(f"Feedback recorded: uid={uid[:8]}... url={summary_url} feedback={feedback}")
    return json_response({"status": "ok"})
```

- [ ] **Step 4: Write tests**

Create `functions/feedback-receiver/test_main.py`:

```python
import json
import pytest
from unittest.mock import patch, MagicMock


@pytest.fixture(autouse=True)
def mock_firebase_init():
    with patch("main.firebase_admin") as mock_admin:
        mock_admin._apps = {"[DEFAULT]": True}
        yield mock_admin


@pytest.fixture
def mock_firebase():
    with patch("main.auth") as mock_auth:
        mock_auth.verify_id_token.return_value = {"uid": "test-uid-123"}
        yield mock_auth


@pytest.fixture
def mock_gcs():
    with patch("main.storage") as mock_storage:
        mock_bucket = MagicMock()
        mock_blob = MagicMock()
        mock_blob.download_as_text.side_effect = Exception("Not found")
        mock_bucket.blob.return_value = mock_blob
        mock_storage.Client.return_value.bucket.return_value = mock_bucket
        yield mock_storage, mock_bucket, mock_blob


@pytest.fixture
def app():
    from main import receive_feedback
    return receive_feedback


def make_request(method="POST", json_body=None, auth_token="valid-token"):
    request = MagicMock()
    request.method = method
    request.headers = {"Authorization": f"Bearer {auth_token}"} if auth_token else {}
    request.get_json.return_value = json_body
    return request


def test_rejects_get(app):
    request = make_request(method="GET")
    response = app(request)
    assert response[1] == 405


def test_rejects_missing_auth(app):
    request = make_request(auth_token=None)
    request.headers = {}
    response = app(request)
    assert response[1] == 401


def test_rejects_invalid_feedback(app, mock_firebase, mock_gcs):
    request = make_request(json_body={"summary_url": "gs://test", "feedback": "maybe"})
    response = app(request)
    assert response[1] == 400


def test_stores_feedback(app, mock_firebase, mock_gcs):
    _, mock_bucket, mock_blob = mock_gcs
    request = make_request(json_body={
        "summary_url": "gs://tsvet01-agent-brain/summaries/gemini/2026-03-14.md",
        "feedback": "up",
        "prompt_version": None,
    })
    response = app(request)
    body = json.loads(response[0])
    assert body["status"] == "ok"
    mock_blob.upload_from_string.assert_called_once()
    uploaded = json.loads(mock_blob.upload_from_string.call_args[0][0])
    assert len(uploaded) == 1
    assert uploaded[0]["feedback"] == "up"
    assert uploaded[0]["uid"] == "test-uid-123"


def test_upserts_existing_feedback(app, mock_firebase, mock_gcs):
    _, mock_bucket, mock_blob = mock_gcs
    existing = json.dumps([{
        "summary_url": "gs://tsvet01-agent-brain/summaries/gemini/2026-03-14.md",
        "feedback": "up",
        "prompt_version": None,
        "uid": "test-uid-123",
        "timestamp": "2026-03-14T08:00:00+00:00",
    }])
    mock_blob.download_as_text.side_effect = None
    mock_blob.download_as_text.return_value = existing

    request = make_request(json_body={
        "summary_url": "gs://tsvet01-agent-brain/summaries/gemini/2026-03-14.md",
        "feedback": "down",
        "prompt_version": None,
    })
    response = app(request)
    uploaded = json.loads(mock_blob.upload_from_string.call_args[0][0])
    assert len(uploaded) == 1
    assert uploaded[0]["feedback"] == "down"
```

- [ ] **Step 5: Run tests locally**

```bash
cd functions/feedback-receiver
cp -r ../shared ./shared
pip install -r requirements.txt pytest
python -m pytest test_main.py -v
```

Expected: All 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add functions/feedback-receiver/ functions/shared/http_utils.py
git commit -m "feat: add feedback-receiver Cloud Function"
```

---

## Chunk 2: Swift App — Firebase Setup

### Task 2: Add Firebase SDK via SPM and configure anonymous auth

**Files:**
- Modify: `apps/mobile-swift/EngPulse.xcodeproj/project.pbxproj` (via Xcode SPM)
- Create: `apps/mobile-swift/EngPulse/GoogleService-Info.plist` (from Firebase Console)
- Modify: `apps/mobile-swift/EngPulse/EngPulseApp.swift`

**Prerequisites:** Generate `GoogleService-Info.plist` from the Firebase Console for project `tsvet01`. Enable Anonymous authentication in Firebase Console → Authentication → Sign-in method.

- [ ] **Step 1: Add Firebase SDK via Xcode**

In Xcode:
1. File → Add Package Dependencies
2. URL: `https://github.com/firebase/firebase-ios-sdk`
3. Select version: 11.x (latest stable)
4. Add products: `FirebaseAuth` only (no other Firebase products needed)

- [ ] **Step 2: Add GoogleService-Info.plist**

Download from Firebase Console (project `tsvet01`, iOS app). Add to `apps/mobile-swift/EngPulse/` and ensure it's included in the target.

- [ ] **Step 3: Configure Firebase and anonymous auth in AppDelegate**

Modify `apps/mobile-swift/EngPulse/EngPulseApp.swift`:

Add import at top:
```swift
import FirebaseCore
import FirebaseAuth
```

In `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, add Firebase setup:
```swift
func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
) -> Bool {
    FirebaseApp.configure()
    UNUserNotificationCenter.current().delegate = NotificationService.shared

    // Sign in anonymously (fire-and-forget, retries on next launch if fails)
    if Auth.auth().currentUser == nil {
        Auth.auth().signInAnonymously { _, error in
            if let error {
                print("Anonymous auth failed: \(error.localizedDescription)")
            }
        }
    }

    return true
}
```

- [ ] **Step 4: Build and verify**

Build in Xcode. Verify in console output that Firebase initializes and anonymous auth succeeds (no crash, prints UID or no error).

- [ ] **Step 5: Commit**

```bash
git add apps/mobile-swift/
git commit -m "feat: add Firebase SDK with anonymous auth to Swift app"
```

---

## Chunk 3: Swift App — FeedbackService

### Task 3: Create FeedbackService to upload feedback

**Files:**
- Create: `apps/mobile-swift/EngPulse/Services/FeedbackService.swift`

- [ ] **Step 1: Create FeedbackService**

```swift
import Foundation
import FirebaseAuth

actor FeedbackService {
    static let shared = FeedbackService()

    private let endpointURL: URL

    private init() {
        // Will be updated after Cloud Function deployment
        self.endpointURL = URL(string: "https://us-central1-tsvet01.cloudfunctions.net/feedback-receiver")!
    }

    /// Upload feedback to Cloud Function. Fire-and-forget — errors are logged, not surfaced.
    /// Note: If auth hasn't completed yet (offline first launch), feedback is silently skipped.
    /// Local UserDefaults still captures it. Offline queuing deferred to future iteration.
    func submitFeedback(summaryURL: String, feedback: String, promptVersion: String?) async {
        guard let user = Auth.auth().currentUser else {
            print("FeedbackService: No authenticated user, skipping upload")
            return
        }

        do {
            let token = try await user.getIDToken()

            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any?] = [
                "summary_url": summaryURL,
                "feedback": feedback,
                "prompt_version": promptVersion,
            ]

            request.httpBody = try JSONSerialization.data(
                withJSONObject: body.compactMapValues { $0 },
                options: []
            )

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("FeedbackService: Server returned \(httpResponse.statusCode)")
            }
        } catch {
            print("FeedbackService: Upload failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Build and verify compilation**

Build in Xcode. No runtime test yet — Cloud Function not deployed.

- [ ] **Step 3: Commit**

```bash
git add apps/mobile-swift/EngPulse/Services/FeedbackService.swift
git commit -m "feat: add FeedbackService for uploading feedback to Cloud Function"
```

---

## Chunk 4: Swift App — Wire Up Feedback Upload

### Task 4: Call FeedbackService from DetailView on thumbs tap

**Files:**
- Modify: `apps/mobile-swift/EngPulse/Views/DetailView.swift`

- [ ] **Step 1: Read DetailView.swift feedback code**

Read the current feedback button implementation to understand the exact toggle logic and UserDefaults usage.

- [ ] **Step 2: Add FeedbackService call after UserDefaults write**

Find the feedback button handlers in DetailView. After each `UserDefaults.standard.set(...)` call for feedback, add:

```swift
// Upload feedback to cloud (fire-and-forget, skip if cleared)
if !newValue.isEmpty {
    Task {
        await FeedbackService.shared.submitFeedback(
            summaryURL: summary.url,
            feedback: newValue,  // "up" or "down"
            promptVersion: summary.promptVersion
        )
    }
}
```

- [ ] **Step 3: Build and verify**

Build in Xcode. Verify the feedback buttons still work (toggle, persist locally). Cloud upload will fail gracefully until function is deployed.

- [ ] **Step 4: Commit**

```bash
git add apps/mobile-swift/EngPulse/Views/DetailView.swift
git commit -m "feat: wire feedback upload to thumbs up/down buttons"
```

---

## Chunk 5: Swift App — Display Both Signals in UI

### Task 5: Show eval score and user feedback on summary cards

**Files:**
- Modify: `apps/mobile-swift/EngPulse/Views/HomeView.swift`

The eval score badge already exists in DetailView's info sheet. This task adds both signals to the summary cards in the feed (HomeView) so the user can see at a glance:
- The automated eval score (star badge, already computed)
- Their own feedback (thumbs icon, if they've rated it)

- [ ] **Step 1: Read HomeView.swift SummaryCardView**

Read the current card layout to find where to add the indicators.

- [ ] **Step 2: Add eval score and feedback indicators to SummaryCardView**

In the card's metadata row (near date/model info), add:

```swift
// Eval score badge
if let score = summary.evalScore {
    let displayScore = max(score * 5, 1.0)
    Label(String(format: "%.1f", displayScore), systemImage: "star.fill")
        .font(.caption2)
        .foregroundColor(.secondary)
}

// User feedback indicator
let fb = UserDefaults.standard.string(forKey: "feedback_\(summary.url)") ?? ""
if fb == "up" {
    Image(systemName: "hand.thumbsup.fill")
        .font(.caption2)
        .foregroundColor(.green)
} else if fb == "down" {
    Image(systemName: "hand.thumbsdown.fill")
        .font(.caption2)
        .foregroundColor(.red)
}
```

- [ ] **Step 3: Build and verify**

Build in Xcode. Verify cards show eval scores and feedback thumbs for items you've previously rated.

- [ ] **Step 4: Commit**

```bash
git add apps/mobile-swift/EngPulse/Views/HomeView.swift
git commit -m "feat: display eval score and user feedback on summary cards"
```

---

## Chunk 6: Deployment

### Task 6: Add feedback-receiver to CI and deploy workflow

**Files:**
- Modify: `.github/workflows/deploy.yml`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add to CI**

In `.github/workflows/ci.yml`, extend the existing `python-check` job (don't create a separate job — follow the established pattern where all function tests run in one job):

Add to the syntax check step:
```yaml
python -m py_compile functions/feedback-receiver/main.py
```

Add a new step after the existing function test steps:
```yaml
- name: Run feedback-receiver tests
  run: |
    cp -r functions/shared functions/feedback-receiver/shared
    cd functions/feedback-receiver
    pip install -r requirements.txt pytest
    python -m pytest test_main.py -v
```

- [ ] **Step 2: Add to deploy workflow**

In `.github/workflows/deploy.yml`, add deployment step for feedback-receiver (follow the notifier deployment pattern):

```yaml
- name: Deploy Feedback Receiver
  run: |
    cp -r functions/shared functions/feedback-receiver/shared
    cd functions/feedback-receiver
    gcloud functions deploy feedback-receiver \
      --gen2 \
      --runtime=python311 \
      --region=us-central1 \
      --project=${{ env.PROJECT_ID }} \
      --source=. \
      --entry-point=receive_feedback \
      --trigger-http \
      --allow-unauthenticated
```

Note: `--allow-unauthenticated` is required because the function handles auth itself via Firebase ID tokens. GCP IAM auth would block the request before our code runs.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy.yml .github/workflows/ci.yml
git commit -m "ci: add feedback-receiver to CI tests and deploy workflow"
```

---

## Chunk 7: End-to-End Verification

### Task 7: Deploy and test the full flow

- [ ] **Step 1: Enable Firebase Anonymous Auth**

In Firebase Console → project `tsvet01` → Authentication → Sign-in method → Anonymous → Enable.

- [ ] **Step 2: Deploy the Cloud Function manually**

```bash
cd functions/feedback-receiver
cp -r ../shared ./shared
gcloud functions deploy feedback-receiver \
  --gen2 --runtime=python311 \
  --region=us-central1 \
  --source=. \
  --entry-point=receive_feedback \
  --trigger-http \
  --allow-unauthenticated \
  --project=tsvet01
```

- [ ] **Step 3: Test with curl (should fail — no valid token)**

```bash
curl -X POST https://us-central1-tsvet01.cloudfunctions.net/feedback-receiver \
  -H "Content-Type: application/json" \
  -d '{"summary_url": "gs://test", "feedback": "up"}'
```

Expected: 401 Unauthorized.

- [ ] **Step 4: Run the Swift app on device**

Build and run on iPhone. Verify:
1. App launches without crash
2. Console shows anonymous auth success
3. Tap thumbs up on a summary
4. Console shows FeedbackService upload (success or logged error)

- [ ] **Step 5: Verify GCS storage**

```bash
gsutil cat gs://tsvet01-agent-brain/feedback/2026-03-14.json
```

Expected: JSON array with one entry containing your feedback.

- [ ] **Step 6: Test toggle (upsert)**

Tap thumbs down on the same summary. Re-check GCS — should still be 1 entry, now with `"feedback": "down"`.
