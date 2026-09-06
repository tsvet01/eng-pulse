# Week 5 — The RHEL dialect: dnf, SELinux, firewalld

> **By the end:** you diagnose and fix an SELinux denial properly, in under ten minutes,
> without weakening enforcement.

**Time:** ≈6 h across 3 sessions · **Where:** Rocky box **only** (SELinux needs a real kernel)
**Prereq:** week 4 checkpoint

---

## What this is, and why it matters

Most Linux material on the internet assumes Debian or Ubuntu. Your fleet doesn't run those.
This week covers the three subsystems where RHEL genuinely differs, and where an
Ubuntu-trained instinct produces wrong answers.

SELinux is the centrepiece. In 2013 the universal reflex was `setenforce 0`, and it was
defensible then — the tooling was poor and the policies were rough. That has changed on both
counts. Today, disabling SELinux is an audit finding, and the diagnostic path is genuinely
short once you know it. You have spent a decade signing off on compliance postures that assume
it's on; this is the week you stop being able to sympathise with the engineer who turns it off.

### The mental model — two independent permission systems

This is the single idea that makes SELinux click:

```
   request to open /srv/www/index.html
              │
              ▼
   ┌──────────────────────┐   Discretionary Access Control
   │  DAC: rwx / owner    │   "does this UID have permission?"
   └──────────┬───────────┘
              │ pass
              ▼
   ┌──────────────────────┐   Mandatory Access Control
   │  MAC: SELinux label  │   "is this SUBJECT TYPE allowed to
   └──────────┬───────────┘    act on this OBJECT TYPE?"
              │ pass
              ▼
          access granted
```

**Both must pass.** This is why the classic symptom is so disorienting: `ls -l` shows perfect
permissions, the file is world-readable, you're running as the right user — and you still get
"Permission denied". The DAC check passed; the MAC check didn't.

Every process and every file carries a label. View it with `-Z`, which most core tools accept:

```bash
ls -Z /srv/www/index.html
# unconfined_u:object_r:default_t:s0    ← 'default_t' is the problem; nginx can't read it
ps -eZ | grep nginx
# system_u:system_r:httpd_t:s0          ← nginx runs as httpd_t
```

The policy says `httpd_t` may read `httpd_sys_content_t`. Your file is `default_t`. Denied.
The fix is to **label the file correctly**, not to disable the system.

---

## Session 1 — dnf and RPM (≈1.5 h)

### The package model

RPM is the low-level format and database; dnf is the dependency resolver and repository
client. `yum` is a symlink to `dnf` on RHEL 8+.

```bash
dnf search nginx
dnf info nginx
sudo dnf install -y nginx
sudo dnf remove nginx
sudo dnf update                    # everything
sudo dnf update --security         # security errata only — the one that matters operationally
dnf list installed | wc -l
dnf repolist                       # configured repositories
dnf provides /usr/bin/dig          # which package provides this file? (bind-utils)
```

`dnf provides` answers "I need this command, what do I install?" and it works on paths,
binaries, and library sonames.

### Querying what's on the box

```bash
rpm -qa | wc -l                    # all installed
rpm -qf /etc/nginx/nginx.conf      # which package owns this file
rpm -ql nginx                      # every file this package installed
rpm -qc nginx                      # just its config files
rpm -qi nginx                      # metadata, including install time
rpm -V nginx                       # verify against the database: what has been modified?
```

`rpm -V` is the one to remember. It compares every installed file against the recorded
checksum, size, mode, and owner. Output like `S.5....T.  c /etc/nginx/nginx.conf` means size,
checksum and mtime differ — someone edited it. On an unfamiliar server, that's how you find
the local modifications nobody documented.

### Transaction history — the underrated feature

```bash
sudo dnf history                        # every transaction, numbered
sudo dnf history info 12                # exactly what changed in transaction 12
sudo dnf history undo 12                # roll it back
sudo dnf history rollback 10            # return to the state after transaction 10
```

This is a genuine safety net that apt has no clean equivalent for. Update breaks something at
2am → `dnf history undo last`. Worth knowing before you need it.

### Repositories

```bash
ls /etc/yum.repos.d/
cat /etc/yum.repos.d/rocky.repo
sudo dnf install -y epel-release        # Extra Packages for Enterprise Linux
sudo dnf --disablerepo='*' --enablerepo=baseos list available | head
```

A word on EPEL: it's community-maintained, not vendor-supported. Fine for `htop` and
`ShellCheck` on a practice box; a policy question in a regulated production fleet, because
those packages don't carry your vendor's CVE-backport guarantee. That distinction is exactly
the kind of thing you'll be asked to rule on.

### Prove it

Find which package owns `/etc/nginx/nginx.conf`, list its config files, check whether any have
been modified since install, then show what your last dnf transaction did.

---

## Session 2 — SELinux (≈2 h)

This is the session that matters most this week. Give it the full time.

### Orientation

```bash
sestatus
getenforce                     # Enforcing | Permissive | Disabled
```

- **Enforcing** — denials are blocked and logged. What production runs.
- **Permissive** — denials are logged but allowed. A *diagnostic* mode, not a destination.
- **Disabled** — off entirely. Requires a reboot to change, and on RHEL 9+ is deprecated.

### Reading labels

```bash
ls -Z /var/www/html /srv
ps -eZ | grep -E 'nginx|sshd'
id -Z                          # your own context
sudo semanage fcontext -l | grep httpd | head
```

A context is `user:role:type:level`. In practice, **the type is what matters** — `httpd_t`
for the nginx process, `httpd_sys_content_t` for content it may serve.

### The diagnostic loop

Memorise this sequence. It's the whole skill.

```bash
# 1. Find the denial
sudo ausearch -m AVC -ts recent

# 2. Have it explained in English
sudo ausearch -m AVC -ts recent | audit2why

# 3. Fix the LABEL if the file is in the wrong place (usual case)
sudo semanage fcontext -a -t httpd_sys_content_t '/srv/www(/.*)?'
sudo restorecon -Rv /srv/www

# 4. OR flip a boolean if the policy has a supported switch for what you want
getsebool -a | grep httpd
sudo setsebool -P httpd_can_network_connect on

# 5. Verify
ls -Z /srv/www
```

Install the tooling if it's missing:

```bash
sudo dnf install -y policycoreutils-python-utils setroubleshoot-server
```

With `setroubleshoot` installed, denials also arrive in the journal with a human-readable
summary and suggested remedy:

```bash
journalctl -t setroubleshoot -e
```

### The three legitimate fixes

| Situation | Fix |
|---|---|
| File is in a non-standard location | `semanage fcontext -a -t <type> '<path>(/.*)?'` then `restorecon -Rv` |
| The policy has a switch for what you want | `setsebool -P <boolean> on` |
| Genuinely novel requirement, no existing policy | Generate a module with `audit2allow -M`, **after reading what it grants** |

And the two illegitimate ones: `setenforce 0`, and `chcon` (which sets a label that
`restorecon` or a relabel will silently revert — use `semanage fcontext`, which persists).

`audit2allow -M mypolicy` deserves a caution. It will happily generate a module that grants
exactly what was denied, including things you didn't intend. Always read the generated `.te`
file before installing it. It's a tool for the last case, not the first.

### Common booleans worth knowing

```bash
getsebool -a | grep -E 'httpd|ssh|container'
```

- `httpd_can_network_connect` — let the web server make outbound connections (reverse proxy!)
- `httpd_can_network_connect_db` — narrower: database ports only
- `httpd_enable_homedirs` — serve from `/home`
- `container_manage_cgroup` — relevant in week 9

Note the reverse-proxy one. Putting nginx in front of an app on `localhost:3000` fails out of
the box, and that's a boolean, not a labelling problem — a good example of picking the right
fix for the right cause.

### Prove it

Create a file in a non-standard location, watch nginx fail to read it, and fix it via
`semanage` + `restorecon`. Then re-run and confirm the denial is gone from `ausearch`.

---

## Session 3 — Weekend block: the full exercise (≈2.5 h)

### The task

Serve a static site with nginx from `/srv/www` instead of the default `/usr/share/nginx/html`.
You will hit a denial that looks like a permission problem and isn't. Work it properly.

```bash
# 1. Content in a non-standard location
sudo mkdir -p /srv/www
echo '<h1>hello from /srv/www</h1>' | sudo tee /srv/www/index.html
sudo chmod -R 755 /srv/www           # DAC is perfect. Note that.

# 2. Point nginx at it
sudo systemctl edit --full nginx     # or edit /etc/nginx/nginx.conf: root /srv/www;
sudo nginx -t                        # ALWAYS validate config before reload
sudo systemctl restart nginx

# 3. Watch it fail
curl -i localhost                    # 403 Forbidden
ls -l /srv/www/index.html            # permissions are fine!
```

Now the diagnosis:

```bash
sudo ausearch -m AVC -ts recent
sudo ausearch -m AVC -ts recent | audit2why
ls -Z /srv/www/index.html            # default_t — there's your answer
```

The fix:

```bash
sudo semanage fcontext -a -t httpd_sys_content_t '/srv/www(/.*)?'
sudo restorecon -Rv /srv/www
ls -Z /srv/www/index.html            # httpd_sys_content_t
curl -i localhost                    # 200
```

Then open the firewall properly:

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
firewall-cmd --list-all
curl -i http://<public-ip>/
```

Read the fcontext expression: `'/srv/www(/.*)?'` is a **regex**, and the `(/.*)?` suffix means
"this directory and, optionally, everything under it". Omit it and only the directory itself
gets the label, which produces a maddening half-working state.

### Part 2 — The reverse-proxy boolean

Now do the second kind of fix. Put nginx in front of something on localhost:

```bash
python3 -m http.server 3000 &        # a stand-in backend
```

Add to the nginx config:

```nginx
location /api/ {
    proxy_pass http://127.0.0.1:3000/;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -i localhost/api/               # 502 Bad Gateway
sudo ausearch -m AVC -ts recent | audit2why
```

The denial is nginx attempting an outbound connection. That's not a label problem — it's a
policy switch:

```bash
sudo setsebool -P httpd_can_network_connect on
curl -i localhost/api/               # works
```

Doing both fixes in one session is the point: you now have the instinct for *which* kind of
problem you're looking at.

**The `-P` flag makes it persistent.** Without it, the change is lost on reboot — which is a
memorable way to have something break a month later.

### Part 3 — Reflection for your notes

Write in `notes.md`, in your own words: the difference between a labelling fix and a boolean
fix, and how you tell which you need from the `ausearch` output. That short paragraph is
worth more than re-reading this file.

---

## Command reference

```
# dnf / rpm
dnf provides /path/or/binary        which package provides this
dnf update --security               security errata only
dnf history | history info N | history undo N
rpm -qf FILE                        owning package
rpm -ql / -qc / -qi PKG             files / config files / info
rpm -V PKG                          what has been modified since install

# SELinux
sestatus | getenforce
ls -Z PATH | ps -eZ | id -Z         labels for files / processes / you
ausearch -m AVC -ts recent          recent denials
ausearch -m AVC -ts recent | audit2why      explained
semanage fcontext -a -t TYPE 'PATH(/.*)?'   persistent label rule
restorecon -Rv PATH                 apply the rules
semanage fcontext -l | grep X       existing rules
getsebool -a | grep X               list booleans
setsebool -P BOOL on                persistent boolean
setenforce 0                        DIAGNOSTIC ONLY — never a fix
journalctl -t setroubleshoot -e     human-readable denial summaries

# firewalld
firewall-cmd --list-all
firewall-cmd --permanent --add-service=http && firewall-cmd --reload
firewall-cmd --permanent --add-port=8080/tcp
nft list ruleset                    the generated kernel rules
```

---

## Traps

- **`setenforce 0` to "check if it's SELinux".** Understandable as a five-second diagnostic;
  never acceptable as the fix. If you use it, set it back immediately and note what you learned.
- **`chcon` instead of `semanage fcontext`.** `chcon` changes the current label; a relabel or
  `restorecon` reverts it. `semanage` records the rule so it survives.
- **Forgetting `(/.*)?`** in an fcontext path — labels the directory, not the contents.
- **Forgetting `-P` on `setsebool`** — works until reboot.
- **`--permanent` / `--reload` mismatch** in firewalld, again.
- **Editing nginx config without `nginx -t`.** A syntax error plus a restart means the service
  doesn't come back.

---

## Checkpoint

From memory, timed:

1. **Diagnose and correctly fix an SELinux denial in under ten minutes**, without weakening
   enforcement. Have someone (or a script) break a label and go.
2. Find which package owns `/etc/nginx/nginx.conf`, and roll back your last dnf transaction.
3. Explain when the right fix is a label and when it's a boolean.

---

## If you want more

- `man semanage-fcontext`, `man booleans`, `man 8 selinux`
- Red Hat's *Using SELinux* guide — the best documentation on the subject anywhere
- `sudo sealert -a /var/log/audit/audit.log` for a full annotated report
- Dan Walsh's blog — the original SELinux maintainer, especially on containers + SELinux
