#!/bin/bash
#
# Test suite for validate_agent_metadata() / test-validate-meta command
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IB="$REPO_ROOT/ib"

if [[ ! -x "$IB" ]]; then
    echo -e "\033[0;31mError: ib script not found or not executable at $IB\033[0m"
    exit 1
fi

FIXTURES_DIR="$SCRIPT_DIR/fixtures/validate-meta"

echo "Running test-validate-meta tests..."
echo "========================================"
echo ""

pass_count=0
fail_count=0

for fixture in "$FIXTURES_DIR"/*.json; do
    [[ -f "$fixture" ]] || continue

    # Extract expected result from filename (valid-* or invalid-*)
    filename=$(basename "$fixture" .json)
    expected="${filename%%-*}"

    # Run the test
    result=$("$IB" test-validate-meta "$fixture" | head -1)

    if [[ "$result" == "$expected" ]]; then
        echo -e "\033[0;32mPASS\033[0m [$expected] $filename"
        pass_count=$((pass_count + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m [$expected] $filename (got: $result)"
        fail_count=$((fail_count + 1))
    fi
done

echo ""
echo "========================================"
echo "Results: $pass_count passed, $fail_count failed"

if [[ $fail_count -gt 0 ]]; then
    exit 1
fi
