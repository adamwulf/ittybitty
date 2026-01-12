# PreToolUse Hook Tests: hook-check-path

This document describes manual tests for the `hook-check-path` PreToolUse hook that enforces agent path isolation.

## Overview

The `hook-check-path` hook runs before Read, Write, Edit, and Bash tools to block agents from accessing:
- Other agents' worktrees and data
- The main repository (outside their worktree)

## Test Setup

```bash
# Spawn a test agent
ib new-agent --name test-hooks --worker "You are a test agent. Execute commands exactly as I ask."

# Verify another agent exists to test against
ib list
# Should show test-hooks and at least one other agent (e.g., agent-spawn)
```

## Test Cases

### 1. cd into another agent's repo (SHOULD BLOCK)

```bash
ib send test-hooks "Run this exact bash command: cd /Users/adamwulf/Developer/bash/ittybitty/.ittybitty/agents/agent-spawn/repo && pwd"
```

**Expected behavior:**
- Hook logs: `[hook-check-path] Blocked: Bash cd command tried to enter other agent's worktree: ...`
- Agent receives: `Access denied: cannot cd into other agents' worktrees. Work in your own worktree.`

### 2. cd into main repo (SHOULD BLOCK)

```bash
ib send test-hooks "cd /Users/adamwulf/Developer/bash/ittybitty"
```

**Expected behavior:**
- Hook logs: `[hook-check-path] Blocked: Bash tried to access main repo: ...`
- Agent receives: `Access denied: work in your worktree, not the main repo`

### 3. Read file from another agent (SHOULD BLOCK)

```bash
ib send test-hooks "Use the Read tool to read /Users/adamwulf/Developer/bash/ittybitty/.ittybitty/agents/agent-spawn/meta.json"
```

**Expected behavior:**
- Hook logs: `[hook-check-path] Blocked: Read tried to access other agent's data: ...`
- Agent receives: `Access denied: cannot access other agents' files`

### 4. Read file from main repo (SHOULD BLOCK)

```bash
ib send test-hooks "Use the Read tool to read /Users/adamwulf/Developer/bash/ittybitty/ib"
```

**Expected behavior:**
- Hook logs: `[hook-check-path] Blocked: Read tried to access main repo: ...`
- Agent receives: `Access denied: work in your worktree, not the main repo`

### 5. Write file to another agent (SHOULD BLOCK)

```bash
ib send test-hooks "Use the Write tool to write 'test' to /Users/adamwulf/Developer/bash/ittybitty/.ittybitty/agents/agent-spawn/repo/test.txt"
```

**Expected behavior:**
- Hook logs: `[hook-check-path] Blocked: Write tried to access other agent's data: ...`
- Agent receives: `Access denied: cannot access other agents' files`

### 6. Write file to main repo (SHOULD BLOCK)

```bash
ib send test-hooks "Use the Write tool to write 'test' to /Users/adamwulf/Developer/bash/ittybitty/test.txt"
```

**Expected behavior:**
- Hook logs: `[hook-check-path] Blocked: Write tried to access main repo: ...`
- Agent receives: `Access denied: work in your worktree, not the main repo`

### 7. Edit file in another agent (SHOULD BLOCK)

```bash
ib send test-hooks "Use the Edit tool to edit /Users/adamwulf/Developer/bash/ittybitty/.ittybitty/agents/agent-spawn/repo/ib - replace 'set -e' with 'set -ex'"
```

**Expected behavior:**
- The Edit tool first attempts to Read the file
- Hook logs: `[hook-check-path] Blocked: Read tried to access other agent's data: ...`
- Agent receives: `Access denied: cannot access other agents' files`

### 8. Edit file in main repo (SHOULD BLOCK)

```bash
ib send test-hooks "Use the Edit tool to edit /Users/adamwulf/Developer/bash/ittybitty/ib - replace 'set -e' with 'set -ex'"
```

**Expected behavior:**
- The Edit tool first attempts to Read the file
- Hook logs: `[hook-check-path] Blocked: Read tried to access main repo: ...`
- Agent receives: `Access denied: work in your worktree, not the main repo`

### 9a. Write to own worktree (SHOULD ALLOW)

```bash
ib send test-hooks "Write 'hello world' to a file called test.txt in your current directory using the Write tool"
```

**Expected behavior:**
- File is created at `.ittybitty/agents/test-hooks/repo/test.txt`
- No block message in logs
- Verify: `cat .ittybitty/agents/test-hooks/repo/test.txt` shows "hello world"

### 9b. Write to /tmp (SHOULD ALLOW)

```bash
ib send test-hooks "Write 'test from agent' to /tmp/agent-test-file.txt using the Write tool"
```

**Expected behavior:**
- File is created at `/tmp/agent-test-file.txt`
- No block message in logs
- Verify: `cat /tmp/agent-test-file.txt` shows "test from agent"

## Verification Commands

Check agent log for hook activity:
```bash
cat .ittybitty/agents/test-hooks/agent.log | grep hook-check-path
```

View agent's recent output:
```bash
ib look test-hooks
```

## Cleanup

```bash
ib kill test-hooks --force
rm -f /tmp/agent-test-file.txt
```

## Hook Configuration

The hook is configured in each agent's `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "ib hook-check-path <agent-id>"
          }
        ]
      }
    ]
  }
}
```

**Important:** The command must be a single string, not split into `command` + `args`.

## Hook Logic

The hook (`cmd_hook_check_path` in `ib`) performs these checks in order:

1. **Allow own worktree**: If path starts with agent's worktree path, allow
2. **Allow own log**: If path is agent's `agent.log`, allow
3. **Block other agents**: If path is inside `.ittybitty/agents/` but not own directory, block
4. **Block main repo**: If path is inside main repo but not own worktree, block
5. **Allow other paths**: System paths like `/tmp`, etc. are allowed

## Exit Codes

- `0` - Allow the tool to proceed
- `2` - Block the tool (PreToolUse specific)
