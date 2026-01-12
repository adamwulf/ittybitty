# Test 003: PreToolUse Permission Auto-Allow

## Problem Statement

Location-specific permission prompts (e.g., "Allow tail commands in /path/to/repo?") bypass the PermissionRequest hook. This causes agents to get stuck on permission dialogs even when the command should be allowed.

## Root Cause

The current hook architecture:
1. **PreToolUse hook** (`ib hooks agent-path`) - Only enforces path isolation, uses `exit 0` (allow) or `exit 2` (block)
2. **PermissionRequest hook** - Auto-denies unknown tools, but location prompts bypass it

The problem: Using `exit 0` in PreToolUse just means "proceed with normal permission flow". Claude's permission system then kicks in and shows dialogs for commands not explicitly in the allow list.

According to Claude Code docs, PreToolUse can return `permissionDecision: "allow"` in JSON output to **completely bypass the permission system**.

## Current Implementation

The current `cmd_hooks_agent_path()` function (ib:4174-4294):
- Reads JSON from stdin with `tool_name` and `tool_input`
- Checks path isolation (agent can only access its own worktree)
- Uses `exit 0` to allow, `exit 2` to block
- **Does NOT output JSON for permission decisions**

## Solution

Update the PreToolUse hook to return proper JSON output with `permissionDecision`:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Tool matches allow pattern and path is valid"
  }
}
```

For denials:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Access denied: path outside agent worktree"
  }
}
```

## Implementation Details

### Where the allow list lives

Each agent has `settings.local.json` in its worktree at:
```
.ittybitty/agents/<id>/repo/.claude/settings.local.json
```

The allow list is at `.permissions.allow[]` and contains patterns like:
- `"Edit"` - exact tool name match
- `"Bash(git:*)"` - Bash tool with command starting with "git"
- `"Bash(tail:*)"` - Bash tool with command starting with "tail"

### Hook receives JSON input

The hook receives JSON on stdin like:
```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "tail -15 /path/to/file.txt",
    "description": "..."
  },
  "cwd": "/path/to/worktree"
}
```

### Pattern Matching Logic

For a tool to be allowed, it must match at least one pattern in the allow list:

1. **Exact match**: `"Edit"` matches tool_name `"Edit"`
2. **Bash with command pattern**: `"Bash(git:*)"` matches when:
   - tool_name is "Bash"
   - command starts with "git" (after stripping the pattern)

Pattern parsing:
- `Bash(prefix:*)` means Bash tool where command starts with `prefix`
- Need to extract prefix from pattern and compare to command

### Logging Requirements

**Important**: When denying a tool, the hook must log the denial just like the PermissionRequest hook does. Use `ib log --id <agent-id> --quiet` to write to the agent's log file.

Log format should match PermissionRequest:
```
Permission denied: ToolName (key1: val1, key2: val2)
```

For path violations, include the reason:
```
Path violation: ToolName tried to access main repo: /path/to/file
```

### Modified Flow

1. Read JSON input from stdin
2. Extract tool_name, tool_input, cwd
3. Read allow list from agent's settings.local.json
4. Check if tool matches any allow pattern
5. If tool IS in allow list:
   - Run existing path isolation checks
   - If path OK: output JSON with `permissionDecision: "allow"`
   - If path blocked: **log the violation**, output JSON with `permissionDecision: "deny"` + reason
6. If tool NOT in allow list:
   - **Log the denial** (same format as PermissionRequest hook)
   - Output JSON with `permissionDecision: "deny"`

## Reproduction Steps

1. Spawn an agent with a limited allow list (no `Bash(tail:*)`)
2. Have the agent try to run a `tail` command
3. Observe the permission dialog appears despite PreToolUse hook running

### Example from fix-thinking-state agent

The agent ran:
```
Bash(tail -15 /path/to/fixtures/*.txt)
  ⎿  Running PreToolUse hook…
  ⎿  Running…

────────────────────────────────────────────────────────────
 Bash command
   tail -15 ...
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for tail commands in [path]
   3. No
```

The PreToolUse hook ran but only returned exit code 0, which doesn't bypass permissions.

## Test Cases

### Test 1: Verify allowed command bypasses permission prompt

**Setup**: Agent with `Bash(tail:*)` in allow list
**Action**: Run `tail -5 some-file.txt`
**Expected**: Command executes without permission prompt
**Verification**: No "Do you want to proceed?" dialog appears

### Test 2: Verify denied command is blocked by PreToolUse

**Setup**: Agent WITHOUT `curl` in allow list
**Action**: Run `curl https://example.com`
**Expected**: Command is blocked with denial message
**Verification**: Hook outputs `permissionDecision: "deny"`

### Test 3: Verify path isolation still works

**Setup**: Agent with `Bash(cat:*)` in allow list
**Action**: Try to read file outside worktree: `cat /etc/passwd`
**Expected**: Allowed (path check only blocks access to main repo and other agents)
**Note**: System files are allowed; only repo isolation is enforced

### Test 4: Verify path isolation blocks main repo access

**Setup**: Agent in worktree
**Action**: Try `cat` on a file in main repo (not worktree)
**Expected**: Blocked with `permissionDecision: "deny"` and message "work in your worktree, not the main repo"

### Test 5: Verify path isolation blocks other agent access

**Setup**: Two agents running
**Action**: Agent A tries to access agent B's files
**Expected**: Blocked with `permissionDecision: "deny"` and message "cannot access other agents' files"

### Test 6: Verify complex Bash commands (loops, pipes) are handled

**Setup**: Agent with `Bash(tail:*)` and `Bash(for:*)` in allow list
**Action**: Run `for f in *.txt; do tail -15 "$f"; done`
**Expected**: Command executes without permission prompt
**Note**: The prompt "Yes, allow reading from repo/ from this project" indicates Claude is asking about path access, not just the command. This should be bypassed by `permissionDecision: "allow"`.

**Observed prompt** (from fix-thinking-state):
```
Bash command
   for f in /path/to/fixtures/arrow-keys-{8,9,10}.txt; do echo "=== $f ==="; tail -15 "$f"; done

Do you want to proceed?
❯ 1. Yes
  2. Yes, allow reading from repo/ from this project
  3. No
```

This is a location-access prompt that bypasses PermissionRequest hooks.

## Implementation Checklist

- [x] Modify `cmd_hooks_agent_path()` to output JSON instead of just exit codes
- [x] Add function to read agent's allow list from settings.local.json
- [x] Add function to match tool against allow patterns
- [x] Handle pattern types: exact match, `Bash(prefix:*)`
- [x] Output `permissionDecision: "allow"` for allowed tools that pass path check
- [x] Output `permissionDecision: "deny"` for blocked paths with specific reason
- [x] Output `permissionDecision: "deny"` for tools not in allow list
- [x] Update tests/test-003-pretooluse-allow.md with results

## Implementation Notes

### New Helper Functions Added (ib lines 472-530)

1. **`tool_matches_pattern(tool_name, tool_input, pattern)`** - Checks if a tool matches an allow pattern
   - Handles exact tool name matches (e.g., `"Edit"` matches tool_name `"Edit"`)
   - Handles Bash prefix patterns (e.g., `"Bash(git:*)"` matches Bash tool where command starts with "git")
   - Returns 0 (true) if matches, 1 (false) if not

2. **`tool_in_allow_list(tool_name, tool_input, settings_file)`** - Checks if tool is in the allow list
   - Reads `.permissions.allow[]` from the agent's settings.local.json
   - Iterates through all patterns and checks for matches
   - Returns 0 (true) if allowed, 1 (false) if not

### Modified `cmd_hooks_agent_path()` (ib lines 4234-4393)

The function now outputs JSON with `permissionDecision` instead of using exit codes:

1. **Flow Change**: First checks allow list, THEN checks path isolation
   - If tool NOT in allow list → deny immediately (with logging)
   - If tool IS in allow list → proceed to path checks

2. **JSON Output Format**:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Tool in allow list"
  }
}
```

3. **Permission Decisions**:
   - `allow`: Tool in allow list AND passes path checks
   - `deny`: Tool not in allow list OR path violation

4. **Logging**:
   - Tool denials are logged in same format as PermissionRequest: `Permission denied: ToolName (key1: val1, key2: val2)`
   - Path violations are logged as: `Path violation: ToolName tried to access main repo: /path`

5. **Exit Codes**: All paths now use `exit 0` (hook completed successfully). The decision is communicated via JSON output, not exit code.

## References

- Claude Code hooks documentation: https://docs.anthropic.com/en/docs/claude-code/hooks
- Current implementation: `ib` lines 4234-4393 (`cmd_hooks_agent_path`)
- Helper functions: `ib` lines 472-530 (`tool_matches_pattern`, `tool_in_allow_list`)
- Settings builder: `ib` lines 532-600 (`build_agent_settings`)
- Pattern matching used by Claude: Similar to shell glob patterns
