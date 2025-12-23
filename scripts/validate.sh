#!/bin/bash
# Validation script - runs all checks locally before commit/push
# Usage: ./scripts/validate.sh [--quick]

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

QUICK_MODE=false
if [ "$1" = "--quick" ]; then
    QUICK_MODE=true
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  Eng Pulse Validation Script"
echo "=========================================="

FAILED=0

# Rust checks
echo -e "\n${YELLOW}[1/6] Checking Rust compilation...${NC}"
if (cd apps/daily-agent && cargo check --quiet 2>/dev/null); then
    echo -e "${GREEN}✓ daily-agent compiles${NC}"
else
    echo -e "${RED}✗ daily-agent failed to compile${NC}"
    FAILED=1
fi

if (cd apps/explorer-agent && cargo check --quiet 2>/dev/null); then
    echo -e "${GREEN}✓ explorer-agent compiles${NC}"
else
    echo -e "${RED}✗ explorer-agent failed to compile${NC}"
    FAILED=1
fi

if (cd libs/gemini-engine && cargo check --quiet 2>/dev/null); then
    echo -e "${GREEN}✓ gemini-engine compiles${NC}"
else
    echo -e "${RED}✗ gemini-engine failed to compile${NC}"
    FAILED=1
fi

echo -e "\n${YELLOW}[2/6] Running Clippy lints...${NC}"
if (cd apps/daily-agent && cargo clippy --quiet -- -D warnings 2>/dev/null); then
    echo -e "${GREEN}✓ daily-agent passes clippy${NC}"
else
    echo -e "${RED}✗ daily-agent has clippy warnings${NC}"
    FAILED=1
fi

if (cd apps/explorer-agent && cargo clippy --quiet -- -D warnings 2>/dev/null); then
    echo -e "${GREEN}✓ explorer-agent passes clippy${NC}"
else
    echo -e "${RED}✗ explorer-agent has clippy warnings${NC}"
    FAILED=1
fi

echo -e "\n${YELLOW}[3/6] Running Rust tests...${NC}"
if (cd libs/gemini-engine && cargo test --quiet 2>/dev/null); then
    echo -e "${GREEN}✓ gemini-engine tests pass${NC}"
else
    echo -e "${RED}✗ gemini-engine tests failed${NC}"
    FAILED=1
fi

if (cd apps/daily-agent && cargo test --quiet 2>/dev/null); then
    echo -e "${GREEN}✓ daily-agent tests pass${NC}"
else
    echo -e "${RED}✗ daily-agent tests failed${NC}"
    FAILED=1
fi

if (cd apps/explorer-agent && cargo test --quiet 2>/dev/null); then
    echo -e "${GREEN}✓ explorer-agent tests pass${NC}"
else
    echo -e "${RED}✗ explorer-agent tests failed${NC}"
    FAILED=1
fi

# Python checks
echo -e "\n${YELLOW}[4/6] Checking Python syntax...${NC}"
if python3 -m py_compile functions/notifier/main.py 2>/dev/null; then
    echo -e "${GREEN}✓ notifier/main.py is valid${NC}"
else
    echo -e "${RED}✗ notifier/main.py has syntax errors${NC}"
    FAILED=1
fi

# Flutter checks (skip in quick mode)
if [ "$QUICK_MODE" = false ]; then
    echo -e "\n${YELLOW}[5/6] Running Flutter analysis...${NC}"
    if (cd apps/mobile && flutter analyze --no-pub 2>/dev/null | grep -q "No issues found"); then
        echo -e "${GREEN}✓ Flutter analysis passes${NC}"
    else
        echo -e "${RED}✗ Flutter has analysis issues${NC}"
        FAILED=1
    fi

    echo -e "\n${YELLOW}[6/6] Running Flutter tests...${NC}"
    if (cd apps/mobile && flutter test --no-pub 2>/dev/null); then
        echo -e "${GREEN}✓ Flutter tests pass${NC}"
    else
        echo -e "${RED}✗ Flutter tests failed${NC}"
        FAILED=1
    fi
else
    echo -e "\n${YELLOW}[5/6] Skipping Flutter analysis (quick mode)${NC}"
    echo -e "${YELLOW}[6/6] Skipping Flutter tests (quick mode)${NC}"
fi

echo ""
echo "=========================================="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}  All checks passed! Ready to commit.${NC}"
    echo "=========================================="
    exit 0
else
    echo -e "${RED}  Some checks failed. Please fix before committing.${NC}"
    echo "=========================================="
    exit 1
fi
