terraform {
  backend "gcs" {
    bucket = "tsvet01-terraform-state"
    prefix = "hetzner"
  }
}
