# AGENTS.md - Guide for AI Coding Assistants

This document provides context and guidelines for AI coding assistants (Claude, Copilot, Cursor, etc.) working on the Eng Pulse codebase.

## Project Overview

Eng Pulse is an AI-powered daily engineering digest system with these components:

| Component | Location | Language | Purpose |
|-----------|----------|----------|---------|
| `gemini-engine` | `libs/gemini-engine/` | Rust | Shared Gemini API client |
| `daily-agent` | `apps/daily-agent/` | Rust | Daily article summarization |
| `explorer-agent` | `apps/explorer-agent/` | Rust | Source discovery/management |
| `notifier` | `functions/notifier/` | Python | Email notifications |
| `mobile` | `apps/mobile/` | Flutter/Dart | Cross-platform mobile app |
| `mobile-swift` | `apps/mobile-swift/` | Swift | Native iOS app with TTS |

## Architecture Decisions

### Why Rust for Agents?

- Type safety for complex data transformations
- Excellent async support for concurrent HTTP requests
- Strong error handling with `Result` types
- Efficient memory usage for Cloud Run jobs

### Why Separate Agents?

- **Single Responsibility**: Each agent has one clear job
- **Independent Scaling**: Daily agent runs daily, explorer runs weekly
- **Fault Isolation**: One failing doesn't affect others

### Why GCS as Data Store?

- Simple, serverless storage
- Native Cloud Run integration
- Public URL access for mobile app
- Event triggers for notifications

## Code Patterns

### Rust Error Handling

Use `Result` types with `?` operator. Avoid `.unwrap()` and `.expect()` in production paths:

```rust
// Good
let content = fetch_article(&url).await?;

// Avoid
let content = fetch_article(&url).await.unwrap();
```

### Gemini API Calls

Always use the shared `gemini-engine` crate:

```rust
use gemini_engine::call_gemini_with_retry;

let response = call_gemini_with_retry(&client, &api_key, prompt).await?;
```

### Logging (Rust)

Use `tracing` macros with structured fields:

```rust
use tracing::{info, warn, error, debug};

info!(article_count = articles.len(), "Fetched articles");
warn!(source = %source.name, "Source returned no articles");
error!(error = %e, "Failed to fetch from GCS");
```

### Flutter Services

Services use static methods and Hive for persistence:

```dart
// Initialize in main()
await CacheService.init();

// Use statically
final summaries = CacheService.getCachedSummaries();
```

### Firebase (Optional - Flutter)

Firebase is optional in the Flutter app. When not configured:
- App runs normally without push notifications
- `NotificationService.isAvailable` returns `false`
- Use `flutterfire configure` to enable Firebase

### Swift App Patterns

The native iOS app uses SwiftUI with these patterns:

```swift
// Use @MainActor for observable state
@MainActor
class AppState: ObservableObject {
    @Published var summaries: [Summary] = []
}

// Use @AppStorage for persisted preferences
@AppStorage("ttsSpeechRate") private var speechRate: Double = 0.55

// Handle notification delegate setup early
func application(_:didFinishLaunchingWithOptions:) -> Bool {
    UNUserNotificationCenter.current().delegate = NotificationService.shared
    return true
}
```

## Common Tasks

### Adding a New Source Type

1. Add type to `SourceConfig` in `apps/daily-agent/src/fetcher.rs`
2. Add match arm in `fetch_from_source()`
3. Implement fetch function following existing patterns
4. Test with local run before deployment

### Modifying Gemini Prompts

Prompts are in:
- `apps/daily-agent/src/main.rs` - Article selection, summarization
- `apps/explorer-agent/src/main.rs` - Source relevance, recommendations

When modifying:
- Keep prompts concise but specific
- Request structured output (JSON, "yes/no")
- Test with multiple inputs locally

### Adding Flutter Features

1. Create model in `lib/models/` if needed
2. Add service method in `lib/services/`
3. Create/update screen in `lib/screens/`
4. Follow existing widget patterns in `lib/widgets/`

### Adding Swift Features

1. Create model in `EngPulse/Models/` if needed
2. Add service in `EngPulse/Services/`
3. Create/update view in `EngPulse/Views/`
4. Use `@MainActor` for observable classes
5. Use `@AppStorage` for persisted preferences

## Pre-Commit Protections

### Setup Pre-Commit Hook

Install the pre-commit hook to catch issues before they reach CI:

```bash
cp scripts/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

The hook automatically:
- Checks Rust compilation and clippy for modified crates
- Validates Python syntax for modified `.py` files
- Runs Flutter analyze for modified `.dart` files
- Only runs checks for files in the staged commit

### Full Validation Script

Run all checks manually:

```bash
# Full validation (includes Flutter - slower)
./scripts/validate.sh

# Quick validation (Rust + Python only)
./scripts/validate.sh --quick
```

## Testing Guidelines

### Rust

```bash
cd apps/daily-agent
cargo test
cargo clippy -- -D warnings
```

### Flutter

```bash
cd apps/mobile
flutter test
flutter analyze
```

### Local End-to-End

```bash
# 1. Run daily agent locally
cd apps/daily-agent && cargo run

# 2. Check GCS for output
gsutil cat gs://bucket/manifest.json

# 3. Run mobile app
cd apps/mobile && flutter run
```

## Known Technical Debt

Active issues to be aware of:

1. **#6** - Environment-based API URL configuration (hardcoded URLs in both apps)
2. **#7** - Complete FCM token registration (Flutter only; Swift uses APNs)
3. **#8** - Add observability infrastructure (crash reporting, analytics)
4. **#9** - Replace :latest Docker tags with versioned tags

Resolved:
- ~~#12 - Shared code duplicated~~ (RESOLVED: gemini-engine in libs/)
- ~~#13 - Flutter unit tests~~ (CLOSED)
- ~~Gemini model config~~ (RESOLVED: GEMINI_MODEL env var)

See GitHub Issues for full list.

## File Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Rust modules | snake_case | `fetcher.rs` |
| Dart files | snake_case | `api_service.dart` |
| Dart classes | PascalCase | `ApiService` |
| Swift files | PascalCase | `APIService.swift` |
| Swift classes | PascalCase | `APIService` |
| Constants (Rust) | SCREAMING_SNAKE | `MAX_RETRY_SECS` |
| Constants (Dart) | camelCase with _ prefix | `_manifestUrl` |
| Constants (Swift) | lowerCamelCase | `baseURL` |

## Environment Variables

Required for local development:

```bash
# Rust agents
GEMINI_API_KEY=your_key
GCS_BUCKET=your_bucket    # Optional, default: tsvet01-agent-brain
GEMINI_MODEL=gemini-3-pro-preview  # Optional, default: gemini-3-pro-preview

# Python notifier
GMAIL_USER=email
GMAIL_APP_PASSWORD=app_password
DEST_EMAIL=recipient
```

## Deployment

### Manual Deployment

```bash
# Rust agents
cd apps/daily-agent && ./deploy.sh
cd apps/explorer-agent && ./deploy.sh

# Python notifier
cd functions/notifier && ./deploy.sh
```

### CI/CD

- Push to `main` triggers deployment
- PRs run checks only (no deployment)
- See `.github/workflows/` for details

## Important Files

| File | Purpose |
|------|---------|
| `libs/gemini-engine/src/lib.rs` | Core Gemini API logic |
| `apps/daily-agent/src/main.rs` | Daily agent orchestration |
| `apps/daily-agent/src/fetcher.rs` | RSS/HN fetching logic |
| `apps/explorer-agent/src/main.rs` | Source discovery logic |
| `apps/mobile/lib/services/api_service.dart` | Flutter API client |
| `apps/mobile-swift/EngPulse/EngPulseApp.swift` | Swift app entry point |
| `apps/mobile-swift/EngPulse/Services/` | Swift services (API, Cache, TTS) |
| `.github/workflows/ci.yml` | CI configuration |
| `.github/workflows/deploy.yml` | Deployment configuration |

## Do's and Don'ts

### Do

- **Install the pre-commit hook** (see Pre-Commit Protections above)
- **Run `./scripts/validate.sh` before pushing** to catch issues early
- Use existing patterns from similar code
- Add structured logging for new functionality
- Handle errors explicitly with `Result`/`try-catch`
- Test locally before pushing
- Update documentation when adding features

### Don't

- **Push without running local validation** - CI failures are preventable
- **Skip pre-commit hooks with `--no-verify`** - unless you have a very good reason
- Use `.unwrap()` or `.expect()` in production paths
- Hardcode credentials or API keys
- Skip error handling for "simple" cases
- Modify prompts without testing
- Add dependencies without justification
- Run `cargo update` without checking for edition2024 crates (see below)

## Dependency Notes

Some transitive dependencies have released versions requiring Rust edition2024 (nightly). We pin these to stable-compatible versions in `Cargo.lock`:

- `base64ct` - pinned to 1.6.0 (1.8.x requires edition2024)
- `home` - pinned to 0.5.9 (0.5.12 requires edition2024)

If `cargo update` breaks the build with "feature `edition2024` is required", pin the offending crate:
```bash
cargo update <crate>@<new-version> --precise <old-version>
```

## Getting Help

- Check component READMEs for specific guidance
- Review existing code for patterns
- GitHub Issues for known problems
- Architecture diagrams in root README

## Quick Reference

### Setup (First Time)

```bash
# Install pre-commit hook
cp scripts/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

### Run Locally

```bash
# Rust agent
cd apps/daily-agent && cargo run

# Flutter app
cd apps/mobile && flutter run

# Swift app (open in Xcode)
cd apps/mobile-swift && open EngPulse.xcodeproj
```

### Validate Before Commit

```bash
# Full validation
./scripts/validate.sh

# Quick (Rust + Python only)
./scripts/validate.sh --quick
```

### Build & Test

```bash
# Rust
cargo build && cargo test && cargo clippy

# Flutter
flutter pub get && flutter test && flutter analyze
```

### Deploy

```bash
# Push to main branch triggers auto-deploy
git push origin main
```
