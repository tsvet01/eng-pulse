# Mobile App

Flutter mobile app for viewing AI-curated daily software engineering summaries.

> Part of [Eng Pulse](../../README.md) - see root README for system overview.

## Features

- **Daily Summaries**: View AI-generated article summaries with full markdown rendering
- **Multi-Model Support**: Switch between Gemini, OpenAI, and Claude summaries
- **Offline Support**: Local caching with Hive for offline reading
- **Push Notifications**: Optional Firebase Cloud Messaging for new summary alerts
- **Pull to Refresh**: Manual refresh for latest content
- **Reading History**: Track read articles with visual indicators
- **Dark Mode**: System-aware dark/light theme
- **Share**: Share summaries with other apps
- **Original Links**: Direct links to source articles

## Architecture

```
lib/
├── main.dart                    # App entry point
├── firebase_options.dart        # Firebase configuration (optional)
├── models/
│   ├── summary.dart             # API response model
│   ├── cached_summary.dart      # Local cache model
│   └── reading_history.dart     # Reading history model
├── screens/
│   ├── splash_screen.dart       # Initial loading screen
│   ├── home_screen.dart         # Main summary list
│   ├── detail_screen.dart       # Full article view
│   └── settings_screen.dart     # App settings
├── services/
│   ├── api_service.dart         # GCS API client
│   ├── cache_service.dart       # Hive local storage
│   ├── connectivity_service.dart # Network status
│   ├── notification_service.dart # FCM integration
│   └── user_service.dart        # User preferences & history
├── theme/
│   └── app_theme.dart           # App theming and styles
└── widgets/
    ├── summary_card.dart        # Summary list card
    ├── empty_state.dart         # Empty/error states
    ├── feedback_widget.dart     # Article feedback
    ├── offline_banner.dart      # Offline indicator
    └── shimmer_loading.dart     # Loading placeholder
```

## Setup

### Prerequisites

- Flutter 3.x+
- Dart 3.x+
- Xcode (for iOS/macOS)
- Android Studio (for Android)

### Installation

```bash
# Install dependencies
flutter pub get

# Run on connected device/emulator
flutter run

# Run on specific platform
flutter run -d macos
flutter run -d chrome
flutter run -d <device-id>  # Use `flutter devices` to list
```

### iOS Device Setup

To run on a physical iPhone:

1. Connect iPhone via USB
2. Enable Developer Mode: **Settings → Privacy & Security → Developer Mode**
3. Open `ios/Runner.xcworkspace` in Xcode
4. Select your Apple Developer team in **Signing & Capabilities**
5. Run: `flutter run -d <device-id> --release`

### Firebase Setup (Optional)

Firebase is **optional**. The app works without it (push notifications disabled).

To enable push notifications:

```bash
# Install FlutterFire CLI
dart pub global activate flutterfire_cli

# Configure Firebase (requires Firebase project)
flutterfire configure --project=YOUR_PROJECT_ID
```

This generates `firebase_options.dart` with your credentials.

## Configuration

### API Endpoint

The app fetches data from a GCS bucket. Configure in `lib/services/api_service.dart`:

```dart
static const String defaultBucket = 'your-bucket-name';
```

### UTF-8 Support

The app properly handles UTF-8 encoded content, including non-ASCII characters (Cyrillic, CJK, etc.) in article titles and content.

## Data Flow

```
GCS Bucket                    Mobile App
    │                             │
    │  manifest.json              │
    │  (article list)             │
    │────────────────────────────▶│
    │                             │  ┌─────────┐
    │  summaries/YYYY-MM-DD.md    │  │  Hive   │
    │  (full content)             │──│  Cache  │
    │────────────────────────────▶│  └─────────┘
    │                             │
```

## Services

### ApiService

Fetches data from GCS with caching:

```dart
final apiService = ApiService();

// Fetch manifest with summaries
final summaries = await apiService.fetchSummaries();

// Fetch full markdown content
final content = await apiService.fetchMarkdown(url);

// Pre-cache for offline
await apiService.preCacheContent(summaries);
```

### CacheService

Hive-based local storage:

```dart
// Initialize (call in main())
await CacheService.init();

// Cache summaries
await CacheService.cacheSummaries(summaries);

// Retrieve cached
final cached = CacheService.getCachedSummaries();

// Check content cache
final hasContent = CacheService.hasContent(url);
```

### NotificationService

Firebase Cloud Messaging (optional):

```dart
// Check if available (Firebase configured)
if (NotificationService.isAvailable) {
  await NotificationService.subscribeToTopic('daily_briefings');
}

// Check notification status
final enabled = await NotificationService.areNotificationsEnabled();
```

### UserService

Reading history and preferences:

```dart
// Initialize
await UserService.init();

// Track reading
await UserService.addToHistory(summary);

// Check if read
final isRead = UserService.isRead(articleUrl);

// Model preferences
final model = UserService.getSelectedModel();
await UserService.setSelectedModel('claude');
```

## Multi-Model Support

The app supports summaries generated by different LLM providers. Each summary in the manifest includes a `model` field indicating which model generated it.

### Available Models

| Model | ID | Description |
|-------|-----|-------------|
| Gemini | `gemini-3-pro-preview` | Google Gemini |
| OpenAI | `gpt-5.2-2025-12-11` | OpenAI GPT |
| Claude | `claude-opus-4-5` | Anthropic Claude |

### Model Selection

- The model selector appears in the app bar when multiple models are available
- User's selection is persisted and restored on app launch
- Model matching supports both full IDs (`claude-opus-4-5`) and vendor names (`claude`) for backwards compatibility

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

### Development Build with Version Tracking

Use the build script to inject git commit and build time:

```bash
# Make executable (first time only)
chmod +x build.sh

# Debug build on connected device
./build.sh

# Specify device
./build.sh -d <device-id>

# Release build
./build.sh --release

# Combined
./build.sh -d <device-id> --release
```

The script injects:
- `GIT_COMMIT` - Short git commit hash (e.g., `3290cc2`)
- `BUILD_TIME` - UTC build timestamp (e.g., `2025-01-15 14:30 UTC`)

These appear in **Settings → About → Build**.

### Production Builds

#### Android

```bash
flutter build apk --release
flutter build appbundle --release  # For Play Store
```

#### iOS

```bash
flutter build ios --release
```

#### macOS

```bash
flutter build macos --release
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `http` | HTTP client |
| `hive` / `hive_flutter` | Local storage |
| `firebase_core` | Firebase initialization |
| `firebase_messaging` | Push notifications |
| `flutter_local_notifications` | Local notification display |
| `flutter_markdown` | Markdown rendering |
| `connectivity_plus` | Network status |
| `share_plus` | Share functionality |
| `url_launcher` | Open URLs |

## Platform Notes

### macOS

Requires network entitlements in `macos/Runner/*.entitlements`:
```xml
<key>com.apple.security.network.client</key>
<true/>
```

### iOS

Requires proper signing with Apple Developer account for physical devices.

## Related Components

- [daily-agent](../daily-agent/) - Generates the summaries
- [notifier](../../functions/notifier/) - Sends email notifications
