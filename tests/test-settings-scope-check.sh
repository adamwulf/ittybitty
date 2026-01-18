#!/bin/bash
# Test suite for ib test-settings-scope-check command
# Run from repo root: ./tests/test-settings-scope-check.sh
#
# Tests the scope mismatch detection that prevents accidentally using
# cached values from one scope (user/project) when requesting another.
#
# Fixture format:
#   - Input files: *.txt (line 1: cached_scope, line 2: requested_scope)
#   - Expected output files: *.expected (matching input filename)

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/settings-scope-check"
PASSED=0
FAILED=0

echo "Running settings-scope-check tests..."
echo "========================================"
echo ""

# Loop through all .txt fixture files
for fixture_path in "$FIXTURES_DIR"/*.txt; do
    [[ -f "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")
    basename="${filename%.txt}"

    # Find the corresponding .expected file
    expected_file="$FIXTURES_DIR/${basename}.expected"

    if [[ ! -f "$expected_file" ]]; then
        echo -e "${RED}SKIP${NC} [$basename] Missing expected file: ${basename}.expected"
        continue
    fi

    # Read cached_scope and requested_scope from fixture
    cached_scope=$(sed -n '1p' "$fixture_path")
    requested_scope=$(sed -n '2p' "$fixture_path")

    # Get description from filename (replace hyphens with spaces)
    description="${basename//-/ }"

    # Run ib test-settings-scope-check (ignore exit code since mismatch returns 1)
    actual=$("$IB" test-settings-scope-check "$cached_scope" "$requested_scope" 2>&1) || true
    expected=$(cat "$expected_file")

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $description"
        echo "       Expected:"
        echo "$expected" | sed 's/^/         /'
        echo "       Got:"
        echo "$actual" | sed 's/^/         /'
        ((FAILED++))
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
