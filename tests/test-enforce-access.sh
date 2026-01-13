#!/bin/bash
# Test suite for ib test-enforce-access command
# Run from repo root: ./tests/test-enforce-access.sh
#
# NOTE: This test suite must be run from outside agent context (user terminal or CI).
# Running from within an agent worktree will fail because test-* commands are blocked for agents.
#
# Fixture naming convention: {expected-decision}-{description}.json
# The expected decision (allow or deny) is extracted from the filename prefix (before first hyphen).
#
# Tests the command access restriction policy:
# - Agents are blocked from: watch, parse-state, test-*, hooks install/uninstall
# - Agents are allowed: list, send, look, new-agent, hooks status, etc.
# - Non-agents (users, primary Claude) can run any command

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/enforce-access"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0

echo "Running test-enforce-access tests..."
echo "========================================"
echo ""

# Loop through all fixture files
for fixture_path in "$FIXTURES_DIR"/*.json; do
    # Skip if no files found
    [[ -e "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")

    # Extract expected decision from filename (everything before first hyphen)
    expected="${filename%%-*}"

    # Get description from filename (everything after first hyphen, minus .json)
    description="${filename#*-}"
    description="${description%.json}"
    description="${description//-/ }"

    # Run ib test-enforce-access with fixture file
    actual=$("$IB" test-enforce-access "$fixture_path" 2>&1) || true

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
