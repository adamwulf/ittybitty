#!/bin/bash
# Test suite for ib config --global flag
# Run from repo root: ./tests/test-config-global.sh
#
# Note: This test uses a temporary HOME directory to avoid modifying
# the user's actual ~/.ittybitty.json

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

# Create a fake home directory
FAKE_HOME="$TEST_DIR/home"
mkdir -p "$FAKE_HOME"

pass() {
    echo -e "${GREEN}PASS${NC} $1"
    ((PASSED++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC} $1"
    echo "       $2"
    ((FAILED++)) || true
}

echo "Running config --global tests..."
echo "========================================"
echo ""

# Work in a subdirectory to have a clean project config
WORK_DIR="$TEST_DIR/project"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ===========================================
# Test: --global set creates user config file
# ===========================================
rm -f "$FAKE_HOME/.ittybitty.json"
HOME="$FAKE_HOME" "$IB" config --global set createPullRequests true >/dev/null
if [[ -f "$FAKE_HOME/.ittybitty.json" ]]; then
    value=$(HOME="$FAKE_HOME" "$IB" config --global get createPullRequests)
    if [[ "$value" == "true" ]]; then
        pass "--global set creates user config file"
    else
        fail "--global set creates user config file" "Value not set correctly: $value"
    fi
else
    fail "--global set creates user config file" "File not created"
fi

# ===========================================
# Test: --global get reads from user config
# ===========================================
echo '{"model": "haiku"}' > "$FAKE_HOME/.ittybitty.json"
result=$(HOME="$FAKE_HOME" "$IB" config --global get model)
if [[ "$result" == "haiku" ]]; then
    pass "--global get reads from user config"
else
    fail "--global get reads from user config" "Expected: haiku, Got: $result"
fi

# ===========================================
# Test: --global get ignores project config
# ===========================================
echo '{"model": "haiku"}' > "$FAKE_HOME/.ittybitty.json"
echo '{"model": "opus"}' > .ittybitty.json
result=$(HOME="$FAKE_HOME" "$IB" config --global get model)
if [[ "$result" == "haiku" ]]; then
    pass "--global get ignores project config"
else
    fail "--global get ignores project config" "Expected: haiku, Got: $result"
fi

# ===========================================
# Test: get without --global uses project over user
# ===========================================
echo '{"model": "haiku"}' > "$FAKE_HOME/.ittybitty.json"
echo '{"model": "opus"}' > .ittybitty.json
result=$(HOME="$FAKE_HOME" "$IB" config get model)
if [[ "$result" == "opus" ]]; then
    pass "get without --global uses project over user"
else
    fail "get without --global uses project over user" "Expected: opus, Got: $result"
fi

# ===========================================
# Test: get without --global falls back to user
# ===========================================
echo '{"model": "haiku"}' > "$FAKE_HOME/.ittybitty.json"
rm -f .ittybitty.json
result=$(HOME="$FAKE_HOME" "$IB" config get model)
if [[ "$result" == "haiku" ]]; then
    pass "get without --global falls back to user"
else
    fail "get without --global falls back to user" "Expected: haiku, Got: $result"
fi

# ===========================================
# Test: --global list shows only user config
# ===========================================
echo '{"createPullRequests": true}' > "$FAKE_HOME/.ittybitty.json"
rm -f .ittybitty.json
result=$(HOME="$FAKE_HOME" "$IB" config --global list)
if [[ "$result" == *"createPullRequests:"*"true"*"(user)"* ]] && \
   [[ "$result" == *"~/.ittybitty.json"* ]]; then
    pass "--global list shows user config"
else
    fail "--global list shows user config" "Output: $result"
fi

# ===========================================
# Test: list without --global shows merged view
# ===========================================
echo '{"model": "haiku"}' > "$FAKE_HOME/.ittybitty.json"
echo '{"maxAgents": 25}' > .ittybitty.json
result=$(HOME="$FAKE_HOME" "$IB" config list)
if [[ "$result" == *"maxAgents:"*"25"*"(project)"* ]] && \
   [[ "$result" == *"model:"*"haiku"*"(user)"* ]]; then
    pass "list shows merged view with sources"
else
    fail "list shows merged view with sources" "Output: $result"
fi

# ===========================================
# Test: --global set does not affect project config
# ===========================================
rm -f "$FAKE_HOME/.ittybitty.json"
echo '{}' > .ittybitty.json
HOME="$FAKE_HOME" "$IB" config --global set fps 30 >/dev/null
# Check project config was not modified
project_fps=$(jq -r '.fps // "null"' .ittybitty.json)
if [[ "$project_fps" == "null" ]]; then
    pass "--global set does not affect project config"
else
    fail "--global set does not affect project config" "Project fps was set to: $project_fps"
fi

# ===========================================
# Test: set without --global only affects project
# ===========================================
rm -f "$FAKE_HOME/.ittybitty.json"
echo '{}' > .ittybitty.json
HOME="$FAKE_HOME" "$IB" config set fps 30 >/dev/null
# Check user config was not created
if [[ ! -f "$FAKE_HOME/.ittybitty.json" ]]; then
    pass "set without --global does not create user config"
else
    fail "set without --global does not create user config" "User config was created"
fi

# ===========================================
# Test: --global add works with permissions arrays
# ===========================================
rm -f "$FAKE_HOME/.ittybitty.json"
HOME="$FAKE_HOME" "$IB" config --global add permissions.manager.allow "WebSearch" >/dev/null
result=$(HOME="$FAKE_HOME" "$IB" config --global get permissions.manager.allow)
if [[ "$result" == '["WebSearch"]' ]]; then
    pass "--global add works with permission arrays"
else
    fail "--global add works with permission arrays" "Expected: [\"WebSearch\"], Got: $result"
fi

# ===========================================
# Test: --global remove works with permissions arrays
# ===========================================
echo '{"permissions": {"manager": {"allow": ["Read", "Write"]}}}' > "$FAKE_HOME/.ittybitty.json"
HOME="$FAKE_HOME" "$IB" config --global remove permissions.manager.allow "Read" >/dev/null
result=$(HOME="$FAKE_HOME" "$IB" config --global get permissions.manager.allow)
if [[ "$result" == '["Write"]' ]]; then
    pass "--global remove works with permission arrays"
else
    fail "--global remove works with permission arrays" "Expected: [\"Write\"], Got: $result"
fi

# ===========================================
# Test: -g short flag works same as --global
# ===========================================
echo '{"model": "sonnet"}' > "$FAKE_HOME/.ittybitty.json"
result=$(HOME="$FAKE_HOME" "$IB" config -g get model)
if [[ "$result" == "sonnet" ]]; then
    pass "-g short flag works same as --global"
else
    fail "-g short flag works same as --global" "Expected: sonnet, Got: $result"
fi

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
