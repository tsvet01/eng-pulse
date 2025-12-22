#!/usr/bin/env python3
"""
Batch fetch multiple Substack publications to markdown.

Usage:
    python substack_batch.py                    # Fetch all configured Substacks
    python substack_batch.py --free-only        # Only fetch free content (no tokens needed)
    python substack_batch.py --list             # List configured Substacks
"""

import os
import sys
import ssl
import json
import argparse
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# Import from our other script
from substack_to_markdown import fetch_rss, parse_rss, save_articles, SSL_CONTEXT

# Your Substack subscriptions with known subdomain mappings
# Format: (Name, subdomain) or (Name, "https://custom.domain") for custom domains
SUBSTACKS = [
    # Name, subdomain (or full URL if not standard)
    ("Level Up Newsletter", "levelup"),
    ("The Pragmatic Engineer", "pragmaticengineer"),
    ("Scarlet Ink", "scarletink"),
    ("Software Design: Tidy First?", "tidyfirst"),
    ("Ahead of AI", "https://magazine.sebastianraschka.com"),  # Custom domain
    ("Alex Ewerlöf Notes", "alexewerlof"),
    ("Behind the Craft", "behindthecraft"),
    ("ByteByteGo Newsletter", "https://blog.bytebytego.com"),  # Custom domain
    ("Conks", "conks"),
    ("CTO Logic", "https://www.ctologic.pro"),  # Custom domain
    ("The CTO Substack", "7ctos"),  # By Etienne de Bruin
    ("The Developing Dev", "ryanlpeterman"),  # By Ryan Peterman
    ("Elad Blog", "https://blog.eladgil.com"),  # Custom domain
    ("Engineering Enablement", "engineeringenablement"),
    ("The Engineering Manager", "theengineeringmanager"),
    # ("Engineering Strategy", "..."),  # Will Larson uses lethain.com, not Substack
    ("Fish Food for Thought", "mikefisher"),  # By Mike Fisher
    ("Frederik Journals", "https://www.frederikjournals.com"),  # Custom domain
    ("The Hard Parts of Growth", "amivora"),
    ("High Growth Engineer", "highgrowthengineer"),
    ("Jam with AI", "jamwithai"),
    ("The Last Bear Standing", "thelastbearstanding"),
    ("Lenny's Newsletter", "lennysnewsletter"),
    ("Macro Charts", "macrocharts"),
    ("One Useful Thing", "oneusefulthing"),
    ("Pau Labarta Bajo's Newsletter", "paulabartabajo"),
    ("Paul Krugman", "paulkrugman"),
    ("The Product Compass", "https://www.productcompass.pm"),  # Custom domain, Pawel Huryn
    ("Roam 'n' Around", "williamnjau"),  # By William Njau
    ("Scaling Notes", "scalingnotes"),
    ("Strange Loop Canon", "strangeloopcanon"),
    ("Strategize Your Career", "strategizeyourcareer"),
    ("The Substack Post", "on"),  # Substack's own blog
    ("Sudo Make Me a CTO", "makemeacto"),  # By Sergio Visinoni
    ("The System Design Newsletter", "systemdesignnewsletter"),
    ("Techlead Mentor", "https://newsletter.techleadmentor.com"),  # Custom domain
    ("TheSequence", "thesequence"),
    ("Wes Kao's Newsletter", "weskao"),
    ("What YJ Thinks", "yewjin"),  # By Yew Jin Lim
    ("Wisdom over Waves", "softwarecrafter"),  # By Sapan Parikh
    ("Works on My Machine", "worksonmymachine"),
]


def get_substack_url(subdomain: str) -> str:
    """Convert subdomain to full URL."""
    # If already a full URL, return as-is
    if subdomain.startswith('https://') or subdomain.startswith('http://'):
        return subdomain.rstrip('/')
    # Standard substack subdomain
    return f"https://{subdomain}.substack.com"


def get_output_dirname(subdomain: str) -> str:
    """Get a clean directory name for output."""
    # If it's a full URL, extract the domain name
    if subdomain.startswith('https://') or subdomain.startswith('http://'):
        # Remove protocol and www.
        name = subdomain.replace('https://', '').replace('http://', '')
        name = name.replace('www.', '')
        # Take just the first part (domain without path)
        name = name.split('/')[0]
        # Replace dots with underscores for cleaner paths
        return name.replace('.', '_')
    return subdomain


def load_tokens() -> dict:
    """Load tokens from config file."""
    token_file = Path.home() / '.substack_tokens.json'
    if token_file.exists():
        return json.loads(token_file.read_text())
    return {}


def save_tokens(tokens: dict):
    """Save tokens to config file."""
    token_file = Path.home() / '.substack_tokens.json'
    token_file.write_text(json.dumps(tokens, indent=2))
    token_file.chmod(0o600)


def fetch_substack(name: str, subdomain: str, token: str = None, output_base: Path = None) -> dict:
    """Fetch a single Substack publication."""
    url = get_substack_url(subdomain)
    result = {"name": name, "subdomain": subdomain, "url": url, "success": False, "articles": 0, "error": None}

    try:
        # Try with token first, then without
        xml_content = None
        used_token = False

        if token:
            try:
                xml_content = fetch_rss(url, token)
                used_token = True
            except Exception:
                pass

        if not xml_content:
            # Try without token (free content only)
            try:
                from urllib.request import urlopen, Request
                feed_url = f"{url}/feed"
                req = Request(feed_url, headers={
                    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
                })
                with urlopen(req, timeout=30, context=SSL_CONTEXT) as response:
                    xml_content = response.read().decode('utf-8')

                # Check if we got HTML instead of RSS (paid newsletter)
                if '<!DOCTYPE html>' in xml_content[:500] or '<html' in xml_content[:500]:
                    result["error"] = "Paid newsletter - requires subscriber token"
                    return result
            except Exception as e:
                result["error"] = f"Could not fetch RSS: {e}"
                return result

        articles = parse_rss(xml_content)

        if not articles:
            result["error"] = "No articles found"
            return result

        # Save to subdirectory (using clean dir name for custom domains)
        output_dir = output_base / get_output_dirname(subdomain)
        saved = save_articles(articles, output_dir)

        result["success"] = True
        result["articles"] = saved
        result["used_token"] = used_token

    except Exception as e:
        result["error"] = str(e)

    return result


def main():
    parser = argparse.ArgumentParser(description='Batch fetch Substack publications')
    parser.add_argument('-o', '--output', default='./substack_articles', help='Output directory')
    parser.add_argument('--free-only', action='store_true', help='Only fetch free content (no tokens)')
    parser.add_argument('--list', action='store_true', help='List configured Substacks')
    parser.add_argument('--parallel', type=int, default=4, help='Number of parallel fetches')
    parser.add_argument('--subdomain', help='Fetch only this subdomain')
    args = parser.parse_args()

    if args.list:
        print(f"Configured Substacks ({len(SUBSTACKS)}):\n")
        for name, subdomain in SUBSTACKS:
            url = get_substack_url(subdomain)
            print(f"  {name}")
            print(f"    {url}")
        return

    output_base = Path(args.output)
    output_base.mkdir(parents=True, exist_ok=True)

    # Load tokens
    tokens = {} if args.free_only else load_tokens()

    # Filter to single subdomain if specified
    substacks = SUBSTACKS
    if args.subdomain:
        substacks = [(n, s) for n, s in SUBSTACKS if s == args.subdomain]
        if not substacks:
            print(f"Unknown subdomain: {args.subdomain}")
            print("Use --list to see available Substacks")
            sys.exit(1)

    print(f"Fetching {len(substacks)} Substacks...")
    print(f"Output: {output_base.absolute()}\n")

    results = []

    with ThreadPoolExecutor(max_workers=args.parallel) as executor:
        futures = {
            executor.submit(
                fetch_substack,
                name,
                subdomain,
                tokens.get(subdomain),
                output_base
            ): (name, subdomain)
            for name, subdomain in substacks
        }

        for future in as_completed(futures):
            name, subdomain = futures[future]
            result = future.result()
            results.append(result)

            if result["success"]:
                token_status = " (with token)" if result.get("used_token") else " (free)"
                print(f"✓ {name}: {result['articles']} articles{token_status}")
            else:
                print(f"✗ {name}: {result['error']}")

    # Summary
    successful = sum(1 for r in results if r["success"])
    total_articles = sum(r["articles"] for r in results)

    print(f"\n{'='*50}")
    print(f"Done! {successful}/{len(substacks)} Substacks fetched")
    print(f"Total articles: {total_articles}")
    print(f"Saved to: {output_base.absolute()}")

    # List failures
    failed = [r for r in results if not r["success"]]
    if failed:
        print(f"\nFailed ({len(failed)}):")
        for r in failed:
            print(f"  - {r['name']}: {r['error']}")

        print("\nTo get paywalled content, add tokens to ~/.substack_tokens.json:")
        print('  {"subdomain": "token_from_email", ...}')


if __name__ == '__main__':
    main()
