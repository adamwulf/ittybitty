#!/bin/bash
# Test suite for ib test-questions command
# Run from repo root: ./tests/test-questions.sh
#
# Fixture naming convention:
#   - Input files: *.json
#   - Expected output files: *.expected (matching input filename)
# Example: one-pending.json -> one-pending.expected

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/questions"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0

echo "Running test-questions tests..."
echo "========================================"
echo ""

# Loop through all JSON fixture files
for fixture_path in "$FIXTURES_DIR"/*.json; do
    [[ -f "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")
    basename="${filename%.json}"

    # Find the corresponding .expected file
    expected_file="$FIXTURES_DIR/${basename}.expected"

    if [[ ! -f "$expected_file" ]]; then
        echo -e "${RED}SKIP${NC} [$basename] Missing expected file: ${basename}.expected"
        continue
    fi

    # Get description from filename (replace hyphens with spaces)
    description="${basename//-/ }"

    # Run ib test-questions with file argument
    actual=$("$IB" test-questions "$fixture_path") || true
    expected=$(cat "$expected_file" | tr -d '\n')

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} $description"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}FAIL${NC} $description"
        echo "       Expected: $expected"
        echo "       Got:      $actual"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
