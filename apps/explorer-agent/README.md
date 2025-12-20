# Explorer Agent

Rust-based Cloud Run job that discovers, validates, and manages RSS/blog sources.

> Part of [Eng Pulse](../../README.md) - see root README for system overview.

## What It Does

1. **Loads** current sources from GCS
2. **Processes** user-submitted source candidates
3. **Discovers** RSS/Atom feeds from candidate URLs
4. **Validates** source relevance using Gemini
5. **Checks** existing sources for freshness (published in last 90 days)
6. **Removes** stale sources that haven't published recently
7. **Saves** updated source list to GCS

## Usage

### Local Development

```bash
# Set environment variables
export GEMINI_API_KEY=your_api_key
export GCS_BUCKET=your-bucket-name  # Optional

# Run
cargo run
```

### Deployment

```bash
./deploy.sh
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GEMINI_API_KEY` | Yes | - | Google Gemini API key |
| `GCS_BUCKET` | No | `tsvet01-agent-brain` | GCS bucket for storage |
| `GEMINI_MODEL` | No | `gemini-2.0-flash` | Gemini model to use |
| `RUST_LOG` | No | `info` | Log level |

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `HTTP_TIMEOUT_SECS` | 30 | HTTP request timeout |
| `FRESHNESS_DAYS` | 90 | Days before source is considered stale |
| `MAX_FEED_DISCOVERY_ATTEMPTS` | 2 | Feed URL discovery attempts |

## Feed Discovery Algorithm

When a user submits a candidate URL (e.g., `https://blog.example.com`):

1. **Direct check**: Is the URL itself a valid RSS/Atom feed?
2. **HTML parsing**: Look for `<link rel="alternate" type="application/rss+xml">` tags
3. **Common paths**: Try `/feed`, `/rss`, `/atom.xml`, `/feed.xml`
4. **Homepage fallback**: If URL has path, try base domain

```
https://blog.example.com/post/123
         │
         ▼
    Check if feed ──▶ No
         │
         ▼
    Parse HTML for <link rel="alternate">
         │
         ▼
    Try /feed, /rss, /atom.xml
         │
         ▼
    Try https://blog.example.com/
```

## Relevance Validation

Uses Gemini to evaluate if a source is relevant:

```
Given the blog titled '{name}' at URL '{url}', and a sample of its content: '{sample}'.

Does this source consistently publish high-quality, technically deep content
relevant to a senior software engineer in 2025?

Respond ONLY with 'yes' or 'no'.
```

## Freshness Check

Sources are checked for recent activity:

1. Fetch the RSS/Atom feed
2. Find the most recent publication date
3. If older than `FRESHNESS_DAYS` (90 days), remove the source

## Data Structures

### Source Config

```json
{
  "name": "Engineering Blog",
  "type": "rss",
  "url": "https://blog.example.com/feed.xml"
}
```

### User Candidates

Users can submit new sources via `user_candidates.json`:

```json
[
  {
    "name": "New Blog",
    "type": "rss",
    "url": "https://new-blog.com"
  }
]
```

After processing, candidates are deleted and valid sources added to `sources.json`.

## Gemini Integration

Uses `gemini-engine` crate for:
- Source relevance validation
- Recommendation generation for new sources

### Source Recommendations

Periodically asks Gemini for new source suggestions:

```
Based on current sources, suggest 3 NEW high-quality software engineering
blogs or publications not in the current list.

Return as JSON array: [{"name": "...", "url": "..."}]
```

## Error Handling

- **Feed discovery failure**: Source skipped, logged as warning
- **Gemini validation failure**: Source rejected (defaults to "not relevant")
- **Freshness check failure**: Source marked as stale and removed
- **GCS failures**: Job fails with error

## Output

Updates `sources.json` in GCS with:
- New validated sources from candidates
- New sources from Gemini recommendations
- Stale sources removed

## Scheduling

Typically runs weekly (less frequent than daily agent) to:
- Process accumulated user candidates
- Check source freshness
- Discover new sources
