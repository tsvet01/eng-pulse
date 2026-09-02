resource "cloudflare_record" "api" {
  zone_id = var.cloudflare_zone_id
  name    = "api.eng-pulse"
  type    = "A"
  content = hcloud_primary_ip.pulse.ip_address
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "root" {
  zone_id = var.cloudflare_zone_id
  name    = "eng-pulse"
  type    = "A"
  content = hcloud_primary_ip.pulse.ip_address
  ttl     = 300
  proxied = false
}
