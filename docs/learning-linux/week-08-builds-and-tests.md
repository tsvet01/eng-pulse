# Week 8 — Builds, caches, and tests

> **By the end:** you can state your cold and warm build times and account for every second,
> and your integration tests run against a real database identically everywhere.

**Time:** ≈6 h across 3 sessions · **Where:** Mac + the Hetzner box as a remote builder
**Prereq:** week 7 checkpoint

---

## What this is, and why it matters

You can write a Dockerfile. This week is about the difference between one that works and one
that's *fast, small, reproducible, and safe* — and about using containers as your test harness
rather than just your runtime.

Almost all slow Docker builds come from one mistake, and almost all leaked secrets come from
another. Both are two-line fixes once you understand the layer model. The testing half is
about killing an entire category of flakiness: stop mocking the database and run against the
real thing, in a container that's created and destroyed per test run.

### The mental model — layers and cache invalidation

Every instruction in a Dockerfile produces a layer. A layer is cached and reused **if the
instruction and all preceding layers are unchanged.** Change one thing and every layer after
it is rebuilt.

That single rule dictates the order of your Dockerfile:

```dockerfile
# ✗ WRONG — every source edit reinstalls all dependencies
FROM python:3.12-slim
COPY . .                          # ← any file change invalidates from here down
RUN pip install -r requirements.txt

# ✓ RIGHT — dependencies only reinstall when the manifest changes
FROM python:3.12-slim
COPY requirements.txt .           # changes rarely
RUN pip install -r requirements.txt
COPY . .                          # changes constantly — but it's the LAST layer
```

Same instructions, opposite performance. The rule generalises: **order instructions from
least-frequently-changed to most-frequently-changed.**

---

## Session 1 — Caching, multi-stage, and size (≈1.5 h)

### BuildKit cache mounts

Layer caching helps when the manifest is unchanged. Cache mounts help when it *has* changed —
they persist the package manager's cache directory across builds without baking it into a layer.

```dockerfile
# syntax=docker/dockerfile:1

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

RUN --mount=type=cache,target=/root/.npm \
    npm ci

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends build-essential

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -o /out/app ./cmd/app
```

The cache lives in BuildKit, not in the image, so it costs nothing in the final size. This is
usually the single biggest available build speedup — often 5–10× on a dependency change.

### Multi-stage builds

Build in a fat image, ship a thin one. Only the final stage becomes the image.

```dockerfile
FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -o /out/app ./cmd/app

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
```

A 900 MB toolchain produces a 12 MB image. Note `CGO_ENABLED=0` — see the musl section below
for why that line is load-bearing.

### Named targets

Stages you can build individually. This is what makes the test stage work in session 2.

```dockerfile
FROM python:3.12-slim AS base
# shared dependency install

FROM base AS test
COPY requirements-dev.txt .
RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements-dev.txt
COPY . .
CMD ["pytest", "-q"]

FROM base AS prod
COPY src/ ./src/
USER 1000:1000
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0"]
```

```bash
docker build --target test -t myapp:test .
docker build --target prod -t myapp:prod .
```

### `.dockerignore`

Without it, the build context includes `.git`, `node_modules`, `.venv`, and any stray secrets
— slow to transfer, and `COPY . .` puts them in the image.

```
.git
.gitignore
node_modules
__pycache__
*.pyc
.venv
.env
.env.*
dist
build
coverage
*.log
.DS_Store
```

### Secrets

```dockerfile
# ✗ NEVER — visible forever in `docker history`, in every layer, to everyone
ARG GITHUB_TOKEN
RUN git clone https://$GITHUB_TOKEN@github.com/org/private.git

# ✓ mounted for one instruction, never written to a layer
RUN --mount=type=secret,id=gh_token \
    GITHUB_TOKEN=$(cat /run/secrets/gh_token) git clone https://$GITHUB_TOKEN@github.com/...
```

```bash
docker build --secret id=gh_token,env=GITHUB_TOKEN .
```

Deleting a file in a later layer does **not** remove it from the image — the earlier layer
still contains it and anyone can extract it. Verify with `docker history --no-trunc`.

### Prove it

Measure your project honestly:

```bash
docker builder prune -af                     # force a true cold build
time docker build -t app:cold .
time docker build -t app:warm .              # no changes — should be near-instant
touch src/main.py && time docker build -t app:src .     # source-only change
```

Record all three in `notes.md`. The third one is the number that matters day to day, and if
it's close to the cold build, your layer order is wrong.

---

## Session 2 — The musl trap and multi-arch (≈1.5 h)

### Why Alpine breaks things

Alpine uses **musl** libc instead of **glibc**. They are not ABI-compatible, and four distinct
failure modes follow.

**1. Prebuilt binaries don't run at all.** An ELF binary hardcodes the path to its dynamic
linker. glibc builds want `/lib64/ld-linux-x86-64.so.2`; Alpine only has
`/lib/ld-musl-x86_64.so.1`. The kernel can't find the interpreter and returns ENOENT — giving
Linux's most confusing error:

```
$ ./myapp
sh: ./myapp: not found        # the file is RIGHT THERE
```

"Not found" refers to the *linker*, not your binary. `file ./myapp` shows which one it wants.
Recognising this on sight is a genuine senior-engineer tell.

**2. Python wheels miss on tag matching.** Wheels are tagged by platform:
`manylinux_2_28_x86_64` for glibc, `musllinux_1_2_x86_64` for musl. pip matches exactly, so no
musl wheel means **build from source** — needing gcc, headers, sometimes Rust or BLAS.

```bash
docker run --rm python:3.12-alpine pip debug --verbose | grep -m3 musllinux
docker run --rm python:3.12-slim   pip debug --verbose | grep -m3 manylinux
```

The punchline: Alpine Python images usually end up **larger and much slower to build** than
`python:3.12-slim`, because you install a whole toolchain to compile what would otherwise be a
download. The size win is a mirage for interpreted languages.

**3. Node native modules.** `prebuild-install` fetches binaries keyed on libc. No musl build →
compile from source → you need `build-base python3` in the image.

**4. Go with cgo.** Pure Go is static and runs anywhere. Enable cgo (any C dependency —
`go-sqlite3`, some crypto) and the binary dynamically links glibc, then hits failure mode 1.
Fix with `CGO_ENABLED=0`, or `-tags netgo,osusergo`, or build inside Alpine with musl-gcc.

**And the subtle ones that bite in production, not CI:** musl's default thread stack is ~128 KB
versus glibc's 8 MB, so deeply recursive code segfaults on Alpine and nowhere else; musl's
allocator is slower under multithreaded load; musl has no NSS and historically mishandled DNS
responses over 512 bytes, which is a classic Kubernetes footgun.

**Rule:** Alpine for static Go/Rust binaries and shell tooling. For Python, Node, Java, or
anything with native extensions: `debian:slim`, `distroless`, `chainguard/wolfi` (tiny *and*
glibc), or `ubi9-minimal` (Red Hat's, and relevant to your fleet).

### Multi-arch, and why your Mac isn't your server

Your Mac is ARM64; your fleet is x86. `docker build` locally produces `linux/arm64`.

```bash
docker buildx build --platform linux/amd64 -t app:amd64 .
```

This works via QEMU emulation and can be 5–20× slower, with occasional emulation bugs that
don't exist on real hardware. Use your **Hetzner box as a native x86 builder** instead:

```bash
docker context create hetzner --docker "host=ssh://anton@<cx-ip>"
docker buildx create --name x86 --driver docker-container --platform linux/amd64 hetzner --use
docker buildx build --platform linux/amd64 -t app:amd64 --load .
docker buildx ls
```

Native amd64 builds, driven from your Mac. This is the setup worth keeping.

### Prove it

Build the same image for arm64 natively, amd64 via QEMU, and amd64 on the remote builder.
Time all three.

---

## Session 3 — Weekend block: tests in containers (≈3 h)

### Three patterns, three jobs

**Pattern A — a test stage in the build.** The CI gate.

```bash
docker build --target test -t myapp:test . && docker run --rm myapp:test
```

Note this uses `CMD`, not `RUN pytest`. Putting `RUN pytest` in the build does gate the image
on green tests, but you lose exit-code granularity, you can't extract a coverage report, and a
cached layer means tests silently *don't re-run*. Build the test **stage**, then run it.

**Pattern B — Compose for tests needing real dependencies.**

```yaml
# compose.test.yaml
services:
  test:
    build: { context: ., target: test }
    depends_on:
      db: { condition: service_healthy }
    environment:
      DATABASE_URL: postgres://app:app@db:5432/app
    volumes:
      - ./reports:/app/reports
    command: pytest -q --junitxml=reports/junit.xml

  db:
    image: postgres:17
    environment: { POSTGRES_USER: app, POSTGRES_PASSWORD: app, POSTGRES_DB: app }
    tmpfs: /var/lib/postgresql/data          # RAM-backed: fast and truly ephemeral
    command: >
      postgres -c fsync=off -c full_page_writes=off -c synchronous_commit=off
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 2s
      timeout: 3s
      retries: 15
```

```bash
docker compose -f compose.test.yaml run --rm test
echo $?          # the exit code CI needs
```

Two large, free speedups here: `tmpfs` puts the database in RAM, and the `fsync=off` flags
disable durability guarantees you don't need for a throwaway test database. Together they
often halve integration-test time.

**Pattern C — Testcontainers.** The container lifecycle moves *into your test code*.

```python
# conftest.py
import pytest
from testcontainers.postgres import PostgresContainer

@pytest.fixture(scope="session")
def db_url():
    with PostgresContainer("postgres:17") as pg:
        yield pg.get_connection_url()
```

```bash
pip install testcontainers[postgres]
pytest -q
```

Advantages over Compose: better isolation (each run gets a fresh container on a random port,
so parallel runs don't collide), no separate compose file to keep in sync, and it works
identically from your IDE's test runner and from CI with no wrapper script. This is where most
teams have landed. Learn Compose first, then move here.

Available for Python, Go, Java, Node, .NET, Rust — and it needs a Docker socket, which is worth
knowing before you try to run it inside a container in CI.

### The exercise

1. Split your Dockerfile into `base` / `test` / `prod` targets with cache mounts.
2. Record cold, warm, and source-change build times before and after.
3. Add `compose.test.yaml` with a healthchecked, tmpfs-backed Postgres. Get integration tests
   green against a real database.
4. Set up the Hetzner remote builder and push a native amd64 image.
5. Port the integration tests to Testcontainers. Confirm they run from your IDE with no
   compose file.

### Optional — wire it to CI

```yaml
# .github/workflows/test.yml
- uses: docker/setup-buildx-action@v3
- uses: docker/build-push-action@v6
  with:
    target: test
    load: true
    tags: myapp:test
    cache-from: type=gha
    cache-to: type=gha,mode=max
- run: docker run --rm myapp:test
```

`cache-from`/`cache-to` with `type=gha` persists the BuildKit cache between CI runs, which is
the difference between a 30-second and a 6-minute pipeline.

---

## Command reference

```
docker build --target STAGE -t TAG .
docker build --secret id=NAME,env=VAR .
docker buildx build --platform linux/amd64 -t TAG --load .
docker buildx bake                          declarative multi-target builds
docker context create NAME --docker "host=ssh://user@host"
docker buildx create --name N --driver docker-container --platform P CONTEXT --use
docker builder prune -af                    force a cold build
docker history --no-trunc IMAGE             every layer and the command that made it
docker image inspect IMAGE --format '{{.Size}}'
docker system df                            where the disk went
dive IMAGE                                  (third-party) layer-by-layer size explorer

RUN --mount=type=cache,target=/path         persist a package cache across builds
RUN --mount=type=secret,id=NAME             build-time secret, never in a layer
```

---

## Traps

- **`COPY . .` before installing dependencies.** The number-one cause of slow builds.
- **`ARG` for secrets.** Permanently visible in `docker history`.
- **No `.dockerignore`.** Slow context transfer, bloated images, occasional secret leaks.
- **Alpine for Python/Node.** Usually bigger and slower. Use `slim` or `distroless`.
- **`RUN pytest` in the build.** Cached layers mean the tests silently stop running.
- **`depends_on` without a healthcheck condition.** Flaky integration tests you'll chase for weeks.
- **`:latest` anywhere near production.** Undefined rollback target.
- **QEMU cross-builds by default.** Slow, occasionally wrong. Use a native remote builder.

---

## Checkpoint

1. State your cold, warm, and source-change build times, and **account for every second** of
   the difference.
2. Integration tests run against a real Postgres identically from your IDE and from a clean
   checkout, with no manual setup.
3. Explain the `manylinux` vs `musllinux` wheel tag distinction and what breaks when it misses.

---

## If you want more

- Docker docs: Dockerfile reference (cache mounts, secret mounts), and `buildx bake`
- PEP 600 and PEP 656 — the wheel tag specifications, short and clarifying
- `dive` for exploring where image size actually goes
- The Testcontainers docs for your language
