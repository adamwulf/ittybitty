# Test 001: Plan Mode Blocked (FIXED)

## Fix Applied
Added default block for plan mode tools in `ib` script (lines 502-504, 518).

## Changes
```bash
# Always deny plan mode tools (agents should work directly, not enter planning mode)
# Plan mode creates complexity and agents often get stuck trying to exit
local blocked_tools='["EnterPlanMode", "ExitPlanMode"]'

# In permissions merge:
.permissions.deny = ((.permissions.deny // []) + $blocked + $cfg_deny | unique)
```

## Why This Fix Works

1. **Blocked at source**: EnterPlanMode/ExitPlanMode added to default deny list in `build_agent_settings()`
2. **Cannot be overridden**: User config cannot add these to allow list (deny takes precedence)
3. **Prevents the bug**: Agents can't enter plan mode, so can't get stuck trying to exit
4. **Clean failures**: If agent tries to use plan mode, gets immediate denial (logged to agent.log)

## Verification

### Test 1: New Agent Cannot Enter Plan Mode

```bash
# Spawn agent with task that might trigger plan mode
ib new-agent --name test-fixed "Please refactor the watch command dialog system"

# Watch agent
ib watch

# Expected: Agent works directly, does NOT attempt EnterPlanMode
# If it does try: Permission denied, logged to agent.log
```

### Test 2: Check Permissions in Agent Settings

```bash
# Spawn an agent
ib new-agent --name check-perms "echo hello"

# Check generated settings
cat .ittybitty/agents/check-perms/repo/.claude/settings.local.json | jq '.permissions.deny'

# Expected output:
# [
#   "EnterPlanMode",
#   "ExitPlanMode"
# ]
```

### Test 3: Verify Denied Tools Are Logged

```bash
# Spawn agent (if agent tries to use plan mode tools)
ib new-agent --name test-deny "try to use plan mode"

# Check agent log for denial
grep "Permission denied: EnterPlanMode" .ittybitty/agents/test-deny/agent.log

# Expected: Log entry showing denial (if agent attempted it)
```

### Test 4: Original Bug Cannot Reproduce

```bash
# Try the original failing prompt
ib new-agent --name test-original "Please look at the dialog prompts. the [cancel] button should always be on the Left"

# Monitor agent
ib watch

# Expected:
# - Agent works directly on the task
# - No plan mode entered
# - No Bash(exit 1) workaround attempted
# - Agent reaches waiting or complete state cleanly
```

## User Override (If Needed)

If a user explicitly wants to allow plan mode, they would need to:
1. Remove the blocked_tools line from ib script (lines 502-504)
2. Remove the $blocked merge (line 518)
3. Reinstall ib

**Note**: This is intentionally difficult - plan mode should stay blocked for agent safety.

## Migration for Existing Agents

Existing agents spawned before this fix:
- Already have their settings.local.json created (no plan mode block)
- Will NOT automatically get the fix
- Must be killed and respawned to get new settings

To apply fix to running agents:
```bash
# Kill all agents
ib nuke --force

# Respawn with new permissions
# (agents will get updated settings.local.json with plan mode blocked)
```

## Test Status

✅ **FIXED** - Plan mode is now blocked by default for all agents.

## Related Files

- `ib` script: Lines 502-504 (blocked_tools), line 518 (deny merge)
- `.ittybitty/agents/*/repo/.claude/settings.local.json`: Generated with deny list
- `.ittybitty/agents/*/agent.log`: Logs permission denials if agent attempts plan mode

## Benefits

1. **Prevents bug**: Agents can't get stuck in plan mode
2. **Simpler workflows**: Agents work directly instead of planning
3. **Clearer failures**: Permission denied is logged immediately
4. **Cannot be misconfigured**: User config can't accidentally allow plan mode
5. **Better for automation**: No complex planning workflows, just direct execution

## Trade-offs

- **Loss of planning capability**: Agents can't use Claude's built-in plan mode
- **Alternative**: Agents can still plan using Write tool to create plan files manually
- **Verdict**: Worth it - plan mode was causing more problems than it solved
