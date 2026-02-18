# Plan A: Real-Time Notification System via File Queue + FIFO Signal

## Overview

Enable ib agents to send real-time notifications to the primary Claude session. The primary Claude spawns a background bash task that **blocks** on a FIFO. Agents write messages to a queue file, then signal the FIFO. The background task wakes, drains the queue, prints messages to stdout, and exits. Claude Code sees the background task complete and notifies the primary Claude, who processes the messages and re-spawns the listener.

## ASCII Data Flow

```
                        ┌─────────────────────────────────┐
                        │   Primary Claude Session        │
                        │                                 │
                        │  1. Bash(run_in_background:true) │
                        │     → ib listen                 │
                        │                                 │
                        │  4. Background task completes   │
                        │     → Claude reads output       │
                        │     → Processes messages         │
                        │     → Re-spawns: ib listen      │
                        └──────────┬──────────────────────┘
                                   │
                          spawns   │
                                   ▼
                  ┌─────────────────────────────────┐
                  │   ib listen (background bash)   │
                  │                                 │
                  │  - Registers PID in pidfile     │
                  │  - Creates FIFO if needed       │
                  │  - Blocks: read < FIFO          │
                  │  - Wakes: drains queue file     │
                  │  - Prints messages to stdout     │
                  │  - Exits (task completes)        │
                  └─────────────────────────────────┘
                                   ▲
                          signals  │ (writes byte to FIFO)
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                     │
    ┌─────────┴───────┐  ┌────────┴────────┐  ┌────────┴────────┐
    │  Agent A         │  │  Agent B         │  │  Stop Hook      │
    │  ib notify "msg" │  │  ib notify "msg" │  │  ib notify "msg" │
    │                  │  │                  │  │                  │
    │ 2a. Append msg   │  │ 2b. Append msg   │  │ 2c. Append msg   │
    │     to queue     │  │     to queue     │  │     to queue     │
    │ 3a. Write byte   │  │ 3b. Write byte   │  │ 3c. Write byte   │
    │     to FIFO      │  │     to FIFO      │  │     to FIFO      │
    └──────────────────┘  └──────────────────┘  └──────────────────┘
```

**Message lifecycle:**
1. Primary Claude spawns `ib listen` as background bash task
2. Agent calls `ib notify "message"` → appends to queue file, writes byte to FIFO
3. `ib listen` wakes from FIFO read, drains queue, prints messages, exits
4. Claude Code notifies primary Claude of completed background task
5. Primary Claude reads output, processes messages, re-spawns `ib listen`

## Data Structures

### File Paths

All notification files live under `.ittybitty/notify/`:

| File | Path | Purpose |
|------|------|---------|
| FIFO | `.ittybitty/notify/signal` | Named pipe; listener blocks on read |
| Queue | `.ittybitty/notify/queue` | Append-only message file; one JSON object per line |
| PID file | `.ittybitty/notify/listener.pid` | PID of current `ib listen` process |
| Lock file | `.ittybitty/notify/queue.lock` | Simple file-based lock for queue drain |

### Queue File Format

Each line is a self-contained JSON object (JSONL format). This avoids needing a JSON parser for the whole file and makes appending atomic at the line level.

```jsonl
{"ts":"2026-02-17T14:30:05-06:00","from":"agent-abc123","type":"status","msg":"Task completed: refactored auth module"}
{"ts":"2026-02-17T14:30:07-06:00","from":"agent-def456","type":"status","msg":"Worker def456 is now waiting for input"}
```

Fields:
- `ts` — ISO 8601 timestamp (from `date -Iseconds` or `date +%Y-%m-%dT%H:%M:%S%z` on macOS)
- `from` — agent ID of sender (or `"hook"` for hook-generated notifications)
- `type` — message category: `"status"`, `"complete"`, `"waiting"`, `"stuck"`, `"error"`
- `msg` — human-readable message text

### FIFO Signal Protocol

The FIFO is a wake-up mechanism only. The actual data is in the queue file. Writers send a single newline (`\n`) to the FIFO. The listener reads one line (which unblocks it), then drains the queue.

## New Commands

### `ib listen`

**Purpose:** Block until notification(s) arrive, then print them and exit.

**Usage:** `ib listen [--timeout SECONDS]`

**Behavior:**
1. Create `.ittybitty/notify/` directory if it doesn't exist
2. Create FIFO at `.ittybitty/notify/signal` if it doesn't exist (`mkfifo`)
3. Write own PID to `.ittybitty/notify/listener.pid`
4. **Check queue first:** If queue file already has messages, drain immediately (handles messages sent while no listener was running)
5. If no messages in queue, block on `read < FIFO` (with optional timeout via `read -t`)
6. On wake (or timeout): drain the queue file
7. Print all drained messages to stdout (one per line, raw JSONL)
8. Remove PID file
9. Exit 0 if messages were delivered, exit 1 if timeout with no messages

**Drain procedure (atomic):**
1. Acquire lock: `mkdir .ittybitty/notify/queue.lock` (atomic on all filesystems)
2. Copy queue file to a temp file: `cp queue queue.drain.$$`
3. Truncate queue file: `> queue`
4. Release lock: `rmdir queue.lock`
5. Read and print lines from `queue.drain.$$`
6. Remove temp file

**Timeout behavior:**
- Default: no timeout (block forever)
- `--timeout 300`: exit after 300 seconds if no signal received
- On timeout with no messages: exit 1

**Implementation function:** `cmd_listen()`

```bash
cmd_listen() {
    local timeout=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout)
                timeout="$2"
                shift 2
                ;;
            -h|--help)
                # ... help text ...
                exit 0
                ;;
            *)
                echo "Error: unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    local notify_dir="$ITTYBITTY_DIR/notify"
    local fifo_path="$notify_dir/signal"
    local queue_path="$notify_dir/queue"
    local pid_path="$notify_dir/listener.pid"
    local lock_path="$notify_dir/queue.lock"

    mkdir -p "$notify_dir"

    # Create FIFO if needed
    if [[ ! -p "$fifo_path" ]]; then
        mkfifo "$fifo_path"
    fi

    # Write PID
    echo $$ > "$pid_path"

    # Cleanup on exit
    trap 'rm -f "$pid_path"' EXIT

    # Check for pre-existing messages
    local has_messages=false
    if [[ -s "$queue_path" ]]; then
        has_messages=true
    fi

    if [[ "$has_messages" != "true" ]]; then
        # Block on FIFO read
        # Open FIFO for reading, but also open it for writing to prevent
        # EOF when no writers are connected (keep FIFO open)
        if [[ -n "$timeout" ]]; then
            # Bash 3.2: read -t only works with integer seconds
            read -t "$timeout" _signal < "$fifo_path" || true
        else
            read _signal < "$fifo_path" || true
        fi
    fi

    # Drain queue
    local drained=false
    if [[ -s "$queue_path" ]]; then
        # Acquire lock (mkdir is atomic)
        local lock_attempts=0
        while ! mkdir "$lock_path" 2>/dev/null; do
            lock_attempts=$((lock_attempts + 1))
            if [[ $lock_attempts -ge 50 ]]; then
                echo "Error: could not acquire queue lock" >&2
                exit 1
            fi
            sleep 0.1
        done

        # Drain
        local drain_file="$notify_dir/queue.drain.$$"
        cp "$queue_path" "$drain_file"
        : > "$queue_path"

        # Release lock
        rmdir "$lock_path"

        # Output messages
        cat "$drain_file"
        rm -f "$drain_file"
        drained=true
    fi

    # Clean up FIFO - recreate it fresh for next listener
    # This prevents stale data in the pipe
    rm -f "$fifo_path"

    if [[ "$drained" == "true" ]]; then
        exit 0
    else
        exit 1
    fi
}
```

**FIFO blocking edge case — preventing immediate EOF:**

A FIFO `read` returns immediately with EOF if no writer has the FIFO open. Two approaches:

- **Approach A (simple):** Open FIFO read-write: `read _signal <> "$fifo_path"`. This keeps the FIFO open and prevents EOF. Works on Bash 3.2. The `<>` operator opens the fd for both reading and writing, which prevents EOF when no writer is connected.
- **Approach B:** Open a background writer: `exec 3>"$fifo_path" &` — more complex, not needed.

**Use Approach A.** Change the read line to:
```bash
read -t "$timeout" _signal <> "$fifo_path" || true
# or without timeout:
read _signal <> "$fifo_path" || true
```

### `ib notify`

**Purpose:** Send a notification message to the primary Claude listener.

**Usage:** `ib notify [--from ID] [--type TYPE] "message"`

**Behavior:**
1. Build JSON line with timestamp, sender, type, message
2. Append line to queue file (atomic via `>>` redirect — single `echo >>` is atomic for lines < PIPE_BUF, 512 bytes on macOS)
3. Write a newline to the FIFO (non-blocking; if FIFO is full or no reader, this is fine)
4. Exit 0

**Arguments:**
- `--from ID` — sender agent ID (auto-detected from worktree if omitted)
- `--type TYPE` — message type (default: `"status"`)
- Positional: the message text

**Implementation function:** `cmd_notify()`

```bash
cmd_notify() {
    local from_id="" msg_type="status" message=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                from_id="$2"
                shift 2
                ;;
            --type)
                msg_type="$2"
                shift 2
                ;;
            -h|--help)
                # ... help text ...
                exit 0
                ;;
            *)
                if [[ -z "$message" ]]; then
                    message="$1"
                else
                    message="$message $1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$message" ]]; then
        echo "Error: message required" >&2
        exit 1
    fi

    # Auto-detect sender from worktree
    if [[ -z "$from_id" ]]; then
        local current_dir
        current_dir=$(pwd)
        if [[ "$current_dir" =~ /.ittybitty/agents/([^/]+)/repo ]]; then
            local agent_dir="${current_dir%/repo*}"
            if [[ -f "$agent_dir/meta.json" ]]; then
                from_id=$(read_meta_field "$agent_dir/meta.json" "id" "unknown")
            fi
        fi
        if [[ -z "$from_id" ]]; then
            from_id="unknown"
        fi
    fi

    local notify_dir="$ITTYBITTY_DIR/notify"
    local queue_path="$notify_dir/queue"
    local fifo_path="$notify_dir/signal"

    mkdir -p "$notify_dir"

    # Build timestamp (macOS-compatible ISO 8601)
    local ts
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Escape message for JSON (handle quotes and backslashes)
    local escaped_msg="${message//\\/\\\\}"
    escaped_msg="${escaped_msg//\"/\\\"}"
    escaped_msg="${escaped_msg//$'\n'/\\n}"

    # Append to queue (>> is atomic for short lines)
    echo "{\"ts\":\"$ts\",\"from\":\"$from_id\",\"type\":\"$msg_type\",\"msg\":\"$escaped_msg\"}" >> "$queue_path"

    # Signal listener via FIFO (non-blocking)
    # Use timeout to avoid blocking if no reader or FIFO is full
    # dd with count=0 or timeout approach
    if [[ -p "$fifo_path" ]]; then
        # Non-blocking write: open with timeout using background + kill
        ( echo "" > "$fifo_path" ) &
        local writer_pid=$!
        ( sleep 1 && kill "$writer_pid" 2>/dev/null ) &
        local killer_pid=$!
        wait "$writer_pid" 2>/dev/null || true
        kill "$killer_pid" 2>/dev/null || true
        wait "$killer_pid" 2>/dev/null || true
    fi

    exit 0
}
```

**Non-blocking FIFO write — critical detail:**

Writing to a FIFO blocks if no reader is connected and the pipe buffer is full (or if no reader has the FIFO open at all on some systems). Since the listener might not be running, the writer MUST NOT block indefinitely.

**Solution:** Use a background subshell with a kill-timer:
```bash
( echo "" > "$fifo_path" ) &
local writer_pid=$!
( sleep 1 && kill "$writer_pid" 2>/dev/null ) &
local killer_pid=$!
wait "$writer_pid" 2>/dev/null || true
kill "$killer_pid" 2>/dev/null || true
wait "$killer_pid" 2>/dev/null || true
```

This gives the write 1 second to complete. If no reader, the subshell is killed. The message is already in the queue file, so nothing is lost — the next `ib listen` will drain it immediately.

**Simpler alternative for the non-blocking write** (preferred if it works on macOS Bash 3.2):

On macOS/BSD, we can try opening the FIFO with `O_NONBLOCK` semantics. Unfortunately Bash doesn't expose `O_NONBLOCK` directly. The background+kill approach is the reliable cross-platform solution.

## Hook Changes

### 1. SessionStart Hook: Inject Listener Instructions

**File:** `cmd_hooks_session_start()` in the `ib` script

**Change:** When `role == "primary"`, append listener bootstrap instructions to the `additionalContext` output.

**What to inject (added to `get_ittybitty_instructions()` for primary role):**

```
### Real-Time Agent Notifications

To receive live updates from running agents, spawn a background listener:

\`\`\`
Bash(command: "ib listen --timeout 300", run_in_background: true)
\`\`\`

When the listener returns output, it contains JSONL-formatted notification messages
from agents. Process each line and take appropriate action (check agent status,
merge completed work, etc.), then re-spawn the listener to continue receiving updates.

If the listener exits with no output (timeout), just re-spawn it.

Keep exactly one listener running at all times while agents are active.
\`\`\`
```

This is injected via `get_ittybitty_instructions()` only for the `primary` role. Agents do NOT get these instructions — they use `ib notify` instead.

### 2. Stop Hook: Send Notifications on State Changes

**File:** `cmd_hooks_agent_status()` in the `ib` script

**Change:** In addition to existing behavior (sending tmux messages to managers, nudging idle agents), also call `ib notify` to alert the primary Claude.

**Where to add `ib notify` calls:**

| State | Current behavior | New addition |
|-------|-----------------|--------------|
| `complete` (worker) | `ib send $manager "[hook]: completed"` | Add: `ib notify --from "$ID" --type complete "Agent $ID completed"` |
| `complete` (manager, no children) | Log only | Add: `ib notify --from "$ID" --type complete "Agent $ID completed"` |
| `waiting` (worker) | `ib send $manager "[hook]: waiting"` | Add: `ib notify --from "$ID" --type waiting "Agent $ID is waiting"` |
| `waiting` (manager) | Log only | Add: `ib notify --from "$ID" --type waiting "Agent $ID is waiting"` |
| `stuck` | N/A (future) | `ib notify --from "$ID" --type stuck "Agent $ID is stuck"` |

**Do NOT notify on:** `running`, `unknown`, `creating`, `compacting`, `rate_limited` — these are transient states and would create noise.

**Implementation detail:** The `ib notify` calls should be **after** the existing `ib send` calls (maintain current manager-notification behavior, add primary-notification on top).

### 3. PreToolUse / PermissionRequest Hooks: No Changes

These hooks enforce path isolation and tool permissions. They don't need modification for the notification system. The notification files (`.ittybitty/notify/`) are within the `.ittybitty/` directory which agents can already access.

**Path isolation consideration:** Agents need to be able to write to `.ittybitty/notify/queue` and `.ittybitty/notify/signal`. The PreToolUse hook (`cmd_hooks_agent_path`) allows access to the agent's own worktree. However, `.ittybitty/notify/` is in the **main repo**, not in the agent's worktree.

**Solution:** Since `ib notify` runs as a Bash command (which is allowed via `Bash(ib:*)`), the path isolation hook doesn't interfere — it only checks paths passed to file tools (Read, Write, Edit, etc.), not paths accessed by allowed bash commands. The `ib notify` command accesses the queue file internally, not via Claude's file tools.

### 4. Liveness Checking (Optional Enhancement)

Add a helper to check if a listener is currently active:

```bash
is_listener_alive() {
    local pid_path="$ITTYBITTY_DIR/notify/listener.pid"
    if [[ -f "$pid_path" ]]; then
        local pid
        pid=$(<"$pid_path")
        if kill -0 "$pid" 2>/dev/null; then
            return 0  # alive
        fi
        # Stale PID file
        rm -f "$pid_path"
    fi
    return 1  # not alive
}
```

This can be used by:
- `ib watch` to show listener status in the UI
- The Stop hook to log a warning if no listener is running when notifications are sent (non-blocking — just a log, no behavior change)

## Edge Cases

### 1. Listener Not Running When `ib notify` Is Called

**Scenario:** Agent completes work and calls `ib notify`, but no `ib listen` is blocking.

**Handling:** The message is appended to the queue file regardless. The FIFO write times out after 1 second (killed background subshell). The message sits in the queue until the next `ib listen` call, which checks for pre-existing messages before blocking on the FIFO.

**No messages are lost.** The queue file is the source of truth; the FIFO is only a wake-up signal.

### 2. Multiple Simultaneous Writers

**Scenario:** Two agents call `ib notify` at the same time.

**Handling:**
- Queue file: `echo "..." >> file` is atomic for writes smaller than `PIPE_BUF` (512 bytes on macOS, 4096 on Linux). Our JSON lines will be well under this limit. No corruption.
- FIFO: Both writers send a newline. The listener's `read` consumes one; the second stays in the pipe buffer (harmless — the listener drains the queue and exits either way).

### 3. Message Ordering

Messages appear in queue file in the order `echo >>` completes. With atomic appends, this is well-defined. The drain procedure copies the entire file atomically, preserving order.

**No ordering guarantees between agents** — if agent A and agent B both write at the same nanosecond, either could appear first. This is acceptable for notifications.

### 4. FIFO Writer Blocking

**Scenario:** FIFO has no reader and a writer tries `echo > fifo`.

**Handling:** The background+kill pattern ensures the writer never blocks for more than 1 second. The message is already in the queue file before the FIFO write attempt, so no data loss.

### 5. Queue File Growth / Rotation

**Scenario:** Many notifications accumulate while no listener is running.

**Handling:** Each `ib listen` drains the entire queue file and truncates it. Under normal operation, the file stays small. If the primary Claude crashes or disconnects, messages accumulate but are bounded by agent activity (at most a few dozen lines per agent session).

**No rotation needed.** The drain-and-truncate pattern keeps the file small.

### 6. Listener Crash / Stale PID File

**Scenario:** `ib listen` crashes or is killed without removing its PID file.

**Handling:**
- The `trap EXIT` handler removes the PID file on normal/signal exit
- `is_listener_alive()` checks if the PID is still running before trusting the PID file
- A new `ib listen` overwrites the stale PID file

### 7. Gap Between Listener Exit and Re-Spawn

**Scenario:** Listener drains queue and exits. Before primary Claude re-spawns it, an agent sends a notification.

**Handling:** The message goes into the queue file. The FIFO write may timeout (no reader). When the new `ib listen` starts, it checks the queue file first before blocking on the FIFO. Messages are not lost.

### 8. Race Condition: Drain vs. Write

**Scenario:** Listener is draining the queue (copy + truncate) while a writer appends a new message.

**Handling:** The `mkdir` lock prevents this race:
- Writer attempts `echo >> queue` — but must first... wait, writers don't acquire the lock.

**Revised design:** Writers do NOT need the lock for appending. The race is:
1. Listener copies queue to drain file
2. Writer appends to queue
3. Listener truncates queue

If step 2 happens between 1 and 3, the new message is lost (truncated but not in the drain file).

**Fix:** The drain procedure must lock around both the copy AND truncate:
1. Lock (`mkdir`)
2. Move (not copy) queue file: `mv queue queue.drain.$$` (atomic on same filesystem)
3. Unlock (`rmdir`)
4. Read from `queue.drain.$$`

With `mv`, any writes that started before the lock complete to the original inode. After the `mv`, new writes create a new `queue` file (because `>> queue` creates it if missing). This eliminates the race entirely.

**Updated drain procedure:**
```bash
mkdir "$lock_path" 2>/dev/null || { ... retry ... }
mv "$queue_path" "$drain_file" 2>/dev/null || true
rmdir "$lock_path"
# Now read drain_file at leisure
```

Writers just do `echo >> "$queue_path"` — if the file doesn't exist (just moved), the shell creates it.

### 9. FIFO Deleted Between Listener Sessions

The FIFO is recreated by `ib listen` if missing, and `ib notify` checks `[[ -p "$fifo_path" ]]` before writing. If the FIFO doesn't exist during `ib notify`, the write is silently skipped (the message is already queued).

### 10. `read` Timeout Granularity on Bash 3.2

On Bash 3.2, `read -t` only accepts integer seconds (no fractional). The `--timeout` value must be an integer. Document this.

## Bash 3.2 Compatibility

| Feature Used | Compatibility | Notes |
|-------------|---------------|-------|
| `mkfifo` | Yes | POSIX standard |
| `read <> fifo` | Yes | POSIX redirection |
| `read -t N` | Yes (integers only) | No fractional seconds in Bash 3.2 |
| `mkdir` as lock | Yes | Atomic on all filesystems |
| `mv` (same filesystem) | Yes | Atomic rename |
| `echo >> file` | Yes | Atomic for < PIPE_BUF |
| `trap EXIT` | Yes | Standard signal handling |
| `$!` (last background PID) | Yes | POSIX |
| `kill -0` | Yes | POSIX process existence check |
| `date +%Y-%m-%dT%H:%M:%S%z` | Yes | macOS date supports this |
| Parameter expansion for JSON escaping | Yes | `${var//pat/rep}` works in 3.2 |

**Nothing in this design requires Bash 4.0+.**

## `set -e` Safety

All patterns that need guarding:

```bash
# FIFO read (may timeout or get signal)
read _signal <> "$fifo_path" || true

# mkdir lock (may fail if lock exists)
# Used in while loop condition — safe in if/while

# kill -0 (returns 1 if process doesn't exist)
# Used in if condition — safe

# wait (may fail if process already exited)
wait "$writer_pid" 2>/dev/null || true
kill "$killer_pid" 2>/dev/null || true
wait "$killer_pid" 2>/dev/null || true

# mv (may fail if queue doesn't exist)
mv "$queue_path" "$drain_file" 2>/dev/null || true

# rm -f (always succeeds)
# mkdir -p (always succeeds if possible)
```

**Rule applied:** Every `[[ ... ]] && ...` has `|| true`. Every command that might return non-zero outside an `if`/`while` has `|| true`.

## Scope Boundaries: What NOT to Build

| NOT building | Why |
|-------------|-----|
| Bidirectional communication | Notifications are one-way: agents → primary. Primary talks to agents via existing `ib send`. |
| Message acknowledgment | Fire-and-forget. The queue drain is the "ack". |
| Message filtering/routing | All messages go to one queue. Primary Claude filters by reading the JSON. |
| Persistent message history | Drained messages are gone. Agent logs provide history. |
| Multiple listeners | Only one listener at a time. PID file prevents confusion. |
| Watch UI integration | `ib watch` doesn't need changes for v1. Can show listener status later. |
| Agent-to-agent notifications | Agents communicate via `ib send` (tmux). Notifications are agent→primary only. |
| Retry/backoff | No retries. Messages queue up; next listener drains them. |
| Message size limits | Trust agents to send reasonable messages. JSON lines will be short. |
| Encryption/auth | All local. Trust the filesystem. |
| Custom notification types beyond status/complete/waiting/stuck/error | Five types is enough for v1. |

## Test Plan

### New Test Fixtures Needed

#### `tests/test-notify.sh` — Tests for queue file operations

| Fixture | Tests |
|---------|-------|
| `tests/fixtures/notify/single-message.jsonl` | Single notification in queue → `ib listen` outputs it |
| `tests/fixtures/notify/multiple-messages.jsonl` | Multiple notifications → all output in order |
| `tests/fixtures/notify/empty-queue.jsonl` | Empty queue → `ib listen --timeout 1` exits with code 1 |
| `tests/fixtures/notify/special-chars.jsonl` | Messages with quotes, newlines, backslashes → proper JSON escaping |

#### Testing approach

Since `ib listen` and `ib notify` involve FIFOs and blocking, unit tests should focus on the **queue operations** in isolation:

1. **`ib test-notify-format`** — Test JSON line generation given from/type/msg arguments
   - Input: fixture with `from`, `type`, `msg` fields
   - Output: properly formatted JSON line
   - Tests JSON escaping, timestamp format, field ordering

2. **`ib test-notify-drain`** — Test queue drain logic given a queue file
   - Input: fixture queue file (JSONL)
   - Output: drained messages (same content)
   - Tests: correct output, file truncation, lock acquisition

3. **Integration tests** (in test script, not via `ib test-*`):
   - Spawn `ib listen --timeout 2` in background
   - Run `ib notify --from test --type status "hello"`
   - Wait for listener to exit
   - Verify output contains the message

### Test Commands to Add

| Command | Function | Purpose |
|---------|----------|---------|
| `ib test-notify-format` | `cmd_test_notify_format` | Test JSON line formatting |
| `ib test-notify-drain` | `cmd_test_notify_drain` | Test queue drain procedure |

## Implementation Order

### Phase 1: Core Infrastructure (build first)

1. **Add `cmd_notify()`** — The write side
   - Create `.ittybitty/notify/` directory structure
   - JSON line formatting with proper escaping
   - Atomic append to queue file
   - Non-blocking FIFO signal with background+kill pattern
   - Add to main dispatcher: `notify) shift; cmd_notify "$@" ;;`

2. **Add `cmd_listen()`** — The read side
   - FIFO creation (`mkfifo`)
   - PID file management with `trap EXIT`
   - Pre-drain check (messages before blocking)
   - FIFO blocking read with `<>` operator
   - Atomic drain with `mv` + `mkdir` lock
   - Add to main dispatcher: `listen) shift; cmd_listen "$@" ;;`

3. **Add `is_listener_alive()` helper**
   - PID file check + `kill -0` liveness verification
   - Stale PID cleanup

### Phase 2: Hook Integration

4. **Modify `cmd_hooks_agent_status()`** (Stop hook)
   - Add `ib notify` calls for `complete` and `waiting` states
   - After existing `ib send` calls (don't change current behavior)

5. **Modify `get_ittybitty_instructions()`** (SessionStart injection)
   - Add listener bootstrap instructions for `primary` role only
   - Include example Bash tool invocation and re-spawn pattern

### Phase 3: Testing

6. **Add `cmd_test_notify_format()`** and fixtures
   - Test JSON escaping edge cases
   - Test auto-detection of sender ID

7. **Add `cmd_test_notify_drain()`** and fixtures
   - Test single/multiple message drain
   - Test empty queue behavior

8. **Add `tests/test-notify.sh`** and integration tests
   - Fixture-based tests for format and drain
   - Background listener + notify integration test

9. **Update `tests/test-all.sh`** to include new test suite

### Phase 4: Polish

10. **Add `listen` and `notify` to help text**
    - `cmd_help()` or main usage output
    - Brief description in `ib --help`

11. **Add cleanup to `cmd_nuke()`**
    - Remove `.ittybitty/notify/` directory
    - Kill listener process if running

12. **Add to permissions**
    - `Bash(ib listen:*)` and `Bash(ib notify:*)` are already covered by `Bash(ib:*)` — no changes needed

## Summary

This design achieves real-time agent→primary notifications with:
- **Zero external dependencies** — only `mkfifo`, `mv`, `mkdir`, `read`, `echo`
- **Zero polling** — the listener truly blocks until signaled
- **No message loss** — the queue file survives gaps between listeners
- **Atomic operations** — `mv` for drain, `>>` for append, `mkdir` for locking
- **Bash 3.2 compatible** — no modern bash features required
- **`set -e` safe** — all fallible commands guarded with `|| true`
- **Simple** — two commands (`listen` + `notify`), one queue file, one FIFO, one lock
