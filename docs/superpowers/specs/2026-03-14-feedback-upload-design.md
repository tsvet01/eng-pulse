# Feedback Upload & Display

## Problem

User feedback (thumbs up/down) is stored locally on device and never leaves the app. There is no way to aggregate feedback, compare it with automated eval scores, or use it to calibrate the LLM judge over time.

## Goals

1. Upload user feedback from the Swift app to GCS via a Cloud Function
2. Display both automated eval scores and user feedback side-by-side in the app
3. Store feedback in GCS for future pipeline integration (judge calibration)

## Non-Goals (Roadmap)

- Account linking (anonymous → Google/Apple sign-in)
- Multi-user calibration profiles
- Judge calibration via few-shot injection
- Flutter app parity

## Architecture

```
Swift App                Cloud Function              GCS
─────────              ──────────────              ───
thumbs up/down  ──POST──▶ feedback-receiver  ──write──▶ feedback/{date}.json
  + Firebase ID token     (verify token,
                           extract UID,
                           upsert by URL+UID)
```

### Cloud Function: `functions/feedback-receiver/`

- Python Cloud Function (matches `functions/notifier/` pattern)
- HTTP POST endpoint
- Verifies Firebase anonymous auth ID token from `Authorization: Bearer <token>` header
- Extracts UID from verified token (does not trust request body)
- Derives date server-side from `datetime.now(timezone.utc)` (does not trust client-supplied date)
- Reads existing `feedback/{date}.json` from GCS, upserts entry by `summary_url + uid`, writes back
- If `feedback/{date}.json` does not exist yet (first feedback of the day), creates it with an empty list
- Concurrency: last-write-wins is acceptable for single-user usage; low collision risk since feedback is infrequent. If multi-user is added later, switch to GCS generation preconditions (`if_generation_match`) or Firestore for atomic writes.

**Request payload:**

```json
{
  "summary_url": "gs://tsvet01-agent-brain/summaries/gemini/2026-03-14.md",
  "feedback": "up",
  "prompt_version": null
}
```

**GCS storage format** (`feedback/{date}.json`):

```json
[
  {
    "summary_url": "gs://tsvet01-agent-brain/summaries/gemini/2026-03-14.md",
    "feedback": "up",
    "prompt_version": null,
    "uid": "firebase-anonymous-uid",
    "timestamp": "2026-03-14T09:15:00Z"
  }
]
```

### Swift App Changes

1. **Firebase anonymous auth** — add `FirebaseAuth` dependency, call `FirebaseApp.configure()` in AppDelegate, then `Auth.auth().signInAnonymously()` on launch. Handle offline first-launch gracefully (queue feedback locally until auth succeeds).
2. **Feedback upload** — on thumbs up/down tap, call `Auth.auth().currentUser?.getIDToken()` (forces refresh if expired — ID tokens expire after 1 hour, never cache the token string) then POST to Cloud Function with token in Authorization header. Fire-and-forget, retry silently on failure.
3. **UI** — display both eval score badge and user feedback indicator on summary cards. Eval score is the automated judge rating; feedback indicator shows your own thumbs up/down if you've rated it.

### Authentication

- Firebase anonymous auth (zero user friction, auto-creates UID per device)
- Cloud Function verifies ID token via Firebase Admin SDK
- UID used for deduplication (same UID + same URL = upsert, not duplicate)
- Upgrade path: anonymous accounts can later be linked to Google/Apple sign-in for multi-device identity

## Phases

### Phase 1 (This Implementation)

- Deploy `feedback-receiver` Cloud Function
- Swift app: anonymous auth + feedback upload on tap
- Swift app: display both eval score and user feedback in UI
- GCS: `feedback/{date}.json` storage

### Phase 2 (Future)

- Daily-agent reads recent feedback before eval stage
- Injects top/bottom rated examples as few-shot context for the LLM judge
- Judge scoring gradually aligns with user preferences

### Phase 3 (Future)

- Account linking: anonymous → Google/Apple sign-in
- Multi-user support with per-user calibration profiles
- Flutter app parity
