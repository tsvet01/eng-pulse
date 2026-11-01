# Playback recovery implementation plan

Goal: fix same-process recovery after failed or stalled playback, and prove it with repeatable network fault tests.

Spec: `docs/superpowers/specs/2026-11-01-playback-chaos-test-design.md`.

Scope ruling: implement the incident regression and directly related cancellation, timeout, retry controls and cloud error handling now. The full hardware qualification matrix, runtime device-voice fallback, automatic retry/cooldown policy and nightly chaos lab remain separate work. Manual retry must work regardless of those additions. Work in the existing checkout to preserve and test the user's pending Swift UI/cache edits; do not commit unrelated changes.

## Tasks

- [x] Add regression tests through real CloudTTSService with scripted URLSession responses and isolated cache files. Demonstrate failed single-article resume, late same-article errors, connection loss and cloud-wide errors with a queue.
- [x] Retain/cancel playback tasks and guard every asynchronous completion by attempt identity. Add a bounded startup timeout and retain original text for retry; preserve queue item on network/service failure. Test timeout, Stop and switching to another article.
- [x] Keep retry controls reachable in Home/Detail and remote commands. Validate native player start and reject stale native player callbacks; add meaningful audio tests as needed.
- [x] Run the focused regression suite, then all Swift tests on an available simulator. Review the final changes and record exact results and hardware limitations.

Validation: Xcode test via the EngPulse scheme, simulator UDID discovered from installed runtimes, cloud fixture responses only. No production API credentials or endpoint calls in tests. Require red/green evidence for regression tests, clean diff checks and no unresolved test failures.

Review focus: A→B→A stale responses, Stop during startup, nil URL identity, hung response timeout, queue errors with JSON bodies, active playback surviving old timeout/callbacks.

Results: `docs/testing/2026-11-01-playback-recovery-results.md`. Review identified queued Combine notification ordering and accidental overclassification of decoder failures; both received failing regression tests before correction. Final reviewed suite: 67 tests passed on each of iOS 26.5 and iOS 18.4.
