# Phase 1 setup (API MVP)

1. Supabase: create project `eng-pulse` (EU), enable Apple, Google, Email (magic link/OTP), set SMTP (runbook phase0 §1). Copy the project ref.
2. `PULSE_ENV` (GitHub environment `production`): set `SUPABASE_JWKS_URL=https://<ref>.supabase.co/auth/v1/.well-known/jwks.json`, `SUPABASE_ISSUER=https://<ref>.supabase.co/auth/v1`, add `ADMIN_EMAIL=<your email>`. No spaces.
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
4. Merge. CI does not order the deploys: `deploy-agents` and `deploy-api` run independently, and only `deploy-api` waits on the `production` approval. Approve `deploy-api` first. `deploy-agents` redeploys the pipeline with `PULSE_API_URL` and the token, then its smoke gate checks `/healthz` (Phase 0 already serves it) and `/internal/feeds` with the service token; `/internal/feeds` exists only once this branch's API is live, so an unapproved `deploy-api` fails the gate — approve it and re-run `deploy-agents` from the Actions tab. Before step 5 the feeds list is empty, which the smoke check logs as `feeds=0` and accepts; a dual-write that lands before the seed warns and the run continues, with the brief still in GCS.
5. Seed on the box: `ssh -i ~/.ssh/pulse-deploy deploy@api.eng-pulse.tsvetkov.org 'cd /opt/pulse && docker compose run --rm pulse-api seed --sources https://storage.googleapis.com/tsvet01-agent-brain/config/sources.json --invite <CODE> --invite-uses 5'`.
6. Verify with a real Supabase token (Supabase dashboard → Authentication → Users → generate magic link, or the `supabase` CLI): `curl -H "Authorization: Bearer $JWT" https://api.eng-pulse.tsvetkov.org/v1/me` → `403 invite_required`; `curl -X POST -H "Authorization: Bearer $JWT" -H 'content-type: application/json' -d '{"invite_code":"<CODE>"}' .../v1/users` → `201` with `is_admin: true` for `ADMIN_EMAIL`; `.../v1/feeds` lists `engineering`.
7. Next morning: `psql` on the box (`docker compose exec postgres psql -U pulse -d pulse -c "select date, article_title, model, eval_score from briefs"`) shows the day's brief; GCS and manifest unchanged.
