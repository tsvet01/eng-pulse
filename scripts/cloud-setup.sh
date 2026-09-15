#!/usr/bin/env bash
# Sandbox bootstrap for cloud agents (Claude Code web, Codex).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cargo >/dev/null || curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION:-1.98}"
export PATH="$HOME/.cargo/bin:$PATH"
rustup component add rustfmt clippy 2>/dev/null || true
cargo fetch --locked
for f in functions/*/requirements.txt; do python3 -m pip install -q -r "$f"; done
python3 -m pip install -q pytest
grep -q cargo/bin ~/.bashrc 2>/dev/null || echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
