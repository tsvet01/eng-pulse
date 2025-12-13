# Eng Pulse

AI-powered daily engineering digest system that curates and delivers the best software engineering content.

## Overview

Eng Pulse is a complete system for curating, summarizing, and delivering daily software engineering articles. It uses Google's Gemini AI to select the most relevant content and generate concise summaries.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Explorer Agent │────▶│  Daily Agent    │────▶│    Notifier     │
│  (Source Mgmt)  │     │  (Summarizer)   │     │  (Email/Push)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
         │                       │                       │
         │                       ▼                       │
         │              ┌─────────────────┐              │
         └─────────────▶│   GCS Bucket    │◀─────────────┘
                        │  (Data Store)   │
                        └─────────────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │  Mobile App     │
                        │  (Flutter)      │
                        └─────────────────┘
```

## Components

| Component | Description | Tech Stack |
|-----------|-------------|------------|
| [gemini-engine](./gemini-engine/) | Shared Gemini API client with retry logic | Rust |
| [se-daily-agent](./se-daily-agent/) | Daily article selection and summarization | Rust |
| [se-explorer-agent](./se-explorer-agent/) | RSS/blog source discovery and management | Rust |
| [se-daily-notifier](./se-daily-notifier/) | Email notification on new summaries | Python |
| [eng_pulse_mobile](./eng_pulse_mobile/) | Mobile app for reading digests | Flutter |

## Quick Start

### Prerequisites

- Rust 1.83+
- Python 3.11+
- Flutter 3.10+
- Google Cloud SDK
- Gemini API key

### Environment Setup

```bash
# Clone repository
git clone https://github.com/tsvet01/eng-pulse.git
cd eng-pulse

# Create .env file
cat > .env << EOF
GEMINI_API_KEY=your_api_key_here
GCS_BUCKET=your-bucket-name
EOF
```

### Run Locally

```bash
# Daily Agent (generates today's summary)
cd se-daily-agent
cargo run

# Explorer Agent (manages sources)
cd se-explorer-agent
cargo run

# Mobile App
cd eng_pulse_mobile
flutter run
```

## Architecture

### Data Flow

1. **Explorer Agent** (weekly): Discovers new RSS/blog sources, validates freshness, removes stale sources
2. **Daily Agent** (daily): Fetches articles from sources, uses Gemini to select best article, generates summary
3. **Notifier** (triggered): Sends email when new summary is uploaded to GCS
4. **Mobile App**: Fetches manifest.json from GCS, displays summaries with offline support

### GCS Bucket Structure

```
bucket/
├── sources.json           # List of RSS/blog sources
├── user_candidates.json   # User-submitted source candidates
├── manifest.json          # Article manifest for mobile app
└── summaries/
    └── YYYY-MM-DD.md     # Daily summaries
```

## Deployment

### Cloud Run Jobs (Rust Agents)

```bash
# Deploy Daily Agent
cd se-daily-agent && ./deploy.sh

# Deploy Explorer Agent
cd se-explorer-agent && ./deploy.sh
```

### Cloud Function (Notifier)

```bash
cd se-daily-notifier && ./deploy.sh
```

### CI/CD

GitHub Actions automatically:
- **On PR**: Runs `cargo check`, `cargo clippy`, `flutter analyze`, `flutter test`
- **On merge to main**: Deploys all components to Google Cloud

## Configuration

### Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `GEMINI_API_KEY` | Google Gemini API key | Yes |
| `GCS_BUCKET` | GCS bucket name | Yes (default: tsvet01-agent-brain) |
| `GMAIL_USER` | Gmail address for notifications | Notifier only |
| `GMAIL_APP_PASSWORD` | Gmail app password | Notifier only |
| `DEST_EMAIL` | Notification recipient | Notifier only |

### Scheduling

- **Daily Agent**: Cloud Scheduler triggers daily at 6 AM UTC
- **Explorer Agent**: Cloud Scheduler triggers weekly on Sundays

## Development

### Project Structure

```
eng-pulse/
├── .github/workflows/     # CI/CD pipelines
├── gemini-engine/         # Shared Rust crate
├── se-daily-agent/        # Daily summarization agent
├── se-explorer-agent/     # Source discovery agent
├── se-daily-notifier/     # Email notification function
├── eng_pulse_mobile/      # Flutter mobile app
└── AGENTS.md             # Guide for AI coding agents
```

### Running Tests

```bash
# Rust tests
cd se-daily-agent && cargo test
cd se-explorer-agent && cargo test

# Flutter tests
cd eng_pulse_mobile && flutter test
```

### Code Quality

```bash
# Rust linting
cargo clippy -- -D warnings

# Flutter analysis
flutter analyze
```

## Contributing

See [AGENTS.md](./AGENTS.md) for guidelines on working with this codebase, especially for AI coding assistants.

## License

MIT
