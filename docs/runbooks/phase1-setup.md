# Phase 1 setup (API MVP)

1. Supabase: create project `eng-pulse` (EU), enable Apple, Google, Email (magic link/OTP), set SMTP (runbook phase0 §1). Copy the project ref.
2. `PULSE_ENV` (GitHub environment `production`): set `SUPABASE_JWKS_URL=https://<ref>.supabase.co/auth/v1/.well-known/jwks.json`, `SUPABASE_ISSUER=https://<ref>.supabase.co/auth/v1`, add `ADMIN_EMAIL=<your email>`. No spaces.
3. GCP: `printf '%s' '<same value as PIPELINE_SERVICE_TOKEN in PULSE_ENV>' | gcloud secrets create pipeline-service-token --project tsvet01 --data-file=-`.
4. Merge; approve `deploy-api`; then `deploy-agents` redeploys the pipeline with `PULSE_API_URL` and the token (smoke checks `/healthz`).
5. Seed on the box: `ssh -i ~/.ssh/pulse-deploy deploy@api.eng-pulse.tsvetkov.org 'cd /opt/pulse && docker compose run --rm pulse-api pulse-api seed --sources https://storage.googleapis.com/tsvet01-agent-brain/config/sources.json --invite <CODE> --invite-uses 5'`.
6. Verify with a real Supabase token (Supabase dashboard → Authentication → Users → generate magic link, or the `supabase` CLI): `curl -H "Authorization: Bearer $JWT" https://api.eng-pulse.tsvetkov.org/v1/me` → `403 invite_required`; `curl -X POST -H "Authorization: Bearer $JWT" -H 'content-type: application/json' -d '{"invite_code":"<CODE>"}' .../v1/users` → `201` with `is_admin: true` for `ADMIN_EMAIL`; `.../v1/feeds` lists `engineering`.
7. Next morning: `psql` on the box (`docker compose exec postgres psql -U pulse -d pulse -c "select date, article_title, model, eval_score from briefs"`) shows the day's brief; GCS and manifest unchanged.
