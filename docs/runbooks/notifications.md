# Push notifications

Pilot users are notified by push only (no email). The sender is a worker inside the API process, gated by `NOTIFY_PUSH_ENABLED` (default `false`). It reads the `notification_outbox` table, sends through APNs to each active iOS token of the user, and rechecks account, membership, preference and token before every send.

## Configure

Add three secrets to `PULSE_ENV` (GitHub environment `production`); the flag itself lives in [`config/pilot-auth.json`](../../config/pilot-auth.json).

| Name | Value |
|---|---|
| `APNS_KEY_BASE64` | the APNs `.p8` key, base64 on one line |
| `APNS_KEY_ID` | key ID shown in Apple Developer |
| `APNS_TEAM_ID` | Apple team ID |

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy
```

Optional: `APNS_TOPIC` (default `org.tsvetkov.eng-pulse`), `APNS_PRODUCTION_URL`, `APNS_SANDBOX_URL`. Deploy validation requires the three secrets only while the flag is `true`, and the API refuses to start when the key is not a valid P-256 PEM.

## Enable

1. With the flag `false`, deploy and confirm `GET /healthz/notifications` returns 503 `{"reason":"disabled"}`. The `Pilot feed freshness` workflow accepts that state.
2. Set `NOTIFY_PUSH_ENABLED` to `true` in `config/pilot-auth.json`, merge and deploy. The endpoint returns 200 `{"reason":"current"}`; 503 reasons are `failed` (a push failed in the last 24 h), `backlog` (a pending push waited over 30 min) and `unavailable` (database error).
3. Pushes are queued only for a brief dated today, so enabling never releases a backlog. Confirm receipt on a real device after the next 06:00 UTC brief.

## Inspect

Backlog:

```sql
select feed_id, date, count(*), min(created_at) from notification_outbox
where channel = 'push' and state = 'pending' group by 1, 2;
```

Failures:

```sql
select date, attempts, last_error, updated_at from notification_outbox
where channel = 'push' and state = 'failed' order by updated_at desc limit 20;
```

## Turn off

Set `NOTIFY_PUSH_ENABLED` to `false` and deploy. Nothing is enqueued and the worker does not start. Rows left `pending` are not replayed on a later enable: they expire after 12 hours and are skipped.

## Delivery guarantees

Delivery is at least once. If the API crashes after APNs accepts a push but before the row is marked `sent`, the lease expires and the push is sent again. One row per user, feed and date keeps routine re-ingestion from queuing a second push.

## Legacy overlap

The pilot bundle `org.tsvetkov.eng-pulse` has its own APNs tokens, so the legacy sender cannot double-push a pilot device. The legacy email to `DEST_EMAIL` and old-app push are untouched and keep running.
