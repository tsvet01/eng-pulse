# Phase 0 Setup Runbook

## Overview

This runbook walks you through the one-time setup for Phase 0 deployment infrastructure. Some secrets live at the **repository level** (needed by PR-time `terraform-plan` jobs, which run before approval) and others only in the **`production` environment** (for box-mutating operations like deploying the API). Repository-level secrets include `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `ADMIN_CIDR`, `SSH_PUBLIC_KEY`, and `GCP_CREDENTIALS`; environment secrets (approval-gated) are `DEPLOY_SSH_KEY`, `PULSE_ENV`, and `GCS_BACKUP_SA_JSON`.

---

## 1. Supabase Project

- [ ] Go to [supabase.com](https://supabase.com) and create a new project named `eng-pulse` in region **EU (Frankfurt)** (closest to Hetzner `nbg1`).
- [ ] Note the project URL: `https://<project-ref>.supabase.co`
- [ ] **Authentication → Providers** — enable:
  - **Apple**: enter Services ID and key from Apple Developer portal, team `9XQ7BW6Q4T`
  - **Google**: enter OAuth 2.0 client IDs for iOS and web from GCP
  - **Email**: magic link + OTP enabled
- [ ] **Authentication → SMTP** — configure Anton's Gmail:
  - SMTP host: `smtp.gmail.com:587`
  - From email/password: use Gmail app password (not account password)
- [ ] Copy the JWKS URL: `https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json`
- [ ] Copy the issuer: `https://<project-ref>.supabase.co/auth/v1`

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
- [ ] **`SSH_PUBLIC_KEY`**: SSH public key (contents of `~/.ssh/id_ed25519.pub`) for Hetzner box
- [ ] **`GCP_CREDENTIALS`**: GCP service account JSON (for backup and Cloud Run deployments)

### Production environment secrets
Set these at **Settings → Environments → production → Environment secrets**:

- [ ] **`HCLOUD_TOKEN`**: (same as repository-level, repeated for `terraform-apply` approval gate)
- [ ] **`CLOUDFLARE_API_TOKEN`**: (same as repository-level, repeated for `terraform-apply` approval gate)
- [ ] **`CLOUDFLARE_ZONE_ID`**: (same as repository-level, repeated for `terraform-apply` approval gate)
- [ ] **`ADMIN_CIDR`**: (same as repository-level, repeated for `terraform-apply` approval gate)
- [ ] **`SSH_PUBLIC_KEY`**: (same as repository-level, repeated for `terraform-apply` approval gate)
- [ ] **`DEPLOY_SSH_KEY`**: SSH private key for `deploy` user on production box (contents of `~/.ssh/id_ed25519`, kept secret)
- [ ] **`PULSE_ENV`**: environment file body (see section 3 below)
- [ ] **`GCS_BACKUP_SA_JSON`**: GCS service account JSON for database backups

---

## 3. `PULSE_ENV` Secret Body

Copy this exact template into the GitHub secret `PULSE_ENV`. Replace placeholders:

```
POSTGRES_PASSWORD=<generate: openssl rand -hex 24>
BIND_ADDR=0.0.0.0:8080
RUST_LOG=info
SUPABASE_JWKS_URL=https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json
SUPABASE_ISSUER=https://<project-ref>.supabase.co/auth/v1
PIPELINE_SERVICE_TOKEN=<generate: openssl rand -hex 32>
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
