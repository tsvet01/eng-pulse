terraform {
  required_version = ">= 1.9"
  required_providers {
    hcloud     = { source = "hetznercloud/hcloud", version = "~> 1.50" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.52" }
  }
}

provider "hcloud" {}     # HCLOUD_TOKEN
provider "cloudflare" {} # CLOUDFLARE_API_TOKEN
