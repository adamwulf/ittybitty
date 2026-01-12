#!/bin/bash
# Test suite for ib parse-state command
# Run from repo root: ./tests/test-parse-state.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Find the ib script (look for it in repo root relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IB="$REPO_ROOT/ib"

if [[ ! -x "$IB" ]]; then
    echo -e "${RED}Error: ib script not found or not executable at $IB${NC}"
    exit 1
fi

FIXTURES_DIR="$SCRIPT_DIR/fixtures"
PASSED=0
FAILED=0
TOTAL=0

# Test function: expects fixture file and expected state
test_fixture() {
    local fixture="$1"
    local expected="$2"
    local description="$3"

    ((TOTAL++))

    local fixture_path="$FIXTURES_DIR/$fixture"
    if [[ ! -f "$fixture_path" ]]; then
        echo -e "${YELLOW}SKIP${NC} $description - fixture not found: $fixture"
        return
    fi

    local actual
    actual=$("$IB" parse-state "$fixture_path")

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $description"
        echo "       Expected: $expected"
        echo "       Got:      $actual"
        ((FAILED++))
    fi
}

# Test function for inline input
test_inline() {
    local input="$1"
    local expected="$2"
    local description="$3"

    ((TOTAL++))

    local actual
    actual=$(echo "$input" | "$IB" parse-state)

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $description"
        echo "       Expected: $expected"
        echo "       Got:      $actual"
        ((FAILED++))
    fi
}

echo "Running parse-state tests..."
echo "========================================"

# Complete state tests
echo ""
echo "Complete state tests:"
test_fixture "complete-simple.txt" "complete" "Simple completion phrase"
test_fixture "complete-with-bullet.txt" "complete" "Completion with bullet marker (bug fix test)"
test_fixture "edge-complete-with-bullet-near-end.txt" "complete" "Completion with bullet nearby"

# Waiting state tests
echo ""
echo "Waiting state tests:"
test_fixture "waiting-standalone.txt" "waiting" "Standalone WAITING"
test_fixture "waiting-with-bullet.txt" "waiting" "WAITING with bullet marker"

# Running state tests
echo ""
echo "Running state tests:"
test_fixture "running-tool.txt" "running" "Tool with esc to interrupt"
test_fixture "running-bash.txt" "running" "Bash with ctrl+c to interrupt"
test_fixture "running-thinking.txt" "running" "Model thinking indicator"
test_fixture "running-tmux-passthrough.txt" "running" "Tmux passthrough mode"
test_fixture "running-explicit.txt" "running" "Explicit Running status"

# Edge cases
echo ""
echo "Edge case tests:"
test_fixture "edge-running-with-old-complete.txt" "running" "Running with old complete in history (outside last 15 lines)"
test_fixture "edge-complete-in-history-but-running.txt" "running" "Complete in recent output but strong running indicator active"

# Unknown state tests
echo ""
echo "Unknown state tests:"
test_fixture "unknown-idle.txt" "unknown" "Idle with no state indicators"

# Inline tests for specific patterns
echo ""
echo "Inline pattern tests:"
test_inline "⏺ I HAVE COMPLETED THE GOAL" "complete" "Bullet followed by completion"
test_inline "⏺ Bash(ls)" "running" "Bullet with tool invocation"
test_inline "⏺ Read(/path/to/file)" "running" "Bullet with Read tool"
test_inline "⏺ Write(/path/to/file)" "running" "Bullet with Write tool"
test_inline "⏺ Edit(/path/to/file)" "running" "Bullet with Edit tool"
test_inline "⏺ Grep(pattern)" "running" "Bullet with Grep tool"
test_inline "⏺ Glob(*.txt)" "running" "Bullet with Glob tool"
test_inline "⏺ Task(...)" "running" "Bullet with Task tool"
test_inline "⏺ TodoWrite(...)" "running" "Bullet with TodoWrite tool"
test_inline "⏺ Just some message" "unknown" "Bullet with plain text (not a tool)"
test_inline "WAITING" "waiting" "Just WAITING"
test_inline "  WAITING  " "waiting" "WAITING with whitespace"
test_inline "" "unknown" "Empty input"

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed, $TOTAL total"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
