# Mobile App (Swift)

Native iOS app for viewing AI-curated daily software engineering summaries.

> Part of [Eng Pulse](../../README.md) - see root README for system overview.

## Existing reader features

- **Daily Summaries**: View AI-generated article summaries with markdown rendering
- **Model Filter**: Filter by AI model (Gemini, Claude, GPT) via toolbar menu
- **Text-to-Speech**: Listen to articles with adjustable speed and pitch
- **CarPlay**: Browse articles in the car and listen to a single article or a playlist with auto-advance
- **Push Notifications**: APNs integration for new summary alerts
- **Offline Support**: Local caching for offline reading
- **Pull to Refresh**: Manual refresh for latest content
- **Share**: Share articles with other apps
- **Original Links**: Direct links to source articles

The renamed pilot build connects admitted accounts to the Hetzner engineering feed, with saved offline articles and listening. Feedback and notification delivery remain gated; their legacy controls are hidden in the pilot.

## Architecture

```
EngPulse/
├── EngPulseApp.swift           # App entry, AppDelegate, AppState
├── AppServices.swift           # Shared service container (app + CarPlay scenes)
├── Models/
│   └── Summary.swift           # Article model with categories
├── Views/
│   ├── ContentView.swift       # Main TabView with navigation
│   ├── HomeView.swift          # Article list with filter
│   ├── DetailView.swift        # Full article with TTS
│   └── SettingsView.swift      # TTS and notification settings
├── CarPlay/
│   ├── CarPlaySceneDelegate.swift   # CarPlay scene entry point
│   ├── CarPlayContentManager.swift  # Tab/list templates, playback wiring
│   └── CarPlayContentBuilder.swift  # Pure list-shaping logic (tested)
└── Services/
    ├── APIService.swift        # GCS API client
    ├── ArticleContentLoader.swift # View-independent content fetching
    ├── CacheService.swift      # UserDefaults caching
    ├── NotificationService.swift # APNs handling
    ├── SpeechTextBuilder.swift # Spoken text (handles insight-brief JSON)
    └── TTSService.swift        # Text-to-speech playback + playlist queue
```

## Requirements

- iOS 17.0+
- Xcode 15+
- Apple Developer account (for device testing)

## Setup

### Pilot app identity

The pilot bundle ID is `org.tsvetkov.eng-pulse`; the display name remains **Eng Pulse**. Before distributing a device build, complete the [app identity setup](../../docs/runbooks/phase0-setup.md#pilot-app-identity).

This installs as a separate app from `org.tsvetkov.EngPulseSwift`, with separate local data and device tokens. The existing GCP notifier still targets the old app. The pilot's API device registration and APNs sender must be ready before enabling notifications for the new app; do not change the legacy sender's default bundle ID. Firebase Auth remains in source for explicit legacy builds. The new bundle never initializes Firebase, registers a token with the legacy sender, submits legacy feedback, or opens the legacy cache. The CI Firebase plist is a build placeholder, not a working configuration.

### Pilot reader

The build defaults to `PILOT_AUTH_ENABLED=YES` for `org.tsvetkov.eng-pulse`. Native Apple and email-code sign-in use Supabase; `/v1/me` confirms admission and the active engineering membership gates feed reads. An admitted account opens the existing reading screen. All phone windows and CarPlay share one account, reader and playback service.

The API returns the latest 100 brief summaries. The app prefetches the latest five complete V3 payloads and saves downloaded articles under the Supabase identity, API user and engineering feed. Playback positions and audio are account-scoped too. A cold offline restart requires a matching saved identity and prior API admission with verified active engineering membership; first-time accounts cannot enter during an outage. Sign-out closes every reader and stops playback. A server denial clears cached admission; revocation cannot be detected while fully offline. Pilot content never falls back to public GCS, and bearer tokens are sent only to the configured API.

1. Copy `Secrets.xcconfig.example` to the ignored `Secrets.xcconfig` if it does not exist. Set `SUPABASE_PUBLISHABLE_KEY` to this project's **public publishable key**, never the service-role key, SMTP password, or signing key. Keep actual configuration out of git.
2. The tracked `EngPulse/Info.plist` uses build-setting substitutions for credentials. Keep it that way; actual values belong in the ignored `Secrets.xcconfig`. `Info.plist.template` has matching pilot substitutions if a fresh template is needed.
3. For simulator builds, use the tracked `GoogleService-Info.plist.ci` placeholder as the ignored `EngPulse/GoogleService-Info.plist` build resource. Firebase is not initialized in pilot mode.
4. Run the app. Sign-in uses the configured Supabase project; admission uses `https://api.eng-pulse.tsvetkov.org/v1`. The API is deployed, engineering history is populated, and the administrator has completed email-code admission. Use that same sign-in method/account; a separate Apple identity may still need its own invitation.
5. Use a signed device build to verify native Apple sign-in. Existing legacy readers are preserved; an explicit legacy development build must use both `PILOT_AUTH_ENABLED=NO` and the old `org.tsvetkov.EngPulseSwift` bundle ID with matching Firebase/provisioning settings.

Automated authentication tests use fake server responses and send no emails.

```bash
swift test --package-path apps/mobile-swift
xcodebuild -project apps/mobile-swift/EngPulse.xcodeproj -scheme EngPulse \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  SUPABASE_PUBLISHABLE_KEY=public-test-placeholder test
```

The simulator needs local ad-hoc signing for the Keychain integration test; disabling signing prevents secure-storage access. CI runs the package tests and existing iOS suite, and checks the built app contains the pilot settings. The full two-account device journey, physical CarPlay provisioning, feedback queues, device cleanup and actual notification delivery remain launch gates in the [pilot plan](../../docs/superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md).

### Build and Run

```bash
# Open in Xcode
open apps/mobile-swift/EngPulse.xcodeproj

# Or build from command line
cd apps/mobile-swift
xcodebuild -scheme EngPulse -sdk iphoneos -configuration Debug
```

### Device Testing

1. Connect iPhone via USB
2. Enable Developer Mode: **Settings > Privacy & Security > Developer Mode**
3. Open project in Xcode, select your team in **Signing & Capabilities**
4. Build and run on device

### Push Notifications

The app uses native APNs (not Firebase). To enable:

1. Add Push Notifications capability in Xcode
2. Create APNs key in Apple Developer portal
3. Configure backend to send notifications via APNs

The app registers its device token with the backend at:
```
https://us-central1-tsvet01.cloudfunctions.net/register-apns-token
```

## Data Flow

```
GCS Bucket                    iOS App
    │                             │
    │  manifest.json              │
    │  (article list)             │
    │────────────────────────────>│
    │                             │  ┌───────────┐
    │  summaries/YYYY-MM-DD.md    │  │ UserDefs  │
    │  (full content)             │──│   Cache   │
    │────────────────────────────>│  └───────────┘
    │                             │
```

## Key Components

### AppState

Main app state with summaries, loading state, and offline mode:

```swift
@MainActor
class AppState: ObservableObject {
    @Published var summaries: [Summary] = []
    @Published var isLoading = false
    @Published var isOffline = false
}
```

### NotificationService

Handles APNs registration and notification taps:

```swift
// Set delegate early in AppDelegate
UNUserNotificationCenter.current().delegate = NotificationService.shared

// Handle notification tap - navigates to article
func userNotificationCenter(_:didReceive:withCompletionHandler:)
```

### TTSService

Text-to-speech with AVSpeechSynthesizer:

```swift
// Play/pause toggle
ttsService.togglePlayPause(content, articleUrl: url)

// Adjust settings
@AppStorage("ttsSpeechRate") var speechRate: Double = 0.55
@AppStorage("ttsPitch") var pitch: Double = 1.0
```

## CarPlay

The app registers a CarPlay audio scene (`CPTemplateApplicationSceneSessionRoleApplication`
in `Info.plist`, delegate `CarPlaySceneDelegate`) with two tabs:

- **Latest**: newest articles first, plus a "Play All" playlist row
- **Topics**: articles grouped by inferred category, each with its own "Play All"

Tapping an article plays just that article; "Play All" queues the list as a
playlist that auto-advances and supports next/previous track from the CarPlay
now-playing screen (backed by the same `TTSService` queue the phone uses, so
playback state stays in sync across both screens).

### Requirements

- The `com.apple.developer.carplay-audio` entitlement is declared in
  `EngPulse.entitlements`. Running on a physical device requires CarPlay
  entitlement approval from Apple
  (request at https://developer.apple.com/contact/carplay/) and a provisioning
  profile that includes it. Simulator builds (including CI) are unaffected.

### Testing in the Simulator

1. Run the app in an iOS Simulator from Xcode
2. In the Simulator menu bar: **I/O → External Displays → CarPlay**
3. The Eng Pulse icon appears on the CarPlay home screen

## Model Filtering

Filter articles by AI model via toolbar menu:

| Filter | Matches |
|--------|---------|
| All | All articles |
| Gemini | `gemini` in model name |
| Claude | `claude` in model name |
| GPT | `gpt` or `openai` in model name |

Selection persists via `@AppStorage`.

## Configuration

### API Endpoint

The pilot uses `https://api.eng-pulse.tsvetkov.org/v1` from `PilotConfiguration`. The explicit legacy build uses `APIService.swift`:

```swift
private let baseURL = "https://storage.googleapis.com/tsvet01-agent-brain"
```

### Notification Registration

Configure in `NotificationService.swift`:

```swift
let url = URL(string: "https://us-central1-tsvet01.cloudfunctions.net/register-apns-token")
```

## Testing

### Simulator

```bash
xcodebuild -scheme EngPulse -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Device

```bash
# Install on connected device
xcrun devicectl device install app --device <DEVICE_ID> build/Debug-iphoneos/EngPulse.app

# Launch
xcrun devicectl device process launch --device <DEVICE_ID> org.tsvetkov.eng-pulse
```

### Send Test Notification

```bash
curl -X POST "https://us-central1-tsvet01.cloudfunctions.net/trigger-apns-notification" \
  -H "Content-Type: application/json" \
  -d '{"title": "Test", "body": "Tap to open", "article_url": "..."}'
```

## Related Components

- [daily-agent](../daily-agent/) - Generates the summaries
- [mobile](../mobile/) - Flutter version of the app
- [notifier](../../functions/notifier/) - Email notifications
