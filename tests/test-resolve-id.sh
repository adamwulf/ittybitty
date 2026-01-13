#!/bin/bash
# Test suite for ib test-resolve-id command
# Run from repo root: ./tests/test-resolve-id.sh
#
# Fixture naming convention: {expected-result}-{description}.json
# The expected result is extracted from the filename prefix (before first hyphen).
# For partial matches, the expected result is the resolved agent ID.

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/resolve-id"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0

echo "Running test-resolve-id tests..."
echo "========================================"
echo ""

# Loop through all fixture files
for fixture_path in "$FIXTURES_DIR"/*.json; do
    # Skip if no files found
    [[ -e "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")

    # Extract expected result from filename (everything before first hyphen)
    expected="${filename%%-*}"

    # Get description from filename (everything after first hyphen, minus .json)
    description="${filename#*-}"
    description="${description%.json}"
    description="${description//-/ }"

    # Run ib test-resolve-id with fixture file
    actual=$("$IB" test-resolve-id "$fixture_path" 2>&1) || true

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} [$expected] $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} [$expected] $description"
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
