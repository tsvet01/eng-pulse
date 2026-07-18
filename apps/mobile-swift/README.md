# Mobile App (Swift)

Native iOS app for viewing AI-curated daily software engineering summaries.

> Part of [Eng Pulse](../../README.md) - see root README for system overview.

## Features

- **Daily Summaries**: View AI-generated article summaries with markdown rendering
- **Model Filter**: Filter by AI model (Gemini, Claude, GPT) via toolbar menu
- **Text-to-Speech**: Listen to articles with adjustable speed and pitch
- **CarPlay**: Browse articles in the car and listen to a single article or a playlist with auto-advance
- **Push Notifications**: APNs integration for new summary alerts
- **Offline Support**: Local caching for offline reading
- **Pull to Refresh**: Manual refresh for latest content
- **Share**: Share articles with other apps
- **Original Links**: Direct links to source articles

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

Configure in `APIService.swift`:

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
xcrun devicectl device process launch --device <DEVICE_ID> org.tsvetkov.EngPulseSwift
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
