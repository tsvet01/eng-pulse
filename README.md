# Eng Pulse

[![CI](https://github.com/tsvet01/eng-pulse/actions/workflows/ci.yml/badge.svg)](https://github.com/tsvet01/eng-pulse/actions/workflows/ci.yml)
[![Deploy](https://github.com/tsvet01/eng-pulse/actions/workflows/deploy.yml/badge.svg)](https://github.com/tsvet01/eng-pulse/actions/workflows/deploy.yml)

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
                 │
                 ▼
        ┌─────────────────┐
        │  Mobile App     │
        │  (Swift/iOS)    │
        └─────────────────┘
```

## Components

| Component | Description | Tech Stack |
|-----------|-------------|------------|
| [llm-client](./libs/llm-client/) | Shared LLM API client with retry logic | Rust |
| [pulse-core](./libs/pulse-core/) | Shared contract types + fixture generator (`docs/contracts/`) | Rust |
| [daily-agent](./apps/daily-agent/) | Daily article selection and summarization | Rust |
| [explorer-agent](./apps/explorer-agent/) | RSS/blog source discovery and management | Rust |
| [pulse-api](./apps/pulse-api/) | Multi-user API skeleton (`/healthz`, sqlx migrations) | Rust |
| [notifier](./functions/notifier/) | Email notification on new summaries | Python |
| mobile-android | Native Kotlin/Compose app | Kotlin (planned, Phase 5) |
| [mobile-swift](./apps/mobile-swift/) | Native iOS app with TTS and CarPlay | Swift |
| [infra/](./infra/hetzner/) | Terraform: Hetzner box + Cloudflare DNS for `pulse-api` | Terraform |

## Quick Start

### Prerequisites

- Rust 1.83+
- Python 3.11+
- Xcode 15+ (for Swift app)
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
cd apps/daily-agent
cargo run

# Explorer Agent (manages sources)
cd apps/explorer-agent
cargo run

# Mobile App (Swift) - requires Xcode
cd apps/mobile-swift
open EngPulse.xcodeproj
# Then build and run from Xcode
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
├── config/
│   └── sources.json       # List of RSS/blog sources
├── user_candidates.json   # User-submitted source candidates
├── manifest.json          # Article manifest for mobile app
└── summaries/
    └── YYYY-MM-DD.md      # Daily summaries
```

## Deployment

### Cloud Run Jobs (Rust Agents)

```bash
# Deploy Daily Agent
cd apps/daily-agent && ./deploy.sh

# Deploy Explorer Agent
cd apps/explorer-agent && ./deploy.sh
```

### Cloud Function (Notifier)

```bash
cd functions/notifier && ./deploy.sh
```

### CI/CD

GitHub Actions automatically:
- **On PR**: Runs `cargo check`, `cargo clippy`, `cargo test`
- **On merge to main**: Deploys all components to Google Cloud

A single path-filtered workflow (`.github/workflows/ci.yml`) also gates and deploys `pulse-core`/`pulse-api`: `fixtures` fails on `docs/contracts/` drift or untracked fixture files, `api-it` boots `pulse-api` against a real Postgres and checks `/healthz`, and `terraform-plan`/`terraform-apply` plan and (with `production`-environment approval) apply the `infra/hetzner` Terraform stack.

Credentials are stored in GCP Secret Manager and GitHub Secrets.

## Configuration

### Environment Variables

For local development, set these environment variables:

| Variable | Description | Required |
|----------|-------------|----------|
| `GEMINI_API_KEY` | Google Gemini API key | Yes |
| `GCS_BUCKET` | GCS bucket name | No (default: tsvet01-agent-brain) |
| `GEMINI_MODEL` | Gemini model to use | No (default: gemini-2.0-flash) |
| `GMAIL_USER` | Gmail address for notifications | Notifier only |
| `GMAIL_APP_PASSWORD` | Gmail app password | Notifier only |
| `DEST_EMAIL` | Notification recipient | Notifier only |

### Production Secrets (GCP Secret Manager)

In production, credentials are stored in GCP Secret Manager:
- `gemini-api-key` - Gemini API key for agents
- `gmail-user` - Gmail sender address
- `gmail-app-password` - Gmail app password
- `dest-email` - Notification recipient

### Scheduling

- **Daily Agent**: Cloud Scheduler triggers daily at 6 AM UTC
- **Explorer Agent**: Cloud Scheduler triggers weekly on Sundays

## Development

### Project Structure

```
eng-pulse/
├── .github/workflows/     # CI/CD pipelines
├── apps/
│   ├── daily-agent/       # Daily summarization agent (Rust)
│   ├── explorer-agent/    # Source discovery agent (Rust)
│   └── mobile-swift/      # Native iOS app (Swift)
├── libs/
│   └── llm-client/        # Shared Rust crate
├── functions/
│   └── notifier/          # Email notification (Python)
├── scripts/               # Utility scripts
└── docs/
    └── AGENTS.md          # Guide for AI coding agents
```

### Running Tests

```bash
# Rust tests
cd libs/llm-client && cargo test
cd apps/daily-agent && cargo test
cd apps/explorer-agent && cargo test
```

### Code Quality

```bash
# Rust linting
cargo clippy -- -D warnings
```

## Contributing

See [AGENTS.md](./docs/AGENTS.md) for guidelines on working with this codebase, especially for AI coding assistants.

## License

MIT
