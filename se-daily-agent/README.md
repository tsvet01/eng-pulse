# se-daily-agent

Rust-based Cloud Run job that generates daily software engineering article summaries.

## What It Does

1. **Fetches articles** from configured RSS feeds and Hacker News
2. **Filters** to articles published in the last 24 hours
3. **Asks Gemini** to select the single most valuable article
4. **Scrapes** the full article content using readability extraction
5. **Generates** a comprehensive summary with Gemini
6. **Uploads** the summary to GCS and updates the manifest

## Usage

### Local Development

```bash
# Set environment variables
export GEMINI_API_KEY=your_api_key
export GCS_BUCKET=your-bucket-name  # Optional, defaults to tsvet01-agent-brain

# Run
cargo run
```

### Deployment

```bash
./deploy.sh
```

This deploys to Google Cloud Run as a scheduled job.

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GEMINI_API_KEY` | Yes | - | Google Gemini API key |
| `GCS_BUCKET` | No | `tsvet01-agent-brain` | GCS bucket for storage |
| `RUST_LOG` | No | `info` | Log level (debug, info, warn, error) |

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `HTTP_TIMEOUT_SECS` | 60 | HTTP request timeout |
| `MAX_ARTICLE_CHARS` | 50,000 | Max article length for summarization |
| `SUMMARY_SNIPPET_CHARS` | 100 | Snippet length in manifest |

## Data Flow

```
sources.json (GCS)
       │
       ▼
┌─────────────────┐
│  Fetch Articles │ ── RSS feeds, HackerNews API
└─────────────────┘
       │
       ▼
┌─────────────────┐
│ Gemini Selection│ ── "Which article is most valuable?"
└─────────────────┘
       │
       ▼
┌─────────────────┐
│ Scrape Content  │ ── readabilityrs extraction
└─────────────────┘
       │
       ▼
┌─────────────────┐
│ Gemini Summary  │ ── Structured summary generation
└─────────────────┘
       │
       ▼
summaries/YYYY-MM-DD.md (GCS)
manifest.json (GCS)
```

## Source Types

### RSS Feeds

Standard RSS/Atom feeds. Filters to articles from last 24 hours.

```json
{
  "name": "Engineering Blog",
  "type": "rss",
  "url": "https://blog.example.com/feed.xml"
}
```

### Hacker News

Fetches top 10 stories, filters by recency and point threshold.

```json
{
  "name": "Hacker News",
  "type": "hackernews",
  "url": "https://hacker-news.firebaseio.com/v0/topstories.json"
}
```

## Output Format

### Summary (Markdown)

```markdown
# Article Title

**Source:** Blog Name | **Date:** 2024-01-15

## Summary
[AI-generated summary]

## Key Points
- Point 1
- Point 2
- Point 3

## Why This Matters
[Relevance explanation]

---
[Original Article](https://...)
```

### Manifest Entry

```json
{
  "date": "2024-01-15",
  "url": "https://storage.googleapis.com/bucket/summaries/2024-01-15.md",
  "title": "Article Title",
  "summary_snippet": "First 100 chars of summary...",
  "original_url": "https://original-article.com"
}
```

## Error Handling

- **No articles found**: Logs warning, exits successfully (no summary generated)
- **Gemini failures**: Retries with exponential backoff via gemini-engine
- **Article scrape failure**: Falls back to title-only summary
- **GCS failures**: Propagates error, job fails

## Logging

Uses `tracing` with JSON output in production:

```bash
# Development (pretty logs)
cargo run

# Production (JSON logs)
RUST_LOG=info cargo run
```

## Dependencies

- `gemini-engine` - Shared Gemini API client
- `reqwest` - HTTP client
- `google-cloud-storage` - GCS operations
- `readability` - Article extraction
- `rss` - RSS parsing
- `tracing` - Structured logging
