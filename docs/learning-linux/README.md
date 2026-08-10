# Linux & Containers — 12-Week Re-entry Curriculum

Companion files for the [12-week plan](https://claude.ai/code/artifact/47f57a79-c561-4428-a1da-e01b348bd57a).
One file per week. Each explains **what the subject actually is** before telling you what to type,
then splits the ~6 hours into three sessions you can actually schedule.

Written for someone who was a developer, managed for a decade, and is now building again.
That means: fundamentals get compressed (it's recall, not acquisition), and everything that
arrived after ~2014 — systemd, containers, nftables, SELinux-that-works, observability,
config-as-code — gets treated as new material, because it is.

---

## The weekly shape

Every week is three sessions. The split is deliberate: two short weekday sessions build
recall through repetition, and one longer weekend block is where the real project happens.

| Session | When | Length | Purpose |
|---|---|---|---|
| 1 | Weekday evening | ≈1.5 h | Concepts + first contact with the commands |
| 2 | Weekday evening | ≈1.5 h | Depth on the hard part of the week |
| 3 | Weekend block | ≈3 h | Build the thing. This is where it sticks. |

Each session ends with a **Prove it** — a small task with a verifiable result.
Each week ends with a **Checkpoint** — pass/fail, from memory, no searching.
Fail a checkpoint and repeat the week. They are the only real measure here.

## The files

| Week | File | Subject |
|---|---|---|
| 0 | [week-00-setup.md](week-00-setup.md) | Provision the rig, retire dead commands |
| **Phase I — Reactivation** | | |
| 1 | [week-01-shell-speed.md](week-01-shell-speed.md) | Filesystem, streams, pipes, text as an API |
| 2 | [week-02-permissions-processes.md](week-02-permissions-processes.md) | Permissions, processes, scripting that survives |
| **Phase II — The system** | | |
| 3 | [week-03-systemd.md](week-03-systemd.md) | Units, the journal, and systemd as a sandbox |
| 4 | [week-04-networking-ssh.md](week-04-networking-ssh.md) | ip/ss, DNS, TLS, nftables, SSH topology |
| 5 | [week-05-rhel-dialect.md](week-05-rhel-dialect.md) | dnf, SELinux, firewalld |
| **Phase III — Containers** | | |
| 6 | [week-06-what-is-a-container.md](week-06-what-is-a-container.md) | Namespaces, cgroups, and daemon-vs-container |
| 7 | [week-07-container-dev-env.md](week-07-container-dev-env.md) | Compose, bind mounts, watch, disposability |
| 8 | [week-08-builds-and-tests.md](week-08-builds-and-tests.md) | Layer caching, multi-stage, Testcontainers |
| 9 | [week-09-podman-quadlets.md](week-09-podman-quadlets.md) | Rootless Podman, quadlets, real deployment |
| **Phase IV — Operating** | | |
| 10 | [week-10-storage-and-recovery.md](week-10-storage-and-recovery.md) | LVM, fstab, chaos day, recovery |
| 11 | [week-11-observability.md](week-11-observability.md) | Prometheus, structured logs, eBPF |
| 12 | [week-12-ansible.md](week-12-ansible.md) | Idempotence, playbooks, rebuild-from-zero |

## The rig

| Machine | Role | Cost |
|---|---|---|
| Apple Silicon Mac | Daily driver. OrbStack for local Linux machines and Docker. | €0 |
| Hetzner CX22 (x86) | Rocky Linux, matching work's major version. Where you live. | ≈€4/mo |
| Hetzner CAX11 (ARM) | Second *host*, added week 4. SSH topology, Ansible inventory. | ≈€4/mo |
| Work RHEL VMs | Where the payoff lands. Never where you practise. | — |

**OrbStack can't do everything.** All its machines share one lightweight VM and therefore one
kernel. Shell work, `dnf`, systemd units, and all the Docker material work fine locally.
SELinux enforcement, nftables against a real stack, LVM, the fstab-recovery drill, and eBPF
need the Hetzner box. Each week file states where its work belongs.

## Rules

- **Type everything.** Don't copy-paste, and don't delegate the exercises to an assistant.
  Recall is a motor skill and you're rebuilding it. Use help freely for *understanding*,
  never for the keystrokes.
- **Read the man page first.** `man 5 systemd.exec` beats a blog post, and getting fluent at
  reading man pages removes your dependency on tutorials permanently.
- **Keep `notes.md` in git.** Anything you look up twice goes in it. That file is your real
  curriculum — these files are just scaffolding.
- **Snapshot before risky weeks**, then break things deliberately. Recovery is the skill.
- **Work over SSH on the Rocky box.** macOS ships BSD userland; `sed`, `date`, and `xargs`
  take different flags there than on any server. Don't build muscle memory against the wrong tool.

## Progress

- [ ] Week 0 — rig provisioned, dead commands retired
- [ ] Week 1 — shell speed
- [ ] Week 2 — permissions, processes, scripting
- [ ] Week 3 — systemd
- [ ] Week 4 — networking and SSH
- [ ] Week 5 — the RHEL dialect
- [ ] Week 6 — what a container is
- [ ] Week 7 — containers as a dev environment
- [ ] Week 8 — builds, caches, tests
- [ ] Week 9 — Podman and quadlets
- [ ] Week 10 — storage, failure, recovery
- [ ] Week 11 — observability
- [ ] Week 12 — Ansible
