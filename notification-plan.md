# Real-Time Notification System — Implementation Plan (v2)

## Overview

Enable running ib agents to push notifications to the primary Claude session (the one the user talks to). When an agent completes, starts waiting, or asks a question, the primary Claude wakes up and can react within seconds.

**Core mechanism:** The primary Claude spawns `ib listen` as a background bash task. The listener polls a queue file every 2 seconds. When messages appear, it drains the queue, prints messages to stdout, and exits. Claude Code's built-in background task completion notification delivers the output to the primary Claude, who processes it and re-spawns the listener. A liveness check on every tool call ensures the listener stays running.

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  Primary Claude (user's terminal, NOT in tmux)                  │
│                                                                 │
│  1. Bash(command:"ib listen", run_in_background: true)          │
│                                                                 │
│  4. Claude Code notifies: "Background task completed"           │
│     → Claude reads output (JSONL lines)                         │
│     → Takes action (ib merge, ib send, ib look, etc.)           │
│     → Re-spawns: ib listen                                      │
│                                                                 │
│  Liveness: every tool call, hook checks if listener is alive.   │
│  If dead, hook injects reminder into Claude's context.          │
└──────────┬──────────────────────────────────────────────────────┘
           │ spawns background bash
           ▼
┌──────────────────────────────────────────────┐
│  ib listen (background bash process)         │
│                                              │
│  - Writes PID to .ittybitty/notify/pid       │
│  - Polls queue file every 2 seconds          │
│  - When messages found: mv queue → drain     │
│  - Prints drained messages to stdout         │
│  - Exits (triggers Claude Code notification) │
│  - After ~9.5 min: exits with reminder       │
└──────────────────────────────────────────────┘
           ▲
           │ appends to queue file
           │
     ┌─────┴─────────────────────────┐
     │                               │
┌────┴────────┐            ┌─────────┴──────────┐
│ Stop Hook   │            │ cmd_ask()           │
│ (agent idle)│            │ (agent questions)   │
│             │            │                     │
│ ib notify   │            │ ib notify           │
│ --type X    │            │ --type question     │
│ "Agent done"│            │ "Agent asks: ..."   │
└─────────────┘            └────────────────────┘
```

**Why this works:** The primary Claude is NOT in a tmux session — it runs in the user's terminal directly. The only reliable way to "wake" it is via Claude Code's background task completion notification. The listener is a background bash process that exits when messages arrive (or on timeout), which triggers that notification.

**Why polling, not FIFO:** A FIFO (named pipe) provides instant wakeup but adds significant complexity: mkfifo lifecycle management, non-blocking write edge cases, drain race conditions, and `<>` mode subtleties. A 2-second polling loop is dramatically simpler and the latency difference is negligible for Claude's workflow (Claude needs seconds to process notifications anyway).

## File Paths

All notification files live under `.ittybitty/notify/`. Since `.ittybitty/` is already repo-specific (it lives inside each repo's root), no additional REPO_ID scoping is needed in filenames.

```
.ittybitty/
├── notify/
│   ├── queue       # JSONL message queue — source of truth
│   └── listener.pid # PID of current ib listen process
└── ...
```

**No REPO_ID in filenames.** The `.ittybitty/` directory is unique per repo. Multiple repos on the same machine each have their own `.ittybitty/notify/` directory. This is consistent with how other `.ittybitty/` files work (e.g., `user-questions.json`, `repo-id`).

## Queue Message Format

Each line in the queue file is a self-contained JSON object (JSONL):

```jsonl
{"ts":"2026-02-17T14:30:05-0600","from":"agent-abc123","type":"complete","msg":"Agent agent-abc123 completed its goal"}
{"ts":"2026-02-17T14:30:07-0600","from":"agent-def456","type":"question","msg":"Agent agent-def456 asks: Should I refactor the auth module?"}
```

| Field | Type | Description |
|-------|------|-------------|
| `ts` | string | ISO 8601 timestamp (`date +%Y-%m-%dT%H:%M:%S%z`) |
| `from` | string | Agent ID of sender, or `"system"` |
| `type` | string | One of: `complete`, `waiting`, `question` |
| `msg` | string | Human-readable message text |

**Exactly three types for v1:** `complete`, `waiting`, `question`. The `--type` argument is validated — unknown types are rejected with an error. Default type (when `--type` is omitted) is `complete`.

**No `question_id` field.** When Claude receives a `type=question` notification, it should run `ib questions` to get the question ID, then `ib acknowledge <id>` + `ib send <agent> "answer"`. This keeps the notification format simple and avoids coupling between the notification and question systems.

### JSON Escaping

The following characters are escaped when building the `msg` field:

| Character | Escaped as | Notes |
|-----------|-----------|-------|
| `\` (backslash) | `\\` | Must be escaped first |
| `"` (double quote) | `\"` | JSON string delimiter |
| Newline (`\n`, 0x0A) | `\n` | Line breaks |
| Carriage return (`\r`, 0x0D) | `\r` | Windows line endings |
| Tab (`\t`, 0x09) | `\t` | Tab characters |

**Known limitation:** Other control characters (0x00-0x08, 0x0B-0x0C, 0x0E-0x1F) are not escaped. These are extremely unlikely in agent status messages. If needed, a full JSON escaping pass can be added later using `sed` or a helper function.

**Use existing `json_escape_string()` function** (defined at ~line 407 of the `ib` script). Do NOT create a new `json_escape_notify()` — it would be an exact duplicate. Usage:

```bash
escaped_msg=$(json_escape_string "$message")
```

## What Claude Sees

### When notifications arrive

When the background `ib listen` task exits with messages, Claude Code delivers output like:

```
Background task completed: ib listen

Output:
{"ts":"2026-02-17T14:30:05-0600","from":"agent-abc123","type":"complete","msg":"Agent agent-abc123 completed its goal"}
{"ts":"2026-02-17T14:30:07-0600","from":"agent-def456","type":"question","msg":"Agent agent-def456 asks: Should I refactor the auth module?"}
```

Claude should parse each JSONL line and take action based on `type`:

| Type | Claude's action |
|------|----------------|
| `complete` | Run `ib look <from>` and/or `ib diff <from>` to review, then `ib merge <from>` or `ib send <from> "feedback"` |
| `waiting` | Run `ib look <from>` to understand why, then `ib send <from> "instructions"` |
| `question` | Read the `msg`. Run `ib questions` to get the question ID. `ib acknowledge <id>`, then `ib send <from> "answer"` |

After processing ALL notifications, Claude **must** re-spawn the listener:
```
Bash(command: "ib listen", run_in_background: true)
```

### When listener times out (no messages)

After ~9.5 minutes with no messages, the listener exits with a reminder:

```
Background task completed: ib listen

Output:
No messages received. Background listener has stopped. Please restart with: ib listen
```

Claude sees this and re-spawns the listener. This creates a ~10-minute heartbeat cycle that keeps the listener alive indefinitely.

### When listener is dead (liveness check)

If Claude makes a tool call and the listener is not running, the PreToolUse/PostToolUse hook injects:

```
[ib] WARNING: Notification listener is not running. Restart it now:
Bash(command: "ib listen", run_in_background: true)
```

This is injected into Claude's context via `additionalContext` in the hook response, similar to how status injection works.

## New Commands

### `ib listen`

**Purpose:** Poll for notifications, print them when found, exit.

**Usage:** `ib listen [--timeout SECONDS]`

**Default timeout:** 570 seconds (~9.5 minutes). This stays under Claude Code's ~10 minute background task limit while maximizing the listening window.

**Implementation:** `cmd_listen()`

```bash
cmd_listen() {
    local timeout=570    # ~9.5 minutes default

    # ... parse --timeout arg ...

    require_git_repo

    local notify_dir="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify"
    local queue_path="$notify_dir/queue"
    local pid_path="$notify_dir/listener.pid"

    mkdir -p "$notify_dir"

    # Clean up stale drain files from previous crashes (kill -9, machine crash, etc.)
    rm -f "$notify_dir"/queue.drain.* 2>/dev/null || true

    # Guard against multiple simultaneous listeners
    is_listener_alive
    if [[ "$_LISTENER_ALIVE" == "true" ]]; then
        echo "Listener already running (PID $(<"$pid_path")). Exiting." >&2
        exit 0
    fi

    # Register PID for liveness checks
    echo "$$" > "$pid_path"
    # Only remove PID file if it still contains our PID (guards against overwrite by second listener)
    trap 'if [[ -f "$pid_path" ]] && [[ "$(<"$pid_path")" == "$$" ]]; then rm -f "$pid_path"; fi' EXIT

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        # Check for messages
        if [[ -s "$queue_path" ]]; then
            drain_and_print "$notify_dir" "$queue_path"
            exit 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Timeout — print reminder and exit cleanly
    echo "No messages received. Background listener has stopped. Please restart with: ib listen"
    exit 0
}

# Atomic drain: mv queue to temp, print, clean up
drain_and_print() {
    local notify_dir="$1"
    local queue_path="$2"
    local drain_file="$notify_dir/queue.drain.$$"

    # mv is atomic on same filesystem — writers that started before mv
    # complete to the old inode. After mv, new >> creates a fresh file.
    mv "$queue_path" "$drain_file" 2>/dev/null || true

    if [[ -s "$drain_file" ]]; then
        cat "$drain_file"
    fi
    rm -f "$drain_file"
}
```

**Key design decisions:**
- **Polling, not FIFO.** A `sleep 2` loop is dramatically simpler than FIFO management. The 2-second worst-case latency is negligible for Claude's workflow.
- **`mv` for drain is atomic.** No lock needed. Concurrent writers' in-flight `echo >>` either completes to the old inode (included in drain) or creates a new queue file (picked up next cycle).
- **Always exit 0.** Timeout is not an error — it's the expected heartbeat cycle. Claude Code won't report it as a failure.
- **PID file with `trap EXIT`.** Cleaned up on normal exit, signal, or timeout. `is_listener_alive()` validates with `kill -0` and sets `_LISTENER_ALIVE` global (safe under `set -e`).

### `ib notify`

**Purpose:** Send a notification to the primary Claude's listener.

**Usage:** `ib notify [--from ID] [--type TYPE] "message"`

**Implementation:** `cmd_notify()`

```bash
cmd_notify() {
    local from_id="" msg_type="complete" message=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --from requires a value" >&2
                    exit 1
                fi
                from_id="$2"
                shift 2
                ;;
            --type)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --type requires a value" >&2
                    exit 1
                fi
                msg_type="$2"
                shift 2
                ;;
            -h|--help)
                # ... help text ...
                exit 0
                ;;
            -*)
                echo "Error: unknown option: $1" >&2
                exit 1
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

    # Validate type
    case "$msg_type" in
        complete|waiting|question) ;;
        *)
            echo "Error: unknown type: $msg_type (expected: complete, waiting, question)" >&2
            exit 1
            ;;
    esac

    # Auto-detect sender from worktree path (same pattern as cmd_log)
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

    require_git_repo

    local notify_dir="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify"
    local queue_path="$notify_dir/queue"

    mkdir -p "$notify_dir"

    # Build timestamp
    local ts
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Escape ALL fields for JSON (uses existing json_escape_string from ib script)
    local escaped_msg
    escaped_msg=$(json_escape_string "$message")
    local escaped_from
    escaped_from=$(json_escape_string "$from_id")
    local escaped_type
    escaped_type=$(json_escape_string "$msg_type")

    # Build JSON line
    local json_line="{\"ts\":\"$ts\",\"from\":\"$escaped_from\",\"type\":\"$escaped_type\",\"msg\":\"$escaped_msg\"}"

    # Append to queue — atomic for regular files with O_APPEND (POSIX guarantee)
    echo "$json_line" >> "$queue_path"
}
```

**Simplicity:** Just append a line to a file. No background subshells, no signal handling, no lock files. The listener will find it within 2 seconds.

### `is_listener_alive()` helper

**Uses global variable pattern** (`_LISTENER_ALIVE`) instead of return codes to avoid `set -e` landmines. Safe to call anywhere — not just inside `if` blocks.

```bash
is_listener_alive() {
    _LISTENER_ALIVE=false
    local pid_path="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener.pid"

    if [[ -f "$pid_path" ]]; then
        local pid
        pid=$(<"$pid_path")
        if kill -0 "$pid" 2>/dev/null; then
            # Verify it's actually our listener (guards against PID reuse)
            local cmd_check
            cmd_check=$(ps -p "$pid" -o args= 2>/dev/null) || true
            if [[ "$cmd_check" == *"ib listen"* ]]; then
                _LISTENER_ALIVE=true
            else
                # PID was reused by a different process — stale
                rm -f "$pid_path"
            fi
        else
            rm -f "$pid_path"
        fi
    fi
}
```

**Usage pattern:**
```bash
is_listener_alive
if [[ "$_LISTENER_ALIVE" == "true" ]]; then
    # listener is running
fi
```

## Hook Changes

### 1. Stop Hook (`cmd_hooks_agent_status`) — Add `ib notify` calls

**This is the main integration point.** The Stop hook already fires per-idle-cycle for every agent. We add `ib notify` calls alongside the existing `ib send` calls.

| State | Current behavior | New addition |
|-------|-----------------|--------------|
| `complete` (worker) | `ib send $manager "[hook]: completed"` | Add: `ib notify --from "$ID" --type complete "Agent $ID completed (worker of $manager)"` |
| `complete` (root manager, no children) | Log only | Add: `ib notify --from "$ID" --type complete "Manager $ID completed its goal"` |
| `waiting` (worker) | `ib send $manager "[hook]: waiting"` | Add: `ib notify --from "$ID" --type waiting "Agent $ID is waiting for input"` |
| `waiting` (root manager) | Log only | Add: `ib notify --from "$ID" --type waiting "Manager $ID is waiting"` |

**Do NOT notify on:** `running`, `unknown`, `creating`, `compacting`, `rate_limited` — these are transient states that would create noise.

**Implementation:** Add `ib notify` calls **after** the existing `ib send` calls. Existing behavior is unchanged — notifications are layered on top.

```bash
# In the complete+worker branch (after existing ib send):
    if [[ -n "$manager" ]]; then
        log_agent "$ID" "[hook] Notifying manager $manager: just completed"
        ib send "$manager" "[hook]: Your subtask $ID just completed"
        ib notify --from "$ID" --type complete "Agent $ID completed (worker of $manager)" || true  # NEW
    else
        # ... existing unfinished children check ...
        # After the check, if truly complete with no children:
        ib notify --from "$ID" --type complete "Manager $ID completed its goal" || true  # NEW
    fi

# In the waiting branch (after existing ib send):
    if [[ -n "$manager" ]]; then
        log_agent "$ID" "[hook] Notifying manager $manager: now waiting"
        ib send "$manager" "[hook]: Your subtask $ID is now waiting for input"
        ib notify --from "$ID" --type waiting "Agent $ID is waiting for input" || true  # NEW
    else
        log_agent "$ID" "[hook] Waiting with no manager, no action" --quiet
        ib notify --from "$ID" --type waiting "Manager $ID is waiting" || true  # NEW
    fi
```

**Shell-out vs inline:** The `ib notify` calls are kept as separate command invocations (shell-out) rather than inlined into `cmd_hooks_agent_status()`. This keeps the code clear and modular. The Stop hook fires per-agent-idle-cycle (not per-tool-call), so the ~50-100ms overhead of a full `ib` script startup per notification is acceptable. If profiling later shows this is a bottleneck, the notification logic can be inlined as an optimization.

### 2. `cmd_ask()` — Notify when agents ask questions

```bash
# At the end of cmd_ask(), after the question is stored:
    ib notify --from "$AGENT_ID" --type question \
        "Agent $AGENT_ID asks: $QUESTION" || true
```

**Relationship to ib ask / ib questions:** These systems remain distinct and complementary:
- `ib ask` / `ib questions` / `ib acknowledge` = **storage and state management** (persistence, acknowledgment tracking, display in ib watch)
- `ib notify` = **real-time delivery channel** that wakes up the primary Claude immediately
- Claude uses `ib questions` to get the question ID for acknowledgment — the notification itself carries only the human-readable message

### 3. SessionStart Hook (`get_ittybitty_instructions`) — Bootstrap the listener

Add to the `primary` role section of `get_ittybitty_instructions()`:

```markdown
### Real-Time Agent Notifications

When you spawn agents, start a background listener to receive live updates:

    Bash(command: "ib listen", run_in_background: true)

When the listener exits with output, you'll see JSONL notification lines. Each line has:
- `type`: "complete", "waiting", or "question"
- `from`: the agent ID
- `msg`: human-readable description

Process each notification based on type:
- `complete`: Review with `ib look`/`ib diff`, then `ib merge` or `ib send` feedback
- `waiting`: Check with `ib look`, then `ib send` instructions
- `question`: Read the message, run `ib questions` for the ID, `ib acknowledge`, then `ib send` the answer

After processing all notifications:
1. Take action on each notification
2. IMMEDIATELY re-spawn: Bash(command: "ib listen", run_in_background: true)
Do NOT skip step 2. Missing notifications means missing agent completions.

If the listener times out with no messages, just re-spawn it.
```

### 4. PreToolUse/PostToolUse Hooks — Listener Liveness Check

**This is the primary mechanism to keep the listener alive.** On every tool call, the existing status injection hook also checks listener liveness. If the listener is dead and agents are running, inject a reminder.

**Implementation:** Add liveness checking to `cmd_hooks_inject_status()` (the PostToolUse/UserPromptSubmit hook that already runs on every tool call).

```bash
# In cmd_hooks_inject_status(), after building the status context:

# Check listener liveness (only for primary Claude, not agents)
# NOTE: $agent_count is already computed earlier in cmd_hooks_inject_status()
# by the loop that scans agent directories (lines ~13039-13073 of ib script).
# Do NOT call a separate count_active_agents helper — it doesn't exist.
local listener_warning=""
is_listener_alive
if [[ "$_LISTENER_ALIVE" != "true" ]]; then
    # Only warn if there are active agents
    if [[ "$agent_count" -gt 0 ]]; then
        # Use real newlines (not \n in single quotes, which would be literal)
        # json_escape_string() will handle escaping for the JSON output
        listener_warning='

[ib] WARNING: Notification listener is not running. Restart it now:
Bash(command: "ib listen", run_in_background: true)'
    fi
fi

# Append warning to additionalContext if needed
if [[ -n "$listener_warning" ]]; then
    status_content="${status_content}${listener_warning}"
fi
```

**Why this is in the status injection hook (not a separate hook):**
- The status injection hook already runs on every PostToolUse and UserPromptSubmit for the primary Claude
- It already skips agent Claude instances (checks cwd)
- Adding the liveness check here avoids registering a new hook
- `is_listener_alive()` is cheap: one file read + one `kill -0` syscall

**Performance:** `is_listener_alive()` does:
1. Check if `listener.pid` file exists (stat syscall)
2. Read PID from file (read syscall)
3. `kill -0 $pid` (kill syscall)
4. Set `_LISTENER_ALIVE` global (no subprocess, no return code)

This adds ~1ms per tool call. The status injection hook already does much more expensive work (scanning agent directories, computing status). The liveness check is negligible.

**Throttling:** No throttling needed. If the listener is alive, the check returns immediately. If dead, the warning is injected on every tool call until Claude restarts it. This is intentional — persistent reminders ensure Claude doesn't ignore the warning.

## Edge Cases

### Listener not running when notification arrives
Message is appended to queue file. Next `ib listen` finds it within 2 seconds of starting. Liveness check on tool calls reminds Claude to restart the listener. **No message loss.**

### Multiple simultaneous writers
`echo "..." >> file` uses `O_APPEND` mode, which POSIX guarantees will atomically seek-to-end-and-write for regular files. Our notification JSON lines are short (well under 1KB), so multiple agents can call `ib notify` simultaneously without corruption. (Note: this guarantee applies to regular files on local filesystems — NFS does not honor `O_APPEND` atomicity, but `.ittybitty/` is always local.)

### Gap between listener exit and re-spawn
Messages accumulate in queue file. Next listener finds them on first poll iteration (within 2 seconds). Liveness check ensures Claude re-spawns promptly. **No message loss.**

### Drain vs. write race
`mv` is atomic on same filesystem. Any `echo >>` that started before the `mv` completes to the old inode (data is included in drain). After `mv`, new `echo >>` creates a fresh queue file (picked up by next listener). **No data loss, no lock needed.**

**Subtlety:** If a writer opens the file descriptor before `mv` but writes after, the data goes to the old inode (now the drain file). The listener's `cat` will include this data because the write completes before or during the `cat`. This relies on standard POSIX behavior where writes to an open fd are visible to all holders of the same inode.

### Stale PID file
`trap EXIT` removes PID file on normal exit and signal delivery (but only if the file still contains our PID — guards against a second listener that overwrote it). `is_listener_alive()` validates with `kill -0` AND verifies the process name contains `ib listen` (via `ps -p PID -o args=`). This guards against both stale PIDs and PID reuse by unrelated processes.

### Claude session ends
Listener polls until timeout (~9.5 min), then exits cleanly. PID file is stale but harmless — next session's `is_listener_alive()` detects it as dead and the liveness hook prompts Claude to restart.

### Claude ignores liveness warning
The liveness check injects a warning on **every** tool call. Claude cannot ignore it indefinitely — the persistent reminder appears in every tool result until the listener is restarted. This is the most robust liveness mechanism available.

### Stale drain files after crash
If the listener is killed between `mv` and `rm -f` of the drain file (e.g., `kill -9`), a `queue.drain.<PID>` file is left behind. These are cleaned up at the next listener startup (`rm -f "$notify_dir"/queue.drain.*`). The stale drain file may contain already-printed messages, but since the listener that drained them was killed, those messages may not have been delivered to Claude. This is an accepted edge case — `kill -9` is inherently unsafe and messages in the drain file are not recoverable.

### Multiple listeners (shouldn't happen)
`cmd_listen()` checks `is_listener_alive()` at startup and exits if a listener is already running. If two listeners somehow run simultaneously (e.g., race condition between check and PID write), both poll the same queue file. The first one to `mv` gets the messages; the other sees no file and continues polling. The `trap EXIT` only removes the PID file if it still contains the exiting listener's PID, so the surviving listener's PID is preserved.

## Relationship to Existing Systems

| System | Purpose | Notification integration |
|--------|---------|------------------------|
| `ib send` | Agent-to-agent communication via tmux stdin | Unchanged. Used for direct messaging between agents. |
| `ib ask` / `ib questions` / `ib acknowledge` | Question storage, state, and display | Unchanged. `cmd_ask()` additionally calls `ib notify` for immediate wake-up. Claude uses `ib questions` to get IDs. |
| Status injection hooks (PostToolUse) | Inject agent status on each tool call | Extended: also checks listener liveness and injects restart reminder if dead. |
| Stop hook (agent-status) | Nudge idle agents, notify managers | Extended with `ib notify` calls for `complete` and `waiting` states. |
| Watchdog | Background agent monitoring | No changes for v1. Could add `ib notify` for rate_limited later. |

## Scope Boundaries — What NOT to Build

| NOT building | Why |
|-------------|-----|
| FIFO / named pipe | Polling is simpler and the 2s latency is negligible |
| Bidirectional notification channel | One-way: agents → primary. Primary uses `ib send` for the reverse. |
| `question_id` in notifications | Claude uses `ib questions` to get IDs. Less coupling. |
| `stuck` / `error` notification types | Nothing generates them yet. Reserved for future use. |
| Notification persistence/history | Drained messages are gone. Agent logs provide history. |
| Agent-to-agent notifications | Agents use `ib send` (tmux). Notifications are agent → primary only. |
| Watch UI changes | `ib watch` doesn't need changes for v1. Could show listener status later. |
| Message filtering/routing | All messages go to one queue. Claude parses the JSON. |

## Bash 3.2 Compatibility

| Feature | Compatible | Notes |
|---------|-----------|-------|
| `sleep 2` | Yes | POSIX standard |
| `mv` (same filesystem) | Yes | Atomic rename |
| `echo >> file` | Yes | Atomic via O_APPEND on regular files |
| `trap EXIT` | Yes | Standard signal handling |
| `kill -0` | Yes | POSIX process check |
| `${var//pat/rep}` | Yes | Parameter expansion in 3.2 |
| `date +%Y-%m-%dT%H:%M:%S%z` | Yes | macOS date supports this |
| `[[ -s file ]]` | Yes | Check file exists and is non-empty |
| `[[ -f file ]]` | Yes | Check file exists |
| Arithmetic: `$((elapsed + 2))` | Yes | POSIX arithmetic |

**Nothing in this design requires Bash 4.0+.** No `read -t` with fractional seconds, no associative arrays, no process substitution features beyond 3.2.

## `set -e` Safety

```bash
mv "$queue_path" "$drain_file" 2>/dev/null || true  # queue may not exist
kill -0 "$pid" 2>/dev/null                          # used inside if — safe
rm -f "$pid_path"                                   # -f prevents non-zero exit
rm -f "$drain_file"                                 # -f prevents non-zero exit
ib notify ... || true                               # advisory — must not kill hook
```

All `[[ ]] && action` patterns need `|| true` unless inside an `if` block. All commands that may return non-zero outside `if`/`while` need `|| true`.

**`is_listener_alive()` uses global variable pattern** — sets `_LISTENER_ALIVE` instead of using return codes. This is safe to call anywhere, not just inside `if` blocks. Never use `if is_listener_alive` or `! is_listener_alive` — always check `$_LISTENER_ALIVE` after calling.

**Specific patterns in the listener loop:**
```bash
# sleep in loop — always succeeds
sleep 2

# [[ -s ]] in while condition — safe (inside while test)
while [[ $elapsed -lt $timeout ]]; do

# [[ -s ]] in if condition — safe (inside if test)
if [[ -s "$queue_path" ]]; then
```

## Test Fixtures

### `tests/test-notify.sh` — Notification format and drain tests

**Fixture-based tests for `ib test-notify-format`:**

| Fixture | Expected | Tests |
|---------|----------|-------|
| `tests/fixtures/notify/format-basic.json` | valid JSON with all fields | Basic message formatting |
| `tests/fixtures/notify/format-quotes.json` | properly escaped `\"` | Message with double quotes |
| `tests/fixtures/notify/format-newlines.json` | properly escaped `\n` | Message with newlines |
| `tests/fixtures/notify/format-tabs.json` | properly escaped `\t` | Message with tab characters |
| `tests/fixtures/notify/format-cr.json` | properly escaped `\r` | Message with carriage returns |
| `tests/fixtures/notify/format-backslash.json` | properly escaped `\\` | Message with backslashes |

Each fixture contains input fields (`from`, `type`, `msg`) and the test verifies the output is valid JSONL with correct escaping.

**Fixture-based tests for `ib test-notify-drain`:**

| Fixture | Expected | Tests |
|---------|----------|-------|
| `tests/fixtures/notify/drain-single.jsonl` | 1 line output | Single message drain |
| `tests/fixtures/notify/drain-multiple.jsonl` | 3 lines output | Multiple messages, order preserved |
| `tests/fixtures/notify/drain-empty.jsonl` | empty output | Empty/missing queue returns nothing |

**Integration test in `tests/test-notify.sh`:**
```bash
# Clean up temp file on exit (even if test is killed)
trap 'rm -f /tmp/listen-output.$$' EXIT

# Spawn listener in background with short timeout
ib listen --timeout 5 > /tmp/listen-output.$$ 2>&1 &
listener_pid=$!
sleep 1

# Send notification
ib notify --from test-agent --type complete "Test message"

# Wait for listener to exit (should find message within 2s)
wait "$listener_pid" || true

# Verify output contains the message
if grep -q "Test message" /tmp/listen-output.$$; then
    echo "PASS: integration"
else
    echo "FAIL: integration"
fi
```

### Test commands to add to `ib`

| Command | Function | Purpose |
|---------|----------|---------|
| `ib test-notify-format FILE` | `cmd_test_notify_format` | Test JSON line formatting from fixture input |
| `ib test-notify-drain FILE` | `cmd_test_notify_drain` | Test queue drain given a fixture queue file |

## Implementation Order

### Phase 1: Core Commands (standalone, testable)

1. **`cmd_notify()`** — Write side
   - Argument parsing (--from, --type, positional message) with `shift 2` guards
   - Type validation (only `complete`, `waiting`, `question`)
   - Auto-detect sender from worktree
   - JSON line formatting — escape ALL fields with `json_escape_string()`
   - Atomic append to queue file
   - Add to dispatcher: `notify) shift; cmd_notify "$@" ;;`

2. **`is_listener_alive()`** — Liveness helper
   - PID file + `kill -0` check + process name verification (`ps -p PID -o args=`)
   - Sets `_LISTENER_ALIVE` global variable (safe under `set -e`)

3. **`cmd_listen()`** + `drain_and_print()` — Read side
   - Guard against multiple simultaneous listeners via `is_listener_alive()`
   - PID management with trap EXIT
   - 2-second polling loop with timeout (`sleep 2` directly, no variable)
   - Atomic drain with `mv`
   - Timeout message on expiry
   - Add to dispatcher: `listen) shift; cmd_listen "$@" ;;`

4. **Manual testing** — Verify in two terminal windows:
   - Terminal 1: `ib listen --timeout 30`
   - Terminal 2: `ib notify "hello world"`
   - Verify Terminal 1 prints the message and exits within ~2 seconds

### Phase 2: Hook Integration

5. **Modify `cmd_hooks_agent_status()`** — Add `ib notify` for `complete` and `waiting`
6. **Modify `cmd_ask()`** — Add `ib notify --type question` after storing question
7. **Modify `cmd_hooks_inject_status()`** — Add listener liveness check + warning injection
8. **Modify `get_ittybitty_instructions()`** — Add listener bootstrap for `primary` role

### Phase 3: Tests

9. **Add `cmd_test_notify_format()`** and fixtures
10. **Add `cmd_test_notify_drain()`** and fixtures
11. **Add `tests/test-notify.sh`** with fixture tests + integration test
12. **Add to `tests/test-all.sh`**

### Phase 4: Cleanup

13. **Add cleanup to `cmd_nuke()`** — Kill listener, remove notify directory:
    ```bash
    local listener_pid_file="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener.pid"
    if [[ -f "$listener_pid_file" ]]; then
        local lpid
        lpid=$(<"$listener_pid_file")
        kill "$lpid" 2>/dev/null || true
        rm -f "$listener_pid_file"
    fi
    rm -rf "$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify"
    ```
14. **Add to help text** — `ib --help`, `ib listen --help`, `ib notify --help`
15. **Update CLAUDE.md** — Document the notification system
16. **Update README.md** — User-facing documentation

## Design Rationale — Why Polling + Queue

| Approach | Latency | CPU | Complexity | Chosen |
|----------|---------|-----|------------|--------|
| Polling (sleep 2) + queue | ~2s worst case | ~0.5% (sleep is cheap) | **Low** | **Yes** |
| FIFO + queue | Instant | Zero when idle | Medium (FIFO lifecycle, non-blocking writes, drain races) | No |
| FIFO only (no queue) | Instant | Zero when idle | Medium+ (message loss across restarts) | No |

**Polling wins on simplicity.** The 2-second latency is negligible for Claude's workflow — Claude needs seconds to minutes to process notifications, review diffs, and make decisions. The queue file provides:
- Durability across listener restarts (no message loss)
- Batching of multiple simultaneous notifications
- Simple debugging (just `cat .ittybitty/notify/queue`)
- No FIFO lifecycle management, no non-blocking write complexity, no drain race conditions
