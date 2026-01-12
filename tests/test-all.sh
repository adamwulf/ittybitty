#!/bin/bash
# Master test runner for all ib test suites
# Run from repo root: ./tests/test-all.sh
#
# This script runs all test-*.sh scripts in the tests directory
# and reports overall pass/fail status.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to repo root
cd "$REPO_ROOT"

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
FAILED_NAMES=()

echo -e "${BLUE}========================================"
echo "         ib Test Suite Runner"
echo -e "========================================${NC}"
echo ""

# Find all test scripts (excluding test-all.sh itself)
for test_script in "$SCRIPT_DIR"/test-*.sh; do
    [[ -f "$test_script" ]] || continue

    # Skip this script
    [[ "$(basename "$test_script")" == "test-all.sh" ]] && continue

    suite_name=$(basename "$test_script" .sh)

    echo -e "${YELLOW}Running $suite_name...${NC}"
    echo ""

    ((TOTAL_SUITES++))

    # Run the test script
    if bash "$test_script"; then
        echo -e "${GREEN}$suite_name: PASSED${NC}"
        ((PASSED_SUITES++))
    else
        echo -e "${RED}$suite_name: FAILED${NC}"
        ((FAILED_SUITES++))
        FAILED_NAMES+=("$suite_name")
    fi

    echo ""
done

# Summary
echo -e "${BLUE}========================================"
echo "              Summary"
echo -e "========================================${NC}"
echo ""
echo "Total suites: $TOTAL_SUITES"
echo -e "Passed: ${GREEN}$PASSED_SUITES${NC}"
echo -e "Failed: ${RED}$FAILED_SUITES${NC}"

if [[ $FAILED_SUITES -gt 0 ]]; then
    echo ""
    echo -e "${RED}Failed suites:${NC}"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
    echo ""
    exit 1
else
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
