# AGENTS.md - Guide for AI Coding Assistants

This document provides context and guidelines for AI coding assistants (Claude, Copilot, Cursor, etc.) working on the Eng Pulse codebase.

## Project Overview

Eng Pulse is an AI-powered daily engineering digest system with these components:

| Component | Language | Purpose |
|-----------|----------|---------|
| `gemini-engine` | Rust | Shared Gemini API client |
| `se-daily-agent` | Rust | Daily article summarization |
| `se-explorer-agent` | Rust | Source discovery/management |
| `se-daily-notifier` | Python | Email notifications |
| `eng_pulse_mobile` | Flutter/Dart | Mobile app |

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

## Common Tasks

### Adding a New Source Type

1. Add type to `SourceConfig` in `se-daily-agent/src/fetcher.rs`
2. Add match arm in `fetch_from_source()`
3. Implement fetch function following existing patterns
4. Test with local run before deployment

### Modifying Gemini Prompts

Prompts are in:
- `se-daily-agent/src/main.rs` - Article selection, summarization
- `se-explorer-agent/src/main.rs` - Source relevance, recommendations

When modifying:
- Keep prompts concise but specific
- Request structured output (JSON, "yes/no")
- Test with multiple inputs locally

### Adding Flutter Features

1. Create model in `lib/models/` if needed
2. Add service method in `lib/services/`
3. Create/update screen in `lib/screens/`
4. Follow existing widget patterns in `lib/widgets/`

## Testing Guidelines

### Rust

```bash
cd se-daily-agent
cargo test
cargo clippy -- -D warnings
```

### Flutter

```bash
cd eng_pulse_mobile
flutter test
flutter analyze
```

### Local End-to-End

```bash
# 1. Run daily agent locally
cd se-daily-agent && cargo run

# 2. Check GCS for output
gsutil cat gs://bucket/manifest.json

# 3. Run mobile app
cd eng_pulse_mobile && flutter run
```

## Known Technical Debt

Active issues to be aware of:

1. **#6** - Make Gemini model configurable
2. **#7** - Complete FCM token registration
3. **#8** - Add observability infrastructure
4. **#9** - Replace :latest Docker tags with versioned tags
5. **#12** - Shared code duplicated between agents
6. **#13** - Flutter services lack unit tests

See GitHub Issues for full list.

## File Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Rust modules | snake_case | `fetcher.rs` |
| Dart files | snake_case | `api_service.dart` |
| Dart classes | PascalCase | `ApiService` |
| Constants (Rust) | SCREAMING_SNAKE | `MAX_RETRY_SECS` |
| Constants (Dart) | camelCase with _ prefix | `_manifestUrl` |

## Environment Variables

Required for local development:

```bash
# Rust agents
GEMINI_API_KEY=your_key
GCS_BUCKET=your_bucket  # Optional, has default

# Python notifier
GMAIL_USER=email
GMAIL_APP_PASSWORD=app_password
DEST_EMAIL=recipient
```

## Deployment

### Manual Deployment

```bash
# Rust agents
cd se-daily-agent && ./deploy.sh
cd se-explorer-agent && ./deploy.sh

# Python notifier
cd se-daily-notifier && ./deploy.sh
```

### CI/CD

- Push to `main` triggers deployment
- PRs run checks only (no deployment)
- See `.github/workflows/` for details

## Important Files

| File | Purpose |
|------|---------|
| `gemini-engine/src/lib.rs` | Core Gemini API logic |
| `se-daily-agent/src/main.rs` | Daily agent orchestration |
| `se-daily-agent/src/fetcher.rs` | RSS/HN fetching logic |
| `se-explorer-agent/src/main.rs` | Source discovery logic |
| `eng_pulse_mobile/lib/services/api_service.dart` | Mobile API client |
| `.github/workflows/ci.yml` | CI configuration |
| `.github/workflows/deploy.yml` | Deployment configuration |

## Do's and Don'ts

### Do

- Use existing patterns from similar code
- Add structured logging for new functionality
- Handle errors explicitly with `Result`/`try-catch`
- Test locally before pushing
- Update documentation when adding features

### Don't

- Use `.unwrap()` or `.expect()` in production paths
- Hardcode credentials or API keys
- Skip error handling for "simple" cases
- Modify prompts without testing
- Add dependencies without justification

## Getting Help

- Check component READMEs for specific guidance
- Review existing code for patterns
- GitHub Issues for known problems
- Architecture diagrams in root README

## Quick Reference

### Run Locally

```bash
# Rust agent
cd se-daily-agent && cargo run

# Flutter app
cd eng_pulse_mobile && flutter run
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
