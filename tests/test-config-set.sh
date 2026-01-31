#!/bin/bash
# Test suite for ib config set/get commands
# Run from repo root: ./tests/test-config-set.sh

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

echo "Running config set/get tests..."
echo "========================================"
echo ""

# ===========================================
# CONFIG SET - String values
# ===========================================

# Test: Set string value (should NOT be double-quoted)
rm -f .ittybitty.json
"$IB" config set model sonnet >/dev/null
content=$(cat .ittybitty.json)
# Should be "model": "sonnet" NOT "model": "\"sonnet\""
if [[ "$content" == *'"model": "sonnet"'* ]] && [[ "$content" != *'\"sonnet\"'* ]]; then
    pass "set string value without double-quoting"
else
    fail "set string value without double-quoting" "Content: $content"
fi

# Test: Set another string value
rm -f .ittybitty.json
"$IB" config set externalDiffTool vimdiff >/dev/null
content=$(cat .ittybitty.json)
if [[ "$content" == *'"externalDiffTool": "vimdiff"'* ]]; then
    pass "set externalDiffTool string"
else
    fail "set externalDiffTool string" "Content: $content"
fi

# ===========================================
# CONFIG SET - Integer values
# ===========================================

# Test: Set integer value (should be unquoted)
rm -f .ittybitty.json
"$IB" config set maxAgents 5 >/dev/null
content=$(cat .ittybitty.json)
# Should be "maxAgents": 5 NOT "maxAgents": "5"
if [[ "$content" == *'"maxAgents": 5'* ]]; then
    pass "set maxAgents as integer"
else
    fail "set maxAgents as integer" "Content: $content"
fi

# Test: Set fps as integer
rm -f .ittybitty.json
"$IB" config set fps 30 >/dev/null
content=$(cat .ittybitty.json)
if [[ "$content" == *'"fps": 30'* ]]; then
    pass "set fps as integer"
else
    fail "set fps as integer" "Content: $content"
fi

# Test: Set autoCompactThreshold as integer
rm -f .ittybitty.json
"$IB" config set autoCompactThreshold 80 >/dev/null
content=$(cat .ittybitty.json)
if [[ "$content" == *'"autoCompactThreshold": 80'* ]]; then
    pass "set autoCompactThreshold as integer"
else
    fail "set autoCompactThreshold as integer" "Content: $content"
fi

# ===========================================
# CONFIG SET - Boolean values
# ===========================================

# Test: Set boolean true (should be unquoted)
rm -f .ittybitty.json
"$IB" config set createPullRequests true >/dev/null
content=$(cat .ittybitty.json)
# Should be "createPullRequests": true NOT "createPullRequests": "true"
if [[ "$content" == *'"createPullRequests": true'* ]]; then
    pass "set createPullRequests boolean true"
else
    fail "set createPullRequests boolean true" "Content: $content"
fi

# Test: Set boolean false (should be unquoted)
rm -f .ittybitty.json
"$IB" config set createPullRequests false >/dev/null
content=$(cat .ittybitty.json)
# Should be "createPullRequests": false NOT "createPullRequests": "false"
if [[ "$content" == *'"createPullRequests": false'* ]]; then
    pass "set createPullRequests boolean false"
else
    fail "set createPullRequests boolean false" "Content: $content"
fi

# Test: Set allowAgentQuestions boolean
rm -f .ittybitty.json
"$IB" config set allowAgentQuestions true >/dev/null
content=$(cat .ittybitty.json)
if [[ "$content" == *'"allowAgentQuestions": true'* ]]; then
    pass "set allowAgentQuestions boolean true"
else
    fail "set allowAgentQuestions boolean true" "Content: $content"
fi

# ===========================================
# CONFIG SET - Overwrite existing value
# ===========================================

# Test: Overwrite existing value
rm -f .ittybitty.json
"$IB" config set model sonnet >/dev/null
"$IB" config set model opus >/dev/null
content=$(cat .ittybitty.json)
if [[ "$content" == *'"model": "opus"'* ]] && [[ "$content" != *'sonnet'* ]]; then
    pass "overwrite existing string value"
else
    fail "overwrite existing string value" "Content: $content"
fi

# Test: Overwrite integer with different integer
rm -f .ittybitty.json
"$IB" config set fps 10 >/dev/null
"$IB" config set fps 30 >/dev/null
content=$(cat .ittybitty.json)
if [[ "$content" == *'"fps": 30'* ]] && [[ "$content" != *': 10'* ]]; then
    pass "overwrite existing integer value"
else
    fail "overwrite existing integer value" "Content: $content"
fi

# ===========================================
# CONFIG GET - Read values back
# ===========================================

# Test: Get string value
rm -f .ittybitty.json
"$IB" config set model haiku >/dev/null
result=$("$IB" config get model)
if [[ "$result" == "haiku" ]]; then
    pass "get string value"
else
    fail "get string value" "Expected 'haiku', got '$result'"
fi

# Test: Get integer value
rm -f .ittybitty.json
"$IB" config set fps 15 >/dev/null
result=$("$IB" config get fps)
if [[ "$result" == "15" ]]; then
    pass "get integer value"
else
    fail "get integer value" "Expected '15', got '$result'"
fi

# Test: Get boolean value
rm -f .ittybitty.json
"$IB" config set createPullRequests true >/dev/null
result=$("$IB" config get createPullRequests)
if [[ "$result" == "true" ]]; then
    pass "get boolean value"
else
    fail "get boolean value" "Expected 'true', got '$result'"
fi

# Test: Get missing key returns empty
rm -f .ittybitty.json
echo '{}' > .ittybitty.json
result=$("$IB" config get nonexistent 2>/dev/null) || true
if [[ -z "$result" || "$result" == "" ]]; then
    pass "get missing key returns empty"
else
    fail "get missing key returns empty" "Expected empty, got '$result'"
fi

# Test: Get from missing file returns empty (defaults)
rm -f .ittybitty.json
result=$("$IB" config get model 2>/dev/null) || true
if [[ -z "$result" || "$result" == "" ]]; then
    pass "get from missing file returns empty"
else
    fail "get from missing file returns empty" "Expected empty, got '$result'"
fi

# ===========================================
# CONFIG SET - Error cases
# ===========================================

# Test: Set requires key
rm -f .ittybitty.json
result=$("$IB" config set 2>&1) || true
if [[ "$result" == *"Key required"* ]]; then
    pass "set requires key"
else
    fail "set requires key" "Output: $result"
fi

# Test: Set requires value
rm -f .ittybitty.json
result=$("$IB" config set model 2>&1) || true
if [[ "$result" == *"Value required"* ]]; then
    pass "set requires value"
else
    fail "set requires value" "Output: $result"
fi

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
