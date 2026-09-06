# Week 7 — Containers as your dev environment

> **By the end:** your Mac has no language runtime installed, and
> `compose down -v && compose up` gets you a working environment from nothing.

**Time:** ≈6 h across 3 sessions · **Where:** Mac + OrbStack
**Prereq:** week 6 checkpoint

---

## What this is, and why it matters

Building images is packaging: produce an artifact that ships. Using containers as a **dev
environment** is the inverse discipline, and it's the half most people never adopt.

The rule is: **the container is disposable; your source and your caches are not.** You should
be able to delete every container, image, and volume at any moment and be back to work in one
command with nothing lost. If you can't, something in there is a pet, and you'll discover
which one at the worst time.

The payoff is concrete. Your laptop stops needing a Python, Node, or Go install. "Works on my
machine" becomes "works in the image, which is the image CI runs". Onboarding a new machine
becomes `git clone && docker compose up`. And version conflicts between projects stop existing.

The cost is a handful of mechanics that are non-obvious and bite everyone once. This week is
mostly those mechanics.

### The mental model — what lives where

```
   HOST                                CONTAINER
   ────                                ─────────
   source code        ──bind mount──▶  /app          (edits visible instantly)
   named volume       ──────────────▶  /app/node_modules   (container-owned, host can't see)
   named volume       ──────────────▶  /var/lib/postgresql/data
   nothing            ──────────────▶  everything else (disposable)
```

Three categories, and you must be able to say which is which for every path in your compose
file:

1. **Bind mounts** — a host directory grafted into the container. Live, two-way. For source.
2. **Named volumes** — Docker-managed storage. Survives `down`, dies on `down -v`. For
   dependency directories and databases.
3. **Ephemeral** — the container's own writable layer. Gone on `rm`. Everything else.

---

## Session 1 — The shadowing problem (≈1.5 h)

### The trap everybody hits

The obvious first attempt:

```yaml
services:
  api:
    build: .
    volumes:
      - ./:/app
```

This breaks immediately, and the reason is worth internalising: a bind mount **replaces**
whatever was at that path in the image. Your Dockerfile carefully ran `npm ci` and put
`node_modules` at `/app/node_modules` — and then the bind mount covered `/app` entirely,
including that directory. Now it's gone, or worse, it's your host's `node_modules` containing
macOS-native binaries that can't execute on Linux.

Symptoms: "Cannot find module", or a native module failing with an ELF error, or `pip` insisting
a package isn't installed when the build clearly installed it.

### Two fixes — pick per ecosystem

**Fix A: mask the path with an anonymous volume.**

```yaml
volumes:
  - ./:/app
  - /app/node_modules      # no host path = anonymous volume, mounted OVER the bind mount
```

Mounts are applied longest-path-first, so `/app/node_modules` wins over `/app`. The image's
copy shows through.

Caveat: the anonymous volume is populated at first creation and then *stays*. Change
`package.json` and you must `docker compose down -v` or the stale volume persists. This is the
most common "why isn't my new dependency there" confusion.

**Fix B (better where possible): install outside the mounted tree.**

```dockerfile
# Python
ENV VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH
RUN python -m venv /opt/venv
COPY requirements.txt .
RUN pip install -r requirements.txt      # lives at /opt/venv, never shadowed

# Node
ENV NODE_PATH=/deps/node_modules PATH=/deps/node_modules/.bin:$PATH
WORKDIR /deps
COPY package*.json ./
RUN npm ci
WORKDIR /app
```

Nothing to mask, no stale-volume confusion. Prefer this when the ecosystem allows it.
Per-language equivalents: Go `GOPATH=/go` and `GOCACHE=/gocache`, Rust
`CARGO_TARGET_DIR=/build`, Java `~/.m2` as a named volume.

### Do this

Take a real project. Get it running with a bind mount, deliberately hit the shadowing problem,
then fix it both ways and note which suits your stack.

```bash
docker compose config       # shows the fully-resolved file, with all merges applied
docker compose up
docker compose exec api ls -la /app/node_modules      # is it actually there?
```

---

## Session 2 — compose watch, and disposability (≈1.5 h)

### `docker compose watch`

Bind mounts plus an in-container file watcher works, but Compose has this natively now and it's
better — particularly on macOS, where filesystem-change notifications across the VM boundary
are unreliable.

```yaml
services:
  api:
    build: .
    ports: ["8000:8000"]
    develop:
      watch:
        - action: sync              # copy changed files in; process reloads itself
          path: ./src
          target: /app/src
          ignore: [node_modules/, __pycache__/]
        - action: sync+restart      # copy in, then restart the container
          path: ./config
          target: /app/config
        - action: rebuild           # dependency change: rebuild the image
          path: package.json
```

```bash
docker compose watch
```

The three actions map onto three genuinely different situations, and getting them right is
what makes the loop feel instant:

- **`sync`** — source your app already hot-reloads. No restart.
- **`sync+restart`** — config or anything read only at startup.
- **`rebuild`** — lockfiles, Dockerfile, system packages. Anything a `sync` can't express.

The most common mistake is not declaring the `rebuild` rule, so a lockfile change silently
leaves you running stale dependencies and you debug a phantom for an hour.

### Disposability as a practice

```bash
docker compose down          # stop and remove containers; NAMED VOLUMES SURVIVE
docker compose down -v       # ...and delete volumes. Your database is gone.
docker compose down --rmi local
```

Know exactly what `-v` destroys before you type it. The discipline to build:

- Anything you'd cry about must be in a **named volume with a documented backup**, or
  regenerable from code (migrations, seed scripts).
- Test `down -v && up` **weekly**. If it doesn't produce a working environment, you have
  undocumented state and you'll find out during an incident.

Seeding should be code, not something you did by hand once:

```yaml
services:
  db:
    image: postgres:17
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init:/docker-entrypoint-initdb.d:ro   # runs on first init only
volumes:
  pgdata:
```

### macOS performance

File I/O across the VM boundary is the main cost of this workflow on a Mac.

- Bind-mount **source only**. Dependency directories and build outputs
  (`node_modules`, `target/`, `.venv`, `__pycache__`) belong in named volumes — container-side,
  no host round-trip.
- **OrbStack over Docker Desktop** for noticeably faster filesystem and network paths.
- `:cached` / `:delegated` mount flags are legacy and mostly no-ops now; don't cargo-cult them.

### Prove it

`docker compose down -v && docker compose up` gives you a working environment with a seeded
database, and an edit to a source file is visible in under two seconds.

---

## Session 3 — Weekend block: delete the runtime (≈3 h)

### The commitment

Pick the project you work on most. Get it fully containerised for development, then
**uninstall that language runtime from your Mac** and work this way for the rest of the plan.

This is the forcing function. As long as `python3` works on the host, you'll fall back to it
whenever the container is inconvenient, and you'll never find the rough edges.

### Part 1 — Write the dev compose file

Full worked example, Python + Postgres:

```yaml
# compose.yaml
name: myapp

services:
  api:
    build:
      context: .
      target: dev
    ports: ["8000:8000"]
    environment:
      DATABASE_URL: postgres://app:app@db:5432/app
      PYTHONUNBUFFERED: "1"        # or logs vanish into a buffer and you think it's hung
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./src:/app/src
    develop:
      watch:
        - { action: sync,    path: ./src,              target: /app/src }
        - { action: rebuild, path: ./requirements.txt }

  db:
    image: postgres:17
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: app
    ports: ["5432:5432"]           # so host GUI clients can connect
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 2s
      timeout: 3s
      retries: 15

volumes:
  pgdata:
```

```dockerfile
# Dockerfile
FROM python:3.12-slim AS base
ENV VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH PYTHONDONTWRITEBYTECODE=1
RUN python -m venv /opt/venv
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM base AS dev
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]

FROM base AS prod
COPY src/ ./src/
USER 1000:1000
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Two details that save real time:

**`depends_on: condition: service_healthy`.** Plain `depends_on` only waits for the container
to *start*, not to be usable. Without the healthcheck condition your app races Postgres's
initialisation and fails intermittently — the kind of flake people blame on "Docker being
weird" for months.

**`PYTHONUNBUFFERED=1`.** Without it, Python buffers stdout when it isn't a TTY, so your logs
appear in bursts or not at all and the service looks hung. Every language has an equivalent trap.

### Part 2 — Working without a host runtime

Every command you used to run directly now runs through Compose:

```bash
docker compose run --rm api pytest              # one-off, container removed after
docker compose run --rm api python -m alembic upgrade head
docker compose exec api bash                    # shell into the RUNNING container
docker compose logs -f api
docker compose ps
docker compose restart api
```

`run` vs `exec` is worth getting straight: **`run`** starts a *new* container from the service
definition (use it for one-off tasks, migrations, a REPL). **`exec`** enters an
*already-running* one (use it to inspect live state). Running a migration with `exec` against
a container that isn't up gives a confusing error; `run --rm` always works.

Add shell aliases so the ergonomics don't push you back to the host:

```bash
# ~/.zshrc
alias dc='docker compose'
alias dcr='docker compose run --rm'
alias dce='docker compose exec'
```

### Part 3 — Editor integration

Your editor still runs on the host and needs to resolve imports for autocomplete. Two options:

- **Dev Containers** (VS Code, or the `devcontainer` CLI) — the editor's language server runs
  *inside* the container. Add a `.devcontainer/devcontainer.json` pointing at your compose
  service. Cleanest solution; a small amount of setup.
- **A host-side venv used only for the language server**, never for running code. Pragmatic,
  slightly dishonest, works fine.

Try Dev Containers first — it's the same idea as everything else this week, applied to the
editor.

### Part 4 — Now delete the runtime

```bash
brew uninstall python@3.12       # or nvm unload, rustup self uninstall, etc.
which python3                    # the system one, not yours
docker compose up                # still works
```

Note in `notes.md` every time you reach for the host runtime over the next month. That list is
your remaining gaps.

---

## Command reference

```
docker compose up [-d]              start (detached)
docker compose watch                start with file-sync/rebuild rules
docker compose down                 stop + remove containers (volumes survive)
docker compose down -v              ...and DELETE volumes
docker compose run --rm SVC CMD     one-off container, removed after
docker compose exec SVC CMD         run inside a RUNNING container
docker compose logs -f SVC
docker compose ps
docker compose config               fully-resolved config after merges
docker compose build --no-cache SVC
docker volume ls | docker volume inspect NAME
docker system df                    what is actually using disk
docker system prune -a --volumes    reclaim everything unused (careful)
```

---

## Traps

- **Bind mount shadowing the dependency directory.** The defining trap of this week.
- **Stale anonymous volumes.** Dependencies change, the volume doesn't. `down -v`.
- **`depends_on` without `condition: service_healthy`.** Intermittent startup races.
- **Unbuffered output not configured.** `PYTHONUNBUFFERED=1`, `stdbuf`, or the language's
  equivalent. Otherwise logs lie to you.
- **Bind-mounting `node_modules` or `target/` on macOS.** Pathological I/O. Named volume.
- **`down -v` on a database you cared about.** Know what `-v` means before you type it.
- **Using `exec` when you meant `run --rm`**, and getting a confusing "not running" error.

---

## Checkpoint

1. `docker compose down -v && docker compose up` takes you from nothing to a working dev
   environment, with a seeded database, no manual steps.
2. Your Mac has **no** host install of your project's language runtime.
3. Editing a source file is reflected in the running service in under two seconds.

---

## If you want more

- Docker docs: Compose file reference, and the `develop.watch` section specifically
- The Dev Containers specification (containers.dev)
- `docker compose config` on a project with multiple compose files — a good way to understand
  override merging before it confuses you
