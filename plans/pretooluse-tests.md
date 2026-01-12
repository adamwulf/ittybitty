# Plan: PreToolUse Hook Unit Tests

## Goal

Create executable unit tests for the PreToolUse hook (`cmd_hooks_agent_path`) following the same pattern as `test-parse-state.sh`.

## Problem

The current hook function requires a real agent directory structure to work. We need to refactor so the core logic is testable without spinning up real agents.

## Approach

### 1. Extract Core Logic into Testable Function

Create a new function that takes explicit parameters instead of deriving everything from agent ID:

```bash
# New testable function
# Args: settings_json, tool_input_json, worktree_path, agents_dir
pretooluse_check() {
    local settings_json="$1"      # Contents of settings.local.json
    local tool_input_json="$2"    # The hook input JSON (tool_name, tool_input, etc.)
    local worktree_path="$3"      # Path to agent's worktree (for path isolation)
    local agents_dir="$4"         # Path to agents dir (for blocking other agent access)

    # Core logic here - check allow list, check paths, output JSON decision
}
```

### 2. Refactor `cmd_hooks_agent_path` to Use It

The existing function becomes a thin wrapper:
1. Resolve agent ID to paths
2. Read settings.local.json
3. Call `pretooluse_check()` with the resolved values

### 3. Create Test Command

Add `ib test-pretooluse` command that:
- Takes path to settings file and path to input JSON file as arguments
- Optionally takes worktree_path and agents_dir (or uses sensible test defaults)
- Reads the files and calls `pretooluse_check()`
- Outputs the JSON result

```bash
ib test-pretooluse <settings-file> <input-file> [--worktree /tmp/test] [--agents-dir /tmp/agents]
```

### 4. Fixture Structure

```
tests/fixtures/pretooluse/
  allow-exact-match.json         # Combined: {settings: {...}, input: {...}, expected: {...}}
  allow-bash-prefix.json
  deny-not-in-list.json
  deny-path-other-agent.json
  deny-path-main-repo.json
  allow-system-path.json         # /etc/passwd should be allowed (only repo isolation)
```

Each fixture is a single JSON file with three sections:
- `settings`: The permissions.allow array
- `input`: The tool_name and tool_input
- `expected`: The expected permissionDecision and reason

### 5. Test Script

`tests/test-pretooluse.sh`:
1. Loop through fixtures
2. Extract settings/input/expected from each
3. Write temp settings file, temp input file
4. Run `ib test-pretooluse <settings> <input>`
5. Compare output to expected
6. Report pass/fail

## Key Test Cases

1. **Exact tool match** - `"Edit"` allows Edit tool
2. **Bash prefix match** - `"Bash(git:*)"` allows `git status`
3. **Bash prefix no match** - `"Bash(git:*)"` denies `curl`
4. **Tool not in list** - Unlisted tool is denied
5. **Path in worktree** - Allowed
6. **Path in other agent** - Denied
7. **Path in main repo** - Denied
8. **System path** - Allowed (only repo isolation enforced)
9. **Bash cd to other agent** - Denied
10. **Bash non-cd command** - Allowed if in list (no path check needed)

## Files to Modify

- `ib` - Add `pretooluse_check()` function, refactor `cmd_hooks_agent_path`, add `cmd_test_pretooluse`
- `tests/test-pretooluse.sh` - New test script
- `tests/fixtures/pretooluse/*.json` - New fixtures

## Success Criteria

- `bash tests/test-pretooluse.sh` runs and reports pass/fail for each fixture
- Existing hook behavior unchanged (refactor only)
- Tests cover the key logic branches
