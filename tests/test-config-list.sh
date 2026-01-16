#!/bin/bash
# Test suite for ib config list command
# Run from repo root: ./tests/test-config-list.sh

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

PASSED=0
FAILED=0

# Create a temporary directory for test configs
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

cd "$TEST_DIR"

pass() {
    echo -e "${GREEN}PASS${NC} $1"
    ((PASSED++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC} $1"
    echo "       $2"
    ((FAILED++)) || true
}

echo "Running config list tests..."
echo "========================================"
echo ""

# ===========================================
# CONFIG LIST - No config file
# ===========================================

# Test: List with no config file shows defaults
rm -f .ittybitty.json
result=$("$IB" config list)
if [[ "$result" == *"maxAgents:"* ]] && [[ "$result" == *"(default)"* ]]; then
    pass "list shows defaults when no config file"
else
    fail "list shows defaults when no config file" "Output: $result"
fi

# ===========================================
# CONFIG LIST - With config file
# ===========================================

# Test: List with empty config file
rm -f .ittybitty.json
echo '{}' > .ittybitty.json
result=$("$IB" config list)
if [[ "$result" == *"maxAgents:"* ]] && [[ "$result" == *"(default)"* ]]; then
    pass "list shows defaults with empty config"
else
    fail "list shows defaults with empty config" "Output: $result"
fi

# Test: List shows customized string value
rm -f .ittybitty.json
"$IB" config set model opus >/dev/null
result=$("$IB" config list)
if [[ "$result" == *"model:"* ]] && [[ "$result" == *"opus"* ]] && [[ "$result" == *"(customized)"* ]]; then
    pass "list shows customized string value"
else
    fail "list shows customized string value" "Output: $result"
fi

# Test: List shows customized integer value
rm -f .ittybitty.json
"$IB" config set maxAgents 25 >/dev/null
result=$("$IB" config list)
if [[ "$result" == *"maxAgents:"* ]] && [[ "$result" == *"25"* ]] && [[ "$result" == *"(customized)"* ]]; then
    pass "list shows customized integer value"
else
    fail "list shows customized integer value" "Output: $result"
fi

# Test: List shows customized boolean value
rm -f .ittybitty.json
"$IB" config set createPullRequests true >/dev/null
result=$("$IB" config list)
if [[ "$result" == *"createPullRequests:"* ]] && [[ "$result" == *"true"* ]] && [[ "$result" == *"(customized)"* ]]; then
    pass "list shows customized boolean value"
else
    fail "list shows customized boolean value" "Output: $result"
fi

# Test: List shows customized array value
rm -f .ittybitty.json
"$IB" config add permissions.manager.allow 'Read' >/dev/null
"$IB" config add permissions.manager.allow 'Write' >/dev/null
result=$("$IB" config list)
if [[ "$result" == *"permissions.manager.allow:"* ]] && [[ "$result" == *"Read"* ]] && [[ "$result" == *"(customized)"* ]]; then
    pass "list shows customized array value"
else
    fail "list shows customized array value" "Output: $result"
fi

# Test: List shows mixed customized and default values
rm -f .ittybitty.json
"$IB" config set model haiku >/dev/null
"$IB" config set fps 30 >/dev/null
result=$("$IB" config list)
# model and fps should be customized
if [[ "$result" == *"model:"*"haiku"*"(customized)"* ]] && \
   [[ "$result" == *"fps:"*"30"*"(customized)"* ]] && \
   [[ "$result" == *"maxAgents:"*"10"*"(default)"* ]]; then
    pass "list shows mixed customized and default values"
else
    fail "list shows mixed customized and default values" "Output: $result"
fi

# Test: List includes legend
rm -f .ittybitty.json
result=$("$IB" config list)
if [[ "$result" == *"Legend:"* ]] && [[ "$result" == *"customized"* ]] && [[ "$result" == *"default"* ]]; then
    pass "list includes legend"
else
    fail "list includes legend" "Output: $result"
fi

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
