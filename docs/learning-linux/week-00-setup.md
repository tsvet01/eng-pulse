# Week 0 — Setup, and retiring dead commands

> **By the end:** a Rocky box you own, key-only SSH, OrbStack running locally, and fingers
> that no longer reach for `ifconfig`.

**Time:** ≈2 h, one evening · **Where:** Mac + Hetzner
**Prereq:** a Hetzner account and a domain you control (optional but useful from week 9)

---

## What this week is

Everything after this assumes a working practice environment. The single most important
decision is already made: **your practice box runs the same distro family as your work fleet.**
That's what makes every hour here transfer directly rather than half-transfer.

The second half of this session is unglamorous and matters more than it looks. Your hands
still know a command set from 2013. About a dozen of those commands are deprecated, removed,
or lying to you through a compatibility shim. Retraining them takes an evening and removes
the most visible sign that you've been away.

---

## Session 1 — Provision the box (≈1 h)

### What you're building

A Hetzner **CX22** (x86, shared vCPU, ~€4/mo) running **Rocky Linux**. Two choices worth
understanding rather than just accepting:

**Why Rocky and not Ubuntu.** Rocky is a bit-compatible rebuild of RHEL. Your work fleet is
RHEL-based, so `dnf`, SELinux contexts, `firewalld`, and the `/etc` layout are identical.
Ubuntu would teach you a different dialect for the same concepts, and you'd translate forever.

**Why x86 and not the cheaper ARM.** CAX (ARM) instances are marginally cheaper, but your work
VMs are almost certainly x86. Architecture mismatches surface in container images and
occasionally in package availability. Match production.

Check your work version first so you provision the same major release:

```bash
cat /etc/redhat-release      # on a work VM
```

### Do this

1. Create the server: Hetzner Cloud → Add Server → Rocky Linux, CX22, and **add your SSH
   public key during creation**. If you don't have one:

   ```bash
   ssh-keygen -t ed25519 -C "you@example.com"    # ed25519, not RSA — smaller and faster
   ```

2. First login and a non-root user. Never work as root day-to-day:

   ```bash
   ssh root@<ip>
   adduser anton
   usermod -aG wheel anton                 # 'wheel' is the sudo group on RHEL, not 'sudo'
   mkdir -p /home/anton/.ssh
   cp /root/.ssh/authorized_keys /home/anton/.ssh/
   chown -R anton:anton /home/anton/.ssh
   chmod 700 /home/anton/.ssh
   chmod 600 /home/anton/.ssh/authorized_keys
   ```

3. **Verify you can log in as the new user in a second terminal before you continue.**
   Locking yourself out here is the classic mistake, and you'd need Hetzner's console to recover.

4. Harden SSH. Edit `/etc/ssh/sshd_config`:

   ```
   PermitRootLogin no
   PasswordAuthentication no
   ```

   Then `sudo systemctl restart sshd`. On RHEL 9+, check `/etc/ssh/sshd_config.d/` for
   drop-in files that may override these — the drop-ins win.

5. Automatic security updates:

   ```bash
   sudo dnf install -y dnf-automatic
   sudo systemctl enable --now dnf-automatic.timer
   ```

6. Confirm SELinux is enforcing, and leave it that way:

   ```bash
   sestatus        # want: SELinux status: enabled / Current mode: enforcing
   ```

7. A `~/.ssh/config` entry on your Mac so connecting is one word:

   ```
   Host rocky
     HostName <ip>
     User anton
     IdentityFile ~/.ssh/id_ed25519
   ```

8. **Take a Hetzner snapshot and label it `clean`.** You will want this in week 10.

### Prove it

`ssh rocky` logs you in with no password prompt, `ssh root@<ip>` is refused, and
`sudo dnf update` runs without asking for a password twice.

---

## Session 2 — Local environment and the command drill (≈1 h)

### OrbStack

Install [OrbStack](https://orbstack.dev). It gives you Docker plus lightweight Linux machines
on macOS, and it's substantially faster than Docker Desktop for filesystem-heavy work.

```bash
orb create rocky dev          # matches your server and work
orb create debian scratch     # you'll meet apt constantly in base images
orb list
orb                           # shell into the default machine
```

**Understand the limitation now, not in week 5.** All OrbStack machines share one lightweight
VM and therefore one kernel. That makes them excellent for shell practice, `dnf`, systemd
units, and every bit of the Docker material — and useless for SELinux enforcement, nftables
against a real network stack, LVM, boot recovery, or eBPF. Those need the Hetzner box.

They're also ARM64 on Apple Silicon while your fleet is x86. Invisible day to day; decisive
when you build images, which is exactly what week 8's remote builder addresses.

### The notes repo

```bash
mkdir -p ~/notes && cd ~/notes && git init && echo "# Linux notes" > notes.md
```

Rule: anything you look up twice goes in here, in your own words. By week 12 this file is
worth more than any of these documents.

### The dead-command drill

Your fingers know these. Retrain them. Run each replacement on the Rocky box until it comes
out without thinking:

| Your reflex | Type instead | Why it changed |
|---|---|---|
| `ifconfig` | `ip a` | net-tools is deprecated and often not installed at all |
| `netstat -tulpn` | `ss -tulpn` | Same information, dramatically faster on busy hosts |
| `route -n` | `ip r` | Folded into the `ip` suite |
| `arp` | `ip n` | Neighbour table, same suite |
| `service x start` | `systemctl start x` | SysV init is gone; the shim hides real errors |
| `chkconfig x on` | `systemctl enable x` | Runlevels became targets |
| `tail -f /var/log/messages` | `journalctl -fu <unit>` | Logs are a structured binary journal now |
| `iptables -L` | `nft list ruleset` / `firewall-cmd --list-all` | nftables replaced it; iptables is a translation shim |
| `yum` | `dnf` | `yum` is a symlink to `dnf` on RHEL 8+ |
| `nslookup` | `dig` | Honest output that shows the actual resolution path |
| `nohup cmd &` | `systemd-run --user cmd` | Supervision, logging and resource limits for free |

Do this twenty minutes a day for the first week and it'll be permanent.

### Prove it

Without hesitating: show all listening TCP sockets with the owning process, the default route,
and the last 20 error-priority journal entries.

<details>
<summary>Answers</summary>

```bash
ss -tlnp
ip r
journalctl -p err -n 20
```
</details>

---

## What changed while you were away

Read this once. It's the map for the next twelve weeks.

**systemd won, completely.** Not just init — service supervision, logging, timers, socket
activation, resource control, sandboxing, and container supervision all live there. Largest
single thing to relearn, which is why week 3 is dedicated to it.

**Containers became the unit of deployment.** Docker was a year old when you stepped away.
The image is now the artifact, and build/test/ship is organised around it. Weeks 6–9.

**Configuration became code.** Puppet and Chef gave way to Ansible for servers and Terraform
for infrastructure, with git as the source of truth. Week 12.

**SELinux got genuinely usable.** The 2013 reflex was `setenforce 0`. That's now an audit
finding, and the diagnostic tooling actually works. Week 5.

**TLS became free and universal.** Let's Encrypt (2016) ended both expensive certificates and
unencrypted internal traffic. Certificate automation is table stakes. Weeks 4 and 9.

**Observability replaced monitoring.** Nagios-style up/down gave way to Prometheus metrics,
structured logs, tracing, and eBPF for live kernel introspection. Week 11.

---

## Checkpoint

- [ ] `ssh rocky` works with keys only; root login and password auth both refused
- [ ] SELinux reports `enforcing`
- [ ] A snapshot labelled `clean` exists
- [ ] OrbStack has a `rocky` machine you can shell into
- [ ] You can produce `ss -tlnp`, `ip r`, and `journalctl -p err` without pausing

---

## If you want more

- `man sshd_config` — read the whole thing once; it's shorter than you expect
- Hetzner's docs on rescue mode — skim now, you'll need it in week 10
