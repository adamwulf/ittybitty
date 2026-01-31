#!/bin/bash
# Integration test suite for rebase conflict detection
# Run from repo root: ./tests/test-rebase-conflicts.sh
#
# This test creates temporary git repos to test the check_rebase_conflicts function
# and the pre-rebase conflict detection in cmd_merge.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Find the ib script (look for it in repo root relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IB="$REPO_ROOT/ib"

if [[ ! -x "$IB" ]]; then
    echo -e "${RED}Error: ib script not found or not executable at $IB${NC}"
    exit 1
fi

# Skip if running from agent worktree
if ! "$IB" is-in-main-repo; then
    echo "SKIP: test-rebase-conflicts requires running from main repo (not agent worktree)"
    exit 0
fi

# Extract just the check_rebase_conflicts function from ib script
# This avoids side effects from sourcing the entire script
extract_function() {
    # Use sed to extract the function definition
    sed -n '/^check_rebase_conflicts()/,/^}/p' "$IB"
}

# Check if the function exists before trying to extract it
FUNC_DEF=$(extract_function)
if [[ -z "$FUNC_DEF" ]]; then
    echo "SKIP: check_rebase_conflicts function not found in ib"
    exit 0
fi

# Evaluate the extracted function to define it in this shell
eval "$FUNC_DEF"

PASSED=0
FAILED=0
TEMP_DIR=""

# Cleanup function
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Create a temporary directory for test repos
setup_temp_dir() {
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
}

# Helper: Create a test repo with initial content
create_test_repo() {
    local repo_name="$1"
    mkdir -p "$repo_name"
    cd "$repo_name"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test User"
    echo "initial content" > file.txt
    git add file.txt
    git commit --quiet -m "Initial commit"
    cd ..
}

# Test: No conflicts when branches have no overlap
test_no_conflict_separate_files() {
    local test_name="no conflict - separate files"
    setup_temp_dir

    create_test_repo "test-repo"
    cd test-repo

    # Create branch that modifies a different file
    git checkout --quiet -b feature
    echo "feature content" > feature.txt
    git add feature.txt
    git commit --quiet -m "Add feature.txt"
    git checkout --quiet main 2>/dev/null || git checkout --quiet master


    local main_branch
    main_branch=$(git branch --show-current)

    if check_rebase_conflicts "$main_branch" "feature"; then
        echo -e "${GREEN}PASS${NC} $test_name"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $test_name - expected no conflicts"
        ((FAILED++))
    fi

    cd "$SCRIPT_DIR"
}

# Test: Conflict when same file modified differently
test_conflict_same_file() {
    local test_name="conflict - same file modified"
    setup_temp_dir

    create_test_repo "test-repo"
    cd test-repo

    local main_branch
    main_branch=$(git branch --show-current)

    # Create conflicting change on main
    echo "main version" > file.txt
    git add file.txt
    git commit --quiet -m "Modify file.txt on main"

    # Create conflicting change on feature branch (from initial commit)
    git checkout --quiet HEAD~1
    git checkout --quiet -b feature
    echo "feature version" > file.txt
    git add file.txt
    git commit --quiet -m "Modify file.txt on feature"
    git checkout --quiet "$main_branch"


    if check_rebase_conflicts "$main_branch" "feature"; then
        echo -e "${RED}FAIL${NC} $test_name - expected conflicts but none detected"
        ((FAILED++))
    else
        echo -e "${GREEN}PASS${NC} $test_name"
        ((PASSED++))
    fi

    cd "$SCRIPT_DIR"
}

# Test: No conflict when changes are compatible (fast-forward possible)
test_no_conflict_fast_forward() {
    local test_name="no conflict - fast-forward possible"
    setup_temp_dir

    create_test_repo "test-repo"
    cd test-repo

    local main_branch
    main_branch=$(git branch --show-current)

    # Create feature branch with additional commits
    git checkout --quiet -b feature
    echo "new feature" > newfile.txt
    git add newfile.txt
    git commit --quiet -m "Add newfile.txt"
    git checkout --quiet "$main_branch"


    if check_rebase_conflicts "$main_branch" "feature"; then
        echo -e "${GREEN}PASS${NC} $test_name"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $test_name - expected no conflicts"
        ((FAILED++))
    fi

    cd "$SCRIPT_DIR"
}

# Test: Conflict detection returns rebase output with conflict info
test_conflict_shows_output() {
    local test_name="conflict - shows conflict output"
    setup_temp_dir

    create_test_repo "test-repo"
    cd test-repo

    local main_branch
    main_branch=$(git branch --show-current)

    # Create conflicting change on main
    echo "main version" > file.txt
    git add file.txt
    git commit --quiet -m "Modify file.txt on main"

    # Create conflicting change on feature branch
    git checkout --quiet HEAD~1
    git checkout --quiet -b feature
    echo "feature version" > file.txt
    git add file.txt
    git commit --quiet -m "Modify file.txt on feature"
    git checkout --quiet "$main_branch"


    local conflict_output
    conflict_output=$(check_rebase_conflicts "$main_branch" "feature" 2>&1) || true

    # Rebase conflict output should mention CONFLICT
    if [[ "$conflict_output" == *"CONFLICT"* ]]; then
        echo -e "${GREEN}PASS${NC} $test_name"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $test_name - expected CONFLICT in output, got: $conflict_output"
        ((FAILED++))
    fi

    cd "$SCRIPT_DIR"
}

# Test: No conflict when feature is ancestor of main (nothing to rebase)
test_no_conflict_ancestor() {
    local test_name="no conflict - feature is ancestor"
    setup_temp_dir

    create_test_repo "test-repo"
    cd test-repo

    local main_branch
    main_branch=$(git branch --show-current)

    # Create feature branch at current commit
    git branch feature

    # Add more commits to main
    echo "newer content" > file.txt
    git add file.txt
    git commit --quiet -m "Update on main"


    if check_rebase_conflicts "$main_branch" "feature"; then
        echo -e "${GREEN}PASS${NC} $test_name"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $test_name - expected no conflicts"
        ((FAILED++))
    fi

    cd "$SCRIPT_DIR"
}

# Test: No leftover temp branches after check
test_cleanup_temp_branches() {
    local test_name="cleanup - no leftover temp branches"
    setup_temp_dir

    create_test_repo "test-repo"
    cd test-repo

    local main_branch
    main_branch=$(git branch --show-current)

    # Create a simple feature branch
    git checkout --quiet -b feature
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Add feature"
    git checkout --quiet "$main_branch"

    # Run conflict check
    check_rebase_conflicts "$main_branch" "feature" >/dev/null 2>&1 || true

    # Check for leftover temp branches
    local temp_branches
    temp_branches=$(git branch | grep "temp-rebase-check" || true)

    if [[ -z "$temp_branches" ]]; then
        echo -e "${GREEN}PASS${NC} $test_name"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC} $test_name - found leftover branches: $temp_branches"
        ((FAILED++))
    fi

    cd "$SCRIPT_DIR"
}

echo "Running rebase conflict detection tests..."
echo "========================================"
echo ""

# Run all tests
test_no_conflict_separate_files
test_conflict_same_file
test_no_conflict_fast_forward
test_conflict_shows_output
test_no_conflict_ancestor
test_cleanup_temp_branches

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
