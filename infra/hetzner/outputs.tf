output "server_ipv4" {
  value = hcloud_primary_ip.pulse.ip_address
}

output "volume_mount" {
  value = "/mnt/HC_Volume_${hcloud_volume.pg.id}"
}
