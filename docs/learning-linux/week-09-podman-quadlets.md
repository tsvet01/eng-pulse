# Week 9 — Podman, quadlets, and shipping it

> **By the end:** a real service on a real domain, rootless, systemd-supervised, surviving
> reboots with zero human action.

**Time:** ≈5 h across 3 sessions · **Where:** Rocky box (rootless needs a real kernel)
**Prereq:** week 8 checkpoint — you need an image to deploy

---

## What this is, and why it matters

**RHEL ships no Docker.** Red Hat removed it in RHEL 8 and replaced it with Podman (run),
Buildah (build), and Skopeo (move images). If your work fleet is RHEL-based, this is what's
actually installed, and knowing it is directly transferable in a way most of this plan's
Docker material is only indirectly.

Two Podman ideas have no Docker equivalent, and both are the kind of thing that reads as
competence to infrastructure people:

**Rootless containers.** No daemon running as root. Containers run as your unprivileged user
via user namespaces — root *inside* the container maps to your ordinary UID *outside*. A
container escape lands the attacker as `anton`, not as root. This is why Red Hat made the
switch, and it's a genuinely better posture than the Docker model where the daemon socket is
root-equivalent.

**Quadlets.** You describe a container in a systemd-unit-shaped file, and systemd generates
and manages a real unit from it. This is how you run a container in production on a single
host without dragging in Kubernetes — and it's the answer to week 6's daemon-vs-container
question: you stop choosing. Image-based packaging, systemd supervision.

### The mental model — how rootless actually works

```
   inside the container        user namespace mapping        on the host
   ────────────────────        ──────────────────────        ───────────
   root (uid 0)          ───────────────────────────▶        anton (uid 1000)
   uid 1                 ───────────────────────────▶        100000
   uid 2                 ───────────────────────────▶        100001
   ...                                                       (from /etc/subuid)
```

```bash
cat /etc/subuid /etc/subgid      # anton:100000:65536 — your allocated range
podman unshare cat /proc/self/uid_map
```

Consequences worth knowing before they surprise you:

- **Ports below 1024 need help.** An unprivileged user can't bind them. Either publish to a
  high port and reverse-proxy (what we'll do), or lower
  `net.ipv4.ip_unprivileged_port_start`.
- **Storage lives under `~/.local/share/containers`**, not `/var/lib/containers`. Root's images
  and yours are separate sets — a frequent "but I pulled that image!" confusion.
- **Your units are user units.** `systemctl --user`, and they stop at logout unless you enable
  lingering.

---

## Session 1 — Podman, Buildah, Skopeo (≈1.5 h)

### Podman as a Docker replacement

The CLI is deliberately compatible. `alias docker=podman` mostly just works, and Podman reads
the same Dockerfiles and OCI images.

```bash
podman run -d --name web -p 8080:80 docker.io/library/nginx:alpine
podman ps
podman logs web
podman exec -it web sh
podman inspect web
podman stop web && podman rm web
podman images
podman system prune -a
```

Differences that actually matter:

| | Docker | Podman |
|---|---|---|
| Architecture | Client → root daemon | Fork/exec, no daemon |
| Default user | root | Your user (rootless) |
| Image names | `nginx` implies Docker Hub | **Fully qualified** — `docker.io/library/nginx` |
| Pods | No | Yes — `podman pod`, shared netns, Kubernetes-shaped |
| systemd integration | Bolt-on | Native, via quadlets |
| Compose | Built in | `podman compose` shim, or the Docker socket |

The fully-qualified image name is the one that trips people first. Podman refuses to guess
which registry you meant (a supply-chain safety choice); either write it out or configure
`unqualified-search-registries` in `/etc/containers/registries.conf`.

### Buildah and Skopeo

```bash
# Buildah builds without a daemon; it also reads Dockerfiles
buildah bud -t myapp:1 .
podman build -t myapp:1 .            # same engine underneath

# Skopeo moves and inspects images without pulling them
skopeo inspect docker://docker.io/library/nginx:alpine | jq '.Digest, .Architecture'
skopeo copy docker://docker.io/library/nginx:alpine containers-storage:localhost/nginx:local
skopeo list-tags docker://docker.io/library/postgres | jq -r '.Tags[-10:][]'
```

`skopeo inspect` reading a remote image's manifest **without downloading it** is genuinely
useful — checking digests, architectures, and tags in CI without burning bandwidth.

### Prove it

Run your week-8 image under Podman rootless. Confirm with `ps -ef` on the host that the
process runs as your user, not root.

---

## Session 2 — Quadlets (≈1.5 h)

### What a quadlet is

A file in `~/.config/containers/systemd/` (rootless) or `/etc/containers/systemd/` (root),
with an extension like `.container`, `.volume`, `.network`, or `.pod`. On `daemon-reload`, a
systemd generator turns it into a real `.service` unit.

You get everything systemd offers — boot ordering, dependencies, restart policy, journald
logging, resource limits, `systemctl status` — with an image as the payload.

> Quadlets superseded `podman generate systemd`, which is deprecated. If you find a tutorial
> using it, it's out of date.

### Your first quadlet

`~/.config/containers/systemd/hello.container`:

```ini
[Unit]
Description=Hello service
After=network-online.target
Wants=network-online.target

[Container]
Image=localhost/myapp:1
PublishPort=8080:8080
Environment=LOG_LEVEL=info
Volume=hello-data:/data
AutoUpdate=registry
# hardening
NoNewPrivileges=true
DropCapability=ALL
AddCapability=NET_BIND_SERVICE
ReadOnly=true
Tmpfs=/tmp

[Service]
Restart=on-failure
RestartSec=10
TimeoutStartSec=90

[Install]
WantedBy=default.target
```

And the volume, `~/.config/containers/systemd/hello-data.volume`:

```ini
[Volume]
```

An empty section is valid — its existence declares the volume.

```bash
systemctl --user daemon-reload           # runs the generator
systemctl --user start hello             # note: 'hello', not 'hello.container'
systemctl --user status hello
journalctl --user -u hello -f
```

The generated unit is named after the file. There is no `enable` step for quadlets —
`WantedBy=` in `[Install]` handles it at generation time, which surprises people used to
`systemctl enable`.

Inspect what was generated when something looks wrong:

```bash
/usr/lib/systemd/user-generators/podman-system-generator --dryrun
```

### Lingering — the step everyone forgets

User units stop when your last session ends. On a server you're rarely logged into, that means
your service dies shortly after you disconnect and never starts at boot.

```bash
loginctl enable-linger $USER
loginctl show-user $USER | grep Linger      # Linger=yes
```

Miss this and you'll have a service that works perfectly in testing and is gone tomorrow.

### Prove it

Start your quadlet, log out entirely, log back in, and confirm it's still running. Then reboot
and confirm it comes back.

---

## Session 3 — Weekend block: a real deployment (≈2.5 h)

### The target

Your week-8 image, running on the Rocky box, behind nginx with a real TLS certificate on a
domain you own, supervised by systemd, surviving reboots.

### Part 1 — DNS and the reverse proxy

Point an A record at the CX22's public IP. Wait for propagation:

```bash
dig +short app.yourdomain.com
```

nginx config, `/etc/nginx/conf.d/app.conf`:

```nginx
server {
    listen 80;
    server_name app.yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Remember week 5 — nginx making an outbound connection is an SELinux boolean, not a label:

```bash
sudo setsebool -P httpd_can_network_connect on
```

Then the firewall:

```bash
sudo firewall-cmd --permanent --add-service=http --add-service=https
sudo firewall-cmd --reload
```

### Part 2 — TLS

```bash
sudo dnf install -y certbot python3-certbot-nginx
sudo certbot --nginx -d app.yourdomain.com
```

Certbot edits your nginx config, obtains the certificate, and installs a renewal timer.
Verify the automation rather than trusting it:

```bash
systemctl list-timers | grep certbot
sudo certbot renew --dry-run
```

That dry run is the whole point. An un-renewed certificate at 3am on a Sunday is a genuinely
avoidable incident, and the failure mode is silent until the expiry date.

### Part 3 — The quadlet, properly

`~/.config/containers/systemd/app.container`:

```ini
[Unit]
Description=MyApp
After=network-online.target
Wants=network-online.target

[Container]
Image=localhost/myapp:1
PublishPort=127.0.0.1:8080:8080     # bind to loopback ONLY — nginx is the front door
Environment=DATABASE_URL=postgres://app:app@10.0.0.3:5432/app
Volume=app-data:/data
NoNewPrivileges=true
DropCapability=ALL
ReadOnly=true
Tmpfs=/tmp
HealthCmd=/usr/bin/curl -fsS http://localhost:8080/healthz || exit 1
HealthInterval=30s
HealthRetries=3

[Service]
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

`PublishPort=127.0.0.1:8080:8080` is the detail worth internalising. Bind to loopback so the
container is reachable *only* through nginx. Publishing on `0.0.0.0:8080` exposes your app
directly, bypassing TLS and the proxy, and the firewall won't save you if that port is open.

```bash
systemctl --user daemon-reload
systemctl --user start app
systemctl --user status app
curl -I https://app.yourdomain.com
```

### Part 4 — Prove it survives

```bash
sudo reboot
# reconnect, then:
systemctl --user status app
curl -I https://app.yourdomain.com
journalctl --user -u app --since "5 minutes ago"
```

If it didn't come back, the cause is almost certainly lingering. Check `loginctl show-user`.

### Part 5 — One supervisor, not two

Worth stating explicitly because it's a real and confusing bug: if systemd manages the
container, **do not** also set a Podman/Docker restart policy. Two supervisors both trying to
restart the same thing produces a flap that's genuinely hard to diagnose — one restarts it,
the other sees an unexpected container and removes it, repeat. Use `Restart=` in `[Service]`
and nothing else.

### Optional — auto-updates

```bash
systemctl --user enable --now podman-auto-update.timer
podman auto-update --dry-run
```

With `AutoUpdate=registry` in the quadlet, Podman checks for a newer digest on the tag and
redeploys, rolling back automatically if the new container fails its healthcheck. Good for a
homelab. In production you'd want this driven by your pipeline, not by a timer on the host —
but the rollback-on-failed-healthcheck mechanism is worth seeing work.

---

## Command reference

```
podman run|ps|logs|exec|inspect|stop|rm       Docker-compatible
podman run -d --name N -p 127.0.0.1:P:P IMAGE
podman unshare CMD                            run inside your user namespace
podman system prune -a
podman auto-update [--dry-run]
buildah bud -t TAG .
skopeo inspect docker://IMAGE
skopeo copy docker://SRC containers-storage:DST
skopeo list-tags docker://IMAGE

# quadlets
~/.config/containers/systemd/NAME.container   rootless
/etc/containers/systemd/NAME.container        system-wide
systemctl --user daemon-reload                regenerate units
systemctl --user start|status NAME            (no .container suffix)
journalctl --user -u NAME -f
loginctl enable-linger $USER                  survive logout / start at boot
/usr/lib/systemd/user-generators/podman-system-generator --dryrun

# TLS
certbot --nginx -d DOMAIN
certbot renew --dry-run
systemctl list-timers | grep certbot
```

---

## Traps

- **Forgetting `enable-linger`.** Service works in testing, gone after you log out.
- **Expecting `systemctl --user enable name.container` to work.** Quadlets use `[Install]` and
  the generator; there's no separate enable step.
- **Forgetting `daemon-reload`** after editing a quadlet. Same trap as week 3.
- **Publishing on `0.0.0.0`** when nginx is meant to be the only entrance.
- **Two supervisors.** systemd `Restart=` *and* a container restart policy will fight.
- **Unqualified image names.** Podman won't guess the registry.
- **Rootless port 80.** Won't bind. Proxy from a high port.
- **Trusting certbot's renewal without testing it.** `--dry-run`, once, now.
- **Root vs rootless image storage.** `sudo podman images` and `podman images` are different
  sets, and building with one and running with the other fails confusingly.

---

## Checkpoint

1. The service returns after a **reboot** with zero human action.
2. It runs as an unprivileged user — verify from the host with `ps -ef`.
3. `journalctl --user -u app` shows its logs like any other system service.
4. `certbot renew --dry-run` succeeds.
5. Explain why Red Hat replaced Docker with Podman, in terms of the daemon and user namespaces.

---

## If you want more

- `man podman-systemd.unit` — the quadlet reference, and it's excellent
- Red Hat's *Building, running, and managing containers* guide
- `man containers.conf`, `man registries.conf`
- Podman's rootless tutorial on the subuid/subgid mechanics
