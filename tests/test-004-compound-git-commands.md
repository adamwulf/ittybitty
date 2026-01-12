# Test: Compound Git Commands Permission Handling

## Test Case

When a command like this is in the allow list:
```
"Bash(git add:*)",
"Bash(git commit:*)",
```

And the agent runs a compound command:
```bash
git add ib tests/test-003-pretooluse-allow.md && git commit -m "commit message"
```

## Expected Behavior

The PreToolUse hook should:
1. Parse the command and recognize it starts with `git add`
2. Check that `Bash(git add:*)` is in the allow list
3. Output `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`
4. The command should execute without showing a permission prompt

## Observed Behavior (Before Fix)

With exit-code-based PreToolUse hooks (exit 0 = proceed):
- The hook exits 0, which just continues normal permission flow
- Claude Code still shows the permission prompt for commands it hasn't seen before
- The `PermissionRequest` hook is NOT triggered (that's for denied tools, not location permissions)

## Root Cause

The PreToolUse hook needs to output JSON with `permissionDecision: "allow"` to completely bypass the permission system. Exit codes only control whether to continue (0) or block (2) the normal flow.

## Test Command

```bash
# Create an agent and have it run a compound git command
ib new-agent --name test-compound-git "Run: git add . && git commit -m 'test commit'"

# Check if permission prompt appears
ib look test-compound-git
```

## Related

- `pretool-allow` agent implementing this fix
- test-003-pretooluse-allow.md for general PreToolUse testing
