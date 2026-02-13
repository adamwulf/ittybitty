#!/bin/bash
# Test suite for ib test-session-start command
# Run from repo root: ./tests/test-session-start.sh
#
# Fixture naming convention: {expected-type}-{description}.json
# The expected type (primary, manager, or worker) is extracted from the filename prefix (before first hyphen).

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Find the ib script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IB="$REPO_ROOT/ib"

if [[ ! -x "$IB" ]]; then
    echo -e "${RED}Error: ib script not found or not executable at $IB${NC}"
    exit 1
fi

FIXTURES_DIR="$SCRIPT_DIR/fixtures/session-start"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0

echo "Running test-session-start tests..."
echo "========================================"
echo ""

# Loop through all fixture files (skip meta-*.json helper files)
for fixture_path in "$FIXTURES_DIR"/*.json; do
    [[ -e "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")

    # Skip meta helper files
    [[ "$filename" == meta-* ]] && continue

    # Extract expected type from filename (everything before first hyphen)
    expected="${filename%%-*}"

    # Get description from filename
    description="${filename#*-}"
    description="${description%.json}"
    description="${description//-/ }"

    # Run test
    actual=$("$IB" test-session-start "$fixture_path" 2>&1) || true

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
