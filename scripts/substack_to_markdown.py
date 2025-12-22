#!/usr/bin/env python3
"""
Fetch Substack RSS feed and save articles as markdown files.

Usage:
    export SUBSTACK_TOKEN="your_token_here"
    python substack_to_markdown.py https://example.substack.com

Or with token file:
    echo "your_token" > ~/.substack_token
    python substack_to_markdown.py https://example.substack.com
"""

import os
import re
import sys
import html
import ssl
import argparse
from pathlib import Path
from datetime import datetime
from urllib.request import urlopen, Request
from xml.etree import ElementTree as ET

# Create SSL context that doesn't verify certificates (for macOS compatibility)
SSL_CONTEXT = ssl.create_default_context()
SSL_CONTEXT.check_hostname = False
SSL_CONTEXT.verify_mode = ssl.CERT_NONE


def html_to_markdown(html_content: str) -> str:
    """Convert HTML to markdown (simple implementation)."""
    if not html_content:
        return ""

    text = html_content

    # Decode HTML entities
    text = html.unescape(text)

    # Headers
    for i in range(6, 0, -1):
        text = re.sub(f'<h{i}[^>]*>(.*?)</h{i}>', lambda m: f"{'#' * i} {m.group(1)}\n\n", text, flags=re.DOTALL | re.IGNORECASE)

    # Bold and italic
    text = re.sub(r'<strong[^>]*>(.*?)</strong>', r'**\1**', text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r'<b[^>]*>(.*?)</b>', r'**\1**', text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r'<em[^>]*>(.*?)</em>', r'*\1*', text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r'<i[^>]*>(.*?)</i>', r'*\1*', text, flags=re.DOTALL | re.IGNORECASE)

    # Links
    text = re.sub(r'<a[^>]*href=["\']([^"\']*)["\'][^>]*>(.*?)</a>', r'[\2](\1)', text, flags=re.DOTALL | re.IGNORECASE)

    # Images
    text = re.sub(r'<img[^>]*src=["\']([^"\']*)["\'][^>]*alt=["\']([^"\']*)["\'][^>]*/?\s*>', r'![\2](\1)', text, flags=re.IGNORECASE)
    text = re.sub(r'<img[^>]*src=["\']([^"\']*)["\'][^>]*/?\s*>', r'![](\1)', text, flags=re.IGNORECASE)

    # Code blocks
    text = re.sub(r'<pre[^>]*><code[^>]*>(.*?)</code></pre>', r'```\n\1\n```', text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r'<code[^>]*>(.*?)</code>', r'`\1`', text, flags=re.DOTALL | re.IGNORECASE)

    # Blockquotes
    text = re.sub(r'<blockquote[^>]*>(.*?)</blockquote>', lambda m: '> ' + m.group(1).strip().replace('\n', '\n> ') + '\n\n', text, flags=re.DOTALL | re.IGNORECASE)

    # Lists
    text = re.sub(r'<li[^>]*>(.*?)</li>', r'- \1\n', text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r'</?[ou]l[^>]*>', '\n', text, flags=re.IGNORECASE)

    # Paragraphs and breaks
    text = re.sub(r'<p[^>]*>(.*?)</p>', r'\1\n\n', text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r'<br\s*/?>', '\n', text, flags=re.IGNORECASE)
    text = re.sub(r'<hr\s*/?>', '\n---\n', text, flags=re.IGNORECASE)

    # Remove remaining HTML tags
    text = re.sub(r'<[^>]+>', '', text)

    # Clean up whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    text = re.sub(r' +', ' ', text)

    return text.strip()


def sanitize_filename(title: str) -> str:
    """Convert title to safe filename."""
    # Remove/replace unsafe characters
    safe = re.sub(r'[<>:"/\\|?*]', '', title)
    safe = re.sub(r'\s+', '-', safe)
    safe = safe.strip('-')
    return safe[:100]  # Limit length


def get_token() -> str:
    """Get token from environment or file."""
    # Try environment variable first
    token = os.environ.get('SUBSTACK_TOKEN')
    if token:
        return token

    # Try token file
    token_file = Path.home() / '.substack_token'
    if token_file.exists():
        return token_file.read_text().strip()

    return None


def fetch_rss(substack_url: str, token: str) -> str:
    """Fetch RSS feed with authentication."""
    # Normalize URL
    base_url = substack_url.rstrip('/')
    feed_url = f"{base_url}/feed?token={token}"

    req = Request(feed_url, headers={
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
    })

    with urlopen(req, timeout=30, context=SSL_CONTEXT) as response:
        return response.read().decode('utf-8')


def parse_rss_regex_fallback(xml_content: str) -> list[dict]:
    """Fallback RSS parser using regex for malformed XML."""
    articles = []
    from email.utils import parsedate_to_datetime

    # Find all items using regex
    item_pattern = re.compile(r'<item[^>]*>(.*?)</item>', re.DOTALL | re.IGNORECASE)
    title_pattern = re.compile(r'<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>', re.DOTALL | re.IGNORECASE)
    link_pattern = re.compile(r'<link[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</link>', re.DOTALL | re.IGNORECASE)
    pubdate_pattern = re.compile(r'<pubDate[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</pubDate>', re.DOTALL | re.IGNORECASE)
    content_pattern = re.compile(r'<content:encoded[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</content:encoded>', re.DOTALL | re.IGNORECASE)
    desc_pattern = re.compile(r'<description[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</description>', re.DOTALL | re.IGNORECASE)

    for item_match in item_pattern.finditer(xml_content):
        item_text = item_match.group(1)

        title_match = title_pattern.search(item_text)
        link_match = link_pattern.search(item_text)
        pubdate_match = pubdate_pattern.search(item_text)
        content_match = content_pattern.search(item_text)
        desc_match = desc_pattern.search(item_text)

        title = html.unescape(title_match.group(1).strip()) if title_match else ''
        link = link_match.group(1).strip() if link_match else ''
        pub_date = pubdate_match.group(1).strip() if pubdate_match else ''
        content = content_match.group(1) if content_match else (desc_match.group(1) if desc_match else '')

        # Parse date
        date_str = ''
        if pub_date:
            try:
                dt = parsedate_to_datetime(pub_date)
                date_str = dt.strftime('%Y-%m-%d')
            except:
                date_str = pub_date[:10] if len(pub_date) >= 10 else ''

        if title:  # Only add if we got a title
            articles.append({
                'title': title,
                'link': link,
                'date': date_str,
                'content_html': content,
            })

    return articles


def parse_rss(xml_content: str) -> list[dict]:
    """Parse RSS XML and extract articles."""
    # Try standard XML parsing first
    try:
        root = ET.fromstring(xml_content)
    except ET.ParseError as e:
        # Fall back to regex parser for malformed XML
        print(f"  XML parse error, using regex fallback: {e}")
        return parse_rss_regex_fallback(xml_content)

    articles = []

    # Handle namespaces
    namespaces = {
        'content': 'http://purl.org/rss/1.0/modules/content/',
        'dc': 'http://purl.org/dc/elements/1.1/',
    }

    for item in root.findall('.//item'):
        title = item.findtext('title', '')
        link = item.findtext('link', '')
        pub_date = item.findtext('pubDate', '')

        # Try content:encoded first (full content), fallback to description
        content = item.findtext('{http://purl.org/rss/1.0/modules/content/}encoded', '')
        if not content:
            content = item.findtext('description', '')

        # Parse date
        date_str = ''
        if pub_date:
            try:
                # Parse RFC 2822 date format
                from email.utils import parsedate_to_datetime
                dt = parsedate_to_datetime(pub_date)
                date_str = dt.strftime('%Y-%m-%d')
            except:
                date_str = pub_date[:10] if len(pub_date) >= 10 else ''

        articles.append({
            'title': title,
            'link': link,
            'date': date_str,
            'content_html': content,
        })

    return articles


def save_articles(articles: list[dict], output_dir: Path) -> int:
    """Save articles as markdown files."""
    output_dir.mkdir(parents=True, exist_ok=True)
    saved = 0

    for article in articles:
        title = article['title']
        date = article['date']
        link = article['link']
        content_md = html_to_markdown(article['content_html'])

        # Create filename
        filename = f"{date}-{sanitize_filename(title)}.md" if date else f"{sanitize_filename(title)}.md"
        filepath = output_dir / filename

        # Build markdown document
        frontmatter = f"""---
title: "{title.replace('"', '\\"')}"
date: {date}
source: {link}
---

"""
        full_content = frontmatter + content_md

        filepath.write_text(full_content, encoding='utf-8')
        print(f"  Saved: {filename}")
        saved += 1

    return saved


def main():
    parser = argparse.ArgumentParser(description='Fetch Substack articles as markdown')
    parser.add_argument('substack_url', help='Substack URL (e.g., https://example.substack.com)')
    parser.add_argument('-o', '--output', default='./substack_articles', help='Output directory')
    parser.add_argument('-t', '--token', help='Subscriber token (or set SUBSTACK_TOKEN env var)')
    args = parser.parse_args()

    # Get token
    token = args.token or get_token()
    if not token:
        print("Error: No token provided.")
        print("Set SUBSTACK_TOKEN environment variable, use -t flag, or create ~/.substack_token")
        sys.exit(1)

    print(f"Fetching RSS from {args.substack_url}...")

    try:
        xml_content = fetch_rss(args.substack_url, token)
    except Exception as e:
        print(f"Error fetching RSS: {e}")
        sys.exit(1)

    print("Parsing articles...")
    articles = parse_rss(xml_content)
    print(f"Found {len(articles)} articles")

    if not articles:
        print("No articles found. Check if the token is valid.")
        sys.exit(1)

    print(f"\nSaving to {args.output}/")
    output_dir = Path(args.output)
    saved = save_articles(articles, output_dir)

    print(f"\nDone! Saved {saved} articles to {output_dir.absolute()}")


if __name__ == '__main__':
    main()
