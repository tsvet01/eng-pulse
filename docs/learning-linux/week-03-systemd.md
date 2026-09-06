# Week 3 — systemd and the journal

> **By the end:** you write hardened unit files from scratch and read the journal fluently.

**Time:** ≈6 h across 3 sessions · **Where:** Rocky box (units also work in OrbStack)
**Prereq:** week 2 checkpoint — specifically the backup script

---

## What this is, and why it matters

**Treat this as new material.** When you were last hands-on, init was SysV shell scripts or
Upstart, and logs were text files in `/var/log`. systemd replaced both, then kept absorbing
responsibilities. Today it owns service supervision, logging, scheduled jobs, socket
activation, resource control, process sandboxing, user sessions, network configuration on some
distros, and — via quadlets in week 9 — container supervision.

It is the single largest thing to relearn, and it pays back more than anything else in this
plan, because it's the layer you touch every time something is running or failing on a server.

The design idea worth grasping: **systemd is declarative and dependency-aware.** A SysV script
was imperative — a shell program that started something, with ordering expressed by two-digit
filename prefixes. A unit file *describes* a service: what it needs, what needs it, what to do
when it dies, how much memory it may use, what parts of the filesystem it can see. systemd
computes a dependency graph and executes it in parallel. This is why modern boots are fast, and
why "just run this script at startup" is no longer the right shape of answer.

### The mental model

```
  target  (a synchronisation point, e.g. multi-user.target — replaces runlevels)
     │
     ├── service   a process systemd supervises
     ├── socket    a listening socket; starting a connection can activate the service
     ├── timer     schedules another unit (the cron replacement)
     ├── mount     a filesystem mount, generated from /etc/fstab
     ├── path      watches a file/dir and activates a unit on change
     └── slice     a cgroup for resource control across a group of units
```

Units live in three places, and precedence matters enormously:

| Location | Owner | Wins? |
|---|---|---|
| `/usr/lib/systemd/system/` | The **package**. Overwritten on every update. | Lowest |
| `/etc/systemd/system/` | **You.** Never touched by package updates. | Highest |
| `/run/systemd/system/` | Runtime, gone on reboot. | Middle |

**Never edit a vendor unit in `/usr/lib`.** The next `dnf update` silently reverts it. Use
`systemctl edit <unit>`, which creates a drop-in at
`/etc/systemd/system/<unit>.d/override.conf` containing only your changes.

---

## Session 1 — Units, and reading the system (≈1.5 h)

### The distinction that trips everyone

- **`start`** — run it now. Does not survive reboot.
- **`enable`** — create the symlink so it starts at boot. Does not start it now.
- **`enable --now`** — both. Almost always what you meant.

### Do this

```bash
systemctl                              # all loaded units
systemctl list-units --type=service --state=running
systemctl list-unit-files --state=enabled     # what starts at boot
systemctl status sshd                  # state, PID, cgroup, recent log lines
systemctl cat sshd                     # the actual unit file, plus any drop-ins
systemctl show sshd | head -40         # every resolved property
systemd-analyze blame                  # what made this boot slow
systemd-analyze critical-chain         # the boot dependency path
```

`systemctl cat` is the one to internalise. It shows the vendor unit *and* every drop-in
applied on top, so you see what's actually in effect rather than guessing.

### Anatomy of a unit

```ini
[Unit]
Description=Example API
Documentation=https://example.com/docs
After=network-online.target          # ordering only — not a requirement
Wants=network-online.target          # weak dependency: try to start it, don't fail if it fails
# Requires=postgresql.service        # strong: if that stops, we stop too

[Service]
Type=simple                          # the process we exec IS the service
ExecStart=/usr/local/bin/api --port 8080
Restart=on-failure
RestartSec=5s
User=api
Group=api

[Install]
WantedBy=multi-user.target           # what `systemctl enable` hooks us into
```

Two distinctions worth getting right:

**`After=` vs `Requires=`.** `After=` is *ordering only*: if both are starting, start us
second. `Requires=` is a *dependency*: pull that unit in, and stop us if it stops. You usually
want `After=` plus `Wants=`. Using `Requires=` casually creates restart cascades.

**`Type=`.** `simple` (the process is the service — the default and usually right),
`exec` (like simple but waits for exec to succeed), `forking` (the process daemonises; needs
`PIDFile=`, a legacy shape), `oneshot` (runs and exits; pair with `RemainAfterExit=yes`),
`notify` (the service tells systemd when it's ready — best for anything with a slow startup).

### Prove it

Find every enabled service on the box, then show the fully-resolved unit for `nginx` including
any drop-ins.

---

## Session 2 — The journal, and systemd as a sandbox (≈1.5 h)

### journalctl

The journal is a structured, indexed, binary log. Every entry carries metadata fields
(unit, PID, UID, hostname, priority, boot ID), which is why you can filter on things text logs
never let you filter on.

```bash
journalctl -u nginx                       # one unit
journalctl -fu nginx                      # follow it (the tail -f replacement)
journalctl -u nginx --since "1 hour ago" --until "10 min ago"
journalctl -p err -b                      # errors, this boot only
journalctl -b -1                          # the previous boot — invaluable after a crash
journalctl -k                             # kernel messages (dmesg)
journalctl _UID=1000                      # by metadata field
journalctl -u nginx -o json-pretty | head -40    # see all available fields
journalctl --disk-usage
journalctl --vacuum-time=7d
```

Priorities run 0–7: emerg, alert, crit, err, warning, notice, info, debug. `-p err` shows
err and everything more severe.

**Make the journal persistent.** Many minimal images default to volatile storage, meaning your
logs vanish on reboot — precisely when you need them:

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
journalctl --list-boots        # more than one entry means it's persisting
```

### systemd as a sandbox

This is the part most people never reach, and it's the reason week 6's daemon-vs-container
comparison is interesting rather than one-sided. A modern unit can confine a service using the
same kernel primitives a container uses:

```ini
[Service]
# filesystem
ProtectSystem=strict            # entire filesystem read-only except...
ReadWritePaths=/var/lib/myapp   # ...these
ProtectHome=yes                 # /home, /root, /run/user invisible
PrivateTmp=yes                  # its own /tmp, destroyed on stop
StateDirectory=myapp            # creates and owns /var/lib/myapp

# privileges
User=myapp
DynamicUser=yes                 # ephemeral UID, no useradd required
NoNewPrivileges=yes             # can never gain privileges, blocks setuid escalation
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateDevices=yes

# kernel
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
SystemCallFilter=@system-service        # this is seccomp
RestrictAddressFamilies=AF_INET AF_INET6

# resources — these are cgroups, the same mechanism Docker uses
MemoryMax=512M
CPUQuota=50%
TasksMax=64
```

And systemd will grade it for you:

```bash
systemd-analyze security                  # every unit, ranked by exposure
systemd-analyze security nginx.service    # line-by-line, with what each directive would fix
```

Scores run 0 (locked down) to 10 (unconfined). Run it against a stock service and you'll see
most vendor units score badly — which is a useful thing to know when someone claims
containers are needed "for isolation".

### Prove it

Take `nginx.service`, check its security score, add a drop-in with three hardening directives,
and measure the improvement.

```bash
systemd-analyze security nginx.service
sudo systemctl edit nginx.service     # add [Service] + your directives
sudo systemctl restart nginx
systemd-analyze security nginx.service
```

---

## Session 3 — Weekend block: service, timer, and hardening (≈3 h)

### Part 1 — Turn the backup script into a service

`/etc/systemd/system/backup.service`:

```ini
[Unit]
Description=Backup /srv to the secondary host
Documentation=file:///home/anton/bin/backup.sh
After=network-online.target
Wants=network-online.target
OnFailure=backup-alert.service

[Service]
Type=oneshot
ExecStart=/home/anton/bin/backup.sh /srv cax:/backups 7
User=anton
Nice=10
IOSchedulingClass=idle          # don't fight real work for disk
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/srv
MemoryMax=512M
```

`Type=oneshot` because it runs to completion rather than staying resident. `OnFailure=`
activates another unit when this one fails — the alerting hook.

The failure handler, `/etc/systemd/system/backup-alert.service`:

```ini
[Unit]
Description=Alert that the backup failed

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'journalctl -u backup.service -n 30 --no-pager | mail -s "backup FAILED on %H" you@example.com'
```

### Part 2 — The timer

`/etc/systemd/system/backup.timer`:

```ini
[Unit]
Description=Nightly backup

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=15m     # avoid thundering-herd if you ever have many hosts
Persistent=true            # if the box was off at 02:30, run at next boot
Unit=backup.service

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload          # ALWAYS after editing unit files
sudo systemctl enable --now backup.timer
systemctl list-timers                 # next and last run for every timer
sudo systemctl start backup.service   # test the service directly, don't wait for 02:30
journalctl -u backup.service -n 50
```

Validate calendar expressions before trusting them:

```bash
systemd-analyze calendar "*-*-* 02:30:00"
systemd-analyze calendar "Mon *-*-* 09:00:00" --iterations=5
```

### Timers versus cron

| | systemd timer | cron |
|---|---|---|
| Logging | Into the journal, per-unit | Whatever you redirect, usually nowhere |
| Missed runs | `Persistent=true` catches up | Silently skipped |
| Dependencies | `After=`, `Requires=` | None |
| Resource limits | Full `[Service]` sandbox | None |
| Failure handling | `OnFailure=` | An email, if `MAILTO` is set and mail works |
| Randomised jitter | `RandomizedDelaySec=` | Manual `sleep $RANDOM` hack |
| Testing | `systemctl start foo.service` | Wait, or copy-paste the line |
| **Simplicity** | Two files | **One line** |

Cron is still fine for a trivial personal job on one box. For anything you'd be paged about,
use a timer. Being able to state this distinction crisply is a week-3 checkpoint.

### Part 3 — Harden it

```bash
systemd-analyze security backup.service
```

Add directives until you're below **4.0**. Then reboot the box and confirm the timer is armed
and the service still works:

```bash
sudo reboot
# then, after reconnecting
systemctl list-timers | grep backup
systemctl status backup.timer
```

---

## Command reference

```
systemctl status|start|stop|restart|reload UNIT
systemctl enable --now UNIT            enable at boot AND start now
systemctl disable --now UNIT
systemctl cat UNIT                     vendor unit + all drop-ins in effect
systemctl edit UNIT                    create/edit a drop-in override (correct way)
systemctl edit --full UNIT             copy the whole unit into /etc and edit
systemctl show UNIT -p MemoryMax       one resolved property
systemctl daemon-reload                after ANY unit file change
systemctl list-units --failed          what's broken right now
systemctl list-timers                  schedules, next run, last run
systemctl mask UNIT                    make it unstartable (symlink to /dev/null)
systemd-analyze security [UNIT]        sandboxing score 0–10
systemd-analyze calendar "EXPR"        validate an OnCalendar expression
systemd-analyze blame                  boot time by unit
systemd-run --user CMD                 ad-hoc supervised job (the nohup replacement)

journalctl -u UNIT / -fu UNIT          per-unit / follow
journalctl -p err -b                   errors this boot
journalctl -b -1                       previous boot
journalctl --since "2h ago" --until "1h ago"
journalctl -k                          kernel ring buffer
journalctl -o json-pretty              all structured fields
journalctl --vacuum-time=7d            trim by age
```

---

## Traps

- **Forgetting `daemon-reload`.** Your edit exists on disk and systemd is running the old
  version. Confusing for exactly as long as it takes to remember this.
- **Editing units in `/usr/lib/systemd/system/`.** Reverted by the next package update, with
  no warning. Use `systemctl edit`.
- **`enable` without `--now`** (nothing happens until reboot) or **`start` without `enable`**
  (works until reboot, then vanishes).
- **`Requires=` where `Wants=` was meant.** Creates restart cascades where one flapping
  dependency takes your service with it.
- **A volatile journal.** No `/var/log/journal` directory means logs are RAM-only and gone
  after the reboot you need to investigate.
- **`Restart=always` on a unit that fails instantly** — you get a restart loop. Bound it with
  `StartLimitIntervalSec=` and `StartLimitBurst=`.

---

## Checkpoint

From memory, no copy-paste:

1. Write a working, hardened unit file from scratch — correct `[Unit]`/`[Service]`/`[Install]`,
   `Restart=on-failure`, at least three sandboxing directives.
2. Explain what a timer gives you over cron, and name the case where cron is still correct.
3. Retrieve the errors from the *previous* boot of the machine.

---

## If you want more

- `man systemd.unit`, `man systemd.service`, `man systemd.exec`, `man systemd.resource-control` —
  `systemd.exec` is the sandboxing reference and is worth reading properly
- `man systemd.time` — the full `OnCalendar` grammar
- Red Hat's "Configuring basic system settings" guide, systemd chapters
