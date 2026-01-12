# Plan: Dynamic Agent Status in CLAUDE.md

## Summary

Automatically update a `<ittybitty-status>` block in CLAUDE.md with current agent tree, status, age, and prompt snippets. This gives the main Claude situational awareness of the agent ecosystem.

## Design

### Opt-in Model

Users "install" by adding an empty block to their CLAUDE.md inside `<ittybitty>`:

```markdown
<ittybitty>
... existing content ...

<ittybitty-status>
</ittybitty-status>
</ittybitty>
```

If the block doesn't exist, ib does nothing. If it exists, ib replaces its contents.

### Content Format

Use `ib tree` style output showing:
- Agent hierarchy (manager/worker relationships)
- Status (running/waiting/complete/stopped)
- Age
- Prompt snippet (truncated)

Example:
```
<ittybitty-status>
## Current Agents (3 active)

hooks-refactor     running   2m   Implement the plan in plans/main-repo-ho...
├─ worker-1        complete  1m   Fix authentication module...
└─ worker-2        waiting   30s  Update tests for auth changes...
</ittybitty-status>
```

### Trigger Points

Update CLAUDE.md status on these events:
- `new-agent` - agent created
- `kill` - agent killed
- `merge` - agent merged
- `hook-status` - agent state changed (via Stop hook)
- `watchdog` - when watchdog detects state change

### Implementation

#### 1. Add `cmd_update_claude_status()` function

```bash
cmd_update_claude_status() {
    local claude_md="$ROOT_REPO_PATH/CLAUDE.md"

    # Check if CLAUDE.md exists
    [[ ! -f "$claude_md" ]] && return 0

    # Check if <ittybitty-status> block exists
    if ! grep -q '<ittybitty-status>' "$claude_md"; then
        return 0  # Not installed, skip silently
    fi

    # Generate status content using ib tree format
    local status_content
    status_content=$(generate_status_block)

    # Replace content between <ittybitty-status> and </ittybitty-status>
    # Use sed or awk to replace the block
}

generate_status_block() {
    local agent_count=$(count_active_agents)

    echo "## Current Agents ($agent_count active)"
    echo ""

    # Use existing tree logic or ib list output
    # Format: ID, status, age, prompt snippet
    for agent in $(list_agents); do
        # ... format each agent line with tree structure
    done
}
```

#### 2. Call from lifecycle events

Add `update_claude_status` call to:
- `cmd_new_agent()` - after agent creation succeeds
- `cmd_kill()` - after agent is killed
- `cmd_merge()` - after agent is merged
- `cmd_hook_status()` / `cmd_hooks_agent_status()` - after state change detected
- `cmd_watchdog()` - when notifying about state changes

#### 3. Watch integration for install/uninstall

Add to the hooks dialog (or create separate menu item):
- Check if `<ittybitty-status>` block exists in CLAUDE.md
- Option to add the block (install)
- Option to remove the block (uninstall)

Could be part of the `h: hooks` menu or a separate `s: status` keybind.

## Files to Modify

| File | Changes |
|------|---------|
| `ib` | Add `cmd_update_claude_status()`, `generate_status_block()`, call from lifecycle events |
| `CLAUDE.md` | (optional) Add `<ittybitty-status>` block as example |

## Implementation Steps

### Step 1: Add status generation functions
- `generate_status_block()` - format agent tree with status/age/prompt
- `update_claude_status()` - find and replace `<ittybitty-status>` block
- Use sed/awk to replace content between tags

### Step 2: Integrate with lifecycle commands
- Add `update_claude_status` call to: new-agent, kill, merge
- Add to hooks: agent-status (after state change)
- Add to watchdog (after notifications)

### Step 3: Watch integration (optional)
- Add status block management to watch UI
- Could be part of hooks dialog or separate keybind

### Step 4: Documentation
- Document the `<ittybitty-status>` block in CLAUDE.md
- Explain opt-in model

## Verification

### Manual testing:

1. **Without block (no-op):**
```bash
# Ensure no <ittybitty-status> in CLAUDE.md
ib new-agent --name test "test"
# CLAUDE.md should be unchanged
```

2. **With block:**
```bash
# Add <ittybitty-status></ittybitty-status> to CLAUDE.md
ib new-agent --name test "test"
# Check CLAUDE.md - should show agent status
cat CLAUDE.md | grep -A 10 'ittybitty-status'
```

3. **Lifecycle updates:**
```bash
# Create agent - status should show running
ib new-agent --name test "test"

# Kill agent - status should be empty or show no agents
ib kill test --force

# Verify CLAUDE.md updates each time
```

## Notes

- Block replacement must be atomic (write to temp file, then move)
- Handle concurrent updates gracefully (multiple agents updating at once)
- Keep status concise - truncate long prompts
- Consider rate limiting updates if too frequent
