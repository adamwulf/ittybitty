# Real-Time Notification System — Implementation Plan

## Overview

Enable running ib agents to push real-time notifications to the primary Claude session (the one the user talks to) without polling. When an agent completes, starts waiting, or asks a question, the primary Claude wakes up automatically and can react.

**Core mechanism:** The primary Claude spawns `ib listen` as a background bash task. It blocks on a FIFO. When an agent (or hook) calls `ib notify`, the message is appended to a queue file and the FIFO is signaled. The listener wakes, drains the queue, prints messages to stdout, and exits. Claude Code's built-in background task completion notification delivers the output to the primary Claude, who processes it and re-spawns the listener.

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│  Primary Claude (user's terminal, NOT in tmux)              │
│                                                             │
│  1. Bash(command:"ib listen --timeout 300",                 │
│         run_in_background: true)                            │
│                                                             │
│  4. Claude Code notifies: "Background task completed"       │
│     → Claude reads output (JSONL lines)                     │
│     → Takes action (ib merge, ib send, ib look, etc.)       │
│     → Re-spawns: ib listen                                  │
└──────────┬──────────────────────────────────────────────────┘
           │ spawns background bash
           ▼
┌──────────────────────────────────────────────┐
│  ib listen (background bash process)         │
│                                              │
│  - Writes PID to .ittybitty/notify/pid       │
│  - Checks queue for pre-existing messages    │
│  - If empty: blocks on read <> FIFO          │
│  - On wake: mv queue → drain (atomic)        │
│  - Prints drained messages to stdout         │
│  - Exits (triggers Claude Code notification) │
└──────────────────────────────────────────────┘
           ▲
           │ signals FIFO + appends to queue
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

**Why this works:** The primary Claude is NOT in a tmux session — it runs in the user's terminal directly. The only reliable way to "wake" it is via Claude Code's background task completion notification. The listener is a blocking bash process that exits when messages arrive, which triggers that notification.

## File Paths

All notification files are scoped by REPO_ID to prevent collisions when multiple repos use ib on the same machine.

```
.ittybitty/
├── notify/
│   ├── signal-${REPO_ID}       # Named pipe (FIFO) — wake-up signal
│   ├── queue-${REPO_ID}        # JSONL message queue — source of truth
│   └── listener-${REPO_ID}.pid # PID of current ib listen process
└── ...
```

`REPO_ID` is obtained via `get_repo_id()` (the existing 8-char hex ID stored in `.ittybitty/repo-id`).

## Queue Message Format

Each line in the queue file is a self-contained JSON object (JSONL):

```jsonl
{"ts":"2026-02-17T14:30:05-0600","from":"agent-abc123","type":"complete","msg":"Agent agent-abc123 completed its goal"}
{"ts":"2026-02-17T14:30:07-0600","from":"agent-def456","type":"question","msg":"Agent agent-def456 asks: Should I refactor the auth module?","question_id":"q-1740000607-a1b2c3"}
```

| Field | Type | Description |
|-------|------|-------------|
| `ts` | string | ISO 8601 timestamp (`date +%Y-%m-%dT%H:%M:%S%z`) |
| `from` | string | Agent ID of sender, or `"system"` |
| `type` | string | One of: `complete`, `waiting`, `question`, `stuck`, `error` |
| `msg` | string | Human-readable message text |
| `question_id` | string | (optional) Present when `type=question` — the ib ask question ID for acknowledgment |

## What Claude Sees

When the background `ib listen` task exits with output, Claude Code delivers a notification like:

```
Background task completed: ib listen --timeout 300

Output:
{"ts":"2026-02-17T14:30:05-0600","from":"agent-abc123","type":"complete","msg":"Agent agent-abc123 completed its goal"}
{"ts":"2026-02-17T14:30:07-0600","from":"agent-def456","type":"question","msg":"Agent agent-def456 asks: Should I refactor the auth module?","question_id":"q-1740000607-a1b2c3"}
```

Claude should parse each JSONL line and take action based on `type`:

| Type | Claude's action |
|------|----------------|
| `complete` | Run `ib look <id>` and/or `ib diff <id>` to review, then `ib merge <id>` or `ib send <id> "feedback"` |
| `waiting` | Run `ib look <id>` to understand why, then `ib send <id> "instructions"` |
| `question` | Read the `msg`, decide on an answer, `ib acknowledge <question_id>`, then `ib send <from> "answer"` |
| `stuck` | Investigate and provide guidance via `ib send` |
| `error` | Investigate the error, potentially `ib kill` and re-spawn |

After processing, Claude re-spawns the listener:
```
Bash(command: "ib listen --timeout 300", run_in_background: true)
```

If the listener times out with no messages, Claude just re-spawns it (no action needed).

## New Commands

### `ib listen`

**Purpose:** Block until notification(s) arrive, print them, exit.

**Usage:** `ib listen [--timeout SECONDS]`

**Implementation:** `cmd_listen()`

```bash
cmd_listen() {
    local timeout=""
    # ... parse --timeout arg ...

    require_git_repo

    local repo_id
    repo_id=$(get_repo_id)

    local notify_dir="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify"
    local fifo_path="$notify_dir/signal-${repo_id}"
    local queue_path="$notify_dir/queue-${repo_id}"
    local pid_path="$notify_dir/listener-${repo_id}.pid"

    mkdir -p "$notify_dir"

    # Create FIFO if needed
    if [[ ! -p "$fifo_path" ]]; then
        mkfifo "$fifo_path"
    fi

    # Register PID for liveness checks
    echo $$ > "$pid_path"
    trap 'rm -f "$pid_path"' EXIT

    # Step 1: Check for pre-existing messages (sent while no listener was running)
    if [[ -s "$queue_path" ]]; then
        # Messages waiting — drain immediately, don't block
        drain_and_print "$notify_dir" "$queue_path" "$fifo_path"
        exit 0
    fi

    # Step 2: Block on FIFO using read-write mode (<>) to prevent EOF
    if [[ -n "$timeout" ]]; then
        read -t "$timeout" _signal <> "$fifo_path" || true
    else
        read _signal <> "$fifo_path" || true
    fi

    # Step 3: Drain queue after wakeup
    if [[ -s "$queue_path" ]]; then
        drain_and_print "$notify_dir" "$queue_path" "$fifo_path"
        exit 0
    fi

    # Timeout or spurious wakeup with no messages
    exit 0
}

# Atomic drain: mv queue to temp, print, clean up
# Uses mv (atomic rename) so concurrent writers create a new queue file
drain_and_print() {
    local notify_dir="$1"
    local queue_path="$2"
    local fifo_path="$3"
    local drain_file="$notify_dir/queue.drain.$$"

    # mv is atomic on same filesystem — writers that started before mv
    # complete to the old inode. After mv, new >> creates a fresh file.
    mv "$queue_path" "$drain_file" 2>/dev/null || true

    if [[ -f "$drain_file" && -s "$drain_file" ]]; then
        cat "$drain_file"
        rm -f "$drain_file"
    fi

    # Clean up FIFO so next listener starts fresh
    rm -f "$fifo_path"
}
```

**Key design decisions:**
- `<>` (read-write) mode prevents FIFO EOF when no writers are connected
- `mv` for drain is atomic — no lock needed, no race with concurrent writers
- FIFO is deleted after drain so next listener creates it fresh (no stale pipe data)
- `read -t` only accepts integers on Bash 3.2 — document this

**Exit behavior:**
- Exit 0 always (messages delivered or timeout)
- Output: JSONL lines on stdout if messages existed, empty stdout on timeout

### `ib notify`

**Purpose:** Send a notification to the primary Claude's listener.

**Usage:** `ib notify [--from ID] [--type TYPE] "message"` or `ib notify [--question-id QID] "message"`

**Implementation:** `cmd_notify()`

```bash
cmd_notify() {
    local from_id="" msg_type="status" message="" question_id=""
    # ... parse args (--from, --type, --question-id, positional message) ...

    # Auto-detect sender from worktree path (same pattern as cmd_log)
    if [[ -z "$from_id" ]]; then
        # ... extract agent ID from cwd if in agent worktree ...
    fi

    require_git_repo

    local repo_id
    repo_id=$(get_repo_id)

    local notify_dir="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify"
    local queue_path="$notify_dir/queue-${repo_id}"
    local fifo_path="$notify_dir/signal-${repo_id}"

    mkdir -p "$notify_dir"

    # Build timestamp
    local ts
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Escape message for JSON
    local escaped_msg="${message//\\/\\\\}"
    escaped_msg="${escaped_msg//\"/\\\"}"
    escaped_msg="${escaped_msg//$'\n'/\\n}"

    # Build JSON line
    local json_line="{\"ts\":\"$ts\",\"from\":\"$from_id\",\"type\":\"$msg_type\",\"msg\":\"$escaped_msg\""
    if [[ -n "$question_id" ]]; then
        json_line="$json_line,\"question_id\":\"$question_id\""
    fi
    json_line="$json_line}"

    # Append to queue (>> is atomic for lines < PIPE_BUF = 512 bytes on macOS)
    echo "$json_line" >> "$queue_path"

    # Signal FIFO (non-blocking with 1s timeout)
    if [[ -p "$fifo_path" ]]; then
        ( echo "" > "$fifo_path" ) &
        local writer_pid=$!
        ( sleep 1 && kill "$writer_pid" 2>/dev/null ) &
        local killer_pid=$!
        wait "$writer_pid" 2>/dev/null || true
        kill "$killer_pid" 2>/dev/null || true
        wait "$killer_pid" 2>/dev/null || true
    fi
}
```

**Non-blocking FIFO write:** The background+kill pattern guarantees the writer never blocks for more than 1 second. If no listener is running, the message sits in the queue file and will be picked up when the next listener starts (it checks for pre-existing messages before blocking on the FIFO).

### `is_listener_alive()` helper

```bash
is_listener_alive() {
    local repo_id
    repo_id=$(get_repo_id)
    local pid_path="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener-${repo_id}.pid"

    if [[ -f "$pid_path" ]]; then
        local pid
        pid=$(<"$pid_path")
        if kill -0 "$pid" 2>/dev/null; then
            return 0  # alive
        fi
        rm -f "$pid_path"
    fi
    return 1  # not alive
}
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

**Do NOT notify on:** `running`, `unknown`, `creating`, `compacting`, `rate_limited` — these are transient states. Adding notifications for them would create noise and potentially overwhelm the listener with spurious wakeups.

**Implementation:** Add `ib notify` calls after the existing `ib send` calls in `cmd_hooks_agent_status()`. The existing behavior is unchanged — notifications are layered on top.

```bash
# In the complete+worker branch (after existing ib send):
    if [[ -n "$manager" ]]; then
        log_agent "$ID" "[hook] Notifying manager $manager: just completed"
        ib send "$manager" "[hook]: Your subtask $ID just completed"
        ib notify --from "$ID" --type complete "Agent $ID completed (worker of $manager)"  # NEW
    else
        # ... existing unfinished children check ...
        # After the check, if truly complete with no children:
        ib notify --from "$ID" --type complete "Manager $ID completed its goal"  # NEW
    fi

# In the waiting branch (after existing ib send):
    if [[ -n "$manager" ]]; then
        log_agent "$ID" "[hook] Notifying manager $manager: now waiting"
        ib send "$manager" "[hook]: Your subtask $ID is now waiting for input"
        ib notify --from "$ID" --type waiting "Agent $ID is waiting for input"  # NEW
    else
        log_agent "$ID" "[hook] Waiting with no manager, no action" --quiet
        ib notify --from "$ID" --type waiting "Manager $ID is waiting"  # NEW
    fi
```

### 2. `cmd_ask()` — Notify when agents ask questions

The existing `ib ask` system stores questions in `user-questions.json` and injects them via hooks. The notification system adds *immediacy* — instead of waiting for the next status injection hook to fire, the primary Claude gets woken up right away.

```bash
# At the end of cmd_ask(), after the question is stored:
    ib notify --from "$AGENT_ID" --type question \
        --question-id "$question_id" \
        "Agent $AGENT_ID asks: $QUESTION"
```

**Relationship to ib ask / ib questions:** These systems remain distinct and complementary:
- `ib ask` / `ib questions` / `ib acknowledge` = **storage and state management** for questions (persistence, acknowledgment tracking, display in ib watch)
- `ib notify` = **real-time delivery channel** that wakes up the primary Claude immediately
- The notification includes `question_id` so Claude can acknowledge without having to look it up

### 3. SessionStart Hook (`get_ittybitty_instructions`) — Bootstrap the listener

Add to the `primary` role section of `get_ittybitty_instructions()`:

```markdown
### Real-Time Agent Notifications

When you spawn agents, start a background listener to receive live updates:

    Bash(command: "ib listen --timeout 300", run_in_background: true)

When the listener exits with output, you'll see JSONL notification lines. Each line has:
- `type`: "complete", "waiting", "question", "stuck", or "error"
- `from`: the agent ID
- `msg`: human-readable description
- `question_id`: (only for type=question) use with `ib acknowledge`

Process each notification, then re-spawn the listener. If it times out with no output,
just re-spawn it. Keep exactly one listener running while agents are active.
```

This is injected once at session start. **No per-tool-call overhead.**

### 4. No PreToolUse/PostToolUse Changes

**Minimizing hook surface area:** We do NOT add liveness checking to PreToolUse or PostToolUse hooks. These fire on every single tool call and adding checks there would:
- Slow down every tool call
- Add complexity for marginal benefit
- The SessionStart instruction is sufficient to get Claude to spawn the listener

If the listener dies and Claude forgets to re-spawn it, the status injection hook (already installed) will still show agent status on each tool call. The notification system is an *enhancement* for immediacy, not a replacement for the existing polling-based status injection.

## Edge Cases

### Listener not running when notification arrives
Message is appended to queue file. FIFO write times out after 1s (harmless). Next `ib listen` checks queue first before blocking — picks up all accumulated messages immediately. **No message loss.**

### Multiple simultaneous writers
`echo "..." >> file` is atomic for writes smaller than PIPE_BUF (512 bytes on macOS). Our JSON lines are well under this. Both writers signal the FIFO — listener wakes on the first signal and drains all messages.

### Gap between listener exit and re-spawn
Messages accumulate in queue file. Next listener drains them immediately before blocking. **No message loss.**

### Drain vs. write race
`mv` is atomic on same filesystem. Any `echo >>` that started before the `mv` completes to the old inode. After `mv`, new `echo >>` creates a fresh queue file. No data loss, no lock needed.

### FIFO deleted between sessions
`ib listen` creates the FIFO if missing. `ib notify` checks `[[ -p "$fifo_path" ]]` before writing — if missing, silently skips the FIFO write (message is already queued).

### Stale PID file
`trap EXIT` removes PID file on normal exit. `is_listener_alive()` checks `kill -0` before trusting it. New `ib listen` overwrites stale PID.

### Claude session ends
Listener blocks until timeout (max 300s), then exits cleanly. PID file is stale but harmless — next session's listener overwrites it.

### Multiple repos on same machine
All paths include `${REPO_ID}` — different repos have different FIFO, queue, and PID files. No collision.

### `read -t` on Bash 3.2
Only accepts integer seconds. The `--timeout` value must be an integer. Document this in help text.

### FIFO writer blocks when no reader
The background+kill pattern ensures max 1s block. The `echo > fifo` runs in a subshell. If no reader, the subshell is killed after 1s. The message is already in the queue — nothing lost.

## Relationship to Existing Systems

| System | Purpose | Notification integration |
|--------|---------|------------------------|
| `ib send` | Agent-to-agent communication via tmux stdin | Unchanged. Used for direct messaging between agents. |
| `ib ask` / `ib questions` / `ib acknowledge` | Question storage, state, and display | Unchanged. `cmd_ask()` additionally calls `ib notify` so primary Claude wakes up immediately. |
| Status injection hooks (PostToolUse) | Inject agent status on each tool call | Unchanged. Provides fallback visibility even without listener. |
| Stop hook (agent-status) | Nudge idle agents, notify managers | Extended with `ib notify` calls for `complete` and `waiting` states. |
| Watchdog | Background agent monitoring | No changes for v1. Could add `ib notify` for rate_limited later. |

## Scope Boundaries — What NOT to Build

| NOT building | Why |
|-------------|-----|
| Bidirectional notification channel | Notifications are one-way: agents → primary. Primary uses `ib send` for the reverse. |
| Per-PreToolUse liveness checking | Too expensive. SessionStart bootstrap + status injection fallback is sufficient. |
| Notification persistence/history | Drained messages are gone. Agent logs provide history. |
| Agent-to-agent notifications | Agents use `ib send` (tmux). Notifications are agent → primary only. |
| Watch UI changes | `ib watch` doesn't need changes for v1. Could show listener status icon later. |
| Message filtering/routing | All messages go to one queue. Claude parses the JSON. |
| Retry/backoff on delivery failure | Messages queue up; next listener drains them. |

## Bash 3.2 Compatibility

| Feature | Compatible | Notes |
|---------|-----------|-------|
| `mkfifo` | Yes | POSIX standard |
| `read <> fifo` | Yes | POSIX read-write redirection |
| `read -t N` | Yes (integers only) | No fractional seconds |
| `mv` (same filesystem) | Yes | Atomic rename |
| `echo >> file` | Yes | Atomic for < PIPE_BUF |
| `trap EXIT` | Yes | Standard signal handling |
| `$!` (last background PID) | Yes | POSIX |
| `kill -0` | Yes | POSIX process check |
| `${var//pat/rep}` | Yes | Parameter expansion in 3.2 |
| `date +%Y-%m-%dT%H:%M:%S%z` | Yes | macOS date supports this |

## `set -e` Safety

```bash
read _signal <> "$fifo_path" || true        # may timeout or signal
mv "$queue_path" "$drain_file" 2>/dev/null || true  # queue may not exist
wait "$writer_pid" 2>/dev/null || true      # process may have exited
kill "$killer_pid" 2>/dev/null || true      # process may have exited
wait "$killer_pid" 2>/dev/null || true      # process may have exited
```

All `[[ ]] &&` patterns need `|| true`. All commands that may return non-zero outside `if`/`while` need `|| true`.

## Test Fixtures

### `tests/test-notify.sh` — Notification format and drain tests

**Fixture-based tests for `ib test-notify-format`:**

| Fixture | Expected | Tests |
|---------|----------|-------|
| `tests/fixtures/notify/format-basic.json` | valid JSON with all fields | Basic message formatting |
| `tests/fixtures/notify/format-quotes.json` | properly escaped `\"` | Message with double quotes |
| `tests/fixtures/notify/format-newlines.json` | properly escaped `\n` | Message with newlines |
| `tests/fixtures/notify/format-question.json` | includes `question_id` field | Question notification with ID |

Each fixture contains input fields (`from`, `type`, `msg`) and the test verifies the output is valid JSONL.

**Fixture-based tests for `ib test-notify-drain`:**

| Fixture | Expected | Tests |
|---------|----------|-------|
| `tests/fixtures/notify/drain-single.jsonl` | 1 line output | Single message drain |
| `tests/fixtures/notify/drain-multiple.jsonl` | 3 lines output | Multiple messages drain, order preserved |
| `tests/fixtures/notify/drain-empty.jsonl` | empty output | Empty queue returns nothing |

**Integration test in `tests/test-notify.sh`:**
```bash
# Spawn listener in background with short timeout
ib listen --timeout 3 > /tmp/listen-output.$$ &
listener_pid=$!
sleep 0.5

# Send notification
ib notify --from test-agent --type complete "Test message"

# Wait for listener to exit
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
   - JSON formatting with escaping
   - Atomic append to queue file
   - Non-blocking FIFO signal
   - Add to dispatcher: `notify) shift; cmd_notify "$@" ;;`

2. **`cmd_listen()`** + `drain_and_print()` — Read side
   - FIFO creation
   - PID management with trap
   - Pre-drain check → FIFO block → drain
   - Atomic drain with `mv`
   - Add to dispatcher: `listen) shift; cmd_listen "$@" ;;`

3. **`is_listener_alive()`** — Helper
   - PID file + `kill -0` check

4. **Manual testing** — Verify in two terminal windows:
   - Terminal 1: `ib listen --timeout 30`
   - Terminal 2: `ib notify "hello world"`
   - Verify Terminal 1 prints the message and exits

### Phase 2: Hook Integration

5. **Modify `cmd_hooks_agent_status()`** — Add `ib notify` for `complete` and `waiting`
6. **Modify `cmd_ask()`** — Add `ib notify --type question` after storing question
7. **Modify `get_ittybitty_instructions()`** — Add listener bootstrap for `primary` role

### Phase 3: Tests

8. **Add `cmd_test_notify_format()`** and fixtures
9. **Add `cmd_test_notify_drain()`** and fixtures
10. **Add `tests/test-notify.sh`** with fixture tests + integration test
11. **Add to `tests/test-all.sh`**

### Phase 4: Cleanup

12. **Add cleanup to `cmd_nuke()`** — Remove notify dir, kill listener
13. **Add to help text** — `ib --help`, `ib listen --help`, `ib notify --help`
14. **Update CLAUDE.md** — Document the notification system
15. **Update README.md** — User-facing documentation

## Design Rationale — Why FIFO + Queue, Not Just Polling

| Approach | Latency | CPU | Complexity |
|----------|---------|-----|------------|
| Polling (sleep loop) | 0.5-1s | Constant (even idle) | Low |
| FIFO only | Instant | Zero when idle | Medium (FIFO edge cases) |
| **FIFO + Queue** | **Instant** | **Zero when idle** | **Medium** |

The FIFO provides instant wakeup with zero CPU cost while waiting. The queue file provides:
- Durability across listener restarts (no message loss)
- Batching of multiple simultaneous notifications
- Simple debugging (just `cat` the queue file)

The queue file is the source of truth; the FIFO is just a doorbell.
