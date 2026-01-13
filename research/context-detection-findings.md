# Context Detection Research Findings

## Executive Summary

`ib` can reliably distinguish between all three execution contexts using a combination of environment variables, PWD patterns, and tmux session information.

---

## The Three Contexts

| Context | Description | Key Signals |
|---------|-------------|-------------|
| **User Terminal** | User runs `ib` directly from terminal | No `CLAUDECODE` env var |
| **Primary Claude** | User asks Claude (not an agent) to run `ib` | `CLAUDECODE=1` but NOT in ib tmux session or worktree |
| **Agent Claude** | A spawned ib agent runs `ib` | `CLAUDECODE=1` AND (in ib tmux session OR worktree path) |

---

## Detection Signals

### 1. Environment Variables

| Variable | User Terminal | Primary Claude | Agent Claude |
|----------|--------------|----------------|--------------|
| `CLAUDECODE` | unset | `1` | `1` |
| `CLAUDE_CODE_ENTRYPOINT` | unset | `cli` | `cli` |
| `TMUX` | may/may not be set | may/may not be set | **set** (ib tmux session) |
| `TMUX_PANE` | may/may not be set | may/may not be set | **set** |

**Key insight**: `CLAUDECODE=1` reliably indicates Claude is running the command. This distinguishes User Terminal from the other two cases.

### 2. PWD (Working Directory)

| Context | PWD Pattern |
|---------|-------------|
| User Terminal | Any directory |
| Primary Claude | Typically NOT matching `*/.ittybitty/agents/*/repo*` |
| Agent Claude | Matches `*/.ittybitty/agents/*/repo*` |

**Current implementation**: `is_running_as_agent()` already uses this pattern:
```bash
is_running_as_agent() {
    local current_dir=$(pwd)
    if [[ "$current_dir" == *"/.ittybitty/agents/"*"/repo"* ]]; then
        return 0
    fi
    return 1
}
```

### 3. Tmux Session Name

Agents are spawned in tmux sessions with a specific naming pattern:
```
ittybitty-<repo-id>-<agent-id>
```

Example: `ittybitty-64c28d2a-context-detect`

**Detection method**:
```bash
tmux display-message -p '#{session_name}' 2>/dev/null
```

If the session name starts with `ittybitty-`, we're in an ib-spawned tmux session.

### 4. Process Tree

The process hierarchy for agents:
```
tmux server (ppid=1)
  └── bash shell (from tmux)
        └── claude process
              └── bash (for Bash tool)
```

**Detection**: Check if ancestor is tmux and great-grandparent has PID 1 (init).

### 5. stdin/stdout TTY Status

| Context | stdin TTY | stdout TTY |
|---------|-----------|------------|
| User Terminal | yes | yes |
| Primary Claude | no | no |
| Agent Claude | no | no |

**Note**: This distinguishes User Terminal from Claude contexts, but NOT Primary vs Agent Claude.

---

## Recommended Detection Functions

### Function: `is_claude_running()`
Detects if Claude is invoking the command (case 2 or 3).

```bash
is_claude_running() {
    [[ "${CLAUDECODE:-}" == "1" ]]
}
```

### Function: `is_running_as_agent()` (existing)
Detects if running in an agent worktree (case 3).

```bash
is_running_as_agent() {
    local current_dir=$(pwd)
    if [[ "$current_dir" == *"/.ittybitty/agents/"*"/repo"* ]]; then
        return 0
    fi
    return 1
}
```

### Function: `is_in_ib_tmux_session()`
Detects if running in an ib-spawned tmux session.

```bash
is_in_ib_tmux_session() {
    local session_name
    session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null) || return 1
    [[ "$session_name" == ittybitty-* ]]
}
```

### Function: `get_execution_context()`
Returns the execution context as a string.

```bash
get_execution_context() {
    # Check if Claude is running at all
    if [[ "${CLAUDECODE:-}" != "1" ]]; then
        echo "user-terminal"
        return 0
    fi

    # Claude is running - check if it's an agent
    local current_dir=$(pwd)
    if [[ "$current_dir" == *"/.ittybitty/agents/"*"/repo"* ]]; then
        echo "agent"
        return 0
    fi

    # Additional check: tmux session name
    local session_name
    if session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null); then
        if [[ "$session_name" == ittybitty-* ]]; then
            echo "agent"
            return 0
        fi
    fi

    echo "primary-claude"
    return 0
}
```

---

## Edge Cases and Limitations

### Edge Case 1: User in tmux, asks Claude to run ib
- `CLAUDECODE=1` → Claude is running
- `TMUX` is set → but NOT with `ittybitty-*` session name
- PWD doesn't match worktree pattern
- **Result**: Correctly detected as "primary-claude"

### Edge Case 2: Agent creates another directory outside worktree
- If an agent `cd`s out of its worktree, PWD check would fail
- But tmux session name check would still work
- **Recommendation**: Use both checks

### Edge Case 3: User manually runs command in agent worktree
- PWD matches worktree pattern
- But `CLAUDECODE` is NOT set
- **Result**: `is_running_as_agent()` returns true, but `is_claude_running()` returns false
- **Recommendation**: Check both for accuracy

### Limitation: No distinction between manager and worker
The current signals don't distinguish manager vs worker agents at the environment level.
To distinguish, must read from meta.json or rely on the `--worker` flag passed at creation.

---

## Implementation Suggestions

### 1. Add `CLAUDECODE` check for user-vs-claude distinction
```bash
# At the start of ib, set a context variable
if [[ "${CLAUDECODE:-}" == "1" ]]; then
    IB_CALLER="claude"
else
    IB_CALLER="user"
fi
```

### 2. Refine agent detection with dual check
```bash
is_running_as_agent() {
    # Primary check: worktree path
    local current_dir=$(pwd)
    if [[ "$current_dir" == *"/.ittybitty/agents/"*"/repo"* ]]; then
        return 0
    fi

    # Secondary check: tmux session name (for cases where agent cd'd elsewhere)
    local session_name
    if session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null); then
        if [[ "$session_name" == ittybitty-* ]]; then
            return 0
        fi
    fi

    return 1
}
```

### 3. Add optional environment variable export in start.sh
Could explicitly set `IB_AGENT_ID=<id>` in the agent's environment via start.sh:
```bash
export IB_AGENT_ID="$AGENT_ID"
export IB_AGENT_ROLE="${IS_WORKER:+worker}${IS_WORKER:-manager}"
```

This would make detection trivial and also identify manager vs worker.

---

## Summary Table

| What to Detect | How to Detect |
|----------------|---------------|
| Claude vs User | `${CLAUDECODE:-}` == "1" |
| Agent vs Primary Claude | PWD pattern OR tmux session name |
| Manager vs Worker | meta.json field or new env var |
| Specific agent ID | Extract from PWD or tmux session name |

---

## Recommendation

**Best approach**: Combine `CLAUDECODE` env var check with existing `is_running_as_agent()`, adding tmux session name as a fallback. Optionally, export `IB_AGENT_ID` and `IB_AGENT_ROLE` in start.sh for future use cases.
