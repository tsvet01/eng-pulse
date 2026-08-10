# Week 10 — Storage, failure, and recovery

> **By the end:** you diagnose five injected faults from symptoms alone and have written the
> runbook for each.

**Time:** ≈6 h across 3 sessions · **Where:** Rocky box. **Snapshot before session 3.**
**Prereq:** week 9 checkpoint

---

## What this is, and why it matters

This is the week that most resembles your last decade, and where your existing instincts are
worth the most. You already know how to triage under pressure — narrow the blast radius, find
what changed, stop the bleeding before chasing root cause. What you're missing is the current
command set and a few failure modes that are specific and non-obvious.

The other half is a deliberate choice about how to learn this: **you cannot get good at
recovery by reading about it.** Session 3 is a chaos day where you break your own server five
different ways and fix each one without restoring the snapshot. That's the only way the
knowledge is there when you're tired and someone is waiting.

### The mental model — the storage stack

```
   /srv/data                     ← mount point, described in /etc/fstab
       │
   ┌───▼────────────┐
   │  filesystem    │  xfs (RHEL default), ext4, btrfs
   └───┬────────────┘
   ┌───▼────────────┐
   │  logical vol   │  LVM: resize without repartitioning, snapshots
   │  volume group  │
   │  physical vol  │
   └───┬────────────┘
   ┌───▼────────────┐
   │  partition     │  /dev/sda1
   └───┬────────────┘
   ┌───▼────────────┐
   │  block device  │  /dev/sda
   └────────────────┘
```

When storage misbehaves, identify the layer first. "Disk full" at the filesystem layer, "no
space" at the inode layer, and "device not found" at the block layer are three unrelated
problems with three unrelated fixes.

### The three kinds of "disk full"

This distinction is the single most useful thing in this week:

| Symptom | Real cause | Diagnose with |
|---|---|---|
| `df -h` shows 100% | Genuinely out of blocks | `du -xh --max-depth=1 /` |
| `df -h` shows space free, writes still fail | **Out of inodes** — millions of tiny files | `df -i` |
| `du` totals far less than `df` reports | **Deleted file still held open** by a process | `lsof +L1` |

The third one catches everyone. A process opens a log file, something deletes it, but the
process still holds the descriptor — so the space is not reclaimed and `du` can't see it,
because there's no directory entry any more. `df` and `du` disagree by gigabytes and it looks
like the filesystem is lying. The fix is to restart the holder (or truncate via
`/proc/<pid>/fd/<n>`), not to hunt for files.

---

## Session 1 — The storage stack (≈1.5 h)

### Look at what you have

```bash
lsblk                              # the tree: devices, partitions, mounts
lsblk -f                           # ...with filesystems and UUIDs
blkid                              # UUIDs and types
df -h                              # space by filesystem
df -i                              # INODES by filesystem  ← run this reflexively
findmnt                            # mounts as a tree, with options
findmnt /                          # one mount, fully described
mount | column -t
cat /etc/fstab
```

`findmnt` is the modern, readable replacement for parsing `mount` output. It shows the actual
mount options in effect, which is where surprises hide.

### LVM

```bash
sudo pvs        # physical volumes
sudo vgs        # volume groups
sudo lvs        # logical volumes
sudo vgdisplay
sudo lvdisplay
```

The value of LVM is that you can grow a filesystem without repartitioning:

```bash
sudo lvextend -L +5G /dev/vg0/data
sudo xfs_growfs /srv/data          # xfs grows online
# (ext4 would be: resize2fs /dev/vg0/data)
```

Note the asymmetry: **xfs cannot shrink.** RHEL defaults to xfs, so a filesystem you make too
large stays too large. Plan accordingly, and know this before someone asks you to reclaim space.

### fstab, and the flag that saves your boot

```
UUID=abc-123   /srv/data   xfs   defaults,nofail,x-systemd.device-timeout=10s   0 0
```

Fields: device, mount point, type, options, dump, fsck order.

- **Use UUIDs, not `/dev/sdX`.** Device names are not stable across reboots or hardware changes.
- **`nofail`** — boot even if this device is missing. Without it, a detached volume drops the
  machine into emergency mode and you need console access. On a cloud box with an attached
  volume, this single word is the difference between a degraded service and an unreachable one.
- **`x-systemd.device-timeout=10s`** — don't wait 90 seconds for a device that isn't coming.

Always validate before rebooting:

```bash
sudo mount -a                      # mounts everything in fstab; errors surface NOW
sudo systemctl daemon-reload       # fstab generates systemd mount units
```

### Prove it

For your Rocky box: describe the full stack from `/` down to the block device, name the
filesystem type, and state how many inodes are free.

---

## Session 2 — Triage in sixty seconds (≈1.5 h)

### The opening sequence

A known-good order for "the box is sick", roughly Brendan Gregg's USE checklist:

```bash
uptime                    # load averages: 1, 5, 15 min. Rising or falling?
dmesg -T | tail -30       # OOM kills, disk errors, network resets. -T for human timestamps
vmstat 1 5                # r=runnable, b=blocked, si/so=swap, us/sy/id/wa=cpu split
free -h                   # memory, and crucially available vs free
df -h && df -i            # both. Always both.
iostat -xz 1 3            # per-device: %util, await. Is the disk the bottleneck?
ss -s                     # socket summary — connection exhaustion?
journalctl -p err -b --no-pager | tail -30
systemctl --failed
```

Reading the signals:

- **Load average high, `%wa` high** — I/O bound, not CPU bound. Look at `iostat`.
- **`free` low but `available` high** — fine. Linux uses free memory for page cache; that's
  the point. `available` is the number that matters.
- **`si`/`so` non-zero in vmstat** — actively swapping. Real trouble.
- **`dmesg` shows `Out of memory: Killed process`** — the OOM killer fired. Note *which*
  process it chose, because it's often not the one that caused it.

### Finding the space

```bash
du -xh --max-depth=1 / 2>/dev/null | sort -rh | head        # -x stays on one filesystem
du -xh --max-depth=1 /var | sort -rh | head
sudo lsof +L1                          # deleted files still held open  ← the sneaky one
sudo lsof -p <pid> | grep deleted
journalctl --disk-usage
sudo du -sh /var/lib/containers ~/.local/share/containers
podman system df
```

`-x` on `du` is important: without it you descend into `/proc`, `/sys`, and other filesystems
and get nonsense totals.

### Prove it

Create a deleted-but-open file and find it:

```bash
# terminal 1
python3 -c "
import time
f = open('/tmp/big','wb'); f.write(b'0'*500_000_000); f.flush()
import os; os.unlink('/tmp/big')
time.sleep(600)"

# terminal 2
df -h /tmp                       # space consumed
du -sh /tmp                      # ...but du can't see it
sudo lsof +L1 | grep big         # there it is
```

---

## Session 3 — Weekend block: chaos day (≈3 h)

> **Take a Hetzner snapshot first.** The rule is that you fix each fault *without* restoring
> it — the snapshot is insurance against a genuine mistake, not part of the exercise.

Work one fault at a time. For each: observe symptoms, diagnose, fix, then **write the runbook
entry** before moving on. The writing is not optional; it's where the learning consolidates.

### Fault 1 — Deleted-but-open file fills the disk

```bash
sudo bash -c 'python3 -c "
import os,time
f=open(\"/var/tmp/filler\",\"wb\")
f.write(b\"0\"*3_000_000_000); f.flush()
os.unlink(\"/var/tmp/filler\")
time.sleep(3600)" &'
```

Symptoms: `df` shows the disk filling; `du` accounts for none of it. Services start failing to
write.

<details>
<summary>Diagnosis and fix</summary>

```bash
df -h /var
du -xsh /var                     # doesn't add up
sudo lsof +L1                    # NLINK 0 — deleted, still open
sudo kill <pid>                  # space returns instantly
# without killing: sudo truncate -s 0 /proc/<pid>/fd/<n>
```
</details>

### Fault 2 — Inode exhaustion

```bash
sudo mkdir -p /var/tmp/inodes
sudo bash -c 'cd /var/tmp/inodes && for i in $(seq 1 300000); do : > "f$i"; done'
```

Symptoms: "No space left on device" while `df -h` shows plenty free.

<details>
<summary>Diagnosis and fix</summary>

```bash
df -i                            # IUse% at 100%
sudo find /var -xdev -type d -printf '%h\n' | sort | uniq -c | sort -rn | head
sudo find /var/tmp/inodes -type f -delete     # rm * would fail: argument list too long
```
</details>

### Fault 3 — Broken fstab, unbootable server

The big one. **Do this deliberately and read the recovery steps first.**

```bash
echo 'UUID=00000000-dead-beef-0000-000000000000 /data xfs defaults 0 0' | sudo tee -a /etc/fstab
sudo reboot
```

The box won't come back. SSH times out; it's sitting in emergency mode.

<details>
<summary>Recovery</summary>

**Option A — Hetzner console.** Cloud console → open the VNC console. You'll see the emergency
prompt. Log in as root, then:

```bash
mount -o remount,rw /
vi /etc/fstab                    # remove or fix the line
systemctl daemon-reload
reboot
```

**Option B — rescue mode** (the one worth practising, because it works when the console
doesn't help):

1. Hetzner console → Rescue → Enable rescue and reset the server
2. SSH into the rescue system with the password it gives you
3. Mount your real root and repair it:

```bash
lsblk
mount /dev/sda1 /mnt
vi /mnt/etc/fstab
umount /mnt
```

4. Disable rescue, reboot.

**The lesson:** `nofail` on every non-essential mount. One word would have turned an
unreachable server into a boot with a missing directory.
</details>

### Fault 4 — DNS broken

```bash
sudo cp /etc/resolv.conf /root/resolv.conf.bak
echo "nameserver 192.0.2.1" | sudo tee /etc/resolv.conf
```

Symptoms: `dnf` hangs, `curl example.com` fails, but `curl 1.1.1.1` works and SSH by IP is fine.

<details>
<summary>Diagnosis and fix</summary>

```bash
dig example.com                  # times out
dig @1.1.1.1 example.com         # works → local resolver config, not the network
cat /etc/resolv.conf             # there it is
sudo cp /root/resolv.conf.bak /etc/resolv.conf
```

Note that `/etc/resolv.conf` is usually managed by NetworkManager — check the header comment,
and fix it at the manager rather than the file if so.
</details>

### Fault 5 — Orphan process holding a port

```bash
sudo python3 -m http.server 8080 --bind 0.0.0.0 &
disown
```

Then try to start your quadlet on 8080. Symptom: "address already in use", and nothing obvious
in `systemctl status`.

<details>
<summary>Diagnosis and fix</summary>

```bash
sudo ss -tlnp 'sport = :8080'    # names the PID and command
sudo lsof -i :8080
sudo kill <pid>
```
</details>

### Write the runbook

In `notes.md` or a `runbook.md` beside it, one entry per fault:

```markdown
## Disk full but du shows nothing

**Symptom:** df reports 100%, du -xsh accounts for far less. Writes fail.
**Cause:** A process holds an open descriptor to a deleted file; space isn't reclaimed
until the descriptor closes.
**Diagnose:** sudo lsof +L1
**Fix:** Restart the holding process, or truncate /proc/<pid>/fd/<n> to free it in place.
**Prevent:** Rotate logs with copytruncate, or signal the process to reopen after rotation.
```

Five of these is the actual deliverable of this week. It's also the first artifact of your
management career that's written from current hands-on experience rather than memory.

---

## Command reference

```
lsblk [-f]                        block device tree [with filesystems]
findmnt [PATH]                    mounts as a tree, with effective options
df -h / df -i                     space / INODES — always check both
du -xh --max-depth=1 PATH         usage, staying on one filesystem
du -xsh PATH
lsof +L1                          deleted files still held open   ← remember this
lsof -i :PORT / lsof -p PID
pvs / vgs / lvs                   LVM summary
lvextend -L +5G LV && xfs_growfs MOUNT
mount -a                          validate fstab WITHOUT rebooting
blkid                             UUIDs for fstab
uptime / free -h / vmstat 1 5
iostat -xz 1 3                    per-device utilisation and latency
dmesg -T | tail -30               OOM kills, disk errors
journalctl -p err -b
systemctl --failed
truncate -s 0 /proc/PID/fd/N      free a deleted-but-open file in place
```

---

## Traps

- **`df` without `df -i`.** You'll chase phantom disk space while the real problem is inodes.
- **`du` and `df` disagreeing** and not knowing why. `lsof +L1`.
- **No `nofail` in fstab.** A missing volume becomes an unbootable server.
- **`/dev/sdX` in fstab** instead of a UUID. Names reorder.
- **Rebooting without `mount -a`.** Validate first; the error is free now and expensive later.
- **`rm *` on a directory with 300,000 files.** "Argument list too long". Use
  `find -delete` or `xargs`.
- **Assuming xfs can shrink.** It can't.
- **`du` without `-x`** wandering into `/proc` and `/sys`.

---

## Checkpoint

1. Diagnose all five faults **from symptoms alone**, no notes.
2. A written runbook entry for each: symptom, cause, diagnosis command, fix, prevention.
3. Recover an unbootable box via Hetzner rescue mode without restoring the snapshot.

---

## If you want more

- Brendan Gregg, *Systems Performance* — the definitive book; his USE Method page is a
  ten-minute read that will change how you triage
- `man xfs_growfs`, `man lvm`, `man 5 fstab`
- `man systemd.mount` — how fstab becomes systemd units, which explains several odd behaviours
