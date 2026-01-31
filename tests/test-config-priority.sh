#!/bin/bash
# Test suite for config priority logic (project > user > default)
# Run from repo root: ./tests/test-config-priority.sh

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

echo "Running config-priority tests..."
echo "========================================"
echo ""

USER_FILE="$TEST_DIR/user.json"
PROJECT_FILE="$TEST_DIR/project.json"

# ===========================================
# Test: Default value when neither file exists
# ===========================================
rm -f "$USER_FILE" "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "maxAgents")
if [[ "$result" == "10 (default)" ]]; then
    pass "default value when neither file exists"
else
    fail "default value when neither file exists" "10 (default)" "$result"
fi

# ===========================================
# Test: User config used when project config missing
# ===========================================
echo '{"maxAgents": 25}' > "$USER_FILE"
rm -f "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "maxAgents")
if [[ "$result" == "25 (user)" ]]; then
    pass "user config when project missing"
else
    fail "user config when project missing" "25 (user)" "$result"
fi

# ===========================================
# Test: Project config overrides user config
# ===========================================
echo '{"maxAgents": 25}' > "$USER_FILE"
echo '{"maxAgents": 50}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "maxAgents")
if [[ "$result" == "50 (project)" ]]; then
    pass "project overrides user"
else
    fail "project overrides user" "50 (project)" "$result"
fi

# ===========================================
# Test: User value used when key missing in project
# ===========================================
echo '{"model": "opus"}' > "$USER_FILE"
echo '{"maxAgents": 50}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "model")
if [[ "$result" == "opus (user)" ]]; then
    pass "user value when key missing in project"
else
    fail "user value when key missing in project" "opus (user)" "$result"
fi

# ===========================================
# Test: Default when key missing in both files
# ===========================================
echo '{"other": "value"}' > "$USER_FILE"
echo '{"something": "else"}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "maxAgents")
if [[ "$result" == "10 (default)" ]]; then
    pass "default when key missing in both"
else
    fail "default when key missing in both" "10 (default)" "$result"
fi

# ===========================================
# Test: Project config used when user file missing
# ===========================================
rm -f "$USER_FILE"
echo '{"createPullRequests": true}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "createPullRequests")
if [[ "$result" == "true (project)" ]]; then
    pass "project config when user missing"
else
    fail "project config when user missing" "true (project)" "$result"
fi

# ===========================================
# Test: Boolean false in project overrides user true
# ===========================================
echo '{"createPullRequests": true}' > "$USER_FILE"
echo '{"createPullRequests": false}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "createPullRequests")
if [[ "$result" == "false (project)" ]]; then
    pass "project false overrides user true"
else
    fail "project false overrides user true" "false (project)" "$result"
fi

# ===========================================
# Test: Empty string in project overrides user value
# ===========================================
echo '{"externalDiffTool": "vimdiff"}' > "$USER_FILE"
echo '{"externalDiffTool": ""}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "externalDiffTool")
# Note: empty string with existing key should show (project)
if [[ "$result" == "(unset) (project)" ]]; then
    pass "empty string in project overrides user"
else
    fail "empty string in project overrides user" "(unset) (project)" "$result"
fi

# ===========================================
# Test: Nested key - project overrides user
# ===========================================
echo '{"permissions": {"manager": {"allow": ["Read"]}}}' > "$USER_FILE"
echo '{"permissions": {"manager": {"allow": ["Write"]}}}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "permissions.manager.allow")
if [[ "$result" == '["Write"] (project)' ]]; then
    pass "nested key project overrides user"
else
    fail "nested key project overrides user" '["Write"] (project)' "$result"
fi

# ===========================================
# Test: Nested key - user used when project key missing
# ===========================================
echo '{"permissions": {"manager": {"allow": ["Read"]}}}' > "$USER_FILE"
echo '{}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "permissions.manager.allow")
if [[ "$result" == '["Read"] (user)' ]]; then
    pass "nested key user when project missing"
else
    fail "nested key user when project missing" '["Read"] (user)' "$result"
fi

# ===========================================
# Test: Empty array in project overrides user array
# ===========================================
echo '{"permissions": {"manager": {"allow": ["Read", "Write"]}}}' > "$USER_FILE"
echo '{"permissions": {"manager": {"allow": []}}}' > "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "permissions.manager.allow")
if [[ "$result" == "[] (project)" ]]; then
    pass "empty array in project overrides user"
else
    fail "empty array in project overrides user" "[] (project)" "$result"
fi

# ===========================================
# Test: Default for unset key (model has empty default)
# ===========================================
rm -f "$USER_FILE" "$PROJECT_FILE"
result=$("$IB" test-config-priority "$USER_FILE" "$PROJECT_FILE" "model")
if [[ "$result" == "(unset) (default)" ]]; then
    pass "unset key with empty default"
else
    fail "unset key with empty default" "(unset) (default)" "$result"
fi

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
