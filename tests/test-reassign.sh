#!/bin/bash
# Test suite for ib test-reassign command
# Run from repo root: ./tests/test-reassign.sh
#
# Fixture naming convention: {expected}-{description}.json
# The expected output is extracted from the filename prefix (before first hyphen).
# Expected values: ok, noop, error
# For noop and error, the full output includes a colon and reason, e.g., "noop:same-parent"

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/reassign"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0

echo "Running test-reassign tests..."
echo "========================================"
echo ""

# Loop through all fixture files
for fixture_path in "$FIXTURES_DIR"/*.json; do
    # Skip if no files found
    [[ -e "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")

    # Extract expected prefix from filename (everything before first hyphen)
    # e.g., "ok-simple-reassign.json" -> "ok"
    # e.g., "error-cannot-reassign-to-self.json" -> "error"
    # e.g., "noop-same-parent.json" -> "noop"
    expected_prefix="${filename%%-*}"

    # Get description from filename (everything after first hyphen, minus .json)
    description="${filename#*-}"
    description="${description%.json}"
    description="${description//-/ }"

    # Run ib test-reassign with fixture file
    actual=$("$IB" test-reassign "$fixture_path" 2>&1) || true

    # Extract prefix from actual output (everything before colon, or whole string if no colon)
    actual_prefix="${actual%%:*}"

    # For "ok" results, match exactly
    # For "error" and "noop" results, match the prefix and check full output
    if [[ "$expected_prefix" == "ok" ]]; then
        if [[ "$actual" == "ok" ]]; then
            echo -e "${GREEN}PASS${NC} [ok] $description"
            ((PASSED++))
        else
            echo -e "${RED}FAIL${NC} [ok] $description"
            echo "       Expected: ok"
            echo "       Got:      $actual"
            ((FAILED++))
        fi
    else
        # For error/noop, verify prefix matches and show full result
        if [[ "$actual_prefix" == "$expected_prefix" ]]; then
            echo -e "${GREEN}PASS${NC} [$actual] $description"
            ((PASSED++))
        else
            echo -e "${RED}FAIL${NC} [$expected_prefix:*] $description"
            echo "       Expected prefix: $expected_prefix"
            echo "       Got:             $actual"
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
