#!/usr/bin/env bash
# Bootstrap for cloud agent sandboxes (Claude Code on the web, Codex cloud).
# Idempotent. Needs network; warms caches so later steps work with restricted egress.
set -euo pipefail
cd "$(dirname "$0")/.."

RUST_VERSION="${RUST_VERSION:-1.94}"   # matches apps/*/Dockerfile

if ! command -v cargo >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "$RUST_VERSION"
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustup component add rustfmt clippy >/dev/null 2>&1 || true   # no-op where rustup is absent

cargo fetch --locked

for f in functions/*/requirements.txt; do python3 -m pip install -q -r "$f"; done
python3 -m pip install -q pytest

# Setup scripts run in their own shell on some platforms; persist PATH for the agent phase.
grep -q 'cargo/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.bashrc"

echo "toolchain: $(cargo --version) | $(python3 --version)"
