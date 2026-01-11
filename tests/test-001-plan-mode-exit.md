# Test 001: Plan Mode Exit Bug

## Issue
Agents can enter plan mode (EnterPlanMode tool) but get stuck when trying to exit because they attempt to use Bash commands instead of the ExitPlanMode tool.

## Prompt
```
Please look at the dialog prompts. the [cancel] button should always be on the Left
```

## Agent Type
Manager (gets permissions: Read, Write, Edit, Glob, Grep)

## Configuration
`.ittybitty.json` permissions:
```json
{
  "permissions": {
    "manager": {
      "allow": ["Read", "Write", "Edit", "Glob", "Grep"],
      "deny": []
    }
  }
}
```

## Actual Behavior (Bug)

1. Agent uses `EnterPlanMode` tool - **succeeds** (tool not in deny list)
2. Agent explores codebase and creates plan
3. Agent attempts to exit plan mode by running:
   ```bash
   Bash(echo "exiting plan mode" && exit 1)
   ```
4. Bash command triggers permission prompt (Bash not in allow list)
5. Agent gets stuck waiting for user to approve permission
6. Agent state: `waiting` with permission dialog blocking progress

## Expected Behavior

Agent should:
1. Enter plan mode with `EnterPlanMode` tool
2. Explore and create plan
3. Exit plan mode with `ExitPlanMode` tool (not Bash)
4. Continue with implementation or wait for user approval of plan

## Root Cause Analysis

### Why This Happens

The agent is likely trying to "force exit" plan mode because:
- ExitPlanMode requires writing a plan file first
- Agent may not have Write permission (manager allow list: Read, Edit, Glob, Grep only)
- Agent can't write the plan file, so tries alternative approach (Bash exit)

### Permission Issue

Manager agents cannot use:
- `Bash` - not in allow list
- `Write` - not in allow list (but IS needed for plan files!)
- `ExitPlanMode` - requires Write permission to create plan file

### The Contradiction

1. `EnterPlanMode` is allowed (not in deny list)
2. But `Write` is NOT in manager allow list
3. `ExitPlanMode` requires Write to create plan file
4. Result: Agent can enter plan mode but cannot exit it properly

## Expected Outcome

**Current (bug)**: Agent gets stuck in permission prompt, state = `waiting`

**Fixed**: Agent should either:
- **Option A**: Not be able to enter plan mode if Write not allowed
- **Option B**: Have Write added to manager permissions
- **Option C**: ExitPlanMode should work without Write permission

## Success Criteria

Test passes when agent:
1. Either cannot enter plan mode (if Write not allowed)
2. OR can enter AND exit plan mode cleanly
3. Does NOT get stuck in permission prompts
4. Ends in `waiting` or `complete` state without manual intervention

## Reproduction Steps

```bash
# 1. Ensure .ittybitty.json has manager permissions WITHOUT Write/Bash
cat > .ittybitty.json <<EOF
{
  "permissions": {
    "manager": {
      "allow": ["Read", "Edit", "Glob", "Grep"],
      "deny": []
    }
  }
}
EOF

# 2. Spawn agent with task requiring exploration
ib new-agent --name test-001 "Please look at the dialog prompts. the [cancel] button should always be on the Left"

# 3. Monitor agent
ib watch

# 4. Wait for agent to enter plan mode
# Expected: Agent gets stuck trying to exit plan mode

# 5. Check agent state
ib status test-001
# Should show: waiting (permission prompt)

# 6. Look at tmux output
ib look test-001
# Should show: "Do you want to proceed?" with Bash command blocked
```

## Proposed Fixes

### Fix 1: Block EnterPlanMode if Write not allowed

In `ib` script, modify permission checks:
```bash
# When evaluating EnterPlanMode tool
if ! tool_allowed "Write" "$agent_type"; then
    # Block EnterPlanMode since ExitPlanMode requires Write
    deny_tool "EnterPlanMode (requires Write permission for plan files)"
fi
```

### Fix 2: Add Write to manager permissions

Update default manager permissions:
```json
{
  "permissions": {
    "manager": {
      "allow": ["Read", "Write", "Edit", "Glob", "Grep"],
      "deny": []
    }
  }
}
```

### Fix 3: Make ExitPlanMode work without Write

Modify Claude Code's ExitPlanMode tool to:
- Accept plan content as parameter instead of reading from file
- Or use a different mechanism that doesn't require Write permission

## Recommendation

**Fix 2 is the best approach**: Add `Write` to manager permissions.

**Reasoning**:
1. Managers often need to create plan files, summary files, reports
2. Write is a low-risk permission (only writes to codebase)
3. Consistent with manager role (strategic, high-level work)
4. Minimal code changes required

## Related Issues

- Permission hooks not logging denied tools (no entries in agent.log)
- EnterPlanMode/ExitPlanMode asymmetry (enter easy, exit hard)
- No validation that agent has required permissions before allowing plan mode

## Notes

This bug was discovered on 2026-01-11 with agent `tool-use` (session: f19fb57b-be70-4cad-93c5-bf4d24f5e5c2).

The original prompt was innocuous: "Please look at the dialog prompts. the [cancel] button should always be on the Left"

The agent correctly identified this as a task requiring plan mode (UI changes across multiple files), but couldn't complete the workflow due to permission restrictions.

## Test Status

🔴 **FAILING** - Agent gets stuck in permission prompt when trying to exit plan mode.
