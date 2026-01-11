# Test Suite Summary

## Test 001: Plan Mode Exit Bug

### Status: 🔴 FAILING

### Issue
Agents can enter plan mode but get stuck trying to exit because they lack Write permission for the plan file.

### Evidence
From agent `tool-use` (session f19fb57b-be70-4cad-93c5-bf4d24f5e5c2):

**Tmux output:**
```
Let me exit plan mode and try more tools:

⏺ Bash(echo "exiting plan mode" && exit 1)
  ⎿  Running…

Do you want to proceed?
 ❯ 1. Yes
  2. Yes, and don't ask again for exit 1 commands
   3. No
```

**Analysis:**
1. Agent entered plan mode successfully
2. Agent tried to exit with `Bash(exit 1)` instead of `ExitPlanMode` tool
3. Bash command blocked by permission system (not in manager allow list)
4. Agent stuck waiting for user to approve Bash permission

### Root Cause
- Manager permissions: `["Read", "Edit", "Glob", "Grep"]`
- Missing: `Write` (required for ExitPlanMode to write plan file)
- Agent attempted workaround: force exit via Bash
- Bash also not allowed, so agent got stuck

### Fix
Add `Write` to manager permissions in `.ittybitty.json`:

```diff
 {
   "permissions": {
     "manager": {
-      "allow": ["Read", "Edit", "Glob", "Grep"],
+      "allow": ["Read", "Write", "Edit", "Glob", "Grep"],
       "deny": []
     }
   }
 }
```

### Test Plan
After fix:
1. Update `.ittybitty.json` with Write permission
2. Spawn test agent with same prompt
3. Verify agent can enter AND exit plan mode
4. Verify no permission prompts appear
5. Agent should reach `waiting` or `complete` state cleanly

### Commands to Apply Fix
```bash
# Apply fix
cd /Users/adamwulf/Developer/bash/ittybitty
jq '.permissions.manager.allow += ["Write"] | .permissions.manager.allow |= unique' \
   .ittybitty.json > .ittybitty.json.tmp && mv .ittybitty.json.tmp .ittybitty.json

# Verify
jq '.permissions.manager' .ittybitty.json

# Expected output:
# {
#   "allow": ["Read", "Write", "Edit", "Glob", "Grep"],
#   "deny": []
# }
```

### Unblock Stuck Agent
```bash
# Option 1: Answer permission prompt
ib send tool-use "2"  # Yes, and don't ask again

# Option 2: Kill and restart with fixed permissions
ib kill tool-use --force
ib new-agent --name tool-use-fixed \
  "i'm debugging tool use denials in ib. please try different commands to find a few commands that are denied, and then wait"
```

---

## Future Tests

### Test 002: Worker Permissions (TODO)
Verify workers can use Bash but not plan mode tools.

### Test 003: Manager Worker Hierarchy (TODO)
Test that manager can spawn workers and workers inherit correct permissions.

### Test 004: ib Command Pass-through (TODO)
Verify `Bash(ib *)` commands always pass through permission system.

### Test 005: Permission Hook Logging (TODO)
Verify denied permissions are logged to agent.log correctly.

---

## Test Infrastructure

### Running Tests
```bash
# Run specific test
./run-test.sh 001

# Run all tests
./run-test.sh all

# Run failing tests only
./run-test.sh --failing
```

### Test Format
Each test in `tests/test-NNN.md` includes:
- Prompt (exact text to give agent)
- Agent type (manager/worker)
- Expected behavior
- Expected outcome
- Success criteria
- Reproduction steps

### Automated Testing (Future)
Plan to create `run-test.sh` script that:
1. Reads test file
2. Spawns agent with test prompt
3. Monitors agent state
4. Validates outcome matches expected
5. Reports pass/fail
6. Cleans up test agents

---

## Configuration for Testing

### Test Config (`.ittybitty.json`)
```json
{
  "model": "sonnet",
  "fps": 10,
  "permissions": {
    "manager": {
      "allow": ["Read", "Write", "Edit", "Glob", "Grep"],
      "deny": []
    },
    "worker": {
      "allow": ["Read", "Write", "Edit", "Bash"],
      "deny": []
    }
  }
}
```

### Key Principles
1. **Manager permissions**: Strategic tools only (Read, Write, Edit, Glob, Grep)
2. **Worker permissions**: Tactical tools (Bash for commands, file operations)
3. **ib commands**: Always allowed via special case `Bash(ib *)` or `Bash(./ib *)`
4. **Plan mode**: Requires Write for plan files

---

## Next Steps

1. ✅ Document Test 001 (complete)
2. ⏳ Apply fix to `.ittybitty.json`
3. ⏳ Verify fix with test agent
4. ⏳ Create `run-test.sh` automation script
5. ⏳ Add more test cases (002-005)
6. ⏳ Set up CI/CD for automated testing

---

## Notes

- All tests should be idempotent (can run multiple times)
- Test agents should auto-clean up after completion
- Failed test agents should be archived for debugging
- Test results should be logged to `tests/results/test-NNN-TIMESTAMP.log`
