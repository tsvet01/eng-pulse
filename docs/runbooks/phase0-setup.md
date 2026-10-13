# Phase 0 Setup Runbook

## Overview

This runbook walks you through the one-time setup for Phase 0 deployment infrastructure. Repository-level secrets are visible to all jobs in GitHub Actions; the **`production` environment** adds a required-reviewer approval gate and holds only the secrets that must never be exposed to PR-time `terraform-plan` jobs. Repository-level secrets: `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `ADMIN_CIDR`, `SSH_PUBLIC_KEY`, `GCP_CREDENTIALS`. Production-only secrets: `DEPLOY_SSH_KEY`, `DEPLOY_HOST_FINGERPRINT`, `PULSE_ENV`, `GCS_BACKUP_SA_JSON`.

---

## 1. Supabase Project

For the [2026-10-13 pilot](../superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md), Apple and email/OTP are required; Google is deferred if it would delay launch. This runbook provisions prerequisites, not the complete pilot. Verify the Supabase tier and any SMTP charges in the pilot cost worksheet.

- [x] Supabase project supplied by Anton: `zimjnykjqsxwsidwmemd`. Project exists; region/tier still need dashboard verification. Use the existing project.
- [x] Project URL: `https://zimjnykjqsxwsidwmemd.supabase.co` (2026-10-13).
- [ ] **Authentication → Providers** — enable:
  - **Apple (native iOS)**: enable Sign in with Apple for App ID `org.tsvetkov.EngPulseSwift` in Apple Developer; add that ID to the Supabase Apple provider's Client IDs. Follow the [native sign-in guidance](https://supabase.com/docs/guides/auth/social-login/auth-apple). Native-only sign-in does not need the web OAuth Services ID/signing-secret rotation. If web OAuth is added later, configure it separately.
  - **Google (optional for pilot)**: enter OAuth 2.0 client IDs for iOS and web from GCP
  - **Email**: magic link + OTP enabled
- [ ] **Authentication → SMTP** — configure a verified sender and custom SMTP credentials directly in Supabase. Its default sender only reaches organization team addresses, so it cannot deliver OTPs to ordinary pilot users. Follow [custom SMTP setup](https://supabase.com/docs/guides/auth/auth-smtp); do not paste SMTP passwords into chat or commit them.
- [ ] Keep email confirmation enabled. Confirm the **current** JWT signing key uses ES256 or RS256, as required by the API; a published standby key alone is insufficient. See [JWT signing keys](https://supabase.com/docs/guides/auth/signing-keys).
- [x] Public JWKS responds with an ES256/P-256 key (2026-10-13): `https://zimjnykjqsxwsidwmemd.supabase.co/auth/v1/.well-known/jwks.json`. Real token verification remains pending.
- [x] Issuer derived from the project URL: `https://zimjnykjqsxwsidwmemd.supabase.co/auth/v1`. Audience: `authenticated`.

---

## 2. GitHub Environment & Secrets

- [ ] Go to repository **Settings → Environments → New environment**; name it `production`.
- [ ] Set **Deployment branches**: allow `main` only.
- [ ] Set **Required reviewers**: Anton (anton.tsvetkov@gmail.com).

### Repository-level secrets
Set these at **Settings → Secrets and variables → Actions → New repository secret** (PR plans read these before approval):

- [ ] **`HCLOUD_TOKEN`**: Hetzner project `eng-pulse` → Security → API tokens → create Read & Write token
- [ ] **`CLOUDFLARE_API_TOKEN`**: Cloudflare account → API Tokens → create token with scope `Zone:DNS:Edit` for the `tsvetkov.org` zone
- [ ] **`CLOUDFLARE_ZONE_ID`**: from Cloudflare zone overview for `tsvetkov.org`
- [ ] **`ADMIN_CIDR`**: your home IP range or corporate network (e.g., `1.2.3.4/32`)
- [x] **`SSH_PUBLIC_KEY`**: public half of the dedicated deploy keypair `~/.ssh/pulse-deploy` on Anton's Mac (generated 2026-09-14; use `ssh -i ~/.ssh/pulse-deploy deploy@<host>` for manual access)
- [ ] **`GCP_CREDENTIALS`**: GCP service account JSON (for backup and Cloud Run deployments)

### Production environment secrets
Set these at **Settings → Environments → production → Environment secrets** (repository-level secrets are inherited; set only these three):

- [x] **`DEPLOY_SSH_KEY`**: private half of `~/.ssh/pulse-deploy`. The public half (`SSH_PUBLIC_KEY`) is installed by cloud-init on the box.
- [ ] **`DEPLOY_HOST_FINGERPRINT`**: the box's SSH host key fingerprint, so `appleboy/ssh-action` verifies it instead of trusting on first connect. Capture it **after the first `terraform apply`**, once `server_ipv4` is known:
  ```bash
  ssh-keygen -lf <(ssh-keyscan -t ecdsa <server_ipv4> 2>/dev/null) | awk '{print $2}'
  ```
  The output looks like `SHA256:AbCdEf...`; set that whole string as this secret. It must be the ECDSA key: `appleboy/ssh-action` negotiates ECDSA before ed25519, and a fingerprint of another key type fails with `host key fingerprint mismatch`.
- [ ] **`PULSE_ENV`**: environment file body (see section 3 below)
- [x] **`GCS_BACKUP_SA_JSON`**: key for `pulse-backup@tsvet01.iam.gserviceaccount.com` (objectAdmin on `tsvet01-pulse-backups` only; set 2026-09-14). Rotate with `gcloud iam service-accounts keys create` and re-set the secret.

---

## 3. `PULSE_ENV` Secret Body

Copy this exact template into the GitHub secret `PULSE_ENV`. Replace placeholders:

```
POSTGRES_PASSWORD=<generate: openssl rand -hex 24>
BIND_ADDR=0.0.0.0:8080
RUST_LOG=info
SUPABASE_JWKS_URL=https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json
SUPABASE_ISSUER=https://<project-ref>.supabase.co/auth/v1
SUPABASE_AUDIENCE=authenticated
PIPELINE_SERVICE_TOKEN=<generate: openssl rand -hex 32>
ADMIN_EMAIL=<your email>
```

To generate secrets:
- `openssl rand -hex 24` → 24-byte hex string (48 characters)
- `openssl rand -hex 32` → 32-byte hex string (64 characters)

Replace `<project-ref>` with your Supabase project reference (e.g., `xyzabc`).

**Note**: `POSTGRES_PASSWORD`, `BIND_ADDR`, and `RUST_LOG` are used in Phase 0; Supabase and service-token keys are for Phase 1 — set them now so Phase 1 requires no environment change.

---

## 4. Cloudflare

- [ ] Verify `tsvetkov.org` nameservers point to Cloudflare:
  ```bash
  dig NS tsvetkov.org
  ```
  Expected: `ns1.cloudflare.com`, `ns2.cloudflare.com`, etc.
- [ ] Go to Cloudflare dashboard → Zones → select `tsvetkov.org`.
- [ ] **Account Home → API Tokens** → Create token:
  - Permissions: `Zone:DNS:Edit`
  - Zone resources: `Include → tsvetkov.org`
  - Copy token → save as repository secret `CLOUDFLARE_API_TOKEN`
- [ ] **Zone overview** → copy Zone ID → save as repository secret `CLOUDFLARE_ZONE_ID`

---

## 5. Hetzner

- [ ] Go to Hetzner Cloud console → select project `eng-pulse`.
- [ ] **Security** → **API Tokens** → Generate new token:
  - Permissions: Read & Write
  - Copy token → save as repository secret `HCLOUD_TOKEN`

---

## Summary

Once all sections are complete:
- Supabase project is live with auth providers and SMTP configured.
- GitHub has two layers of secrets: repository-level (for PR plans) and production-environment (approval-gated for deployments).
- `PULSE_ENV` is set with Supabase URLs and generated secrets.
- Cloudflare and Hetzner tokens are in place.

Proceed to Terraform deployment (`terraform-apply` job) once a PR with infrastructure changes is approved.

---

## Merge day order

Follow this order end to end for the first (and any subsequent infra-touching) merge to `main`:

1. **Set repository secrets** — all of section 2's repository-level secrets (`HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `ADMIN_CIDR`, `SSH_PUBLIC_KEY`, `GCP_CREDENTIALS`) so PR-time `terraform-plan` can run.
2. **Open the PR and wait for `terraform-plan` to go green** on it (the plan summary posts as a PR comment; the full redacted plan is the `terraform-plan` workflow artifact).
3. **Merge to `main`.**
4. **Approve `terraform-apply`** in the `production` environment (required reviewer: Anton). This provisions the box and DNS records.
5. **Capture `DEPLOY_HOST_FINGERPRINT`** (see item 8 in section 2) now that `server_ipv4` is known, and set it as a `production`-environment secret.
6. **Wait out the DNS TTL** (300s) for `api.eng-pulse.tsvetkov.org` to resolve to the new box.
7. **Trigger `deploy-api`.** Prefer re-running the failed/skipped jobs on the merge-commit's workflow run (Actions → that run → "Re-run failed jobs") so it reuses the same commit and build cache; only fall back to `workflow_dispatch` with `deploy_api=true` if that run is no longer re-runnable (e.g. expired).
8. **Verify**: `curl https://api.eng-pulse.tsvetkov.org/healthz` returns `{"status":"ok","db":"ok"}` over valid TLS.
9. **Run the backup once, as the `deploy` user** (not `sudo`, since `/opt/pulse` is owned by `deploy`):
   ```bash
   ssh deploy@api.eng-pulse.tsvetkov.org /opt/pulse/backup.sh
   ```
10. **Next morning, confirm the daily pipeline ran unaffected**: `./scripts/shadow-eval-report.sh 1`.
