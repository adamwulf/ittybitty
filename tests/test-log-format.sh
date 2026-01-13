#!/bin/bash
# Test suite for ib test-log-format command
# Run from repo root: ./tests/test-log-format.sh
#
# This test uses a fixed timestamp for deterministic output.
# Tests verify that messages are properly formatted with [timestamp] prefix.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Find the ib script (look for it in repo root relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IB="$REPO_ROOT/ib"

if [[ ! -x "$IB" ]]; then
    echo -e "${RED}Error: ib script not found or not executable at $IB${NC}"
    exit 1
fi

FIXTURES_DIR="$SCRIPT_DIR/fixtures/log-format"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0
TEST_TIMESTAMP="2026-01-12 10:30:45"

echo "Running test-log-format tests..."
echo "========================================"
echo ""

# Loop through all fixture files
for fixture_path in "$FIXTURES_DIR"/*.txt; do
    # Skip if no files found
    [[ -e "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")
    description="${filename%.txt}"
    description="${description//-/ }"

    # Read the message from fixture
    message=$(cat "$fixture_path")

    # Expected output is the message with timestamp prefix
    expected="[$TEST_TIMESTAMP] $message"

    # Run ib test-log-format with fixture file and fixed timestamp
    actual=$("$IB" test-log-format --timestamp "$TEST_TIMESTAMP" "$fixture_path" 2>&1) || true

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $description"
        echo "       Expected: $expected"
        echo "       Got:      $actual"
        ((FAILED++))
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
