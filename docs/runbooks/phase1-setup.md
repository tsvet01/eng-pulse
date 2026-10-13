# Phase 1 setup (API MVP)

**Pilot update, 2026-10-13:** This runbook configures the existing API integration. Follow the [active pilot plan](../superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md) for required code corrections, deployment ordering, history/reconciliation, recovery, Swift, and delivery gates. Keep the GCP pipeline and legacy artifact path. These setup steps alone do not establish launch readiness.

1. Supabase: use the existing project `zimjnykjqsxwsidwmemd` (public URL/JWKS verified 2026-10-13). Confirm region/tier, native Apple provider, confirmed email/OTP, and custom SMTP using [Phase 0 §1](phase0-setup.md#1-supabase-project). A published ES256 key is compatible, but verify a real access token before release. Google is optional.
2. `PULSE_ENV` (GitHub environment `production`): preserve its existing database password and pipeline token; set `SUPABASE_JWKS_URL=https://zimjnykjqsxwsidwmemd.supabase.co/auth/v1/.well-known/jwks.json`, `SUPABASE_ISSUER=https://zimjnykjqsxwsidwmemd.supabase.co/auth/v1`, `SUPABASE_AUDIENCE=authenticated`, and `ADMIN_EMAIL=anton.tsvetkov@gmail.com` (confirmed by Anton on 2026-10-13). The backend needs no Supabase secret/service-role key or Supabase database password. For Swift later, use the project URL and client publishable key. Keep all private credentials in their existing secret stores.
3. GCP: create the secret and let the daily-agent job read it.
   ```bash
   printf '%s' '<same value as PIPELINE_SERVICE_TOKEN in PULSE_ENV>' \
     | gcloud secrets create pipeline-service-token --project tsvet01 --data-file=-
   SA=$(gcloud run jobs describe se-daily-agent-job --project tsvet01 --region us-central1 \
     --format 'value(spec.template.spec.template.spec.serviceAccountName)')
   # Empty output means the job runs as the project's default compute service account.
   [ -n "$SA" ] || SA="$(gcloud projects describe tsvet01 --format 'value(projectNumber)')-compute@developer.gserviceaccount.com"
   gcloud secrets add-iam-policy-binding pipeline-service-token --project tsvet01 \
     --member "serviceAccount:$SA" --role roles/secretmanager.secretAccessor
   ```
   Without the binding the job fails to start: Cloud Run resolves `--set-secrets` before the container runs.
4. **Before the pilot release, implement the API-first integration ordering required by P1 of the active plan.** Current behavior (not the target): CI does not order the deploys: `deploy-agents` and `deploy-api` run independently, and only `deploy-api` waits on the `production` approval. The current manual workaround is to approve `deploy-api` first; this is not a guarantee of job ordering. `deploy-agents` redeploys the pipeline with `PULSE_API_URL` and the token, then its smoke gate checks `/healthz` (Phase 0 already serves it) and `/internal/feeds` with the service token; `/internal/feeds` exists only once this branch's API is live, so an unapproved `deploy-api` fails the gate — approve it and re-run `deploy-agents` from the Actions tab. Before step 5 the feeds list is empty, which the smoke check logs as `feeds=0` and accepts; a dual-write that lands before the seed warns and the run continues, with the brief still in GCS.
5. Seed on the box: `ssh -i ~/.ssh/pulse-deploy deploy@api.eng-pulse.tsvetkov.org 'cd /opt/pulse && docker compose run --rm pulse-api seed --sources https://storage.googleapis.com/tsvet01-agent-brain/config/sources.json --invite <CODE> --invite-uses 5'`.
6. Verify with a real Supabase token (Supabase dashboard → Authentication → Users → generate magic link, or the `supabase` CLI): `curl -H "Authorization: Bearer $JWT" https://api.eng-pulse.tsvetkov.org/v1/me` → `403 invite_required`; `curl -X POST -H "Authorization: Bearer $JWT" -H 'content-type: application/json' -d '{"invite_code":"<CODE>"}' .../v1/users` → `201` with `is_admin: true` for `ADMIN_EMAIL`; `.../v1/feeds` lists `engineering` with `member: true`. Use email/OTP for the first admin sign-in so Apple Hide My Email does not produce an unexpected admin address. Signup before the active engineering seed returns 503 and rolls back the invite; an email collision with another subject returns 409. A retry of an existing identity returns 200 without changing membership/preferences.
7. Next morning: `psql` on the box (`docker compose exec postgres psql -U pulse -d pulse -c "select date, article_title, model, eval_score from briefs"`) shows the day's brief; GCS and manifest unchanged.

## Pilot readiness after setup

Use the evidence table in the active pilot plan. In particular, confirm seeded engineering membership for new users, import recent history without LLM calls or historical notifications, test scheduled reconciliation after an API outage, and prove a backup restore. The new Swift experience and per-user email/APNs with legacy sender isolation must pass real-device checks before inviting the pilot group. Record release/build IDs and results there; never record secret values.

## Revoke pilot access / departure

An authorized operator runs this against the Hetzner application database through the existing controlled access process. First identify the exact user UUID and verify the target; do not target a user by display name. Bind `user_id` as a psql variable. This is a procedure, not an automated deployment step.

```sql
BEGIN;
UPDATE users SET is_active = false WHERE id = :'user_id'::uuid;
UPDATE memberships SET notify_email = false, notify_push = false
  WHERE user_id = :'user_id'::uuid;
UPDATE device_tokens SET is_active = false WHERE user_id = :'user_id'::uuid;
UPDATE invites SET expires_at = now() WHERE created_by = :'user_id'::uuid;
COMMIT;
```

Verify the affected row counts. Subsequent authenticated API requests, including signup retries, return 403 even for an unexpired token. In-flight requests may finish. Keep the identity/email record so a fresh invite cannot link around the disabled account; do not delete it as the revocation mechanism. Revoke any shared invite the departing user knows, and ban/revoke their Supabase sessions separately. Revoke recipient/device routing in the legacy notification system through its existing process: this database flag cannot stop GCP legacy delivery or erase an offline client's cached content. Before P2 invitations, the new sender must check `users.is_active` as well as membership/preferences/device ownership.

For account deletion, separately review retention and dependent records, then perform explicit cleanup in both systems. Disabling access is reversible and preserves feedback for that review. Re-enabling a user must not silently re-enable email/push preferences or device tokens.

## Pilot API compatibility

Only active `engineering` is exposed to readers and `/internal` consumers. Feed creation and source/topic writes return 403 for every registered role, including admins/owners. Apply reviewed source changes through the existing GCP configuration workflow, then refresh the API seed; no HTTP edit changes generation behavior. Join/leave and notification preference updates remain available to active users.

Migration `0003_pilot_readiness.sql` adds account disabling and widens evaluation scores to double precision. Existing rounded scores need re-ingestion to restore source precision. Do not roll back to an API build that ignores `is_active` after revoking a user; that would restore access. Any emergency rollback needs a compatible forward fix or a maintenance window with authenticated routes unavailable.
