# Week 2 — Permissions, processes, and scripting that survives contact

> **By the end:** you read a permission string instantly, find a runaway process in two
> minutes, and write bash that passes review in 2026.

**Time:** ≈6 h across 3 sessions · **Where:** Rocky box
**Prereq:** week 1 checkpoint

---

## What this is, and why it matters

The permission and process models are the two parts of Linux that have changed **least** since
you were hands-on. That's the good news — an hour of refresh and they're back.

What *has* changed is the standard for shell code. A script that was acceptable in 2013 —
unquoted variables, no error handling, `ls` parsing — will be rejected in review now, and
correctly so. ShellCheck exists, it's in everyone's CI, and the failure modes it catches
(filenames with spaces, silent failure mid-pipeline, unset variables expanding to nothing) are
the ones that eat production data.

There's also a conceptual payoff you'll cash in during week 6: **a container is a process.**
Everything you re-learn about PIDs, signals, users, and `/proc` this week is what makes
containers legible later rather than magic.

### The mental model — permissions

```
   -    rwx    r-x    r--     anton   devs
   │     │      │      │        │      │
  type  owner  group  other   owner  group
```

Three triads, three bits each: read (4), write (2), execute (1). Hence `755` = `rwxr-xr-x`.

The three bits nobody remembers:

| Bit | On a file | On a directory |
|---|---|---|
| **setuid** (4000) | Runs as the file's owner, not you | (ignored on Linux) |
| **setgid** (2000) | Runs as the file's group | New files inherit the directory's group |
| **sticky** (1000) | (ignored) | Only the owner can delete their own files — this is why `/tmp` is `1777` |

On a directory, the bits mean something different from what you'd guess: `r` lists names,
`w` creates and deletes entries, and **`x` is required to enter or access anything inside**.
A directory with `r--` lets you see filenames but read nothing.

### The mental model — processes

Every process except PID 1 is created by **fork** (clone yourself) followed by **exec**
(replace your program image). Every process has a parent. When a parent dies, its children are
re-parented to PID 1, whose job includes reaping them. A **zombie** is a process that has
exited but whose parent hasn't collected its exit status yet — harmless in ones, a leak in
thousands. This exact mechanism is why containers need `--init` when their main process spawns
children (week 6).

Signals are how you talk to a running process:

| Signal | Number | Meaning | Catchable |
|---|---|---|---|
| `SIGTERM` | 15 | Please shut down cleanly | Yes — the default for `kill` |
| `SIGKILL` | 9 | Die now | **No** — the kernel does it, no cleanup runs |
| `SIGHUP` | 1 | Terminal closed; by convention, "reload config" | Yes |
| `SIGINT` | 2 | Ctrl-C | Yes |
| `SIGSTOP` / `SIGCONT` | 19/18 | Pause / resume | No / Yes |

`kill -9` as a first move is a bad habit: no cleanup, no flush, no graceful connection drain.
Reach for it only when SIGTERM has demonstrably failed.

---

## Session 1 — Permissions and users (≈1.5 h)

### Do this

```bash
# read a permission string aloud, then verify with stat
stat -c '%A %a %U:%G %n' /tmp /etc/shadow /usr/bin/passwd
# /tmp        drwxrwxrwt  1777  — sticky: anyone writes, only owners delete
# /etc/shadow -rw-r-----   640  — root only; this is why it's separate from passwd
# /usr/bin/passwd -rwsr-xr-x 4755 — setuid root: you run it, it runs as root

# umask decides default permissions for new files
umask                      # usually 0022
touch /tmp/u && stat -c '%a' /tmp/u    # 644 — 666 minus the umask
(umask 077; touch /tmp/p); stat -c '%a' /tmp/p   # 600 — private

# setgid on a directory: shared group ownership that actually sticks
sudo mkdir /srv/shared
sudo groupadd -f devs
sudo chgrp devs /srv/shared
sudo chmod 2775 /srv/shared        # the 2 is setgid
sudo touch /srv/shared/f && stat -c '%U:%G' /srv/shared/f   # group is devs, not root
```

### The user files

```bash
getent passwd anton        # name:x:uid:gid:comment:home:shell
getent group wheel
sudo getent shadow anton   # hashes live here, mode 000/640, deliberately separate
```

A **service account** should have no login shell — `/sbin/nologin`. That's not decoration:
it means a compromised service can't get an interactive session.

### sudoers

Always `sudo visudo`. It syntax-checks before saving; a broken `/etc/sudoers` locks everyone
out of root and needs console access to fix. Prefer drop-ins:

```bash
sudo visudo -f /etc/sudoers.d/deploy
# %devs ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart myapp
```

Grant specific commands, not `ALL`. This is the kind of thing you've been signing off on for
a decade — now you're writing it.

### Prove it

Read `drwxrwsr-t` aloud and account for every character.

<details>
<summary>Answer</summary>

Directory; owner rwx; group rwx with **setgid** (the `s` replaces the group `x`, so new files
inherit the group); other has r, w, and the **sticky bit** (`t` replaces other's `x`, so only
owners may delete their own entries). A shared drop-box directory.
</details>

---

## Session 2 — Processes and signals (≈1.5 h)

### Do this

```bash
ps aux | head                   # BSD-style: all processes, user-oriented
ps -ef --forest                 # the parent/child tree — often more useful
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu | head

# /proc is the kernel pretending to be a filesystem
ls /proc/self/                  # 'self' is whatever process is looking
cat /proc/self/status | head -20
sudo ls -l /proc/1/exe          # what is PID 1? (systemd)
sudo cat /proc/1/cmdline | tr '\0' ' '
```

Signals, hands-on:

```bash
sleep 300 &
jobs
kill %1                          # SIGTERM by default
sleep 300 & PID=$!
kill -TERM $PID                  # by PID; prefer names over numbers
pkill -f 'sleep 300'             # by command pattern — check with pgrep -af first
```

Finding what's eating the box:

```bash
top          # then: 'P' sort by CPU, 'M' by memory, '1' show all cores, 'k' kill
htop         # sudo dnf install htop — friendlier; F6 sort, F9 kill
ss -tlnp                          # which process owns which port
sudo lsof -p <pid>                # every file that process has open
sudo lsof -i :80                  # who's on port 80
```

### The triage sequence

You'll do this for real in week 10; learn the order now.

1. `uptime` — load average. Is it CPU-bound at all?
2. `top` / `htop` — one process or many?
3. `ps -eo ...--sort=-%cpu | head` — name the offender
4. `sudo lsof -p <pid>` — what is it touching?
5. `sudo cat /proc/<pid>/status` — threads, memory, parent

### Prove it

Start a CPU-burning process, find it purely from "the server feels slow", and stop it cleanly.

```bash
yes > /dev/null &        # burns a core
```

---

## Session 3 — Weekend block: the backup script (≈3 h)

### The 2026 bash preamble

Put this at the top of every script and understand each part:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- `-e` exit immediately on any command failing
- `-u` treat an unset variable as an error (catches typos before they delete `/`)
- `-o pipefail` a pipeline fails if **any** stage fails, not just the last

Without `pipefail`, `false | true` succeeds — which is how a failing backup silently "works"
for six months.

Add cleanup that runs no matter how you exit:

```bash
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
```

### Quoting, the actual rule

Quote every variable expansion unless you have a specific reason not to.

```bash
f="my file.txt"
rm $f              # WRONG: tries to remove 'my' and 'file.txt'
rm "$f"            # right

"$@"               # all arguments, each kept as a separate word
"$*"               # all arguments joined into one string — rarely what you want
"${arr[@]}"        # array expansion, each element separate
```

### Build this

`~/bin/backup.sh` — tar a directory, rsync it to the second location, rotate old copies,
log to stderr, exit non-zero on failure, and survive filenames containing spaces.

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly SRC="${1:?usage: backup.sh SRC DEST_HOST:DEST_PATH [KEEP]}"
readonly DEST="${2:?usage: backup.sh SRC DEST_HOST:DEST_PATH [KEEP]}"
readonly KEEP="${3:-7}"

log() { printf '%s [backup] %s\n' "$(date -Is)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ -d "$SRC" ]] || die "source '$SRC' is not a directory"

readonly STAMP="$(date +%Y%m%d-%H%M%S)"
readonly TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

readonly ARCHIVE="$TMP/backup-$STAMP.tar.gz"

log "archiving $SRC"
tar -czf "$ARCHIVE" -C "$(dirname "$SRC")" "$(basename "$SRC")" \
  || die "tar failed"

log "shipping to $DEST"
rsync -a --partial "$ARCHIVE" "$DEST/" \
  || die "rsync failed"

log "rotating, keeping $KEEP"
# shellcheck disable=SC2029  # we intend $KEEP to expand locally
ssh "${DEST%%:*}" "ls -1t '${DEST#*:}'/backup-*.tar.gz | tail -n +$((KEEP+1)) | xargs -r rm --"

log "done: $(basename "$ARCHIVE")"
```

Things to notice, because each is a deliberate choice:

- `${1:?message}` fails immediately with a usage message if the argument is missing.
- `log()` writes to **stderr** so stdout stays clean if you ever pipe this script's output.
- `date -Is` is ISO-8601 — sortable, unambiguous, machine-parsable. Never `date` default format.
- `tail -n +$((KEEP+1))` skips the newest N, leaving the rest for deletion.
- `xargs -r` doesn't run at all when input is empty (GNU extension; saves you a spurious error).
- `--` before the file list stops a filename starting with `-` being read as an option.

### Now lint it

```bash
sudo dnf install -y ShellCheck
shellcheck ~/bin/backup.sh
```

Fix every warning. Read the wiki link for any you don't understand — ShellCheck's explanations
are genuinely educational and this is the fastest way to update your bash instincts.

### Test it against the real failure modes

```bash
mkdir -p "/tmp/src dir" && echo data > "/tmp/src dir/file with spaces.txt"
~/bin/backup.sh "/tmp/src dir" cax:/backups 3

# and the one that catches most scripts — cron's empty environment
env -i /bin/bash -c '~/bin/backup.sh "/tmp/src dir" cax:/backups 3'
```

That last line is the real test. Cron gives you almost no environment: no `PATH` beyond a
minimum, no shell profile, no `HOME` conveniences. Scripts that work interactively and fail at
3am nearly always fail here.

---

## Command reference

```
stat -c '%A %a %U:%G %n' F         permission string, octal, owner:group
chmod 2775 DIR                     setgid directory (group inheritance)
chmod 1777 DIR                     sticky directory (/tmp semantics)
umask 077                          private-by-default for this shell
getent passwd|group|shadow NAME    query the user databases properly
visudo -f /etc/sudoers.d/NAME      safe, syntax-checked sudoers drop-in
ps -eo pid,ppid,%cpu,cmd --sort=-%cpu    ranked process list
ps -ef --forest                    parent/child tree
pgrep -af PATTERN                  preview before pkill
kill -TERM PID / kill -9 PID       polite / last resort
lsof -p PID | lsof -i :PORT        open files | port owner
set -euo pipefail                  the mandatory script preamble
trap 'cleanup' EXIT                cleanup on any exit path
"${var:?message}"                  fail fast on a missing value
"${var:-default}"                  default when unset
```

---

## Traps

- **`chmod 777` as a reflex.** It's almost never the fix and it's an audit finding. Work out
  which of owner/group/other actually needs the access.
- **`kill -9` first.** No cleanup runs. Try SIGTERM and wait.
- **Unquoted `$@`.** `"$@"` preserves argument boundaries; bare `$@` destroys them.
- **`set -e` doesn't do what you think inside `if`, `&&`, or `||`.** A command whose failure
  is being tested doesn't trigger the exit. That's correct behaviour, but it surprises people.
- **Editing `/etc/sudoers` without `visudo`.** One typo, no root, console recovery.

---

## Checkpoint

All from memory:

1. ShellCheck reports **zero** warnings on `backup.sh`.
2. The script runs correctly under `env -i` (cron's empty environment).
3. Read `drwxrwsr-t` aloud and account for every character.
4. Given only "the server feels slow", name the offending process in under two minutes.

---

## If you want more

- `man 7 signal`, `man 7 credentials`, `man 5 proc` — all worth a read
- ShellCheck's wiki: every warning code has a page explaining the failure it prevents
- Google's Shell Style Guide — a reasonable house standard to adopt wholesale
