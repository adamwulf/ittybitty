# Debugging Orphaned Claude Processes

This document explains how to manually find and clean up orphaned Claude processes that may occur if the `ib` script's cleanup fails.

## What is an Orphaned Claude Process?

An orphaned Claude process is a `claude` process that continues running after its corresponding agent has been killed or deleted. This can happen if:
- The `ib` script is forcefully interrupted during cleanup
- System crashes or power loss
- Bugs in the cleanup logic

Orphaned processes typically consume high CPU (50-300%) and have no controlling terminal (`??` in ps output).

## How to Manually Find Orphaned Processes

### Step 1: List All Claude Processes

```bash
# Find all Claude processes with their PIDs
ps aux | grep -E '[c]laude'
```

This shows all processes with "claude" in their command. Look for processes with:
- `??` in the TTY column (no controlling terminal)
- High CPU usage
- State `R` (Running)

### Step 2: Check Each Process's Working Directory

For each suspicious PID:

**On macOS:**
```bash
# Replace <PID> with the actual process ID
lsof -a -d cwd -p <PID> -Fn | grep '^n' | cut -c2-
```

**On Linux:**
```bash
# Replace <PID> with the actual process ID
readlink /proc/<PID>/cwd
```

**Check multiple PIDs at once (macOS):**
```bash
for pid in $(ps aux | grep '[c]laude$' | awk '{print $2}'); do
  echo -n "PID $pid: "
  lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | grep '^n' | cut -c2-
done
```

### Step 3: Identify Orphans

A Claude process is orphaned if:
1. Its working directory contains `/.ittybitty/agents/` in the path
2. The agent directory no longer exists (has been deleted)

**Example orphaned process:**
```
PID: 12345
CWD: /Users/you/project/.ittybitty/agents/agent-abc123/repo
Directory exists: NO (deleted)  <-- This is an orphan!
```

**Example legitimate process:**
```
PID: 67890
CWD: /Users/you/project/.ittybitty/agents/agent-xyz789/repo
Directory exists: YES  <-- This is a running agent, don't kill!
```

### Step 4: Kill Orphaned Processes

For each confirmed orphaned process:

```bash
# Try graceful shutdown first (SIGTERM)
kill -TERM <PID>

# Wait a few seconds
sleep 2

# Check if still running
kill -0 <PID> 2>/dev/null && echo "Still running"

# If still running, force kill (SIGKILL)
kill -KILL <PID>
```

## Automated Cleanup

The `ib` script now automatically scans for orphans after agent cleanup:
- After `ib kill <id>`
- After `ib merge <id>`
- After `ib nuke` operations

You should rarely need manual cleanup, but these steps are here if needed.

## Quick One-Liner for Emergency Cleanup

**Caution:** This will find and kill ALL orphaned Claude processes. Only use if you understand what it does.

```bash
# macOS version - finds and kills orphaned Claude processes
for pid in $(pgrep -f "claude"); do
    cwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | grep '^n' | cut -c2-)
    if [[ "$cwd" == *"/.ittybitty/agents/"* ]]; then
        # Extract agent directory path
        agent_dir=$(echo "$cwd" | grep -oE '.*/\.ittybitty/agents/[^/]+')
        if [[ -n "$agent_dir" && ! -d "$agent_dir" ]]; then
            echo "Killing orphaned PID $pid (deleted: $agent_dir)"
            kill -TERM "$pid" 2>/dev/null
            sleep 0.5
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
        fi
    fi
done
```

## Prevention

The `ib` script now implements several safeguards:

1. **PID Tracking**: Claude PIDs are stored in `meta.json` when agents start
2. **Graceful Shutdown**: Uses SIGTERM first, waits 2 seconds, then SIGKILL
3. **Orphan Scanning**: After cleanup, scans for any processes that slipped through
4. **Safety Checks**: Only kills processes with cwd in deleted agent directories

## Troubleshooting

### Many orphans after `ib nuke`

If you see many orphaned processes after running `ib nuke`, the fix may not be in place yet. Run the one-liner above or manually kill each orphaned process.

### Can't determine if a process is orphaned

If you can't get the working directory for a process:
1. Check if the process is actually a Claude process (`ps -p <PID> -o comm=`)
2. Use `pstree` to see the process hierarchy
3. When in doubt, don't kill it - legitimate Claude sessions will recover

### High CPU usage from unknown Claude processes

1. First identify if they're orphaned using the steps above
2. If confirmed orphaned, kill them
3. If not orphaned, they may be legitimately processing - check `ib list`

## Getting Help

If you encounter persistent orphaned processes:
1. Run `tmux list-sessions` to check for orphaned tmux sessions
2. Run `ib list` to see active agents
3. Compare process working directories with `ls .ittybitty/agents/`
4. File an issue with the output of steps 1-3
