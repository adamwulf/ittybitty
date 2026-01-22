#!/bin/bash
# Test suite for ib test-filter-questions command
# Tests that questions from dead agents are filtered out
# Also tests output format correctness
# Run from repo root: ./tests/test-filter-questions.sh

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/filter-questions"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0

echo "Running test-filter-questions tests..."
echo "========================================"
echo ""

# Loop through all JSON fixture files
for fixture_path in "$FIXTURES_DIR"/*.json; do
    [[ -f "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")
    basename="${filename%.json}"

    # Get expected count from fixture
    if command -v jq &>/dev/null; then
        expected=$(jq -r '.expected_count // "0"' "$fixture_path")
    else
        json_b64=$(base64 < "$fixture_path")
        expected=$(osascript -l JavaScript -e "
ObjC.import('Foundation');
function decodeB64(b64) {
    return $.NSString.alloc.initWithDataEncoding(
        $.NSData.alloc.initWithBase64EncodedStringOptions(b64, 0),
        $.NSUTF8StringEncoding
    ).js;
}
var data = JSON.parse(decodeB64('$json_b64'));
data.expected_count || '0';
" 2>/dev/null)
    fi

    # Get description from filename (replace hyphens with spaces)
    description="${basename//-/ }"

    # Run ib test-filter-questions with file argument
    actual=$("$IB" test-filter-questions "$fixture_path") || actual="error"

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} [$expected] $description"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}FAIL${NC} [$expected] $description"
        echo "       Expected: $expected"
        echo "       Got:      $actual"
        FAILED=$((FAILED + 1))
    fi

    # Check output format if expected_output_contains is defined
    if command -v jq &>/dev/null; then
        has_output_test=$(jq -r 'if .expected_output_contains then "yes" else "no" end' "$fixture_path")
    else
        has_output_test=$(osascript -l JavaScript -e "
ObjC.import('Foundation');
function decodeB64(b64) {
    return $.NSString.alloc.initWithDataEncoding(
        $.NSData.alloc.initWithBase64EncodedStringOptions(b64, 0),
        $.NSUTF8StringEncoding
    ).js;
}
var data = JSON.parse(decodeB64('$(base64 < "$fixture_path")'));
data.expected_output_contains ? 'yes' : 'no';
" 2>/dev/null)
    fi

    if [[ "$has_output_test" == "yes" ]]; then
        # Get actual output
        actual_output=$("$IB" test-filter-questions-output "$fixture_path" 2>/dev/null) || actual_output=""

        # Get expected strings to check
        if command -v jq &>/dev/null; then
            expected_strings=$(jq -r '.expected_output_contains[]' "$fixture_path")
        else
            expected_strings=$(osascript -l JavaScript -e "
ObjC.import('Foundation');
function decodeB64(b64) {
    return $.NSString.alloc.initWithDataEncoding(
        $.NSData.alloc.initWithBase64EncodedStringOptions(b64, 0),
        $.NSUTF8StringEncoding
    ).js;
}
var data = JSON.parse(decodeB64('$(base64 < "$fixture_path")'));
(data.expected_output_contains || []).join('\n');
" 2>/dev/null)
        fi

        # Check each expected string
        output_test_passed=true
        missing_strings=""
        while IFS= read -r expected_str; do
            [[ -z "$expected_str" ]] && continue || true  # set -e safety
            if ! echo "$actual_output" | grep -qF "$expected_str"; then
                output_test_passed=false
                missing_strings="${missing_strings}  Missing: $expected_str\n"
            fi
        done <<< "$expected_strings"

        if [[ "$output_test_passed" == "true" ]]; then
            echo -e "${GREEN}PASS${NC} [output] $description (format check)"
            PASSED=$((PASSED + 1))
        else
            echo -e "${RED}FAIL${NC} [output] $description (format check)"
            echo -e "$missing_strings"
            echo "       Actual output:"
            echo "$actual_output" | sed 's/^/       /'
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
