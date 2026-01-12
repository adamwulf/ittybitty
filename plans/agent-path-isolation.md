# Agent Path Isolation Strategy

## Problem Statement

Agents are getting permission prompts despite having a PermissionRequest hook configured. Additionally, agents can potentially access files outside their worktree, including:
- The main repository files
- Other agents' worktrees in `.ittybitty/agents/`
- System directories like `/tmp/`

## Research Findings

### Two Types of Permission Prompts

Claude Code has two distinct permission systems:

| Type | Example | PermissionRequest Hook |
|------|---------|----------------------|
| **Tool permissions** | "Allow WebSearch?" | Works - hook fires and can auto-deny |
| **Location permissions** | "Allow access to /tmp/?" | Bypasses hooks entirely |

### Deny Patterns Are Unreliable

According to GitHub issues [#6631](https://github.com/anthropics/claude-code/issues/6631), [#6699](https://github.com/anthropics/claude-code/issues/6699), [#4467](https://github.com/anthropics/claude-code/issues/4467):

> "The deny permission system configured in settings.json files is completely non-functional for Read/Write/Edit tools."

Using `permissions.deny` with path patterns like `Read(/path/*)` does not reliably block file access.

### PreToolUse Hooks Are Reliable

The recommended workaround is using **PreToolUse hooks** which:
- Execute before any tool runs
- Receive JSON with `tool_name` and `tool_input` (including file paths)
- Can block operations by returning exit code 2
- Are well-documented and widely used

## Proposed Solution

Add a **PreToolUse hook** to each agent that enforces path isolation:

1. **Allow** access to the agent's own worktree
2. **Allow** access to `.ittybitty/` for logging (excluding other agents' directories)
3. **Block** access to everything else (main repo, other agents, system directories)

### Hook Configuration

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Read|Write|Edit|Bash",
      "hooks": [{
        "type": "command",
        "command": "ib",
        "args": ["hook-check-path", "__AGENT_ID__"]
      }]
    }]
  }
}
```

### Path Check Logic

The `ib hook-check-path` command will:

```bash
# Receive JSON from stdin with tool_input
# Extract file_path from tool_input
# Check against allowed paths:

ALLOWED_PATHS=(
  "$AGENT_WORKTREE"           # Agent's own worktree
  "$ROOT_REPO/.ittybitty"     # Logging directory (but not /agents/)
)

BLOCKED_PATHS=(
  "$ROOT_REPO/.ittybitty/agents"  # Other agents' data
  "$ROOT_REPO"                     # Main repo (if not in worktree)
)

# For Bash commands, parse the command to extract paths
# For Read/Write/Edit, use file_path from tool_input
```

### Edge Cases

1. **Bash commands with paths**: Need to parse command string to extract file paths
2. **Relative paths**: Resolve to absolute paths before checking
3. **Symlinks**: Resolve symlinks to prevent bypass
4. **ib commands**: Always allow `ib` commands (they're in the allow list)

## Implementation Plan

1. Add `hook-check-path` command to `ib` script
2. Update `build_agent_settings()` to include PreToolUse hook
3. Test with agents attempting to access:
   - Their own worktree (should work)
   - Main repo files (should block)
   - Other agents' worktrees (should block)
   - `/tmp/` (should block)

## Alternatives Considered

### 1. Watchdog Auto-Deny
Have watchdog monitor output for prompts and send denial keystrokes.
- **Rejected**: Reactive, race conditions, fragile pattern matching

### 2. additionalDirectories
Pre-approve directories in settings.
- **Rejected**: Grants broad access, doesn't enforce isolation

### 3. --yolo Mode
Skip all permission checks.
- **Rejected**: No guardrails, loses PermissionRequest logging

### 4. Deny Patterns
Use `permissions.deny` with path patterns.
- **Rejected**: Documented as buggy/non-functional for file tools
