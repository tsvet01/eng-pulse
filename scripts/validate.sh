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

# Rust checks (using workspace)
echo -e "\n${YELLOW}[1/4] Checking Rust compilation...${NC}"
if cargo check --workspace --quiet 2>/dev/null; then
    echo -e "${GREEN}✓ Rust workspace compiles${NC}"
else
    echo -e "${RED}✗ Rust workspace failed to compile${NC}"
    FAILED=1
fi

echo -e "\n${YELLOW}[2/4] Running Clippy lints...${NC}"
if cargo clippy --workspace --quiet -- -D warnings 2>/dev/null; then
    echo -e "${GREEN}✓ All crates pass clippy${NC}"
else
    echo -e "${RED}✗ Clippy found warnings${NC}"
    FAILED=1
fi

echo -e "\n${YELLOW}[3/4] Running Rust tests...${NC}"
if cargo test --workspace --quiet 2>/dev/null; then
    echo -e "${GREEN}✓ All tests pass${NC}"
else
    echo -e "${RED}✗ Some tests failed${NC}"
    FAILED=1
fi

# Python checks
echo -e "\n${YELLOW}[4/4] Checking Python syntax...${NC}"
if python3 -m py_compile functions/notifier/main.py 2>/dev/null; then
    echo -e "${GREEN}✓ notifier/main.py is valid${NC}"
else
    echo -e "${RED}✗ notifier/main.py has syntax errors${NC}"
    FAILED=1
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
