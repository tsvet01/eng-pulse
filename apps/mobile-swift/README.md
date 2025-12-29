# Mobile App (Swift)

Native iOS app for viewing AI-curated daily software engineering summaries.

> Part of [Eng Pulse](../../README.md) - see root README for system overview.

## Features

- **Daily Summaries**: View AI-generated article summaries with markdown rendering
- **Model Filter**: Filter by AI model (Gemini, Claude, GPT) via toolbar menu
- **Text-to-Speech**: Listen to articles with adjustable speed and pitch
- **Push Notifications**: APNs integration for new summary alerts
- **Offline Support**: Local caching for offline reading
- **Pull to Refresh**: Manual refresh for latest content
- **Share**: Share articles with other apps
- **Original Links**: Direct links to source articles

## Architecture

```
EngPulse/
├── EngPulseApp.swift           # App entry, AppDelegate, AppState
├── Models/
│   └── Summary.swift           # Article model with categories
├── Views/
│   ├── ContentView.swift       # Main TabView with navigation
│   ├── HomeView.swift          # Article list with filter
│   ├── DetailView.swift        # Full article with TTS
│   └── SettingsView.swift      # TTS and notification settings
└── Services/
    ├── APIService.swift        # GCS API client
    ├── CacheService.swift      # UserDefaults caching
    ├── NotificationService.swift # APNs handling
    └── TTSService.swift        # Text-to-speech playback
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
