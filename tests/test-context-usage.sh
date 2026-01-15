#!/bin/bash
# Test suite for ib test-context-usage command
# Run from repo root: ./tests/test-context-usage.sh
#
# Fixture naming convention: {expected-value}-{description}.txt
# The expected value is extracted from the filename prefix (before first hyphen).

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/context-usage"
PASSED=0
FAILED=0

echo "Running context-usage tests..."
echo "========================================"
echo ""

# Loop through all fixture files
for fixture_path in "$FIXTURES_DIR"/*.txt; do
    filename=$(basename "$fixture_path")

    # Extract expected value from filename (everything before first hyphen)
    expected="${filename%%-*}"

    # Get description from filename (everything after first hyphen, minus .txt)
    description="${filename#*-}"
    description="${description%.txt}"
    description="${description//-/ }"

    # Run ib test-context-usage with file argument
    actual=$("$IB" test-context-usage "$fixture_path")

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
