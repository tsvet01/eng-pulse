# Playback recovery verification — 2026-11-01

The recovery fix is local and has not been installed on the reported iPhone 14 Pro / iOS 27.2. The field incident has not been reproduced on that physical device. Its relevant same-process failure modes were reproduced in automated tests before fixing them.

## Changes

- A stopped single article can restart through the shared player button and remote Play command, using retained input text.
- Home keeps the player and error visible after failure. Dismissing an error no longer clears the recoverable article; Stop remains explicit.
- Starting another attempt or stopping cancels cloud/content work. Attempt IDs protect against same-URL retries and older completions.
- Deferred player notifications carry their originating attempt ID, so they cannot move a new download out of loading or cancel its deadline.
- A 45-second startup deadline covers queue content loading and synthesis together. Expiry cancels work and leaves the current item retryable. Tests inject a shorter deadline to exercise expiry without waiting 45 seconds.
- Cloud HTTP status is preserved even with a JSON error body; service outages and rate limits preserve queue position.
- Native audio only reports playing after a successful start, reactivates its session on resume, and ignores callbacks from replaced players. File/decoder errors remain distinct from output failures so one invalid article can be skipped.
- Hosted unit tests disable app-launch notifications, live feed loading and Firebase initialization. Fixture HTTP sessions and cache directories are isolated per test.

## Evidence

New suites: `apps/mobile-swift/EngPulseTests/TTSRecoveryTests.swift` (12 tests) and `AudioPlayerRecoveryTests.swift` (4 tests). They use the real cloud HTTP client with controlled URL loading, plus real AVAudioPlayer tests with generated WAV data. Network faults do not call the speech provider. Native audio progress is checked; physical speaker/Bluetooth audibility is not certified.

Observed red/green sequence:

| Regression | Before fix | After fix |
| --- | --- | --- |
| Single-article remote/shared Play, late same-article error, article-switch cancellation, Stop cancellation, cloud-outage queue retention | All six original tests failed; 14 assertions failed | All six passed |
| Download never returns; retry after timeout | Timeout/retry test failed | Passed |
| Resume without loaded audio; old native completion/decode callback | Three native tests failed | Passed |
| Queued old player events during article switch or Stop | Both ordering tests failed | Passed |
| Invalid audio followed by valid queued article | Test failed | Passed with real audio on the next article |

Full-suite results with Xcode 27.2:

- iPhone 17 Pro simulator / iOS 26.5: **67 tests passed, zero failures**, Xcode exit 0. Result bundle: `/tmp/engpulse-chaos-build/Logs/Test/Test-EngPulse-2026.11.01_11-22-57-+0000.xcresult`.
- iPhone 16 Pro simulator / iOS 18.4: **67 tests passed, zero failures**, Xcode exit 0. Result bundle: `/tmp/engpulse-chaos-build/Logs/Test/Test-EngPulse-2026.11.01_11-23-35-+0000.xcresult`.
- Independent code review rechecked the ordering, error classification and test fixes; no remaining consequential findings in that review.
- `git diff --check` passed. An existing Swift concurrency warning remains in `SettingsView.swift:290` (directory enumeration in an async context); it is outside this playback change. Xcode also emits the benign “no AppIntents.framework dependency” metadata warning.

Local execution logs are in `/tmp/engpulse-chaos-*.log`; temporary paths may be cleaned by the OS. The tests are registered in the shared EngPulse test scheme, so the existing Swift CI job will run them.

To rerun, select an installed simulator UDID from `xcrun simctl list devices available`, then run from the repository root:

```sh
xcodebuild test -project apps/mobile-swift/EngPulse.xcodeproj \
  -scheme EngPulse -destination 'platform=iOS Simulator,id=<UDID>' \
  CODE_SIGNING_ALLOWED=NO
```

## Remaining qualification

The complete chaos design is broader than this incident fix. Automatic network retries/backoff/cooldowns, runtime local-voice fallback, real bandwidth/loss conditioning, seeded soak tests, low-memory/storage faults and the full device/CarPlay matrix are not implemented or certified by this change. The tests cover manual retry, delayed/failed/hung requests, cancellation, cache playback and audio lifecycle races. No UI automation suite was added; Home/Detail compile and share the tested service entry points.

On the reported phone, install a development build containing this change, then start an uncached article under weak signal, toggle airplane mode during preparation, restore connectivity and press Play. Repeat by selecting another article before the first attempt completes. Confirm audio starts without force-quit, Home/Detail retain working controls, and Stop prevents later playback. Also verify Bluetooth and lock-screen Play. Record the exact OS/app build. Neither the reported iOS 27.2 runtime nor minimum iOS 17 was installed locally, so those versions remain unqualified.

## Release integration

The fix was ported from the older local checkout onto current main `e4f205b` in `codex/playback-recovery`, preserving the current pilot account isolation, cache implementation and newer playback UI. Independent review found no consequential issues in this port. Current-main validation: **103 iOS simulator tests** and **58 Swift package tests** passed; both brief contract fixtures decoded. The additional UI test verifies a retryable item remains visible in the current library player.

The paired physical device was confirmed as iPhone 14 Pro, iOS 27.2 build 24B119. A signed Release build numbered `2026110101` is being prepared for direct installation. As in the existing device runbook, the temporary phone-build entitlement file omits the unapproved CarPlay capability; repository entitlements remain unchanged. Phone installation/launch is a separate step from the automated test results above.
