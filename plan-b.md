# Plan B: Notification System — Polling-Based Background Listener

## Design Philosophy

The simplest possible design: a background bash command that polls a notification file and exits when messages arrive. No FIFOs, no named pipes, no new primitives beyond files.

## Core Insight

Claude Code already has a built-in mechanism for async notifications: **background bash tasks**. When a background task completes, Claude gets notified automatically. We just need:

1. A way for agents to write notifications (append to a file)
2. A way for main Claude to wait for notifications (poll the file, exit when non-empty)

## Architecture

```
Agent (worker/manager)                   Main Claude Session
         │                                        │
         │  ib notify "agent X completed"         │  Bash(run_in_background:true)
         ▼                                        │     ib listen
┌──────────────────┐                     ┌────────┴────────┐
│ Append message to │                     │ Poll every 1s   │
│ notifications.jsonl│                     │ for new messages │
│ (with flock)      │                     │ in notifications │
└──────────────────┘                     │ .jsonl           │
                                          │                  │
                                          │ Messages found?  │
                                          │ ──Yes──→ Print   │
                                          │          them &  │
                                          │          EXIT    │
                                          └──────────────────┘
                                                   │
                                                   ▼
                                          Claude gets notified
                                          (built-in behavior)
                                                   │
                                                   ▼
                                          Claude re-spawns listener
```

## New Commands

### `ib notify <message>` (called by agents/hooks)

Appends a notification to the shared notifications file.

```bash
cmd_notify() {
    local MESSAGE="$1"
    local FROM_ID=""

    # Auto-detect agent ID from worktree path
    # ...same pattern as cmd_log...

    require_git_repo

    local NOTIFY_DIR="$ROOT_REPO_PATH/.ittybitty"
    local NOTIFY_FILE="$NOTIFY_DIR/notifications.jsonl"
    local LOCK_FILE="$NOTIFY_DIR/notifications.lock"

    mkdir -p "$NOTIFY_DIR"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local json_line="{\"ts\":\"$timestamp\",\"from\":\"$FROM_ID\",\"msg\":\"$(json_escape "$MESSAGE")\"}"

    # Atomic append with flock (available on macOS via /usr/bin/flock or shlock)
    # Fallback: just append (races are tolerable — worst case, interleaved lines)
    echo "$json_line" >> "$NOTIFY_FILE"
}
```

**Arguments:** `ib notify "message"` or `ib notify --id <agent-id> "message"`
**Exit code:** Always 0
**Side effects:** Appends one JSONL line to `.ittybitty/notifications.jsonl`

### `ib listen` (called by main Claude as background task)

Blocks until notifications appear, then prints them and exits.

```bash
cmd_listen() {
    local NOTIFY_DIR="$ROOT_REPO_PATH/.ittybitty"
    local NOTIFY_FILE="$NOTIFY_DIR/notifications.jsonl"
    local PID_FILE="$NOTIFY_DIR/listener.pid"
    local POLL_INTERVAL=1  # seconds
    local TIMEOUT=300      # 5 minutes max wait, then exit cleanly

    require_git_repo
    mkdir -p "$NOTIFY_DIR"

    # Record our PID for liveness checks
    echo $$ > "$PID_FILE"

    # Clean trap
    trap 'rm -f "$PID_FILE"; exit 0' INT TERM

    local elapsed=0
    while [[ $elapsed -lt $TIMEOUT ]]; do
        # Check if notifications file exists and has content
        if [[ -f "$NOTIFY_FILE" && -s "$NOTIFY_FILE" ]]; then
            # Atomically drain: move file to tmp, print, delete
            local tmp_file="$NOTIFY_DIR/notifications.draining.$$"
            mv "$NOTIFY_FILE" "$tmp_file" 2>/dev/null || {
                # Another listener grabbed it (race), retry
                sleep "$POLL_INTERVAL"
                elapsed=$((elapsed + POLL_INTERVAL))
                continue
            }

            # Print all messages
            cat "$tmp_file"
            rm -f "$tmp_file"

            # Clean up PID and exit
            rm -f "$PID_FILE"
            exit 0
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    # Timeout — exit cleanly with no output
    rm -f "$PID_FILE"
    echo '{"ts":"timeout","from":"listener","msg":"No notifications for 5 minutes. Re-spawn listener."}'
    exit 0
}
```

**Arguments:** None (or `--timeout <seconds>`)
**Exit code:** Always 0
**Output:** JSONL lines on stdout when messages arrive, or timeout message
**Side effects:** Creates/removes `.ittybitty/listener.pid`

## Hook Changes

### 1. SessionStart Hook (main repo)

**Current:** Injects ittybitty instructions for the primary Claude.

**Add:** Append instruction to spawn the listener.

```
After the existing ittybitty instructions, add:

"## Real-time Notifications
To receive live updates from agents, run this as a background task:
\`\`\`
Bash(command: \"ib listen\", run_in_background: true)
\`\`\`
When the listener returns messages, process them and re-spawn the listener.
If the listener times out, just re-spawn it."
```

This goes in `cmd_hooks_session_start()` — only for the `primary` role.

### 2. PostToolUse Hook (main repo) — Liveness Check

**Current:** Calls `ib hooks inject-status --if-changed --visible`

**Add:** Also check listener liveness. If dead, inject a reminder.

```bash
# In cmd_hooks_inject_status or a new cmd_hooks_check_listener:
check_listener_liveness() {
    local PID_FILE="$ROOT_REPO_PATH/.ittybitty/listener.pid"

    if [[ ! -f "$PID_FILE" ]]; then
        return 1  # No listener
    fi

    local pid
    pid=$(<"$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        return 0  # Alive
    else
        rm -f "$PID_FILE"
        return 1  # Dead
    fi
}
```

If listener is dead AND agents are running, inject into `additionalContext`:
```
"[ib] Your notification listener is not running. Re-spawn it:
Bash(command: \"ib listen\", run_in_background: true)"
```

**Throttling:** Only inject this reminder every 30 seconds (use a timestamp cache file `.ittybitty/listener-reminder-ts`).

### 3. Stop Hook (agent hooks) — Auto-notify

**Current:** The agent Stop hook (`cmd_hooks_agent_status`) already notifies managers via `ib send`.

**Add:** Also call `ib notify` for significant state changes so the primary Claude gets notified:

```bash
# In cmd_hooks_agent_status, when worker completes:
if [[ "$state" == "complete" ]]; then
    # Existing: notify manager via ib send
    ib send "$manager" "[hook]: Your subtask $ID just completed"

    # NEW: also notify the primary Claude listener
    ib notify "Agent $ID completed (worker of $manager)"
fi

# When any top-level manager completes:
if [[ "$state" == "complete" && -z "$manager" ]]; then
    ib notify "Manager $ID completed its goal"
fi

# When agent asks a question:
# (Already in cmd_ask, add ib notify there)
ib notify "Agent $ID is asking: $QUESTION"
```

### 4. Watchdog — Auto-notify on waiting

**Current:** Watchdog sends messages via `ib send` to managers.

**Add:** For top-level managers, also notify the primary listener:

```bash
# In cmd_watchdog, when top-level agent starts waiting:
if [[ -z "$manager" && "$state" == "waiting" ]]; then
    ib notify "Agent $ID is now waiting"
fi
```

## Data Structures

### `.ittybitty/notifications.jsonl`
```jsonl
{"ts":"2026-02-17T15:00:00Z","from":"agent-abc123","msg":"Agent agent-abc123 completed its goal"}
{"ts":"2026-02-17T15:00:01Z","from":"agent-def456","msg":"Agent agent-def456 is asking: Should I proceed?"}
```

One JSON object per line. Each has: `ts` (ISO timestamp), `from` (agent ID or "system"), `msg` (human-readable message).

### `.ittybitty/listener.pid`
Contains the PID of the currently running listener process. Deleted on listener exit.

### `.ittybitty/listener-reminder-ts`
Contains epoch timestamp of last liveness reminder injection. Used for throttling.

## Edge Cases

### Listener not running when notification arrives
- Message is appended to `notifications.jsonl` regardless
- Next time listener starts, it immediately finds messages and returns them
- No message loss

### Multiple simultaneous writers
- JSONL append is mostly atomic for short lines on local filesystems
- Worst case: interleaved partial lines — but `mv` drain atomically grabs the whole file
- Optionally use `flock` for safety (macOS has it)

### Listener restarts (gap between exit and re-spawn)
- Messages accumulate in `notifications.jsonl`
- Next listener picks them all up at once
- No loss, minor delay

### Multiple listeners
- First one to `mv` the file gets the messages
- Others see no file and keep polling
- Not ideal but safe — and there should only be one primary Claude

### Timeout
- Listener exits after 5 minutes with a timeout message
- Claude re-spawns it
- This prevents orphan processes if Claude session ends

### Claude session ends
- Listener keeps polling until timeout (5 min max)
- PID file eventually becomes stale
- Next session's liveness check detects dead PID

### Notification file grows large
- `mv` atomically drains the entire file
- Listener prints all messages at once
- File is deleted after drain — no unbounded growth

## What NOT to Build

- **No FIFO/named pipe** — too many edge cases (writer blocks if no reader, reader blocks if no writer, can't handle multiple writers safely)
- **No message persistence** — notifications are ephemeral. Once delivered, they're gone.
- **No message types/routing** — all notifications go to one listener. Claude decides what to do.
- **No notification history** — no archiving of delivered messages
- **No notification filtering** — every message is delivered
- **No web UI or dashboard** — this is CLI-only
- **No daemon** — the listener is a simple polling loop, not a long-running service

## Test Fixtures

### `tests/test-notify.sh`
Test the notify and listen commands in isolation.

**Fixtures:**
```
tests/fixtures/notify/
├── single-message.jsonl        # One notification
├── multiple-messages.jsonl     # Several notifications
├── empty-file.jsonl           # Empty file (no notifications)
└── concurrent-writes.jsonl    # Simulated concurrent appends
```

**Tests:**
1. `ib notify "test"` appends correctly formatted JSONL
2. `ib listen` returns immediately when file has content
3. `ib listen` times out cleanly with empty file (use short timeout)
4. Drain is atomic: file is removed after listen completes
5. Multiple notifies then one listen returns all messages

### `tests/test-listener-liveness.sh`
Test the liveness check function.

**Fixtures:**
```
tests/fixtures/listener/
├── alive-pid.txt              # PID of a real running process
├── dead-pid.txt               # PID of a non-existent process
├── no-pid-file.txt            # No PID file exists
```

## Implementation Order

### Phase 1: Core Commands (can be tested standalone)
1. `cmd_notify()` — write to notifications file
2. `cmd_listen()` — poll and drain
3. Add to command dispatcher (`case` statement at bottom of script)
4. Write tests

### Phase 2: Hook Integration
5. Modify `cmd_hooks_agent_status()` — add `ib notify` calls for completions
6. Modify `cmd_ask()` — add `ib notify` call for questions
7. Modify `cmd_watchdog()` — add `ib notify` for top-level waiting

### Phase 3: Primary Claude Integration
8. Modify `cmd_hooks_session_start()` — inject listener spawn instruction (primary role only)
9. Add listener liveness check to `cmd_hooks_inject_status()`
10. Test end-to-end: spawn agent, verify main Claude receives notification

### Phase 4: Documentation
11. Update CLAUDE.md with notification system docs
12. Update README.md with user-facing feature description
13. Update `<ittybitty>` instructions in `get_ittybitty_instructions()`
