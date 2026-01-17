#!/bin/bash
# Test suite for ib config add/remove commands
# Run from repo root: ./tests/test-config-array.sh

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

echo "Running config array tests..."
echo "========================================"
echo ""

# Test 1: Add to new file creates proper structure
rm -f .ittybitty.json
output=$("$IB" config add permissions.manager.allow "Read")
if [[ "$output" == "Added 'Read' to permissions.manager.allow" ]]; then
    # Verify the JSON structure
    value=$(jq -r '.permissions.manager.allow[0]' .ittybitty.json 2>/dev/null)
    if [[ "$value" == "Read" ]]; then
        pass "add to new file creates structure"
    else
        fail "add to new file creates structure" "JSON value incorrect: $value"
    fi
else
    fail "add to new file creates structure" "Output: $output"
fi

# Test 2: Add prevents duplicates
output=$("$IB" config add permissions.manager.allow "Read")
if [[ "$output" == "Value 'Read' already exists in permissions.manager.allow" ]]; then
    # Verify only one entry exists
    count=$(jq '.permissions.manager.allow | length' .ittybitty.json 2>/dev/null)
    if [[ "$count" == "1" ]]; then
        pass "add prevents duplicates"
    else
        fail "add prevents duplicates" "Array has $count items instead of 1"
    fi
else
    fail "add prevents duplicates" "Output: $output"
fi

# Test 3: Add multiple values
"$IB" config add permissions.manager.allow "Write" >/dev/null
"$IB" config add permissions.manager.allow "Edit" >/dev/null
count=$(jq '.permissions.manager.allow | length' .ittybitty.json 2>/dev/null)
if [[ "$count" == "3" ]]; then
    pass "add multiple values"
else
    fail "add multiple values" "Expected 3 items, got $count"
fi

# Test 4: Remove existing value
output=$("$IB" config remove permissions.manager.allow "Write")
if [[ "$output" == "Removed 'Write' from permissions.manager.allow" ]]; then
    # Verify it's gone
    has_write=$(jq '.permissions.manager.allow | index("Write")' .ittybitty.json 2>/dev/null)
    if [[ "$has_write" == "null" ]]; then
        pass "remove existing value"
    else
        fail "remove existing value" "Value still present in array"
    fi
else
    fail "remove existing value" "Output: $output"
fi

# Test 5: Remove non-existent value
output=$("$IB" config remove permissions.manager.allow "NotThere")
if [[ "$output" == "Value 'NotThere' not found in permissions.manager.allow" ]]; then
    pass "remove non-existent value"
else
    fail "remove non-existent value" "Output: $output"
fi

# Test 6: Add rejects non-array keys
output=$("$IB" config add model "sonnet" 2>&1) || true
if [[ "$output" == *"'add' only works with array keys"* ]]; then
    pass "add rejects non-array keys"
else
    fail "add rejects non-array keys" "Output: $output"
fi

# Test 7: Remove rejects non-array keys
output=$("$IB" config remove maxAgents "10" 2>&1) || true
if [[ "$output" == *"'remove' only works with array keys"* ]]; then
    pass "remove rejects non-array keys"
else
    fail "remove rejects non-array keys" "Output: $output"
fi

# Test 8: Add to permissions.worker.deny
output=$("$IB" config add permissions.worker.deny "Bash(curl:*)")
if [[ "$output" == "Added 'Bash(curl:*)' to permissions.worker.deny" ]]; then
    value=$(jq -r '.permissions.worker.deny[0]' .ittybitty.json 2>/dev/null)
    if [[ "$value" == "Bash(curl:*)" ]]; then
        pass "add to permissions.worker.deny"
    else
        fail "add to permissions.worker.deny" "JSON value incorrect: $value"
    fi
else
    fail "add to permissions.worker.deny" "Output: $output"
fi

# Test 9: Add requires key
output=$("$IB" config add 2>&1) || true
if [[ "$output" == *"Error: Key required"* ]]; then
    pass "add requires key"
else
    fail "add requires key" "Output: $output"
fi

# Test 10: Add requires value
output=$("$IB" config add permissions.manager.allow 2>&1) || true
if [[ "$output" == *"Error: Value required"* ]]; then
    pass "add requires value"
else
    fail "add requires value" "Output: $output"
fi

# Test 11: Remove from missing file
rm -f .ittybitty.json
output=$("$IB" config remove permissions.manager.allow "Read" 2>&1) || true
if [[ "$output" == *"not found"* ]] || [[ "$output" == *"Config file not found"* ]]; then
    pass "remove from missing file"
else
    fail "remove from missing file" "Output: $output"
fi

# Test 12: Test all four array keys work
echo '{}' > .ittybitty.json
"$IB" config add permissions.manager.allow "Tool1" >/dev/null
"$IB" config add permissions.manager.deny "Tool2" >/dev/null
"$IB" config add permissions.worker.allow "Tool3" >/dev/null
"$IB" config add permissions.worker.deny "Tool4" >/dev/null

all_present=true
for key in "permissions.manager.allow" "permissions.manager.deny" "permissions.worker.allow" "permissions.worker.deny"; do
    len=$(jq ".$key | length" .ittybitty.json 2>/dev/null)
    if [[ "$len" != "1" ]]; then
        all_present=false
        break
    fi
done

if [[ "$all_present" == "true" ]]; then
    pass "all four array keys work"
else
    fail "all four array keys work" "Some keys missing or incorrect length"
fi

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
