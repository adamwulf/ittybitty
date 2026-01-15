#!/bin/bash
# Test suite for ib test-token-usage command
# Run from repo root: ./tests/test-token-usage.sh
#
# Fixture naming convention: {expected-percentage}-{description}.jsonl
# The expected percentage is extracted from the filename prefix (before first hyphen).
# Special prefix "error" indicates expected error output.

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/token-usage"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0

echo "Running test-token-usage tests..."
echo "========================================"
echo ""

# Loop through all JSONL fixture files
for fixture_path in "$FIXTURES_DIR"/*.jsonl; do
    # Skip if no files found
    [[ -e "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")

    # Extract expected result from filename (everything before first hyphen)
    expected="${filename%%-*}"

    # Get description from filename (everything after first hyphen, minus .jsonl)
    description="${filename#*-}"
    description="${description%.jsonl}"
    description="${description//-/ }"

    # Run ib test-token-usage with fixture file
    actual=$("$IB" test-token-usage "$fixture_path" 2>&1) || true

    # Handle error cases
    if [[ "$expected" == "error" ]]; then
        if [[ "$actual" == error:* ]]; then
            echo -e "${GREEN}PASS${NC} [$expected] $description"
            ((PASSED++))
        else
            echo -e "${RED}FAIL${NC} [$expected] $description"
            echo "       Expected: error:*"
            echo "       Got:      $actual"
            ((FAILED++))
        fi
    else
        if [[ "$actual" == "$expected" ]]; then
            echo -e "${GREEN}PASS${NC} [$expected%] $description"
            ((PASSED++))
        else
            echo -e "${RED}FAIL${NC} [$expected%] $description"
            echo "       Expected: $expected"
            echo "       Got:      $actual"
            ((FAILED++))
        fi
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
