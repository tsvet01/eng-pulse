variable "cloudflare_zone_id" {
  type = string
}

variable "admin_cidr" {
  type = string
  # Not currently applied to any firewall rule: GitHub-hosted runners have no
  # stable IP to allowlist, so port 22 is open (see main.tf) and hardened at
  # the SSH layer instead. Kept declared, and still populated by CI's
  # TF_VAR_admin_cidr, reserved for a future SSH allowlist (e.g. a
  # self-hosted runner or bastion with a known egress IP).
  description = "Reserved for a future SSH allowlist (CIDR, e.g. Anton's IP/32); not currently wired into any firewall rule"
  sensitive   = true
}

variable "ssh_public_key" {
  type      = string
  sensitive = true
}

variable "server_type" {
  type    = string
  default = "cx22"
}

variable "location" {
  type    = string
  default = "nbg1"
}

variable "api_image" {
  type    = string
  default = "ghcr.io/tsvet01/pulse-api"
}
