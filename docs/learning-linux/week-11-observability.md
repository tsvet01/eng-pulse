# Week 11 — Observability, as it works now

> **By the end:** an alert fires for a week-10 fault before you notice it manually, and you've
> answered a question with eBPF that no other tool could answer.

**Time:** ≈6 h across 3 sessions · **Where:** both Hetzner boxes (eBPF needs a real kernel)
**Prereq:** week 10 checkpoint

---

## What this is, and why it matters

When you were last hands-on, monitoring meant Nagios asking "is it up?" every five minutes.
Two things replaced that, and they're genuinely different in kind rather than degree.

**Metrics became dimensional and pull-based.** Prometheus scrapes numeric time series with
key/value labels attached, so you can ask "p99 latency for the checkout endpoint on hosts in
eu-central" *after* the fact, without having decided to record that specific combination in
advance. The shift from "a check per thing I thought of" to "dimensions I can slice later" is
what makes debugging unknown problems possible.

**eBPF made the kernel introspectable.** You can now attach small verified programs to kernel
functions, tracepoints, and user-space probes at runtime — no module, no patch, no restart, on
a production box. Questions that used to require a debug build or a maintenance window are now
a one-liner. This is the biggest genuinely new capability since your era, and almost every
modern performance tool (and much of Kubernetes networking and security) is built on it.

### The mental model — three signals

| Signal | Answers | Cost | Tool here |
|---|---|---|---|
| **Metrics** | "Is it happening, how often, how bad?" | Cheap, aggregated | Prometheus |
| **Logs** | "What exactly happened in this one case?" | Expensive at volume | journald, structured JSON |
| **Traces** | "Where did the time go across services?" | Sampled | OpenTelemetry |

Use metrics to *detect*, traces to *localise*, logs to *understand*. Reaching for logs first
is the most common expensive mistake — you end up grepping terabytes for something a metric
would have told you in a second.

---

## Session 1 — Prometheus and PromQL (≈1.5 h)

### The model

Prometheus **pulls**. Each target exposes `/metrics` over HTTP; Prometheus scrapes on an
interval and stores the samples. Pull matters more than it sounds: the target has no config
about where to send data, service discovery lives in one place, and a scrape failing is itself
a signal (`up == 0`) rather than silence you have to notice.

Four metric types:

- **Counter** — only goes up (requests total, errors total). Always query with `rate()`.
- **Gauge** — goes up and down (memory in use, queue depth, temperature).
- **Histogram** — bucketed observations; lets you compute quantiles server-side.
- **Summary** — client-side quantiles. Can't be aggregated across instances; prefer histograms.

### Install

On the Rocky box:

```bash
# node_exporter — host metrics
sudo useradd -rs /sbin/nologin node_exporter
curl -sL https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-*.linux-amd64.tar.gz \
  | sudo tar xz -C /usr/local/bin --strip-components=1 --wildcards '*/node_exporter'
```

`/etc/systemd/system/node_exporter.service` — you can write this from memory now:

```ini
[Unit]
Description=Prometheus node exporter
After=network-online.target

[Service]
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
User=node_exporter
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=yes
MemoryMax=128M
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now node_exporter
curl -s localhost:9100/metrics | head -30
```

Read some of that output. It's plain text: metric name, labels in braces, value. That's the
entire exposition format, and its simplicity is why everything speaks it.

Prometheus itself, as a quadlet (week 9 skills, reused):

```yaml
# /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['10.0.0.2:9100', '10.0.0.3:9100']
rule_files:
  - /etc/prometheus/alerts.yml
```

```ini
# ~/.config/containers/systemd/prometheus.container
[Container]
Image=docker.io/prom/prometheus:latest
PublishPort=127.0.0.1:9090:9090
Volume=/etc/prometheus:/etc/prometheus:ro,Z
Volume=prom-data:/prometheus

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

The `:Z` suffix on the bind mount is the SELinux relabel flag — without it the container can't
read the host directory, and you get a week-5 denial. Good reinforcement.

### PromQL, the parts you need

```promql
# a gauge, right now
node_memory_MemAvailable_bytes

# per-second rate of a counter over 5 minutes — ALWAYS rate() a counter
rate(node_cpu_seconds_total{mode="idle"}[5m])

# CPU utilisation as a percentage
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# disk space percentage
100 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100)

# inodes — the week-10 fault
100 - (node_filesystem_files_free / node_filesystem_files * 100)

# is the target even up?
up == 0

# will the disk fill in the next 4 hours, based on the last 6?
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4*3600) < 0
```

`predict_linear` is the one worth internalising: alerting on a *trend* rather than a threshold
means you get paged while there's still time to act, instead of at 100%.

### Cardinality — the operational trap

Every unique combination of label values creates a separate time series. Add a label with
unbounded values — user ID, request ID, full URL path, container ID — and you get millions of
series, and Prometheus falls over.

```promql
topk(10, count by(__name__)({__name__=~".+"}))     # what's costing you
```

Rule: labels must have **bounded, low-cardinality** values. Status code, method, endpoint
*template* (`/user/:id`, not `/user/8134`), environment. Never a raw identifier. This is the
single most common way teams break their own monitoring, and it's a good thing to be able to
catch in a design review.

### Prove it

Query current CPU utilisation, memory available, and root filesystem percentage for both hosts.

---

## Session 2 — Alerts and structured logs (≈1.5 h)

### Alerts that would have caught week 10

`/etc/prometheus/alerts.yml`:

```yaml
groups:
  - name: host
    rules:
      - alert: DiskWillFillIn4Hours
        expr: predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4*3600) < 0
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}: / will be full within 4 hours"

      - alert: InodesExhausting
        expr: 100 - (node_filesystem_files_free / node_filesystem_files * 100) > 85
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}: {{ $value | printf \"%.0f\" }}% of inodes used"

      - alert: TargetDown
        expr: up == 0
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "{{ $labels.job }} on {{ $labels.instance }} is not scrapeable"
```

`for:` is what separates an alert from a nuisance. It requires the condition to hold
continuously for that duration, which suppresses the transient spikes that make people mute
alerting entirely.

```bash
promtool check rules /etc/prometheus/alerts.yml
promtool check config /etc/prometheus/prometheus.yml
```

Design principle, and one you already hold from the management side: **alert on symptoms, not
causes.** "The API is returning errors" is actionable. "CPU is at 90%" might be completely
fine. Every alert should correspond to something a human must do; anything else belongs on a
dashboard.

### Structured logging

Text logs stopped scaling. The modern shape is one JSON object per line, so logs are queryable
rather than greppable.

```json
{"ts":"2026-08-10T14:22:01Z","level":"error","msg":"payment failed","order_id":"A-1234","user_id":8134,"duration_ms":412,"trace_id":"4bf92f..."}
```

journald is already structured — every entry has metadata fields:

```bash
journalctl -u myapp -o json-pretty | head -40
journalctl -u myapp -o json | jq -r 'select(.PRIORITY=="3") | .MESSAGE'
journalctl _SYSTEMD_UNIT=myapp.service _PID=1234
```

If your app emits JSON to stdout, journald captures it as the message and you can query with
`jq`. The field to standardise on across services is `trace_id`, because it's what links a log
line to a trace.

### Traces, in outline

You don't need to build a tracing stack this week, but know the shape: OpenTelemetry is the
vendor-neutral standard for emitting traces, metrics, and logs. A **trace** is one request's
journey; a **span** is one operation within it; **context propagation** passes the trace ID
across service boundaries via headers.

The practical value is answering "where did the 900ms go" across five services — which metrics
can't tell you and logs can only tell you with enormous effort. Add the SDK to a service, point
it at a collector, and look at one trace. That's enough for now.

### Prove it

Re-run the week-10 disk-fill fault and watch `DiskWillFillIn4Hours` fire before you'd have
noticed manually.

---

## Session 3 — Weekend block: eBPF (≈3 h)

### What eBPF is

A verified, JIT-compiled virtual machine **inside the kernel**. You attach small programs to
hooks — kernel function entry/exit (kprobes), stable tracepoints, user-space functions
(uprobes), network paths, syscalls — and they run in kernel context, aggregate data in maps,
and hand results to userspace.

Why it matters: no kernel module, no reboot, no recompile, and the verifier rejects anything
that could crash or loop. You can run it on a production box during an incident, which is
exactly when you need it and exactly when nothing else was previously safe.

```bash
sudo dnf install -y bpftrace bcc-tools
uname -r                            # need 4.9+; you'll have far newer
ls /usr/share/bcc/tools/            # ~100 ready-made tools
```

### The BCC tools — start here

```bash
sudo /usr/share/bcc/tools/execsnoop      # every process exec, live. Run a command elsewhere.
sudo /usr/share/bcc/tools/opensnoop      # every file open, with the process
sudo /usr/share/bcc/tools/tcpconnect     # every outbound TCP connection
sudo /usr/share/bcc/tools/tcpaccept
sudo /usr/share/bcc/tools/biolatency     # block I/O latency as a histogram
sudo /usr/share/bcc/tools/cachestat      # page cache hit ratio
sudo /usr/share/bcc/tools/runqlat        # scheduler run-queue latency
sudo /usr/share/bcc/tools/profile -F 99 30    # sampled stacks — a flamegraph's raw input
```

`execsnoop` is the one that converts people. Leave it running and watch every process the
machine spawns, with arguments and parent. Mysterious cron jobs, surprise shell-outs from an
application, a container's entrypoint chain — all visible, immediately.

### bpftrace one-liners

bpftrace is awk for the kernel: a small language for ad-hoc tracing.

```bash
# every file opened, by process
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%-16s %s\n", comm, str(args->filename)); }'

# count syscalls by process over 10 seconds
sudo bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); } interval:s:10 { exit(); }'

# read() size distribution as a histogram
sudo bpftrace -e 'tracepoint:syscalls:sys_exit_read /args->ret > 0/ { @bytes = hist(args->ret); }'

# who is spawning processes?
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_execve { printf("%s -> %s\n", comm, str(args->filename)); }'

# TCP retransmits — invaluable for "the network feels slow"
sudo bpftrace -e 'kprobe:tcp_retransmit_skb { @[comm] = count(); }'
```

The structure is always `probe /filter/ { action }`. `@name` declares a map; `count()`,
`hist()`, and `quantize()` aggregate in the kernel so almost no data crosses to userspace —
which is why this is cheap enough to run on a live system.

### The exercise

**Part 1 — Alerts.** Get Prometheus scraping both hosts, load the alert rules, and confirm
`promtool check rules` passes. Re-run a week-10 fault and see the alert fire.

**Part 2 — Answer a question only eBPF can answer.** Pick one, do it for real:

- Which process is opening a specific file, when you don't know who's responsible?
  `opensnoop -n <filename>`
- What is the actual latency distribution of disk I/O under your workload, not the average?
  `biolatency`
- Which processes make outbound connections, and to where?
  `tcpconnect`
- Where is CPU time going in your app, at 99 Hz, without instrumenting it?
  `profile -F 99 -p <pid> 30`

Write in `notes.md` what you asked, which tool answered it, and what you'd have had to do
before eBPF existed. That comparison is the point.

**Part 3 — Optional: Grafana.** Add a Grafana quadlet, point it at Prometheus, import
dashboard ID **1860** (Node Exporter Full). It's a good way to see what the metrics can show
you before you write your own panels.

---

## Command reference

```
# Prometheus
curl -s localhost:9100/metrics
promtool check config|rules FILE
rate(counter[5m])                          per-second rate — always for counters
100 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100
predict_linear(metric[6h], 4*3600) < 0     trend-based alerting
up == 0                                    target down
topk(10, count by(__name__)({__name__=~".+"}))    cardinality audit

# logs
journalctl -u UNIT -o json-pretty
journalctl -o json | jq -r 'select(.PRIORITY=="3") | .MESSAGE'

# eBPF
/usr/share/bcc/tools/execsnoop|opensnoop|tcpconnect|biolatency|runqlat|profile
bpftrace -l 'tracepoint:syscalls:*'        list available probes
bpftrace -e 'probe /filter/ { action }'
bpftrace -e '... { @[comm] = count(); }'   aggregate in-kernel by process
```

---

## Traps

- **High-cardinality labels.** User IDs, request IDs, raw URLs. It kills Prometheus, and it's
  always discovered too late.
- **Counters without `rate()`.** A raw counter is a meaningless ever-increasing number.
- **Alerting on causes.** "CPU 90%" pages people for nothing. Alert on user-visible symptoms.
- **No `for:` clause.** Every transient spike becomes a page; people mute the channel; the
  alert that mattered is missed.
- **Bind mounts into containers without `:Z`** on SELinux. Week 5's lesson, re-learned.
- **Treating logs as the primary signal.** Expensive to store, expensive to search. Metrics
  detect; logs explain.
- **Running heavy `bpftrace` in production carelessly.** It's safe by design, but a probe on a
  very hot path still costs measurable overhead. Filter narrowly.

---

## Checkpoint

1. Re-run a week-10 fault and have the alert fire **before** you notice manually.
2. Explain what makes a metric high-cardinality and why it's an operational cost, not a
   theoretical one.
3. Answer a real question with `bpftrace` or a BCC tool that you could not have answered with
   `ps`, `top`, or logs.

---

## If you want more

- Brendan Gregg's site — the BPF tools index and the USE Method. He wrote most of these tools.
- *BPF Performance Tools* (Gregg) — the reference
- `man bpftrace`, and the bpftrace reference guide's one-liner collection
- Prometheus docs: "Instrumentation" and "Alerting rules" best-practice pages
- Google SRE Book, chapter 6 ("Monitoring Distributed Systems") — short, and the source of the
  symptoms-not-causes principle
