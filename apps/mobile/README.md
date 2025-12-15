# Mobile App

Flutter mobile app for viewing AI-curated daily software engineering summaries.

> Part of [Eng Pulse](../../README.md) - see root README for system overview.

## Features

- **Daily Summaries**: View AI-generated article summaries
- **Offline Support**: Local caching with Hive for offline reading
- **Push Notifications**: Firebase Cloud Messaging for new summary alerts
- **Pull to Refresh**: Manual refresh for latest content
- **History**: Browse past summaries by date

## Architecture

```
lib/
├── main.dart                # App entry point
├── firebase_options.dart    # Firebase configuration
├── models/
│   └── summary.dart         # Summary data model
├── screens/
│   ├── splash_screen.dart   # Initial loading screen
│   └── summary_screen.dart  # Main summary display
├── services/
│   ├── api_service.dart     # GCS API client
│   ├── cache_service.dart   # Hive local storage
│   └── notification_service.dart # FCM integration
├── theme/
│   └── app_theme.dart       # App theming and styles
└── widgets/
    └── summary_card.dart    # Reusable summary card widget
```

## Setup

### Prerequisites

- Flutter 3.x+
- Dart 3.x+
- iOS/Android development environment

### Installation

```bash
# Install dependencies
flutter pub get

# Run on device/emulator
flutter run
```

### Firebase Setup (Optional)

For push notifications:

1. Create Firebase project
2. Add `google-services.json` (Android) and `GoogleService-Info.plist` (iOS)
3. Enable Cloud Messaging in Firebase Console

## Configuration

The app fetches data from a GCS bucket. Configure the endpoint in `lib/services/api_service.dart`:

```dart
static const _manifestUrl = 'https://storage.googleapis.com/YOUR_BUCKET/manifest.json';
```

## Data Flow

```
GCS Bucket                    Mobile App
    │                             │
    │  manifest.json              │
    │────────────────────────────▶│
    │                             │
    │  summaries/YYYY-MM-DD.md    │
    │────────────────────────────▶│
    │                             │
    │                        ┌────┴────┐
    │                        │  Hive   │
    │                        │  Cache  │
    │                        └─────────┘
```

## Services

### ApiService

Static service for fetching data from GCS:

```dart
// Fetch manifest
final manifest = await ApiService.fetchManifest();

// Fetch summary content
final content = await ApiService.fetchSummary(url);
```

### CacheService

Hive-based local storage:

```dart
// Initialize (call in main())
await CacheService.init();

// Cache summaries
CacheService.cacheSummaries(summaries);

// Retrieve cached
final cached = CacheService.getCachedSummaries();
```

### NotificationService

Firebase Cloud Messaging integration:

```dart
// Initialize
await NotificationService.init();

// Request permissions
await NotificationService.requestPermission();
```

## Testing

```bash
# Run tests
flutter test

# Analyze code
flutter analyze

# Check formatting
dart format --set-exit-if-changed .
```

## Building

### Android

```bash
flutter build apk --release
```

### iOS

```bash
flutter build ios --release
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `http` | HTTP client |
| `hive` / `hive_flutter` | Local storage |
| `firebase_messaging` | Push notifications |
| `firebase_core` | Firebase initialization |
| `flutter_markdown` | Markdown rendering |

## Known Issues

- FCM token registration not fully implemented (see issue #7)
- Widget tests need expansion (see issue #13)

## Related Components

- [daily-agent](../daily-agent/) - Generates the summaries
- [notifier](../../functions/notifier/) - Sends email notifications
