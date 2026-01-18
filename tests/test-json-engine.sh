#!/bin/bash
# Test JSON helpers with both jq and osascript engines
# Usage: ./tests/test-json-engine.sh [jq|osascript]
# If no engine specified, tests both

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/json"

# Source the ib script to get JSON functions
# We need to override JSON_ENGINE detection for testing
source_ib_with_engine() {
    local engine="$1"

    # Create a temporary copy with forced engine
    local temp_ib=$(mktemp)
    cat "$REPO_DIR/ib" > "$temp_ib"

    # Override the detect_json_engine function
    if [[ "$engine" == "jq" ]]; then
        sed -i.bak 's/detect_json_engine/# detect_json_engine/' "$temp_ib"
        echo "JSON_ENGINE=jq" >> "$temp_ib"
    elif [[ "$engine" == "osascript" ]]; then
        sed -i.bak 's/detect_json_engine/# detect_json_engine/' "$temp_ib"
        echo "JSON_ENGINE=osascript" >> "$temp_ib"
    fi

    echo "$temp_ib"
}

PASS=0
FAIL=0
SKIP=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1 (expected: $2, got: $3)"
    FAIL=$((FAIL + 1))
}

skip() {
    echo "  SKIP: $1"
    SKIP=$((SKIP + 1))
}

test_engine() {
    local engine="$1"
    echo ""
    echo "=== Testing with $engine engine ==="
    echo ""

    # Check if engine is available
    if [[ "$engine" == "jq" ]] && ! command -v jq &>/dev/null; then
        skip "jq not installed"
        return
    fi
    if [[ "$engine" == "osascript" ]] && ! command -v osascript &>/dev/null; then
        skip "osascript not available (not macOS)"
        return
    fi

    # Export engine for child processes
    export JSON_ENGINE="$engine"

    # Source ib script functions (we need to do this carefully)
    # For simplicity, we'll call ib directly with test commands

    echo "--- json_get tests ---"

    # Test 1: Simple key access
    local result
    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-get "$FIXTURES_DIR/get-simple.json" "name")
    if [[ "$result" == "test" ]]; then
        pass "json_get simple key"
    else
        fail "json_get simple key" "test" "$result"
    fi

    # Test 2: Numeric value
    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-get "$FIXTURES_DIR/get-simple.json" "count")
    if [[ "$result" == "42" ]]; then
        pass "json_get numeric"
    else
        fail "json_get numeric" "42" "$result"
    fi

    # Test 3: Boolean value
    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-get "$FIXTURES_DIR/get-simple.json" "active")
    if [[ "$result" == "true" ]]; then
        pass "json_get boolean"
    else
        fail "json_get boolean" "true" "$result"
    fi

    # Test 4: Nested key
    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-get "$FIXTURES_DIR/get-nested.json" "config.settings.debug")
    if [[ "$result" == "true" ]]; then
        pass "json_get nested"
    else
        fail "json_get nested" "true" "$result"
    fi

    # Test 5: Missing key returns empty
    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-get "$FIXTURES_DIR/get-simple.json" "missing")
    if [[ -z "$result" ]]; then
        pass "json_get missing key"
    else
        fail "json_get missing key" "" "$result"
    fi

    # Test 6: Default value for missing key
    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-get "$FIXTURES_DIR/get-simple.json" "missing" "default")
    if [[ "$result" == "default" ]]; then
        pass "json_get default value"
    else
        fail "json_get default value" "default" "$result"
    fi

    echo ""
    echo "--- json_get_array tests ---"

    # Test array iteration
    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-get-array "$FIXTURES_DIR/array-items.json" "tags")
    local expected=$'red\ngreen\nblue'
    if [[ "$result" == "$expected" ]]; then
        pass "json_get_array"
    else
        fail "json_get_array" "$expected" "$result"
    fi

    echo ""
    echo "--- json_array_length tests ---"

    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-array-length "$FIXTURES_DIR/array-items.json" "tags")
    if [[ "$result" == "3" ]]; then
        pass "json_array_length"
    else
        fail "json_array_length" "3" "$result"
    fi

    echo ""
    echo "--- json_escape tests ---"

    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-escape 'hello "world"')
    if [[ "$result" == '"hello \"world\""' ]]; then
        pass "json_escape quotes"
    else
        fail "json_escape quotes" '"hello \"world\""' "$result"
    fi

    echo ""
    echo "--- json_pretty tests ---"

    result=$(JSON_ENGINE=$engine "$REPO_DIR/ib" test-json-pretty '{"a":1}')
    # Check that it contains proper formatting (newlines or at minimum valid JSON)
    if echo "$result" | grep -q '"a"'; then
        pass "json_pretty"
    else
        fail "json_pretty" "formatted JSON" "$result"
    fi
}

# Main
echo "JSON Engine Tests"
echo "================="

if [[ -n "$1" ]]; then
    # Test specific engine
    test_engine "$1"
else
    # Test both engines
    test_engine "jq"
    test_engine "osascript"
fi

echo ""
echo "================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
