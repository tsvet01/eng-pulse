variable "cloudflare_zone_id" {
  type = string
}

variable "admin_cidr" {
  type        = string
  description = "CIDR allowed to SSH (Anton's IP/32)"
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
