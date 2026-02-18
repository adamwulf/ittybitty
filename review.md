# Notification System Plan — Critical Review

## Executive Summary

The plan is well-structured and the core FIFO+queue mechanism is sound. The design correctly identifies that Claude Code's background task completion is the only reliable wake-up mechanism for the primary Claude. However, the plan has several concrete issues: inconsistencies between `notification-plan.md` and `plan-a.md` that need reconciliation, a FIFO deletion race condition in the drain procedure, unnecessary complexity in the non-blocking write that will slow down the Stop hook, and an under-specified listener liveness story that could leave the primary Claude deaf for an entire session.

## Critical Issues (must fix before implementing)

### 1. FIFO deletion in `drain_and_print()` creates a race condition

In `notification-plan.md` lines 191-192, the drain function deletes the FIFO after draining:

```bash
# Clean up FIFO so next listener starts fresh
rm -f "$fifo_path"
```

This creates a race window:
1. Listener drains queue, deletes FIFO, is about to exit
2. A new `ib notify` fires, sees no FIFO (`[[ -p ]]` fails), skips the signal
3. New `ib listen` starts, creates FIFO, blocks on it
4. The message from step 2 is in the queue but the new listener is already blocking on the FIFO — nobody signals it

The message IS in the queue, and the **next** notification will wake the listener. But if only one notification arrives during this window, the listener sits idle until timeout despite having a message waiting.

**Fix:** Don't delete the FIFO. There's no "stale pipe data" problem because the FIFO is just a doorbell — any leftover bytes in it just cause an immediate (harmless) wake-up. If you're worried about stale data, just drain the FIFO with a non-blocking read after creating the listener, before checking the queue.

### 2. `plan-a.md` and `notification-plan.md` contradict each other on drain approach

- `plan-a.md` uses `mkdir` lock + `cp` + truncate (lines 109-114), then later self-corrects to `mv` (lines 517-523)
- `notification-plan.md` uses `mv` without any lock (lines 175-192)

The `mv` approach in `notification-plan.md` is correct and simpler. But the plan-a.md self-contradiction suggests the drain race condition wasn't fully thought through.

**Concern with `mv` approach:** After `mv`, a concurrent `echo >> queue_path` creates a new file. But between the `mv` and the new `echo >>`, is there a window where a writer's `>>` could fail? No — `>>` creates the file if it doesn't exist. This is fine.

**However**, there's a subtlety: if a writer opens the file (gets a file descriptor to the old inode) before `mv`, then writes after `mv`, the data goes to the old inode (now the drain file). The listener has already `mv`'d it and is about to `cat` it — will it see the late write? Probably yes on macOS (writes are visible to all fd holders of the same inode), but this is an implicit assumption worth documenting.

### 3. The non-blocking FIFO write spawns 2 subprocesses per notification

The background+kill pattern in `cmd_notify()`:

```bash
( echo "" > "$fifo_path" ) &
local writer_pid=$!
( sleep 1 && kill "$writer_pid" 2>/dev/null ) &
local killer_pid=$!
wait "$writer_pid" 2>/dev/null || true
kill "$killer_pid" 2>/dev/null || true
wait "$killer_pid" 2>/dev/null || true
```

This spawns 2 subshells and calls `wait` + `kill` for every single notification. The Stop hook fires per-agent-idle-cycle, so this runs frequently. Each invocation of `ib notify` is already a full `ib` script startup (parsing the entire 2500-line script), plus 2 background subshells.

**Simpler alternative:** Use timeout directly:

```bash
if [[ -p "$fifo_path" ]]; then
    # Bash 3.2: use a simple background write with disown
    ( echo "" > "$fifo_path" ) &
    disown
fi
```

If no listener is reading, the background subshell hangs on the open() call until a listener starts or the subshell is reaped. With `disown`, the calling process doesn't wait. The orphaned subshell is harmless — it'll either deliver its signal when a listener starts, or be reaped when the shell exits.

This is one subprocess instead of two, and the caller doesn't block at all.

**Alternative alternative:** Since `ib notify` exits immediately after the FIFO write attempt, the subshell will be killed when the parent exits anyway. So even `( echo "" > "$fifo_path" ) &` without the killer is fine — the process will be cleaned up on parent exit or deliver its signal, whichever comes first.

### 4. No `REPO_ID` scoping in `plan-a.md`, inconsistent with `notification-plan.md`

- `notification-plan.md` uses `signal-${REPO_ID}`, `queue-${REPO_ID}`, `listener-${REPO_ID}.pid`
- `plan-a.md` uses `signal`, `queue`, `listener.pid` (no REPO_ID)

Since the notify directory is inside `.ittybitty/` which is already repo-specific, REPO_ID scoping in the filenames is redundant. A single machine won't have two different repos sharing the same `.ittybitty/` directory.

**Recommendation:** Drop the REPO_ID from filenames. It's unnecessary complexity. The files are already scoped by being inside `.ittybitty/notify/`.

## Concerns (should address but not blockers)

### 5. Listener liveness is insufficiently guaranteed

The plan relies on:
1. SessionStart hook instruction telling Claude to spawn `ib listen`
2. Status injection fallback (PostToolUse hook) as safety net

**Problem:** If Claude doesn't follow the SessionStart instruction (it's just a suggestion in the `<ittybitty>` block, not a forced action), the listener never starts. Claude is an LLM — it can forget, get distracted, or decide not to follow the instruction.

The status injection hook provides _visibility_ but not _immediacy_. The whole point of this system is instant wake-up. If the listener is dead, you're back to polling-era latency.

**Mitigation options (pick one):**
- Add a check in the Stop hook: if `is_listener_alive()` returns false, log a warning. This doesn't fix the problem but makes it visible in agent logs.
- Add a line to the status injection (PostToolUse) output that says "WARNING: no notification listener running. Run: `ib listen --timeout 300` in background." This is lightweight and reminds Claude every tool call.
- Accept the limitation for v1 and document it clearly.

### 6. `exit 0` on timeout vs `exit 1` — inconsistency and Claude Code behavior

`notification-plan.md` exits 0 on timeout (line 170). `plan-a.md` exits 1 on timeout (line 216).

More importantly: **how does Claude Code report background task completion?** Does it distinguish between exit 0 and exit 1? If Claude Code says "Background task failed" for exit 1, Claude might treat a timeout as an error rather than a no-op.

**Recommendation:** Always exit 0. A timeout with no messages is not an error — it's normal operation. Print nothing on timeout. Claude sees empty output and re-spawns.

### 7. The `question_id` field adds coupling without clear benefit

The notification plan includes `question_id` in the JSONL so Claude can call `ib acknowledge` directly. But Claude already needs to `ib send` the answer to the agent, and the `ib questions` command shows pending questions with their IDs. The notification `msg` field already includes the question text.

Is `question_id` in the notification really necessary? Claude can:
1. See the question in the notification `msg`
2. Run `ib questions` to get the `question_id` if needed
3. Call `ib acknowledge` + `ib send`

The `question_id` saves one `ib questions` call. That's minimal value for extra complexity in the JSONL format. Consider dropping it for v1.

### 8. JSON escaping is incomplete

The escaping in `cmd_notify()`:
```bash
local escaped_msg="${message//\\/\\\\}"
escaped_msg="${escaped_msg//\"/\\\"}"
escaped_msg="${escaped_msg//$'\n'/\\n}"
```

This misses:
- Tab characters (`$'\t'`) — should be `\\t`
- Carriage returns (`$'\r'`) — should be `\\r`
- Control characters (bytes 0x00-0x1F)
- Backspace, form feed, etc.

For agent status messages, these are unlikely but possible (e.g., a question containing a tab). For v1 this is probably fine, but it should be documented as a known limitation.

### 9. `cat "$drain_file"` in the drain function spawns a subprocess

Line 187 in `notification-plan.md`:
```bash
cat "$drain_file"
```

This could use `printf '%s\n' "$(<"$drain_file")"` or just `echo "$(<"$drain_file")"` to avoid the subprocess. Since this isn't in the render hot path (it's in the listener, which runs once per batch), this is low priority. But it's worth noting for consistency with the codebase conventions.

### 10. Stop hook adds latency to every agent idle transition

Every `ib notify` call in the Stop hook means: full `ib` script startup + parse args + `require_git_repo` + `get_repo_id` + `mkdir -p` + `date` + JSON formatting + `echo >>` + FIFO signal attempt. This adds ~50-100ms to the Stop hook per notification.

The Stop hook already does significant work (state detection, tmux capture, debug logging). Adding `ib notify` doubles the external command invocations. This isn't a correctness issue, but it could slow down agent state transitions noticeably.

**Mitigation:** Instead of calling `ib notify` as a separate command, inline the notification logic into `cmd_hooks_agent_status()`. This avoids the second `ib` script startup. The notification code is simple enough (~20 lines) to inline.

## Suggestions (nice to have improvements)

### 11. Consider a simpler polling-based v0

Before building the full FIFO+queue system, consider whether a much simpler approach would suffice:

```bash
# ib listen --timeout 300
# Just poll the queue file every 2 seconds
while true; do
    if [[ -s "$queue_path" ]]; then
        mv "$queue_path" "$drain_file"
        cat "$drain_file"
        rm -f "$drain_file"
        exit 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    if [[ $elapsed -ge $timeout ]]; then exit 0; fi
done
```

This eliminates the FIFO entirely. The tradeoff is 2-second latency instead of instant. For a system where the primary Claude needs to process notifications, review diffs, and make decisions, 2 seconds of additional latency is negligible.

The FIFO adds: mkfifo lifecycle management, non-blocking write complexity, the drain race condition, FIFO deletion concerns, and `<>` mode edge cases. All for saving ~2 seconds of latency.

### 12. `drain_and_print` could batch-print more efficiently

Instead of `cat`, read lines and prefix each with a marker so Claude can distinguish notification output from other background task output:

```
[ib-notify] {"ts":"...","from":"agent-abc","type":"complete","msg":"..."}
[ib-notify] {"ts":"...","from":"agent-def","type":"waiting","msg":"..."}
```

This makes the output unambiguous if Claude has multiple background tasks running.

### 13. Document the listener re-spawn contract explicitly

The plan assumes Claude will always re-spawn the listener after processing notifications. This is a behavioral contract that Claude might violate. The `<ittybitty>` instructions should be explicit about this and ideally include a concrete example:

```
After processing all notification lines:
1. Take action on each notification (ib merge, ib send, etc.)
2. IMMEDIATELY re-spawn: Bash(command: "ib listen --timeout 300", run_in_background: true)
Do NOT skip step 2. Missing notifications means missing agent completions.
```

### 14. Cleanup in `cmd_nuke` should kill the listener

The plan mentions this in Phase 4 (item 12) but doesn't provide specifics. `cmd_nuke` should:
```bash
# Kill listener if running
local listener_pid_file="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener-${REPO_ID}.pid"
if [[ -f "$listener_pid_file" ]]; then
    local lpid=$(<"$listener_pid_file")
    kill "$lpid" 2>/dev/null || true
    rm -f "$listener_pid_file"
fi
# Clean up notify directory
rm -rf "$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify"
```

## Scope Assessment

### Essential for v1:
- `ib notify` (write side)
- `ib listen` (read side)
- Stop hook integration (complete + waiting states)
- SessionStart bootstrap instruction
- Basic tests

### Could be cut from v1:
- `question_id` in JSONL format (use existing `ib questions` flow)
- `is_listener_alive()` helper (nice but not needed for core functionality)
- `ib ask` integration (questions already work via existing mechanism)
- Drain test fixtures (manual testing is sufficient for v1)
- `stuck` and `error` notification types (nothing generates them yet)

### Nice to have for v2:
- `ib watch` listener status indicator
- PostToolUse liveness reminder
- Inlined notification logic in Stop hook (performance optimization)
- Watchdog integration for rate_limited notifications

## Verdict

**Needs minor revision before implementing.** The core design is solid and the FIFO+queue mechanism works correctly on macOS Bash 3.2 (verified). The main issues to fix are:

1. **Don't delete the FIFO in drain** — this creates a real race condition (Critical #1)
2. **Simplify the non-blocking write** — use `disown` instead of the background+kill pattern (Critical #3)
3. **Reconcile the two plan documents** — pick one drain approach and stick with it (Critical #2)
4. **Always exit 0** — don't make timeout look like an error (Concern #6)
5. **Consider dropping the FIFO entirely** for a simpler polling approach (Suggestion #11)

Items 1-4 are straightforward fixes. Item 5 is a design question worth discussing — if 2-second latency is acceptable, the implementation gets dramatically simpler.
