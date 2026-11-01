# Playback chaos test suite

Status: proposed test design; tests and product changes are not implemented.
Date: 2026-11-01.

## Incident and release criterion

The user reported an iPhone 14 Pro running iOS 27.2, in woods with weak signal. Playback failed with a connection error. Pressing Play again did nothing; selecting another article did not recover playback. Force-quitting the app was necessary. The OS version is user-reported; record the exact OS build and app version when reproducing.

**Release criterion: after a recoverable playback failure, Play/Retry and choosing another article must work in the same app process. Restoring connectivity must never require force-quit, cache deletion, or reinstall.** A network outage may prevent downloading uncached content; it must not wedge playback controls.

Primary scope: native Swift iOS app, including phone UI, iPad UI, lock-screen commands, and CarPlay's shared playback service. Secondary scope: Flutter's content fetching and platform TTS, with its own adapter tests rather than assuming it uses the Swift cloud pipeline. No claim of coverage on literally every device: certify the supported OS/device matrix below and record untested combinations.

## Findings that drive the tests

These are inspected code risks, not a confirmed diagnosis of the field incident. References describe the current working tree, which contains pre-existing edits.

| Priority | Evidence | Risk and test implication |
| --- | --- | --- |
| P1 | `apps/mobile-swift/EngPulse/Services/TTSService.swift:194–258` | Cloud work runs in an unretained task. Guards use article URL and state, not a unique attempt identity; error handling checks only URL. Retrying the same URL and A→B→A transitions need delayed success/error tests, including after Stop. |
| P1 | `TTSService.swift:314–325, 433–439`; `Views/HomeView.swift:127–144`; `Views/DetailView.swift:197–226` | Recovery differs between surfaces. Remote resume retries stopped queues, not stopped single articles; Home hides the stopped player. Exercise actual controls, not only direct service calls. |
| P1 | `Services/CloudTTSService.swift:121–159, 187–207` | Sequential synthesis requests have no application retry policy. Multi-chunk audio is fully assembled before playback. Drop connections during any chunk and verify bounded failure/recovery and complete output. |
| P1 | `TTSService.swift:264–287`; `CloudTTSService.swift:193–200` | Systemic error classification covers transport and article-loader failures but not cloud HTTP errors. Parsed API errors discard HTTP status. A 429/503 can skip through a playlist instead of preserving the current item. |
| P1 | `Services/AudioPlayerService.swift:17–50, 59–62` | Session activation errors are logged, and `play()` results are ignored before publishing playing state. A green UI alone does not prove audible playback. |
| P1 | `Services/CacheService.swift:84–95` | Audio writes are not explicitly atomic and reads check existence only. Partial/corrupt cached audio can repeatedly fail. Test invalidation and recovery without deleting all caches. |
| P2 | `TTSService.swift:48–58`; `Services/LocalTTSService.swift` | Local voice is selected when a cloud key is absent, not as runtime offline recovery. Device-voice fallback below is a proposed behavior, not an existing guarantee. |
| P2 | `EngPulseTests/`; `.github/workflows/ci.yml:swift-check` | Current Swift tests cover parsing, content building and basic local TTS state; no cloud fault, recovery, or UI test suite exists. CI currently runs one available simulator. |

Unless prefixed otherwise, paths in the table are relative to `apps/mobile-swift/EngPulse/`.

## Proposed recovery contract

The following are design defaults chosen for this suite, not previously agreed product behavior or measured performance. Pin them in shared test configuration so tests cannot pass by silently extending timeouts.

1. **One current playback intent.** Each fresh Play/Retry, article change, Next, Previous, or Stop invalidates older work. Track an intent identifier independent of article URL. At most one synthesis request and one audio output are active for that intent; content fetch precedes synthesis. Duplicate taps during loading coalesce. Stop cancels queued retries and work; late callbacks cannot start audio, show stale errors, change track, or advance a queue.
2. **Bounded startup.** A fresh intent has a 45-second wall-clock startup deadline across content fetch, all synthesis chunks, retry delays, cache I/O, and player startup. Show loading immediately and a slow-connection explanation by 5 seconds. At the deadline, terminate startup and expose Retry, Stop, and device voice when available. Never leave an indefinite disabled spinner. Slow multi-chunk WAV downloads may deliberately reach this bound; success then means useful recovery, not impossible throughput.
3. **Limited automatic retry.** Transient transport failures and HTTP 408/429/500/502/503/504 are retryable. Allow two additional failed-request attempts across the entire intent, not two per chunk or per service. Delay retry 1 by 1 second and retry 2 by 2 seconds, plus seeded uniform jitter of 0–250 ms. Retry only the failed chunk; retain completed chunks in memory for that intent. Do not restart a successful chunk merely because a later chunk failed. When offline is known, wait without polling until usable connectivity or the deadline; the actual request outcome, not a reachability flag, determines success.
4. **Server backoff.** For 429/503, honor a valid `Retry-After` (seconds or HTTP date) as a minimum delay; use the greater of it and local backoff. If that exceeds the remaining deadline, enter recoverable failure immediately and display the cooldown. Manual Retry cannot bypass a server cooldown. A fresh user retry resets the intent deadline and transient retry credits; rapid duplicate taps do not. Cooldowns live for the current app process and survive Stop, Retry and article changes: synthesis cooldown is shared by provider origin and configured credential identity; content cooldown is shared by content origin (scheme/host/port). The two services have separate cooldown stores even in fixtures sharing a server. Cached playback, local speech and requests to unrelated content origins remain usable. Convert HTTP dates to remaining duration using an injected wall clock, then enforce using monotonic time; record no credential values in logs.
5. **Permanent failures.** No automatic retries for cancellation, TLS trust failure, authentication/configuration failure, malformed content, invalid audio, or other 4xx responses. Authentication, TLS and service-wide failures preserve the current queue item; an article-specific missing/invalid item may skip exactly once to the next item. An all-invalid queue terminates after each item is tried once. Corrupt cache gets one eviction/rebuild attempt, subject to the same deadline; it is not a network retry loop.
6. **Visible recovery.** Recoverable failure retains article identity, queue index, text if available, and valid saved position. Home and Detail expose Play/Retry. Lock-screen and CarPlay Play retry the same current item, including a single article. Dismissing an error hides the message; Stop is a separate action that clears playback intent. After restored normal connectivity, the fixed short-audio fixture must play within 10 seconds of Retry, without relaunch.
7. **Offline behavior.** Valid cached audio plays with zero network requests. With text but no audio, expose “Use device voice”; after the user chooses it, an installed usable voice starts within 5 seconds. No automatic cloud switch when the connection returns during local playback. If text or a usable local voice is absent, give an actionable error and keep Retry and navigation usable. Missing voice assets must not silently initiate an indefinite download.
8. **Playback truth.** Publish playing only after the player/synthesizer actually starts. Playback failure/interruption is not natural completion: preserve queue position and the last valid resume checkpoint. The explicit article-invalid skip in rule 5 is a separate queue transition, never a synthetic completion event. For the same cached cloud audio, resume within ±2 seconds of that checkpoint. Device voice can restart the current article with clear messaging; do not pretend cloud seconds map to speech text. Explicit Stop never auto-resumes when the network returns.
9. **Responsiveness.** Stop/Retry/article selection visibly acknowledge within 1 second on certified physical devices, with a target of 250 ms. Deterministic tests assert the state change on the next scheduled executor turn. OS suspension is not an execution guarantee: a suspended startup must reconcile its elapsed deadline within 1 second of foregrounding and must not begin stale playback on return.

Conceptual state model (these need not become separate enum cases):

```text
idle → loading → playing ↔ paused
         ↓
    retry waiting → loading
         ↓
    recoverable failure ── Retry/new intent ──→ loading
         └──────── Use device voice ─────────→ playing locally

Stop from any state → idle, invalidating all outstanding work.
New article from any state → loading under a new intent.
Automatic queue advancement requires natural completion or the explicit
article-invalid skip policy; network/player errors must not advance it.
```

## Test architecture

### Layer 1: deterministic service and state tests (every PR)

Use existing XCTest and Foundation; no paid API calls, credentials, external network or physical sleeps. Inject a clock/scheduler and seeded jitter for deadlines/backoff. Drive the public service methods and observe states, requests, cache contents and player actions. Assert invariants after every event, not only the final result.

Use a per-session `URLProtocol` fixture transport through the existing `CloudTTSService(apiKey:session:)` and `APIService(session:)` seams. Add session injection to `ArticleContentLoader.load`, which currently uses `URLSession.shared`; include the DetailView caller of that loader. Register handlers per test session rather than in shared global mutable state. Unmatched fixture requests fail the test instead of falling through to the internet. Use a dummy nonempty cloud key so CI does not silently test only the local fallback.

Add only the seams necessary to exercise real orchestration: injectable content loader, cloud synthesizer, cloud/local audio drivers, Now Playing commands, cache root and UserDefaults suite, plus clock/jitter. Keep real cloud HTTP encoding/decoding and real cache files in their integration tests. A fake player supports failure-to-start, delayed start, natural completion, decode error and interruption independently. A controlled late-completion dependency should deliberately ignore cancellation to test the caller's stale-result guards.

Each case owns its temporary directory, preferences, fake clock, request log and callback queue. Teardown must cancel work and verify zero pending requests, retry timers and active outputs. Parallel tests must not share `AppServices.shared`, `NowPlayingService.shared`, system media commands or the user's cache. Isolate the few native-media integration tests in a serial lane.

### Layer 2: real HTTP and UI integration (PR smoke; nightly full suite)

Run a local fixture server with deterministic scenarios: delayed headers/body, bounded transfer rates, truncated responses, reset connections, blackholes and sequenced HTTP status codes. Start it on an ephemeral port and wait for health before launching the app. Provide test-only endpoint and fixture configuration through the app composition root; keep production endpoints and TLS validation unchanged. Mock URL loading alone is not evidence that real URLSession deadlines, TCP behavior, or native audio recover correctly.

Add an XCUITest target and a test configuration that wires the fixture server into both content and synthesis endpoints. Its debug-only control channel holds/releases responses at named barriers and returns request counts. Restrict any development transport exception to the fixture build. Physical devices use an isolated lab endpoint reachable from the device; `localhost` there is the phone. Any platform local-network permission needed by the harness must be provisioned and recorded before measuring application recovery.

Use real MP3/WAV fixtures and AVAudioPlayer for integration tests. Assert player start, advancing playback time, matching article identity and eventual natural completion. UI automation independently checks enabled/accessibility-labelled Play/Retry/Stop controls and observes an action taking effect. Timing comparisons use monotonic clocks. Avoid fixed sleeps; wait on events with outer test timeouts.

### Layer 3: physical-device network and audio chaos (nightly subset; release gate)

Use Apple device network conditions/Network Link Conditioner or an isolated lab network for bandwidth, latency and loss. Verify the applied profile using a calibration transfer, disable unintended Wi-Fi/cellular escape paths for fixed-profile cases, and restore settings afterward. Use actual Wi-Fi/cellular changes for handover tests; a fixture HTTP 503 does not simulate radio handover. Do not impair the developer's general connection or production services.

Observe speaker/headset output using a loopback/recording fixture where available, otherwise a recorded manual audible check. Software `isPlaying` is insufficient evidence for Bluetooth, session activation or device voice. Capture OS build, app revision, audio route, power/thermal state and installed voice assets. Simulator-only results cannot certify hardware audio or modem recovery.

## Fixtures and fault profiles

Fixtures: short single-chunk article; long article requiring at least three TTS chunks; Unicode article near the 4,500-byte split boundary; insight brief JSON; three-item playlist A/B/C; valid MP3; valid mono PCM WAV chunks with distinct tones and known sample counts; malformed JSON/base64; audio lengths 0/1/43 bytes; invalid WAV headers; cached corrupt audio. Record payload byte counts, audio duration and hashes in a manifest. Use distinguishable tracks to detect old audio or duplicated/reordered chunks.

All rates below are **kilobits per second**, not bytes; RTT is round-trip latency. These are lab profiles, not promises about particular mobile standards. Configure per-direction delay as half the RTT. Loss is independent in each direction; seed it where the impairment tool supports seeds, otherwise record it as stochastic device coverage.

| Profile | Download / upload | RTT / jitter | Packet loss | Purpose |
| --- | --- | --- | --- | --- |
| N0 normal | 10,000 / 5,000 | 40 ms / 0 | 0% | Baseline and restored connectivity |
| N1 weak | 256 / 128 | 600 ms / ±100 ms | 2% | Slow request and response |
| N2 woods | 64 / 32 | 1,500 ms / ±500 ms | 10% | User incident stress profile |
| N3 intermittent | N1 for 5 s, total blackhole for 10 s; repeat 3 times, then N0 | N1 | 100% during blackout | Repeated loss and recovery |
| N4 connected but unusable | Route remains up; drop all packets for 60 s, then N0 | No responses | 100% | False “online” signal and bounded startup |
| N5 slow drip | 1 KiB body fragment every 4 s; no final EOF | Otherwise N0 | 0% | Progress must not extend the overall deadline forever |
| N6 asymmetric | 5,000 / 16, then 16 / 5,000 | 600 ms / ±100 ms | 2% | Large synthesis POST upload versus audio response |

Separately inject DNS failure, TLS trust failure, connection reset, offline before launch, and HTTP errors. Deliver HTTP 200 with a captive-portal HTML body for both content and synthesis endpoints; never speak/cache a login page as an article. Fault points: before request, after headers, at 25% and 90% response, between chunks 1/2 and 2/3, immediately before/after cache commit, and immediately before native playback starts.

## Scenario catalogue

All cases inherit the recovery contract and teardown assertions. “P0” means release-blocking regression coverage, not a claim of an ongoing production outage. Run time-based edges just before, at and just after the relevant deadline using the fake clock.

| ID / gate | Setup and injection | Required observations |
| --- | --- | --- |
| C01 / P0 | Native iPhone 14 Pro incident: cached text, no audio; N2; fail synthesis after headers; press Play again, select B, restore N0; never terminate process | Same process ID throughout; controls respond; B plays; error for A cannot replace B; no stuck spinner. Repeat with failure during content fetch and with a playlist. |
| C02 / P0 | Fail A, Retry A before old success/error returns; repeat A→B→A and nil-URL service playback | Unique intent wins even when URL matches; old success/error/finish callbacks have no visible effect; only one output. |
| C03 / P0 | Stop while content fetching, synthesis, backoff, cache write or player startup; release old callback; restore network | Remains idle, no audio, no queue advancement, no new requests. Repeat new article selection instead of Stop and require new article success. |
| C04 / P0 | First request times out/resets; second succeeds. Then first two fail and third succeeds. Then all fail | Exact failed-request retry budget, jitter bounds and deadline; success clears error; exhausted case exposes working manual Retry. Explicitly verify user Retry starts a fresh intent. |
| C05 / P0 | N4 and N5 with no cached audio, single and multi-chunk text | At 45 s recoverable failure; no indefinite wait despite route-up or incoming bytes. Retry on N0 succeeds within fixture budget. |
| C06 / P0 | Error on Detail; navigate Home; issue Play from Home, lock screen and CarPlay, each in fresh case | Same item retried on each surface, including single-item playback; visible errors/actions accessible; dismissal does not discard recoverable item. |
| C07 / P0 | Playlist A/B/C; inject cloud and article HTTP 429/503, JSON error body and plain body variants | Retain A and queue index; preserve status/Retry-After; no cascade through B/C. Transport offline, 401/403 and TLS variants also preserve queue. |
| C08 / P0 | Cache valid text/audio, restart app offline, play and seek; drop network after playback begins | No playback network requests; cached playback advances and completes. Current downloaded track keeps playing across loss; next uncached item follows recovery policy. |
| C09 / P0 | Offline, text cached/audio absent; choose device voice; repeat missing voice and missing text | Installed voice produces audible speech in ≤5 s with no cloud request; unavailable prerequisites give actionable error and working Retry. Reconnection never starts a second voice. |
| C10 / P0 | Fail chunk 2 of 3, retry succeeds; separately cancel before chunk 3; return short/corrupt chunk data | Final complete WAV has expected sample count, order and duration, no duplicated chunk; successful chunks requested once; no partial cache publication or crash for 0/1/43-byte payloads. |
| C11 / P0 | Player returns false, session activation fails, decode fails, finish callback says unsuccessful | Never claim playing without start; error is recoverable; do not treat unsuccessful finish as natural completion or skip queue. Later valid play succeeds. |
| C12 / P0 | Fill/inject disk-write failure, interrupt cache publication, delete file between lookup/play, or use corrupt cache | No crash or poisoned permanent cache hit; valid entries preserved; corrupt entry rebuilt at most once, or actionable failure offline; next valid article remains playable. |
| C13 / P1 | Ten Play/Retry taps in 1 s; Next/Previous/Stop while callbacks reorder | Coalesced same-intent load, no retry storm, latest explicit selection wins, correct Now Playing title and enabled commands. |
| C14 / P1 | 429/503 with Retry-After: 3 s, future HTTP date, 120 s, malformed, past; tap Retry repeatedly; switch A→B on same and different content origins | Correct minimum wait; beyond-deadline case fails usefully without waiting 120 s; invalid/past value uses local backoff; taps and article changes do not bypass applicable cooldown. Synthesis cooldown spans articles; content cooldown spans its origin only; cached/local playback and unrelated service/origin requests remain usable. |
| C15 / P1 | Article 404 or malformed content at A, then valid B; all three articles invalid | Skip one article at a time, bounded by queue size; no wraparound/infinite retry; error shown if no playable item. Service-wide errors never use this policy. |
| C16 / P1 | Wi-Fi→cellular→Wi-Fi mid-upload/download; toggle airplane mode; restrict cellular access | Current request resolves or fails within bound; same-process Retry works; no assumption that interface available means endpoint reachable. |
| C17 / P1 | Background/lock during loading and during playing; outage while suspended; foreground after deadline | Expired startup reconciles in ≤1 s on foreground; active audio respects intended background behavior; no stale auto-start or position reset. |
| C18 / P1 | Call/Siri interruption, Bluetooth disconnect/reconnect, route change during retry/start/playing | No simultaneous voices or unexpected speaker playback on headphone removal; pause safely; explicit Play recovers correct article after route/session availability returns. |
| C19 / P1 | Cached track paused at known checkpoint, error on another item, return to first | Resume at correct per-article checkpoint ±2 s; never save another item's position; natural finish alone clears completion position. |
| C20 / P1 | Corrupt JSON/base64, captive portal, invalid encoding, wrong content type, invalid WAV sizes | No crash, no spoken HTML/login/error body, no bad cache entry; recover by loading a valid article. Nonretryable input does not consume endless retry attempts. |
| C21 / P1 | N1/N2/N6 with short/long/Unicode/insight-brief fixtures, cold and warm cache | Short fixture succeeds if it fits deadline; large payload either completes correctly or exposes bounded recovery; no text loss, wrong chunk order or stale configuration. |
| C22 / P1 | Low Power Mode, supported thermal stress, memory pressure and nearly-full storage while network flaps | UI contract holds; no crash/watchdog, leaked tasks or lost controls. Inject deterministic allocation/disk failures in tests where real pressure cannot be controlled safely. |
| C23 / P1 | Terminate process during cache write; relaunch offline | Valid committed cache still usable; incomplete entry rejected; no spontaneous audio on relaunch. Process termination is a resilience test, never the recovery step for C01. |
| C24 / P1 | Seeded action/fault sequence: play, retry, stop, next, previous, pause, resume, voice change, route/network changes | Invariants hold after every event; report/shrink failing sequence into a permanent regression; old voice/rate configuration cannot publish as the new intent. |

## Exact incident regression script

1. Record device/OS/app build and process identifier. Use a test install with fixture A/B, cached text and cleared audio entries only. Set N2 and cloud mode explicitly.
2. Tap Listen on A. Hold its response after headers, then fail it with `networkConnectionLost`. Allow the bounded retry policy to exhaust using the fake clock in unit tests or controlled wall time in integration tests.
3. Verify recoverable error and enabled Play/Retry. Tap Play once. Hold this new request, then choose B. Deliver old A success and error callbacks in separate variants after B has started loading and after B starts playing.
4. Restore N0 and let B return valid audio. Verify B's playback time advances for at least 3 seconds, correct Now Playing title, no A audio/error, and unchanged process identifier.
5. Stop B, return to A and tap Play. Verify A now plays in the same process. Run again from Home, a single-item remote command, and a playlist command. Include a variant in which the network never returns: controls must still work and errors must remain bounded.
6. Save UI video, timestamped event/request log and actual audio evidence on hardware. A pass after force-quit is a failure.

## Device and scheduling matrix

| Lane | Matrix and work | Gate |
| --- | --- | --- |
| Every PR | All deterministic C01–C24 variants; simulator UI C01–C07/C11; simulated native audio smoke. Fixed simulator runtime/toolchain recorded in artifacts. | 100% required cases pass; no rerun-to-green. Aim for <10 min by keeping timing tests virtual. |
| Nightly | Full real-HTTP suite; 100 seeded model runs × 200 actions; simulator minimum supported iOS 17 and newest supported runtime available in CI. Seed = committed base + run index, recorded explicitly. | Failures block promotion until triaged; minimize and replay with recorded seed/event order. |
| Physical nightly subset | iPhone 14 Pro with reported iOS 27.2 if available; record exact build. C01/C03/C08/C16/C18; rotate remaining profiles. | No wedge/crash/incorrect-track playback. If this OS/device combination is unavailable, mark incident qualification pending, not passed by substitution. |
| Before release | Oldest supported iPhone available at minimum supported OS, iPhone 14 Pro incident device, current-generation iPhone, one supported iPad; built-in speaker, wired output where supported, Bluetooth; CarPlay for C06/C18. | C01–C12 applicable hardware cases pass per device; C13–C24 pairwise across device/network/route/power/cache dimensions. Record exact coverage. |
| Weekly soak | 60-minute network/action chaos on oldest device and incident device; 100 start/fail/retry/stop cycles; N3 plus route changes | Zero crashes/wedges/unexpected playback; no retained-task growth; memory and disk checks below. |

Use real supported combinations: do not require a new device to run an OS it cannot install. Capture hardware, OS, build mode and coverage in a versioned lab manifest. Use Release configuration for device performance qualification, with diagnostic instrumentation enabled in the fixture build. The iOS target currently declares iOS 17.0 and iPhone/iPad families; revisit the manifest whenever deployment targets change.

If Flutter is shipped, mirror C01–C05/C08–C09/C13/C16–C23 for `apps/mobile/lib/services/api_service.dart`, `tts_service.dart`, `connectivity_service.dart` and their screens. Use existing injected HTTP client for network cases and a fake platform TTS channel for callback races. Add physical low-memory Android at the declared minimum supported Android version, current Android, and supported Flutter iOS. Verify installed/offline versus network-required voice engines separately. Cloud synthesis/chunk assertions apply only to native Swift; Flutter cannot inherit Swift certification.

## Oracles, diagnostics and release evidence

- Correlate every event by test ID, seed, playback intent ID, request/chunk/attempt, article fixture ID and monotonic timestamp. Log state transitions, timeout reason, HTTP status, bytes received, cache hit/write/eviction, player start result, route and cancellation. Redact API keys, authorization, full article text and personal URLs.
- Assert request counts by logical chunk, not just totals: baseline one per chunk, at most two additional network attempts across an intent. Cache hits require zero network. Cancelled attempts may finish at the transport but cannot mutate active state.
- Measure Retry-to-audio, time in loading, cancellation acknowledgement, queue index, position restoration and actual output. Report distributions by profile/device without averaging away the slowest supported device. C01 and all deterministic safety invariants tolerate zero failures; timing gates are per-run upper bounds, with p50/p95 reported as diagnostics.
- For the 100-cycle soak, warm 10 cycles, stop and drain work, then compare median idle resident memory for cycles 11–20 versus 91–100: growth ≤ max(10 MiB, 10% of initial idle median). Capture memory graphs on failure; allocator noise is not automatically a leak, but the gate needs triage rather than silent relaxation. Pending tasks/timers/output must return to zero after every Stop. With the same fixture cache, file count and bytes must stabilize after warm-up; across distinct audio keys, cleanup returns audio count to the existing 20-entry retention policy and leaves no partial files.
- Upload `.xcresult`, JUnit summary, fixture scenario/seed, request log, OS/device manifest and failure video/audio. Keep failed-run evidence; reruns diagnose flakiness and do not erase the original failure. Replay the minimal failing sequence before any fix is accepted.
- Infrastructure failure (server unavailable, missing OS/device, uncalibrated link) is “not qualified”, never an application pass. Require evidence that the fault actually happened. Keep live-provider staging checks separately labelled; they do not replace deterministic tests and should use a budgeted test account.

## Delivery sequence and proposed files

This is a design deliverable, not authorization to ship a recovery-policy change. Implement tests and any fixes in separate reviewable steps; preserve existing unrelated working-tree edits.

1. **Pin the incident:** add `EngPulseTests/TTSRecoveryTests.swift`, `Support/ScriptedURLProtocol.swift`, `Support/TestClock.swift`, `Support/PlaybackSpies.swift` and fixtures. Add injection seams in `TTSService`, `ArticleContentLoader`, `CacheService`, and app composition; first demonstrate C01–C03 failure against existing behavior. Do not lock tests to today's broken UI state.
2. **Transport and cache:** add `CloudTTSChaosTests.swift`, `ArticleContentLoaderChaosTests.swift`, `AudioCacheRecoveryTests.swift` and `AudioPlayerRecoveryTests.swift`. Cover C04–C05/C07–C12/C14–C15/C19–C21 with exact counts, errors, deadlines and output hashes. Fixes to retry, cache, cancellation and status preservation are independent production work driven by these failing cases.
3. **Control surfaces:** add `EngPulseUITests/PlaybackRecoveryUITests.swift`, a UI test target, shared test scheme/plan and fixture launch wiring. Exercise Home, Detail, remote-command handler and CarPlay paths. Include local voice availability and real player-start tests. Do not install fake transport into production builds.
4. **Real transport and CI:** add `tests/chaos/fixture_server.py`, `tests/chaos/scenarios/`, `tests/chaos/fixtures/manifest.json` and `scripts/test-playback-chaos.sh`; extend `.github/workflows/ci.yml` and add scheduled `.github/workflows/playback-chaos.yml`. Runner must discover a valid simulator, await server health, propagate nonzero test exits, archive artifacts and clean up server/processes/network profiles even on failure. Register every new Swift test source in the existing Xcode project.
5. **Hardware qualification:** add `tests/chaos/device-matrix.json` with actual lab inventory and `docs/testing/playback-chaos-runbook.md` for conditioning, audio evidence and C01. Run release gates before describing the incident as fixed. Add the Flutter parity lane only if that app is in the release scope.

Each step is complete when its named scenarios have been observed failing under the intended fault where appropriate, then passing with the recovery behavior, with a normal-network control passing too. Retain deterministic pre-fix repro evidence. No new chaos framework dependency is required initially; add a network impairment tool only for effects the local HTTP server and Apple device tools cannot provide.

## Platform references

- Apple describes device network conditions and testing transitions during an operation in [Test under adverse device conditions](https://help.apple.com/xcode/mac/current/en.lproj/dev308429d42.html).
- Apple recommends exercising changing network conditions and device Network Link Conditioner in [Adapt to changing network conditions](https://developer.apple.com/videos/play/tech-talks/111378/).
- Foundation exposes connectivity waiting through [`waitsForConnectivity`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/waitsforconnectivity). Waiting is not a substitute for application retry and cancellation policy; C04–C05 exercise those separately.

No chaos tests, builds, device sessions or incident reproduction were run while preparing this design. Source inspection supports the risks above; the suite supplies the evidence needed to confirm the cause and validate fixes.
