#!/bin/bash
# Test suite for ib test-detect-state-message command
# Run from repo root: ./tests/test-detect-state-message.sh
#
# Tests detect_state_from_message() which derives agent state from
# last_assistant_message (plain text, no ⏺ markers) before falling
# through to tmux-based detection.
#
# Fixture naming convention: {expected-output}-{description}.txt
#   waiting-*  → expects "waiting"
#   complete-* → expects "complete"
#   unknown-*  → expects "" (empty string = fall through to tmux)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IB="$REPO_ROOT/ib"

if [[ ! -x "$IB" ]]; then
    echo -e "${RED}Error: ib script not found or not executable at $IB${NC}"
    exit 1
fi

FIXTURES_DIR="$SCRIPT_DIR/fixtures/detect-state-message"
PASSED=0
FAILED=0

echo "Running detect-state-message tests..."
echo "========================================"
echo ""

for fixture_path in "$FIXTURES_DIR"/*.txt; do
    filename=$(basename "$fixture_path")

    # Extract expected output from filename prefix (before first hyphen)
    expected="${filename%%-*}"
    # "unknown" fixtures expect empty output (fall-through signal)
    if [[ "$expected" == "unknown" ]]; then
        expected=""
    fi

    description="${filename#*-}"
    description="${description%.txt}"
    description="${description//-/ }"

    actual=$("$IB" test-detect-state-message "$fixture_path")

    if [[ "$actual" == "$expected" ]]; then
        local_label="${expected:-<empty>}"
        echo -e "${GREEN}PASS${NC} [$local_label] $description"
        ((PASSED++)) || true
    else
        local_label="${expected:-<empty>}"
        echo -e "${RED}FAIL${NC} [$local_label] $description"
        echo "       Expected: '${expected}'"
        echo "       Got:      '${actual}'"
        ((FAILED++)) || true
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}test-detect-state-message: FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}test-detect-state-message: PASSED${NC}"
fi
