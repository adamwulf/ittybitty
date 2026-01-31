#!/bin/bash
# Test suite for json_has function
# Run from repo root: ./tests/test-json-has.sh

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

PASSED=0
FAILED=0

# Create a temporary directory for test files
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

pass() {
    echo -e "${GREEN}PASS${NC} $1"
    ((PASSED++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC} $1"
    echo "       Expected: $2"
    echo "       Got: $3"
    ((FAILED++)) || true
}

echo "Running json-has tests..."
echo "========================================"
echo ""

# ===========================================
# Test: Key exists with string value
# ===========================================
echo '{"model": "opus"}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "model")
if [[ "$result" == "true" ]]; then
    pass "key exists with string value"
else
    fail "key exists with string value" "true" "$result"
fi

# ===========================================
# Test: Key exists with integer value
# ===========================================
echo '{"maxAgents": 20}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "maxAgents")
if [[ "$result" == "true" ]]; then
    pass "key exists with integer value"
else
    fail "key exists with integer value" "true" "$result"
fi

# ===========================================
# Test: Key exists with boolean false
# ===========================================
echo '{"createPullRequests": false}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "createPullRequests")
if [[ "$result" == "true" ]]; then
    pass "key exists with boolean false"
else
    fail "key exists with boolean false" "true" "$result"
fi

# ===========================================
# Test: Key exists with empty string
# ===========================================
echo '{"model": ""}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "model")
if [[ "$result" == "true" ]]; then
    pass "key exists with empty string"
else
    fail "key exists with empty string" "true" "$result"
fi

# ===========================================
# Test: Key exists with null value
# ===========================================
echo '{"model": null}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "model")
if [[ "$result" == "true" ]]; then
    pass "key exists with null value"
else
    fail "key exists with null value" "true" "$result"
fi

# ===========================================
# Test: Key does not exist
# ===========================================
echo '{"other": "value"}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "model")
if [[ "$result" == "false" ]]; then
    pass "key does not exist"
else
    fail "key does not exist" "false" "$result"
fi

# ===========================================
# Test: Empty JSON object
# ===========================================
echo '{}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "model")
if [[ "$result" == "false" ]]; then
    pass "empty JSON object"
else
    fail "empty JSON object" "false" "$result"
fi

# ===========================================
# Test: Nested key exists
# ===========================================
echo '{"permissions": {"manager": {"allow": ["Read"]}}}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "permissions.manager.allow")
if [[ "$result" == "true" ]]; then
    pass "nested key exists"
else
    fail "nested key exists" "true" "$result"
fi

# ===========================================
# Test: Nested key does not exist
# ===========================================
echo '{"permissions": {"manager": {}}}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "permissions.manager.allow")
if [[ "$result" == "false" ]]; then
    pass "nested key does not exist"
else
    fail "nested key does not exist" "false" "$result"
fi

# ===========================================
# Test: Partial path exists but not full path
# ===========================================
echo '{"permissions": {}}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "permissions.manager.allow")
if [[ "$result" == "false" ]]; then
    pass "partial path exists but not full path"
else
    fail "partial path exists but not full path" "false" "$result"
fi

# ===========================================
# Test: File does not exist
# ===========================================
result=$("$IB" test-json-has "$TEST_DIR/nonexistent.json" "model")
if [[ "$result" == "false" ]]; then
    pass "file does not exist"
else
    fail "file does not exist" "false" "$result"
fi

# ===========================================
# Test: Key exists with array value
# ===========================================
echo '{"permissions": {"manager": {"allow": ["Read", "Write"]}}}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "permissions.manager.allow")
if [[ "$result" == "true" ]]; then
    pass "key exists with array value"
else
    fail "key exists with array value" "true" "$result"
fi

# ===========================================
# Test: Key exists with empty array
# ===========================================
echo '{"permissions": {"manager": {"allow": []}}}' > "$TEST_DIR/test.json"
result=$("$IB" test-json-has "$TEST_DIR/test.json" "permissions.manager.allow")
if [[ "$result" == "true" ]]; then
    pass "key exists with empty array"
else
    fail "key exists with empty array" "true" "$result"
fi

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
