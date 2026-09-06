# Week 6 — What a container actually is

> **By the end:** you can explain `docker run` in kernel terms, and argue daemon-vs-container
> for a specific service with reasons.

**Time:** ≈6 h across 3 sessions · **Where:** Rocky box (namespaces need a real kernel) + OrbStack
**Prereq:** week 5 checkpoint. Weeks 2 and 3 are what make this week land.

---

## What this is, and why it matters

You can already build images. This week is about what you're building *for*, and it starts by
removing the mystery.

**There is no "container" object in the Linux kernel.** There is no container syscall, no
container data structure, no container subsystem. A container is an ordinary process that has
been started with some combination of five existing kernel features. Docker and Podman are
programs that arrange those features and then call `execve()` like anything else.

Once you see that, three things follow that most people never quite get straight: why a
hardened systemd unit gives you most of what people assume is container-only; why
`--privileged` throws away nearly the whole point; and why containers are an *isolation and
packaging* mechanism rather than a security boundary in the way a VM is.

### The mental model — five ingredients

| Ingredient | What it does | Kernel feature since |
|---|---|---|
| **Namespaces** | Change what the process can *see* | ~2002–2013, by type |
| **cgroups** | Limit what it can *use* | v1 2008, v2 2016 |
| **Union filesystem** | Give it a root filesystem built from stacked layers | overlayfs, 2014 |
| **Capabilities** | Split root's powers into ~40 separate privileges | 1999 |
| **seccomp** | Restrict which syscalls it may make at all | 2012 |

The namespaces, specifically:

| Namespace | Isolates | Consequence |
|---|---|---|
| `pid` | Process IDs | Your process is PID 1 and can't see the host's processes |
| `net` | Interfaces, routes, ports | Its own `lo`, its own port space |
| `mnt` | Mount table | Its own filesystem view |
| `uts` | Hostname, domain | `hostname` differs from the host |
| `ipc` | Shared memory, semaphores | Can't reach the host's IPC objects |
| `user` | UID/GID mapping | Root inside maps to unprivileged outside — the basis of rootless |
| `cgroup` | cgroup hierarchy view | Can't see the host's cgroup layout |

So `docker run` means, roughly: create a set of namespaces, set up an overlay mount as the
root, place the process in a cgroup with limits, drop most capabilities, apply a seccomp
profile, then `execve` your binary. That's it. That's the whole trick.

**The corollary that matters for your job:** a container's isolation is the sum of those
choices. Turn them off — `--privileged`, `--net=host`, `--pid=host`, `-v /:/host` — and you
have a normal process with extra steps and a worse debugging story.

---

## Session 1 — See the ingredients directly (≈1.5 h)

Do this on the **Rocky box**, not OrbStack, so you're looking at a real kernel.

### Namespaces, without Docker

```bash
# every process has a set of namespaces; here are yours
ls -l /proc/self/ns/

# create a UTS namespace and change the hostname inside it
sudo unshare --uts sh -c 'hostname isolated; hostname; echo "--- but outside:"'
hostname                     # unchanged

# a PID namespace: watch the process become PID 1
sudo unshare --pid --fork --mount-proc sh -c 'echo "I am PID $$"; ps aux'
```

That last command is the whole concept in one line. You have built the essential part of a
container with a coreutils command. There's no daemon, no image, no Docker.

```bash
lsns                         # every namespace on the box and what's in it
lsns -t pid
```

### Now compare with a real container

```bash
sudo dnf install -y podman   # already on RHEL; Docker isn't
podman run -d --name demo docker.io/library/nginx:alpine
podman inspect demo --format '{{.State.Pid}}'
PID=$(podman inspect demo --format '{{.State.Pid}}')

# from the HOST, the container process is just... a process
ps -p $PID -o pid,ppid,user,cmd
sudo ls -l /proc/$PID/ns/          # compare these inode numbers to your own
lsns -p $PID

# and you can step into its namespaces
sudo nsenter -t $PID -n ss -tlnp   # its network namespace: its ports, not yours
sudo nsenter -t $PID -m ls /       # its mount namespace: the image's filesystem
```

`nsenter` is your debugging superpower for containers with no shell or tools inside. It runs a
*host* binary inside the container's namespaces — so you get the host's `ss`, `ps`, or `strace`
looking at the container's world. Put this in `notes.md`.

### cgroups

```bash
systemd-cgls                 # the full cgroup tree, as systemd sees it
systemd-cgtop                # live resource usage per cgroup
cat /sys/fs/cgroup/cgroup.controllers

podman run -d --name limited --memory 128m --cpus 0.5 docker.io/library/nginx:alpine
podman stats --no-stream
```

Note that `systemd-cgls` shows containers and systemd services **in the same tree**, using the
same mechanism. That's the punchline of this session.

### Prove it

Explain, without using the word "magic", what happens when you run
`docker run --rm -it alpine sh`.

---

## Session 2 — The deployment-model question (≈1.5 h)

### The framing that cuts through it

Most daemon-vs-container debates are really an argument about **who owns the patch pipeline.**

Install from the distro and your vendor backports CVE fixes onto a version you already
qualified — you run `dnf update` and you're done. Ship a container image and that becomes
your job: track base-image CVEs, rebuild, retest, redeploy. Neither is wrong. But the trade is
the actual decision, and everything else is downstream of it.

### What systemd already gives you

The comparison is only interesting because a hardened unit isn't the naked process people
imagine. From week 3:

```ini
MemoryMax=512M                  # cgroups — the same mechanism as --memory
CPUQuota=50%
ProtectSystem=strict            # read-only filesystem
PrivateTmp=yes                  # its own /tmp — a mount namespace
PrivateDevices=yes
NoNewPrivileges=yes
SystemCallFilter=@system-service   # seccomp
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
DynamicUser=yes
```

Namespaces, cgroups, seccomp, capabilities. Four of the five ingredients. What systemd does
*not* give you is the fifth: **a bundled root filesystem.** That's the container's real
differentiator — dependency isolation and one artifact that is byte-identical in dev, CI,
and production.

### The comparison

| Dimension | Native systemd daemon | Container |
|---|---|---|
| CVE patching | Vendor, backported to your version | You: rebuild, retest, redeploy |
| Dependency isolation | Shared host userspace | **Bundled — the main reason** |
| Resource limits | `MemoryMax=`, `CPUQuota=` | `--memory`, `--cpus` (same cgroups) |
| Sandboxing | `ProtectSystem=`, seccomp, caps | Namespaces + seccomp; rootless closes the gap |
| Rollback | `dnf history undo` | Redeploy the previous digest |
| Dev/prod parity | Weak — depends on host state | **Strong — same artifact** |
| Debugging | Host tools just work | Minimal images lack `ps`, `curl`, `ss` |
| Boot integration | Native | Needs a quadlet or an orchestrator |
| Startup overhead | None | Milliseconds, but non-zero |

### The heuristic

> **Containerise what you write. Use the distro's daemon for what keeps the box alive.
> Supervise both with systemd.**

**Native daemon wins when** it's OS-adjacent (sshd, chrony, auditd, firewalld — never
containerise the thing you need in order to fix a broken box); or vendor CVE backports matter
more than version currency, which in a regulated shop is often the whole argument; or it needs
deep host access. That last one has a tell: if your run command is accumulating
`--privileged --net=host --pid=host -v /:/host`, stop. You have built a worse daemon.

**Container wins when** it's your own application code (almost always); or two services need
conflicting runtime versions; or the distro's version is three years stale; or you want one
artifact across dev, CI, and prod — the strongest argument, and the one that justifies the
operational cost of everything else.

**And on RHEL the answer is usually both**, via quadlets in week 9: image-based packaging with
systemd supervision, journald logging, boot ordering, and resource control. The dichotomy
mostly dissolves.

---

## Session 3 — Weekend block: build it both ways (≈3 h)

### The exercise

Deploy the same trivial service twice on the Rocky box — once as a hardened systemd unit, once
as a container — and compare them on evidence rather than opinion.

Use a tiny Python HTTP service so there's a real runtime dependency in play.

```bash
sudo mkdir -p /srv/hello && cd /srv/hello
cat <<'EOF' | sudo tee app.py
import http.server, socketserver, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(f"hello from pid {os.getpid()}\n".encode())
    def log_message(self, *a): pass
socketserver.TCPServer(("", 8080), H).serve_forever()
EOF
```

**Version A — native systemd unit.** `/etc/systemd/system/hello-native.service`:

```ini
[Unit]
Description=Hello (native)
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 /srv/hello/app.py
DynamicUser=yes
ProtectSystem=strict
PrivateTmp=yes
NoNewPrivileges=yes
MemoryMax=128M
CPUQuota=50%
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now hello-native
curl localhost:8080
```

**Version B — container.**

```dockerfile
# /srv/hello/Dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
USER 1000:1000
EXPOSE 8080
CMD ["python3", "app.py"]
```

```bash
cd /srv/hello
sudo podman build -t hello:1 .
sudo podman run -d --name hello-ctr -p 8081:8080 --memory 128m --cpus 0.5 hello:1
curl localhost:8081
```

### Now measure, honestly

Fill this in for yourself — the answers are the point, not the table:

```bash
# startup time
systemd-analyze blame | grep hello-native
time (podman stop hello-ctr && podman start hello-ctr)

# memory overhead
systemctl status hello-native | grep Memory
podman stats --no-stream hello-ctr

# how does each look from the host?
ps -ef | grep -E 'app\.py'
systemd-cgls | grep -A2 -E 'hello'

# logs
journalctl -u hello-native -n 5
podman logs hello-ctr

# what does it take to patch a Python CVE in each?
#   native:    sudo dnf update python3          → done
#   container: rebuild image, retest, redeploy  → your pipeline

# security posture
systemd-analyze security hello-native.service
podman inspect hello-ctr --format '{{.HostConfig.SecurityOpt}} {{.HostConfig.CapDrop}}'

# disk footprint
podman images hello:1 --format '{{.Size}}'
```

### Part 2 — Break the isolation deliberately

See what `--privileged` actually costs:

```bash
podman run --rm alpine ls /dev | wc -l                # a handful of devices
podman run --rm --privileged alpine ls /dev | wc -l   # the host's devices
podman run --rm alpine cat /proc/self/status | grep CapEff
podman run --rm --privileged alpine cat /proc/self/status | grep CapEff
```

Compare the capability bitmasks. `--privileged` is not "a bit more access" — it's most of the
way back to being a root process on the host.

### Part 3 — Write it down

In `notes.md`, answer for a **specific service on your work fleet**: daemon or container, and
why. Name the patch pipeline, the dependency situation, and whether it needs host access.
That written argument is your checkpoint.

---

## Command reference

```
unshare --pid --fork --mount-proc CMD    build the essential part of a container by hand
lsns [-t TYPE] [-p PID]                  every namespace on the box
nsenter -t PID -n|-m|-p CMD              run a host tool inside a container's namespaces
ls -l /proc/PID/ns/                      a process's namespace inode numbers
systemd-cgls | systemd-cgtop             cgroup tree | live usage
podman run -d --name N --memory M --cpus C IMAGE
podman inspect N --format '{{.State.Pid}}'
podman stats --no-stream
podman logs N
cat /proc/PID/status | grep Cap          effective capabilities
systemd-analyze security UNIT
```

---

## Traps

- **Treating a container as a lightweight VM.** It shares the host kernel. A kernel exploit
  from inside is a host compromise. Use a VM when you need that boundary.
- **`--privileged` as a debugging habit.** It gets committed, then it's permanent.
- **Assuming containers are more secure than a hardened unit.** Run
  `systemd-analyze security` and a `podman inspect` side by side before claiming it.
- **Containerising sshd, chrony, or the firewall.** When the box is broken, you need those.
- **Forgetting the kernel is shared.** Your ARM Mac's OrbStack machines and containers all
  run one kernel; a "different distro" container is only a different userspace.

---

## Checkpoint

1. Explain what `docker run` asks the kernel to do, without using the word "magic".
2. Argue both sides of daemon-versus-container for a specific service on your work fleet,
   then land on an answer with stated reasons.
3. Use `nsenter` to inspect the listening sockets of a running container that has no `ss`
   installed inside it.

---

## If you want more

- `man 7 namespaces`, `man 7 cgroups`, `man 7 capabilities` — the primary sources, all readable
- Liz Rice, *Containers From Scratch* (talk) — builds one live in Go in 30 minutes
- Julia Evans' container zine
- `man 5 containers.conf` for Podman's defaults
