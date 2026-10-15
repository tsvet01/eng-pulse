# Phase 0 Setup Runbook

## Overview

This runbook walks you through the one-time setup for Phase 0 deployment infrastructure. Repository-level secrets are visible to all jobs in GitHub Actions; the **`production` environment** adds a required-reviewer approval gate and holds only the secrets that must never be exposed to PR-time `terraform-plan` jobs. Repository-level secrets: `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `ADMIN_CIDR`, `SSH_PUBLIC_KEY`, `GCP_CREDENTIALS`. Production-only secrets: `DEPLOY_SSH_KEY`, `DEPLOY_HOST_FINGERPRINT`, `PULSE_ENV`, `GCS_BACKUP_SA_JSON`.

---

## 1. Supabase Project

For the [2026-10-13 pilot](../superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md), Apple and email/OTP are required; Google is deferred if it would delay launch. This runbook provisions prerequisites, not the complete pilot. Verify the Supabase tier and any SMTP charges in the pilot cost worksheet.

- [x] Supabase project supplied by Anton: `zimjnykjqsxwsidwmemd`. Dashboard verified healthy in Frankfurt (`eu-central-1`), Free plan, on 2026-10-13. Use the existing project.
- [x] Project URL: `https://zimjnykjqsxwsidwmemd.supabase.co` (2026-10-13).
- [x] **Authentication → Providers** — required pilot providers enabled:
  - **Apple (native iOS)**: the pilot App ID `org.tsvetkov.eng-pulse` was registered with Sign in with Apple on 2026-10-14. With Anton's explicit approval, saved it as the Supabase Apple provider's Client IDs, replacing the incorrect team ID `9XQ7BW6Q4T`; persistence verified after a page reload on 2026-10-14. The provider remains enabled and allowing users without an email remains off. Native sign-in is implemented in [draft PR #190](https://github.com/tsvet01/eng-pulse/pull/190) and passed the physical-device test below on 2026-10-15. Follow the [native sign-in guidance](https://supabase.com/docs/guides/auth/social-login/auth-apple). Native-only sign-in does not need the web OAuth Services ID/signing-secret rotation. If web OAuth is added later, configure it separately.
  - **Google (optional for pilot)**: enter OAuth 2.0 client IDs for iOS and web from GCP
  - **Email**: enabled; signup and sign-in templates use `{{ .Token }}` for code entry in the app (saved and verified 2026-10-13).
- [x] **Authentication → SMTP** — Anton saved the Resend credential directly in Supabase; enabled SMTP and stored password verified on 2026-10-13. Sender: `Eng Pulse <eng-pulse@n21.me>`. Signup and repeat sign-in emails were delivered and both codes accepted on 2026-10-14. Follow [custom SMTP setup](https://supabase.com/docs/guides/auth/auth-smtp); do not paste SMTP passwords into chat or commit them.
- [x] Email provider and email confirmation enabled; dashboard **current** JWT signing key is ECC P-256/ES256 (2026-10-13). Two real email sign-in tokens verified on 2026-10-14. See [JWT signing keys](https://supabase.com/docs/guides/auth/signing-keys).
- [x] Public JWKS responds with an ES256/P-256 key: `https://zimjnykjqsxwsidwmemd.supabase.co/auth/v1/.well-known/jwks.json`. Both real token signatures verified against it on 2026-10-14.
- [x] Issuer derived from the project URL: `https://zimjnykjqsxwsidwmemd.supabase.co/auth/v1`. Audience: `authenticated`.

### Pilot app identity

Anton selected `org.tsvetkov.eng-pulse` on 2026-10-13. Debug/Release build settings and the dummy CI Firebase plist use it; the display name remains **Eng Pulse**. This is a separate installed app from `org.tsvetkov.EngPulseSwift`, with separate local data and APNs tokens.

- [x] Check the current App Store Connect app records. On 2026-10-15, refreshing the stale browser tab cleared the Terms of Service screen; the Apps page opened normally and showed **No Apps** for Anton's account. No existing app record is available to reuse in the current account.
- [ ] Create the Eng Pulse App Store Connect record using `org.tsvetkov.eng-pulse` before TestFlight distribution. Apple does not allow changing an app record's bundle ID after upload. See [Apple app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information).
- [x] Register the explicit App ID `org.tsvetkov.eng-pulse`, description **Eng Pulse**, under team `9XQ7BW6Q4T` with Sign in with Apple (primary App ID) and Push Notifications. Anton approved registration; the new identifier appeared in Apple Developer on 2026-10-14. Existing identifiers remain registered.
- [ ] Obtain the CarPlay audio entitlement for the new ID. On 2026-10-15, refreshing development provisioning resolved Apple sign-in/push signing, but the full app build failed because the profile could not include `com.apple.developer.carplay-audio`. This remains a release gate.
- [x] Build and verify a signed local authentication test app (2026-10-15). A temporary entitlement override omitted only CarPlay; the checked-in entitlements retain it. The device build and strict signature verification passed with the correct bundle ID, Apple sign-in entitlement, pilot flag and local Supabase configuration. Installation and launch on the paired iPhone 14 Pro also succeeded. This does not validate CarPlay or distribution signing.
- [x] Save `org.tsvetkov.eng-pulse` in Supabase's Apple Client IDs; verified after a page reload on 2026-10-14.
- [x] Verify native sign-in from a signed device build (2026-10-15). Anton completed Apple's prompt on the iPhone and reported the app's signed-in state: “You’re signed in; pilot access still needs confirming.” This verifies native Apple-to-Supabase authentication, not API admission, engineering membership or administrator access. Those remain pending.
- [ ] Complete the planned replacement of Firebase Auth/feedback/device registration with the API before distributing the pilot. If testing the new bundle while Firebase remains, register a separate Firebase iOS app and install its matching local configuration; never relabel the old plist or commit credentials.
- [ ] Configure the pilot APNs worker for `org.tsvetkov.eng-pulse`, register fresh device tokens, and test delivery. Preserve the legacy GCP sender's `org.tsvetkov.EngPulseSwift` topic and old registrations; new tokens must not enter the legacy sender's pool. Follow the pilot's per-recipient cutover and rollback steps.

**Device connection note, 2026-10-15:** Pairing completed after the approved local IPv6 change and temporary relaxation of NordVPN's local-device isolation. After installation and launch, **Stay invisible on a local network** was restored to **on**, the required reconnect completed, and NordVPN showed **Connected**. No temporary VPN relaxation remains. Keep the separately approved Wi-Fi IPv6 setting at **Link-Local Only**.

### Email sender status

Custom SMTP is enabled with sender `Eng Pulse <eng-pulse@n21.me>`, host `smtp.resend.com`, port `465`, username `resend`, and a stored password entered directly by Anton. Resend's `n21.me` domain is verified. The prepared key was named `Eng Pulse Supabase Auth`, with sending-only access restricted to `n21.me`; the key value was never collected. The minimum interval remains 60 seconds per user. See [Resend's Supabase SMTP guide](https://resend.com/docs/send-with-supabase-smtp).

Both **Magic link or OTP** (subject `Your Eng Pulse sign-in code`) and **Confirm sign up** (subject `Confirm your email for Eng Pulse`) now show `{{ .Token }}` and instruct the reader to enter the code in the app. Saved template content was verified in the dashboard on 2026-10-13. The Swift client must request `signInWithOTP` and verify the received code using the email OTP flow; see [Supabase passwordless email guidance](https://supabase.com/docs/guides/auth/auth-email-passwordless).

- [x] Actual email receipt and code acceptance verified for signup and repeat sign-in (2026-10-14).
- [x] Both real tokens used ES256; signatures verified against the project JWKS, issuer matched `https://zimjnykjqsxwsidwmemd.supabase.co/auth/v1`, audience was `authenticated`, expiry was valid and the administrator's email was confirmed (2026-10-14). This checks Supabase tokens against the API's configured requirements; deployed API authorization and Swift integration remain separate launch gates.

**Delivery evidence, 2026-10-14:** Anton authorized two test sign-in emails and entered both codes locally. Resend shows **Delivered** for [signup](https://resend.com/emails/01a138ea-dbbe-7b20-9bb2-09a439a1e537), subject `Confirm your email for Eng Pulse`, and [repeat sign-in](https://resend.com/emails/01a138f8-613f-76b6-be36-4b04cff13112), subject `Your Eng Pulse sign-in code`. The local check recorded exactly two email requests and two successful verifications, with the signature/identity checks above. Both temporary test sessions were signed out using local session scope. The confirmed Supabase user remains available for the pilot; this test did not create an API membership or administrator role. No OTPs, session tokens or private credentials were retained.

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
