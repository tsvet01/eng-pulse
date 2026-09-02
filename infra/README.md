# infra

Terraform for Eng Pulse's Hetzner hosting. Stack lives in `infra/hetzner`: a
cx22 box, a 10 GB volume for Postgres data, a firewall, Cloudflare DNS records
for `eng-pulse.tsvetkov.org` and `api.eng-pulse.tsvetkov.org`, and cloud-init
that lays down `/opt/pulse/docker-compose.yml` (Caddy → pulse-api →
Postgres) plus a systemd unit and nightly backup cron.

## Running locally

State is stored remotely in GCS (`gs://tsvet01-terraform-state`, prefix
`hetzner`), created once outside Terraform — see `hetzner/backend.tf`.
Authenticate to GCS and export the provider tokens before running any
command:

```bash
gcloud auth application-default login
export HCLOUD_TOKEN=...
export CLOUDFLARE_API_TOKEN=...
export TF_VAR_cloudflare_zone_id=...
export TF_VAR_admin_cidr=...        # your IP/32, e.g. 203.0.113.7/32
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"

cd infra/hetzner
terraform init
terraform plan
terraform apply
```

cloud-init only *enables* `pulse.service`; on the very first boot the stack
is started by the first CI `deploy-api` run (it writes `.env` then
`docker compose up -d`); every later reboot starts it via systemd.

Without credentials (e.g. in CI or for a quick syntax check), validate the
stack without touching the backend or any provider API:

```bash
cd infra/hetzner
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

## Terraform provisions, CI deploys

Terraform's job stops at the box existing: server, volume, firewall, DNS,
and the cloud-init payload that installs Docker and seeds
`/opt/pulse/docker-compose.yml`. It does **not** push application releases.
Once the host is up, GitHub Actions CI owns deploys — it builds and pushes
the `pulse-api` image, writes `/opt/pulse/.env` over SSH, and restarts the
`pulse.service` systemd unit. Re-running `terraform apply` should be a no-op
between infrastructure changes; it must never be part of the normal release
path.

## First deploy

For bootstrapping a brand-new box (state bucket creation, backup bucket and
service account, first `terraform apply`, first CI deploy), follow
[`docs/runbooks/phase0-setup.md`](../docs/runbooks/phase0-setup.md).
