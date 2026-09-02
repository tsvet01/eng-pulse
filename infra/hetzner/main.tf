resource "hcloud_ssh_key" "anton" {
  name       = "anton"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "pulse" {
  name = "pulse"
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    # GitHub-hosted runners have no stable, publishable IP range, so the
    # deploy job's SSH step cannot be restricted to var.admin_cidr here.
    # Access control is enforced at the SSH layer instead (see
    # cloud-init.yaml.tftpl: key-only auth, AllowUsers deploy root).
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_primary_ip" "pulse" {
  name        = "pulse-ipv4"
  type        = "ipv4"
  auto_delete = false
  location    = var.location
}

resource "hcloud_volume" "pg" {
  name     = "pulse-pg"
  size     = 10
  location = var.location
  format   = "ext4"
}

resource "hcloud_server" "pulse" {
  name         = "pulse"
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.anton.id]
  firewall_ids = [hcloud_firewall.pulse.id]
  public_net {
    ipv4 = hcloud_primary_ip.pulse.id
  }
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_public_key = var.ssh_public_key
    api_image      = var.api_image
    volume_id      = hcloud_volume.pg.id
    compose        = file("${path.module}/files/docker-compose.yml")
    caddyfile      = file("${path.module}/files/Caddyfile")
    backup_sh      = file("${path.module}/files/backup.sh")
  })
}

resource "hcloud_volume_attachment" "pg" {
  volume_id = hcloud_volume.pg.id
  server_id = hcloud_server.pulse.id
  automount = true
}
