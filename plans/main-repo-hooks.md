# Plan: Main Repo Hook Protection

## Summary

Add hooks to prevent the main repo's Claude from `cd`-ing into agent worktrees, while still allowing Read/Write/Edit access. Unify all hook commands under `ib hooks <subcommand>`.

## Problem

When Claude runs in the main repo, it sometimes `cd`s into `.ittybitty/agents/*/repo` to inspect agent work. This is unnecessary because:
- Worktrees share branches - can use `git show agent/foo:path/file`
- Can Read files with absolute paths
- Can use `ib look/diff/status <agent>`

## Changes

### 1. Unify Hook Commands Under `ib hooks`

**Current → New naming:**
| Old Command | New Command | Purpose |
|-------------|-------------|---------|
| `hook-status` | `ib hooks agent-status` | Stop hook - nudges agent, notifies managers |
| `hook-check-path` | `ib hooks agent-path` | PreToolUse - blocks agent file access outside worktree |
| (new) | `ib hooks main-path` | PreToolUse - blocks main Claude from cd into worktrees |

**Management commands:**
| Command | Purpose |
|---------|---------|
| `ib hooks status` | Check if main repo hooks installed |
| `ib hooks install` | Install PreToolUse hook to main repo |
| `ib hooks uninstall` | Remove hook from main repo |

**Backward compatibility:** Keep `hook-status` and `hook-check-path` as aliases.

### 2. New `ib hooks main-path` Implementation

Only blocks Bash `cd` commands targeting `.ittybitty/agents/*/repo` paths.

- Allow: Read/Write/Edit/Glob to worktree paths
- Allow: All non-Bash tools
- Allow: Bash commands that aren't `cd`
- **Block**: `cd` into agent worktree paths

Log full JSON input initially for debugging (to verify we have cwd context).

### 3. Hook Management Commands

**`ib hooks status`**: Check if `.claude/settings.local.json` contains our PreToolUse hook.

**`ib hooks install`**:
- Create `.claude/` dir if needed
- Preserve existing settings.local.json content
- Add PreToolUse hook with matcher "Bash" calling `ib hooks main-path`

**`ib hooks uninstall`**:
- Remove our hook entry
- Clean up empty arrays/objects
- Preserve other user settings

### 4. Watch Integration

**On startup:**
- Check hooks status
- Set `HOOKS_INSTALLED` state variable (1=installed, 2=not installed)

**Warning display:**
- When not installed, show `[h: hooks]` in footer (yellow)
- Non-intrusive, matches existing pattern

**New keybind `h`:**
- Opens hooks dialog (DIALOG_MODE=6)
- Shows current status
- Single button: Install or Uninstall (toggles based on state)
- Close button

## Files to Modify

| File | Changes |
|------|---------|
| `ib` | Add `cmd_hooks()` dispatcher, rename existing hook functions, add new functions, update watch UI |

## Implementation Steps

### Step 1: Add hooks dispatcher and rename existing commands
- Add `cmd_hooks()` at ~line 3555 that routes to subcommands
- Rename `cmd_hook_status()` → `cmd_hooks_agent_status()`
- Rename `cmd_hook_check_path()` → `cmd_hooks_agent_path()`
- Update command routing to add `hooks)` case
- Keep backward compat aliases for `hook-status` and `hook-check-path`

### Step 2: Add `ib hooks main-path`
- Implement `cmd_hooks_main_path()`
- Only check Bash tool with `cd` commands
- Block if path matches `.ittybitty/agents/*/repo`
- Log blocked attempts to stderr
- Initially log full JSON input to /tmp for debugging

### Step 3: Add management commands
- Implement `cmd_hooks_status()` - check settings.local.json for our hook
- Implement `cmd_hooks_install()` - add hook preserving existing settings
- Implement `cmd_hooks_uninstall()` - remove hook preserving other settings

### Step 4: Watch integration
- Add `HOOKS_INSTALLED` state variable in `cmd_watch()`
- Add `watch_check_hooks_status()` helper function
- Call on startup after `load_config`
- Modify footer to show `[h: hooks]` warning when not installed
- Add `h` keybind in `watch_process_key()`
- Add hooks dialog (DIALOG_MODE=6) with init/render/key handlers

### Step 5: Update help and docs
- Update help text to show `hooks` command
- Mark old `hook-*` commands as deprecated aliases (still in help for now)
- Update CLAUDE.md with new command structure

## Verification

### Manual testing:

1. **Hook command renaming:**
```bash
# Old commands still work
echo '{}' | ib hook-check-path test-id
echo '{}' | ib hook-status test-id

# New commands work
echo '{}' | ib hooks agent-path test-id
echo '{}' | ib hooks agent-status test-id
```

2. **Main path hook:**
```bash
# Allow non-cd
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | ib hooks main-path
echo $?  # 0

# Allow cd to normal paths
echo '{"tool_name":"Bash","tool_input":{"command":"cd /tmp"},"cwd":"/"}' | ib hooks main-path
echo $?  # 0

# Block cd to agent worktree
echo '{"tool_name":"Bash","tool_input":{"command":"cd .ittybitty/agents/foo/repo"},"cwd":"'$(pwd)'"}' | ib hooks main-path
echo $?  # 2

# Allow Read to worktree
echo '{"tool_name":"Read","tool_input":{"file_path":"/.ittybitty/agents/foo/repo/x"}}' | ib hooks main-path
echo $?  # 0
```

3. **Hook management:**
```bash
ib hooks status          # not-installed
ib hooks install
cat .claude/settings.local.json  # verify hook added
ib hooks status          # installed
ib hooks uninstall
ib hooks status          # not-installed
```

4. **Watch integration:**
```bash
ib watch
# See [h: hooks] warning if not installed
# Press h, see dialog
# Install from dialog
# Warning disappears
```
