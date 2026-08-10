# Week 4 — Networking, nftables, and SSH

> **By the end:** you debug "it's unreachable" by working the layers, not by guessing.

**Time:** ≈6 h across 3 sessions · **Where:** Rocky box + a **new second host**
**Prereq:** week 3 checkpoint · **Spend:** provision the CAX11 (~€4/mo) in session 3

---

## What this is, and why it matters

Two things changed since you were hands-on. The **tooling** moved: net-tools (`ifconfig`,
`netstat`, `route`) is deprecated in favour of iproute2 (`ip`, `ss`), and iptables was replaced
by nftables underneath firewalld. And the **traffic** changed: Let's Encrypt made certificates
free in 2016, so everything is TLS now, including internal service-to-service traffic. That
moved a whole class of failures from "connection refused" to "certificate problem", which
looks different and debugs differently.

The skill this week is not memorising commands. It's the **discipline of working the layers in
order** instead of restarting things hopefully. You have this instinct from a decade of
incident management; this week attaches the current commands to it.

### The mental model — the layer ladder

When something is unreachable, walk down this list. Each step has exactly one command, and each
answers a yes/no question. Never skip ahead.

| # | Question | Command | If no… |
|---|---|---|---|
| 1 | Is the process running? | `systemctl status svc` | Service problem, not network |
| 2 | Is it listening, and on which address? | `ss -tlnp` | Bound to `127.0.0.1` instead of `0.0.0.0`? |
| 3 | Does the host firewall allow it? | `firewall-cmd --list-all` | Add the service/port |
| 4 | Does the cloud firewall allow it? | Hetzner console | Security group |
| 5 | Does the name resolve, correctly? | `dig +short host` | DNS, stale cache, wrong record |
| 6 | Is there a route to the host? | `ip r get <ip>` | Routing or private-network config |
| 7 | Does TCP connect? | `nc -vz host port` | Filtered somewhere in the middle |
| 8 | Does TLS complete? | `openssl s_client -connect host:443` | Cert expiry, chain, SNI, protocol |
| 9 | Does the app answer? | `curl -v https://host/` | Now it's an application problem |

Step 2 catches an astonishing share of real incidents: the service is up, but bound to
loopback. `ss -tlnp` showing `127.0.0.1:8080` instead of `0.0.0.0:8080` is the answer, and
no amount of firewall poking will help.

---

## Session 1 — Addresses, sockets, and DNS (≈1.5 h)

### The iproute2 suite

One command, subcommands for each object. Every one abbreviates.

```bash
ip a                        # addr — interfaces and their addresses
ip r                        # route — the routing table
ip -br a                    # brief: one line per interface, very readable
ip -4 a                     # IPv4 only
ip n                        # neigh — the ARP/neighbour table
ip r get 1.1.1.1            # which route and source address WOULD be used
ip -s link                  # per-interface counters, including errors and drops
```

`ip r get` is underused and excellent: it asks the kernel to make an actual routing decision
rather than making you read a table and simulate it in your head.

### Sockets

```bash
ss -tlnp        # TCP, listening, numeric, with process — the one to memorise
ss -tunap       # TCP+UDP, all states, numeric, with process
ss -tn state established
ss -tlnp 'sport = :443'
ss -s           # summary counts by socket state
```

Read the flags as words: `-t` tcp, `-u` udp, `-l` listening, `-n` numeric (don't resolve
names, which is also much faster), `-p` process, `-a` all states.

### DNS

Resolution on a modern RHEL box goes: `/etc/nsswitch.conf` decides the source order → usually
`/etc/hosts` first, then DNS → `/etc/resolv.conf` names the servers (often managed by
NetworkManager or systemd-resolved, so editing it by hand may not stick).

```bash
dig example.com                     # full answer, with the sections labelled
dig +short example.com
dig +trace example.com              # walk down from the root servers — great for delegation bugs
dig @1.1.1.1 example.com            # bypass the local resolver to isolate caching
dig -x 1.1.1.1                      # reverse lookup
dig example.com MX
resolvectl status                   # if systemd-resolved is in use
cat /etc/resolv.conf                # check the header — it usually says who manages it
```

**Never use `nslookup`.** `dig` shows you the actual query, the response code, the TTL, and
which server answered. `nslookup` hides all of it.

### Prove it

For your own server: name the listening services and their bind addresses, the default route
and its interface, and the authoritative nameservers for your domain.

---

## Session 2 — TLS, and firewalling with nftables/firewalld (≈1.5 h)

### What actually happens in `curl https://example.com`

Trace it once so the failure modes have somewhere to attach:

1. **Resolve** `example.com` → A/AAAA record (`/etc/hosts`, then cache, then DNS)
2. **TCP handshake** — SYN, SYN-ACK, ACK to port 443
3. **TLS handshake** — ClientHello (with SNI naming the host), ServerHello, certificate,
   chain validation against the local trust store, key exchange
4. **HTTP request** over the encrypted channel
5. **Response**

```bash
curl -v https://example.com                  # annotated: * lines are curl, > request, < response
curl -sS -o /dev/null -w 'dns=%{time_namelookup} conn=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n' https://example.com
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null | openssl x509 -noout -dates -subject -issuer
```

That `-w` timing breakdown immediately tells you whether "the site is slow" is DNS, connection
setup, TLS negotiation, or the application. Put it in `notes.md`.

`-servername` matters: without SNI you get whatever default certificate the server presents,
which is a classic source of "the cert looks wrong" confusion on shared IPs.

### firewalld and nftables

nftables is the kernel's packet filter; firewalld is the management layer on RHEL. Your
`iptables` commands still appear to work through a translation shim — don't rely on it.

The model is **zones**: each interface belongs to a zone, and each zone has a set of allowed
services and ports. Default zone on a server is usually `public`.

```bash
firewall-cmd --state
firewall-cmd --get-active-zones
firewall-cmd --list-all                       # everything about the default zone

# runtime change — lost on reload/reboot
sudo firewall-cmd --add-service=http

# permanent change — NOT active until reload
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload

sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --remove-service=cockpit
firewall-cmd --get-services                   # the named service definitions available
```

**The runtime/permanent split is the trap.** A rule added without `--permanent` disappears on
reload; one added *with* `--permanent` doesn't apply until you reload. The safe habit is: add
permanent, then reload, then verify with `--list-all`.

See what firewalld actually generated:

```bash
sudo nft list ruleset | head -60
```

Reading that output — chains, hooks, verdicts — is worth twenty minutes. It's the ground truth
and firewalld is only a convenience over it.

### Prove it

Open port 8080 permanently, verify with both `firewall-cmd --list-all` and `nft list ruleset`,
then remove it and confirm it's gone from both.

---

## Session 3 — Weekend block: two hosts and SSH topology (≈3 h)

### Part 1 — Provision the second host

Hetzner → **CAX11** (ARM, ~€4/mo), Rocky Linux, same SSH key. Then attach **both** servers to
a Hetzner **Private Network** (Networks → Create, e.g. `10.0.0.0/16`).

Repeat the week-0 hardening: non-root user, key-only SSH, `dnf-automatic`.

Why a second host rather than a second distro: SSH topology, private networking, backups
between machines, and Ansible inventories are all invisible with one box. Two is the smallest
number where operations becomes real.

### Part 2 — Lock box two behind box one

Make the CAX reachable **only** through the CX. On the CAX, restrict SSH to the private
network:

```bash
sudo firewall-cmd --permanent --zone=public --remove-service=ssh
sudo firewall-cmd --permanent --new-zone=internal-ssh 2>/dev/null || true
sudo firewall-cmd --permanent --zone=internal-ssh --add-source=10.0.0.0/16
sudo firewall-cmd --permanent --zone=internal-ssh --add-service=ssh
sudo firewall-cmd --reload
```

**Keep your existing session open** while testing this from a new terminal. If you get it
wrong you'll need Hetzner's console.

Now on your Mac, `~/.ssh/config`:

```
Host rocky
  HostName <cx-public-ip>
  User anton
  IdentityFile ~/.ssh/id_ed25519

Host cax
  HostName 10.0.0.3            # private address
  User anton
  IdentityFile ~/.ssh/id_ed25519
  ProxyJump rocky
```

`ssh cax` now transparently hops through `rocky`.

### ProxyJump vs agent forwarding

Worth understanding properly, because it's a security decision you'll be asked about.

**Agent forwarding (`-A`)** exposes a socket on the intermediate host that can request
signatures from your local key. Anyone with root on that host can use your key, against any
host you have access to, for as long as you're connected. It's a lateral-movement gift.

**ProxyJump (`-J`)** just tunnels TCP through the intermediate. Your key never reaches it, and
authentication happens end-to-end with the final host. Same convenience, none of the exposure.

Use `ProxyJump`. Reach for `-A` only when you specifically need to authenticate *from* the
intermediate host to somewhere else, and prefer `ForwardAgent` scoped to a single `Host` block
rather than globally.

### Part 3 — Port forwarding

Run Postgres on the CAX, reachable only from the private network, and connect a GUI client on
your Mac to it:

```bash
# on cax
sudo dnf install -y postgresql-server && sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
```

```bash
# on your Mac
ssh -L 15432:localhost:5432 cax
# then point any client at localhost:15432
```

Read `-L 15432:localhost:5432` as: listen on **my** port 15432, forward to `localhost:5432`
**as resolved from the far end**. The `localhost` is relative to the SSH server, which is the
part people get backwards.

The reverse, `-R`, exposes one of your local ports on the remote host — useful for letting a
server reach a service on your laptop, and worth knowing before you need it at 2am.

### Part 4 — A useful SSH config

```
Host *
  ServerAliveInterval 30           # keep NAT/firewall state alive
  ServerAliveCountMax 3
  ControlMaster auto               # reuse one connection for subsequent sessions
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
  AddKeysToAgent yes
  HashKnownHosts yes
```

`ControlMaster` alone makes repeated `ssh`/`scp`/`rsync` to the same host near-instant, because
only the first connection pays for the handshake.

---

## Command reference

```
ip a | ip -br a                     addresses (brief form is very readable)
ip r | ip r get IP                  routing table | actual decision for one destination
ip n                                neighbour/ARP table
ip -s link                          interface counters, errors, drops
ss -tlnp                            listening TCP with owning process   ← the one
ss -tn state established
dig +short NAME | dig +trace NAME   quick answer | full delegation walk
dig @SERVER NAME                    bypass the local resolver
resolvectl status                   systemd-resolved view
curl -v URL                         annotated request/response
curl -w 'dns=%{time_namelookup} tls=%{time_appconnect} total=%{time_total}\n'
openssl s_client -connect H:443 -servername H
nc -vz HOST PORT                    TCP reachability, nothing else
mtr HOST                            traceroute + ping, continuous
sudo tcpdump -ni eth0 port 443 -c 20
firewall-cmd --list-all
firewall-cmd --permanent --add-service=http && firewall-cmd --reload
nft list ruleset                    the actual kernel rules
ssh -J jump target                  ProxyJump ad hoc
ssh -L LOCAL:host:REMOTE target     local forward
ssh -R REMOTE:host:LOCAL target     remote forward
```

---

## Traps

- **`--permanent` without `--reload`** (not applied) or **reload without `--permanent`**
  (silently lost). Do both, then verify.
- **Service bound to `127.0.0.1`.** The most common "firewall problem" that isn't one.
  `ss -tlnp` before touching the firewall.
- **The cloud firewall.** Hetzner/AWS security groups are a second, invisible layer above
  firewalld. Check both.
- **Agent forwarding by habit.** Use `ProxyJump`.
- **Locking yourself out.** Always test SSH and firewall changes in a *second* terminal while
  the first stays connected.
- **Editing `/etc/resolv.conf` directly.** Usually managed by NetworkManager or
  systemd-resolved and overwritten. Read the file's header comment.

---

## Checkpoint

From memory:

1. Given "the service is unreachable", walk the nine-step ladder aloud, naming the command for
   each step. No guessing, no hopeful restarts.
2. `ssh cax` works via ProxyJump, and the CAX refuses SSH from the public internet.
3. Explain why ProxyJump is preferred over agent forwarding.

---

## If you want more

- `man ssh_config` — read it once end to end; it's full of things worth knowing
- `man 5 firewalld.zone`, `man nft`
- Julia Evans, *How DNS Works* and *Networking! ACK!* zines
- Try `tcpdump -ni any port 53` while running `dig`, and watch the query go out
