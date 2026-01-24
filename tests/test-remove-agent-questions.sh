#!/bin/bash
# Test suite for ib test-remove-agent-questions command
# Tests that remove_agent_questions correctly removes questions by agent ID
# Run from repo root: ./tests/test-remove-agent-questions.sh

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

FIXTURES_DIR="$SCRIPT_DIR/fixtures/remove-agent-questions"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo -e "${RED}Error: fixtures directory not found at $FIXTURES_DIR${NC}"
    exit 1
fi

PASSED=0
FAILED=0

echo "Running test-remove-agent-questions tests..."
echo "========================================"
echo ""

# Loop through all JSON fixture files
for fixture_path in "$FIXTURES_DIR"/*.json; do
    [[ -f "$fixture_path" ]] || continue

    filename=$(basename "$fixture_path")
    basename="${filename%.json}"

    # Get expected output from fixture
    if command -v jq &>/dev/null; then
        expected=$(jq -r '.expected_output // ""' "$fixture_path")
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
data.expected_output || '';
" 2>/dev/null)
    fi

    # Get description from filename (replace hyphens with spaces)
    description="${basename//-/ }"

    # Run ib test-remove-agent-questions with file argument
    actual=$("$IB" test-remove-agent-questions "$fixture_path") || actual="error"

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC} $description"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}FAIL${NC} $description"
        echo "       Expected: $expected"
        echo "       Got:      $actual"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
