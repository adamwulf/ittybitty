#!/bin/bash
# Test suite for ib test-load-prompts command
# Run from repo root: ./tests/test-load-prompts.sh
#
# Fixture structure:
#   - Each subdirectory contains:
#     - prompts/ subdirectory with optional all.md, manager.md, worker.md
#     - expected file with expected output

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/load-prompts"
PASSED=0
FAILED=0

echo "Running load-prompts tests..."
echo "========================================"
echo ""

# Loop through all fixture directories
for fixture_dir in "$FIXTURES_DIR"/*/; do
    [[ -d "$fixture_dir" ]] || continue

    dirname=$(basename "$fixture_dir")
    expected_file="$fixture_dir/expected"

    if [[ ! -f "$expected_file" ]]; then
        echo -e "${RED}SKIP${NC} [$dirname] Missing expected file"
        continue
    fi

    # Get description from directory name (replace hyphens with spaces)
    description="${dirname//-/ }"

    # Run ib test-load-prompts with directory argument
    actual=$("$IB" test-load-prompts "$fixture_dir")
    expected=$(cat "$expected_file")

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} $description"
        ((PASSED++)) || true
    else
        echo -e "${RED}FAIL${NC} $description"
        echo "       Expected:"
        echo "$expected" | sed 's/^/         /'
        echo "       Got:"
        echo "$actual" | sed 's/^/         /'
        ((FAILED++)) || true
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
