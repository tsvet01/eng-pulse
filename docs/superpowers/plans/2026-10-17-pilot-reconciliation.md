# Pilot Reconciliation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this approved pilot slice task-by-task, with tests before code.

**Goal:** Keep the engineering API mirror current from published GCS artifacts and expose a stopped or stale mirror before switching app reads.
**Architecture:** Reuse the atomic, generation-pinned 30-day importer in a supervised API background loop on Hetzner. Persist attempt/outcome checkpoints in Postgres, serialize workers with a database advisory transaction lock, and expose a minimal public freshness probe plus service-token-protected details. An hourly GitHub Actions probe provides a failed-run signal independently of the API process.
**Tech Stack:** Existing Rust/axum/sqlx/Tokio, Postgres18, GitHub Actions; no new dependency or cloud credential.
**Spec:** `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md`, implementing P1.2 of `2026-10-13-hetzner-multiuser-pilot.md`.

## Global Constraints

- Preserve GCP jobs, schedule, models/prompts, artifact layout, and legacy recipients. Keep API dual-write off until its separate release prerequisites pass.
- No LLM calls, historical notifications, private backup credential use, or user-state changes. Conflicting existing records still require review.
- Agents do not deploy or modify cloud resources directly; release through existing CI and production gates.
- Current-day notification recovery remains a P2 outbox requirement; this slice remains silent.

## Builder decisions

The approved design leaves cadence and process layout to implementation. Run immediately on API startup and every 15 minutes thereafter, with missed ticks skipped and no overlapping cycles. Each cycle tries at most 3 imports, 30 seconds apart; each import retains its 180-second limit, and the entire cycle is bounded to 11 minutes. A separate transaction holds an advisory lock and has a 12-minute idle timeout to release a dead worker. Completed checkpoints survive restart. A successful parity check must be at most 45 minutes old, the public source and database must contain at least yesterday's date before 07:30 UTC or today's date thereafter. Old source gaps are reported but do not make current data stale. The hourly probe runs at minute23; GitHub scheduling/notification preferences affect alert delivery and are not an SLA.

## Review Focus

- Cancellation, restart, DB outage or another replica cannot leave permanent ownership or report a false new success.
- A recent successful fetch must not hide stale source data, disabled engineering, missing current DB rows or stopped background work.
- Retry exhaustion preserves the last good checkpoint and is observable without exposing credentials or raw user content.
- Existing conflict protection and silent history import must survive integration with concurrent daily writes.
- Deployment enables only the intended pilot configuration; tests/local API instances remain opt-in and GCP integration stays unchanged.

### Task 1: Checkpointed repair loop and freshness routes

**Files:** `apps/pulse-api/migrations/0004_reconciliation.sql`, `src/reconciliation.rs`, `src/{lib,config}.rs`, `src/routes/{mod,internal}.rs`, `tests/reconciliation.rs`.
**Interfaces:** `reconcile_cycle(pool,source,end,retry_delay)` returns success/failed/skipped; `run(pool)` supervises scheduled cycles; `status(pool)` returns persisted outcome; public `/healthz/briefs` returns only status/reason and service-authenticated `/internal/reconciliation` returns detailed checkpoint/report. `RECONCILE_HISTORY_ENABLED` strictly accepts true/false and defaults false.

- [x] Write DB/HTTP tests for missing-write recovery/replay, retries/exhaustion, retained success after source failure, conflicting writes, lock contention, and freshness boundaries/auth. Run against stubs; expect failing assertions.
- [x] Implement migration, cycle/checkpoints, bounded scheduler and routes; run focused tests, expect all green.
- [x] Verify full API suite and Clippy; commit this coherent component.

### Task 2: Enable pilot runtime, monitor and record evidence

**Files:** `config/pilot-auth.json`, `scripts/prepare_api_env.py`, `scripts/tests/test_prepare_api_env.py`, `.github/workflows/pilot-freshness.yml`, `scripts/check-pilot-freshness.sh`, `scripts/tests/test_pilot_freshness.py`, existing pilot plan and runbook.
**Interfaces:** Reviewed public runtime overlay enables the worker without replacing any secret. Monitor uses fixed HTTPS endpoint with bounded requests, rejects redirects/invalid JSON/degraded status, and exits nonzero on failure; no external sender credentials or messages.

- [ ] Add failing configuration and monitor tests with real local HTTP fixtures, then implement the minimal runtime overlay/monitor. Expect no cloud calls and preserved existing private values.
- [ ] Add hourly/manual monitoring workflow with pinned checkout and read-only permissions. Document alert routing, cadence, startup/recovery behavior and limitations.
- [ ] Update historical evidence: 29 production imports, 0 replay inserts, 29 verified, 10 October source gap; PR #200 release succeeded.
- [ ] Run API/release tests, formatting/Clippy/ShellCheck/Actionlint; request one fresh whole-branch review, fix important findings with RED→GREEN, and publish a PR.

Production activation, the next 06:00 UTC comparison, a controlled production outage rehearsal and P2 delivery/device gates are separate release evidence; do not infer them from local tests.
