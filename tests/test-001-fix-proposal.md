# Test 001 Fix Proposal

## Root Cause

Manager agents have permissions: `["Read", "Edit", "Glob", "Grep"]`

But plan mode requires:
- `EnterPlanMode` - allowed (not in deny list) ✅
- `Write` - **NOT in allow list** ❌
- `ExitPlanMode` - requires Write to create plan file ❌

**Result**: Agent can enter plan mode but cannot exit it.

## Recommended Fix

Add `Write` to manager permissions in `.ittybitty.json`:

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

## Implementation

```bash
# Update .ittybitty.json
jq '.permissions.manager.allow += ["Write"] | .permissions.manager.allow |= unique' \
   .ittybitty.json > .ittybitty.json.tmp && mv .ittybitty.json.tmp .ittybitty.json
```

## Verification

After applying fix:

```bash
# 1. Apply fix
jq '.permissions.manager.allow += ["Write"] | .permissions.manager.allow |= unique' \
   .ittybitty.json > .ittybitty.json.tmp && mv .ittybitty.json.tmp .ittybitty.json

# 2. Spawn test agent
ib new-agent --name test-001-fixed "Please look at the dialog prompts. the [cancel] button should always be on the Left"

# 3. Monitor
ib watch

# 4. Verify agent can enter AND exit plan mode
# Expected: Agent enters plan mode, creates plan, exits cleanly

# 5. Check state
ib status test-001-fixed
# Expected: waiting (for user to approve plan) OR complete (plan approved)

# 6. No permission prompts should appear
ib look test-001-fixed | grep -i "do you want to proceed"
# Expected: No output (no permission prompt)
```

## Test Success Criteria

✅ Agent enters plan mode
✅ Agent creates plan in plan file
✅ Agent exits plan mode with ExitPlanMode tool
✅ No Bash commands attempted
✅ No permission prompts blocking progress
✅ Agent state: `waiting` (for plan approval) or `complete`

## Alternative Fixes (Not Recommended)

### Alt 1: Block EnterPlanMode for managers without Write

**Problem**: Too restrictive - plan mode is useful for managers
**Verdict**: ❌ Don't do this

### Alt 2: Add Bash to manager permissions

**Problem**: Bash is more powerful than needed, increases risk
**Verdict**: ❌ Write is more appropriate

### Alt 3: Make ExitPlanMode work without Write

**Problem**: Requires changes to Claude Code itself, not in our control
**Verdict**: ❌ Not feasible

## Related Config Changes

While fixing this, consider if managers need other tools:
- `TodoWrite` - for task tracking? (probably useful)
- `Task` - for spawning sub-agents? (already works via Bash(ib))
- `Bash` - for running commands? (risky, avoid unless needed)

**Recommendation**: Keep manager permissions minimal but sufficient:
```json
{
  "permissions": {
    "manager": {
      "allow": ["Read", "Write", "Edit", "Glob", "Grep"],
      "deny": ["Bash", "Task"]
    }
  }
}
```

This way:
- Managers can read, write, search (sufficient for planning)
- Managers spawn workers via `Bash(ib new-agent ...)` which is allowed via special case
- Workers do the heavy lifting with Bash/Task access

## Apply Fix Now?

To apply this fix immediately:

```bash
cd /Users/adamwulf/Developer/bash/ittybitty
jq '.permissions.manager.allow += ["Write"] | .permissions.manager.allow |= unique' \
   .ittybitty.json > .ittybitty.json.tmp && mv .ittybitty.json.tmp .ittybitty.json

# Verify
jq '.permissions.manager' .ittybitty.json
```

Then test with the stuck agent:
```bash
# Send answer to the permission prompt to unblock it
ib send tool-use "2"  # Choose option 2: "Yes, and don't ask again"

# Or restart with new permissions
ib kill tool-use --force
ib new-agent --name tool-use-fixed "i'm debugging tool use denials in ib. please try different commands to find a few commands that are denied, and then wait"
```
