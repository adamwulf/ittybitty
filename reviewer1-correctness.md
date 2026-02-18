# Correctness & Completeness Review of notification-plan.md (v2)

## 1. User Feedback — All 8 Decisions Verified

| # | User Decision | Status | Where in Plan |
|---|---------------|--------|---------------|
| 1 | Polling instead of FIFO | **Addressed** | Lines 7, 54, 234, 510, 534, 674-687. Thoroughly explained with rationale. |
| 2 | Liveness check on EVERY PreToolUse/PostToolUse hook call | **Addressed** | Lines 427-466. Integrated into `cmd_hooks_inject_status()` which runs on every PostToolUse and UserPromptSubmit. |
| 3 | Clean timeout exit at ~9.5 min with exit 0 and restart reminder | **Addressed** | Lines 211-213, 236. Always `exit 0`, prints reminder message. |
| 4 | Dropped question_id from notification format | **Addressed** | Lines 88, 512. Explicit "No `question_id` field" with rationale. |
| 5 | Complete JSON escaping (backslash, quotes, newline, CR, tab) | **Addressed** | Lines 92-115. All 5 characters listed with code. Known limitation for other control chars documented (line 102). |
| 6 | REPO_ID dropped from filenames | **Addressed** | Lines 57-68. Files are `queue` and `listener.pid`, not `queue-${REPO_ID}`. |
| 7 | `ib notify` kept as shell-out (not inlined) | **Addressed** | Lines 383. Explicit: "kept as separate command invocations (shell-out) rather than inlined". |
| 8 | Subprocess in drain (`cat`) kept as-is | **Addressed** | Line 227. `cat "$drain_file"` used in `drain_and_print()`. |

**Verdict: All 8 user decisions are correctly reflected. No omissions.**

## 2. Remaining Contradictions / Stale References

### No contradictions found

The v2 plan is clean. I checked for:

- **FIFO references:** The word "FIFO" appears only in "Why polling, not FIFO" explanations (lines 54, 510, 534, 676-680) and the scope exclusion table (line 510). All are explicitly explaining why FIFO was *rejected*. No code uses `mkfifo`, named pipes, or `read <>`.
- **Signal files:** No references to signal files or doorbell mechanisms.
- **REPO_ID in filenames:** Line 68 explicitly says "No REPO_ID in filenames." The code uses plain `queue` and `listener.pid`. The `cmd_nuke` cleanup on line 661 correctly uses `notify/listener.pid` without REPO_ID.
- **question_id:** Line 88 explicitly says "No `question_id` field." The scope exclusion table (line 512) reinforces this.
- **Old plan artifacts:** The review.md references `plan-a.md` extensively, but `notification-plan.md` v2 has no references to plan-a.md or its approaches (mkdir lock, cp+truncate, etc.).

**Verdict: Clean. No stale artifacts from the old plan.**

## 3. Edge Cases — Analysis

### Edge cases covered in the plan

| Edge Case | Covered? | Location |
|-----------|----------|----------|
| Listener not running when notification arrives | Yes | Lines 470-471 |
| Multiple simultaneous writers | Yes | Lines 473-474 |
| Gap between listener exit and re-spawn | Yes | Lines 476-477 |
| Drain vs. write race condition | Yes | Lines 479-482 |
| Stale PID file | Yes | Lines 484-485 |
| Claude session ends | Yes | Lines 487-488 |
| Claude ignores liveness warning | Yes | Lines 490-491 |
| Multiple listeners running | Yes | Lines 493-494 |

### Edge cases NOT covered (missing from plan)

**3a. Queue file grows unbounded / disk full**

If the listener is dead for a long time and many notifications accumulate, the queue file grows without bound. More critically, if the disk is full, `echo >> "$queue_path"` will fail silently (or write a partial line). The plan doesn't address this.

*Severity: Low.* In practice, notifications are small (~200 bytes each) and agents don't generate them rapidly. Thousands of notifications would still be under 1MB. But a partial-write due to disk full could produce invalid JSON that confuses Claude's parsing.

*Suggestion:* Document as a known limitation. Optionally, add a size check in `cmd_notify()` — if queue exceeds e.g. 100KB, truncate or warn.

**3b. Multiple `ib listen` processes start simultaneously**

Line 493-494 acknowledges this but calls it "not ideal." The plan says "The `listener.pid` file can be used to detect this case in the future." This should be addressed now — it's a straightforward check:

```bash
# At the top of cmd_listen(), before writing PID:
if is_listener_alive; then
    echo "Listener already running (PID $(cat "$pid_path")). Exiting." >&2
    exit 0
fi
```

Without this, two listeners competing for the same queue can cause confusing behavior: listener A does `mv queue drain.A`, listener B sees no queue, listener A prints messages, listener B continues polling and eventually picks up the next batch. The interleaving is safe but wasteful, and Claude Code gets two background tasks to track.

*Severity: Medium.* Claude could easily spawn a second listener if it misinterprets a liveness warning or processes notifications slowly. The fix is trivial.

**3c. `ib` script updated while listener is running**

Not discussed. The listener is a running bash process that has already loaded the `ib` script. If `ib` is updated (e.g., another agent merges changes), the running listener is unaffected — bash has already parsed the script into memory. The next `ib listen` will use the new script.

*Severity: None.* This is a non-issue for bash scripts. No action needed, but could be documented for completeness.

**3d. `ib notify` called but `require_git_repo` fails**

Line 300 calls `require_git_repo` after parsing arguments. If called from a context where no git repo is found (e.g., from `/tmp`), `require_git_repo` will `exit 1` with an error message. This is correct behavior — notifications outside a repo context make no sense.

However, the auto-detect block (lines 286-298) runs *before* `require_git_repo`. If `pwd` returns a path outside any repo, the auto-detect harmlessly sets `from_id="unknown"` and then `require_git_repo` fails. This is fine.

*Severity: None.* Correct behavior. No issue.

**3e. `.ittybitty/notify/` directory deleted while listener runs**

If someone runs `rm -rf .ittybitty/notify/` while the listener is polling:
- The listener's `[[ -s "$queue_path" ]]` check returns false (file gone)
- The loop continues polling, checking a non-existent path
- On timeout, `echo "No messages..."` goes to stdout (fine)
- The `trap EXIT` tries `rm -f "$pid_path"` on a non-existent file — `rm -f` succeeds silently

Meanwhile, if `ib notify` runs, it does `mkdir -p "$notify_dir"` (line 305), which recreates the directory and writes a new queue file. The existing listener won't find it because... actually it will. The listener checks `"$queue_path"` which is the same path. If the directory is recreated and a new `queue` file appears at the same path, the listener will find it on the next poll iteration.

*Severity: Low.* The system self-heals. The only issue is the brief window where the PID file is gone but the listener is alive — `is_listener_alive()` would return false, triggering a liveness warning. But the listener would still drain messages. If Claude spawns a second listener in response to the warning, we hit the "multiple listeners" case (3b).

*Suggestion:* The fix for 3b (check `is_listener_alive` at startup) mitigates this scenario too.

**3f. Claude Code kills the background task before timeout**

If Claude Code terminates the background `ib listen` process (e.g., user sends `/clear`, Claude compacts context, or Claude Code has its own timeout):
- The `trap EXIT` fires, cleaning up the PID file
- The listener exits silently (no output to Claude)
- Any queued messages remain in the queue file
- The liveness check on the next tool call detects the dead listener and warns Claude

*Severity: Low.* Messages are not lost. The liveness check handles recovery. However, Claude won't get a "background task completed" notification with output — it just silently disappears. Claude might not notice until the next tool call triggers the liveness check.

*Suggestion:* Document this behavior. The liveness check is the safety net for this case.

## 4. Implementation Completeness — Could Someone Implement This Mechanically?

### What's well-specified

- **`cmd_listen()`**: Full pseudocode with argument parsing, PID management, polling loop, drain function. Lines 181-231. Clear and implementable.
- **`cmd_notify()`**: Full pseudocode with argument parsing, auto-detect, JSON formatting. Lines 248-320. Clear and implementable.
- **`json_escape_notify()`**: Complete implementation. Lines 106-114.
- **`is_listener_alive()`**: Complete implementation. Lines 328-340.
- **`drain_and_print()`**: Complete implementation. Lines 217-230.
- **Hook changes**: Specific code snippets showing exactly where to add `ib notify` calls. Lines 360-381.
- **Dispatcher entries**: Explicitly specified. Lines 627, 633.
- **Test fixtures**: Detailed table of fixture files. Lines 562-603.
- **Implementation order**: Clear 4-phase plan. Lines 614-671.

### What's under-specified

**4a. `count_active_agents` helper (line 441)**

The liveness check code references `count_active_agents` with a comment "(existing helper or simple ls count)". This function doesn't exist in the codebase — the implementer needs to know: does this count running agents? All agents? Just non-archived ones?

*Fix:* Specify the implementation. Likely:
```bash
count_active_agents() {
    local count=0
    local agents_dir="$ROOT_REPO_PATH/$ITTYBITTY_DIR/agents"
    if [[ -d "$agents_dir" ]]; then
        for d in "$agents_dir"/*/; do
            [[ -d "$d" ]] && count=$((count + 1))
        done
    fi
    echo "$count"
}
```

Or clarify that the implementer should use an existing mechanism (e.g., `ls .ittybitty/agents/ | wc -l`).

**4b. Hook identification — which hook is being modified?**

Line 430 says "Add liveness checking to `cmd_hooks_inject_status()`" but the plan doesn't clarify what hook type this function handles. Reading the plan, it appears to be a PostToolUse/UserPromptSubmit hook. The plan should specify:
- What's the hook name in `settings.local.json`?
- Is this the *primary Claude's* settings, not an agent's?
- How does this hook distinguish primary Claude from agent Claude?

The plan mentions "It already skips agent Claude instances (checks cwd)" (line 456) but doesn't show that check. An implementer unfamiliar with the codebase would need to find this logic.

*Severity: Low-medium.* An implementer familiar with the ib codebase would find this, but the plan aspires to be mechanically implementable.

**4c. Where exactly in `cmd_hooks_agent_status()` to add the notify calls**

Lines 360-381 show code snippets but use `# In the complete+worker branch (after existing ib send):` as a location marker. The implementer needs to find the specific `if` branches in the existing code. The plan doesn't reference line numbers in the `ib` script (which would be fragile anyway), but it also doesn't quote enough surrounding context to make the insertion point unambiguous.

*Severity: Low.* The Stop hook structure is documented in CLAUDE.md and the snippets are clear enough. An implementer reading the hook code would find the right spots.

**4d. `cmd_ask()` integration — where exactly?**

Line 388-390 says "At the end of cmd_ask(), after the question is stored" but doesn't show surrounding context. The implementer needs to find `cmd_ask()` and identify where "after the question is stored" is.

*Severity: Low.* Same as 4c — clear enough for someone reading the code.

**4e. The `get_ittybitty_instructions()` modification**

Lines 398-425 show the markdown to add to the primary role section. But `get_ittybitty_instructions()` is a function that generates a large block of text. The plan says "Add to the `primary` role section" but doesn't clarify: is there a `primary` role section? How is role determined? The function generates different instructions for different contexts.

*Severity: Medium.* An implementer would need to understand the prompt system architecture to place this correctly. The plan should reference the specific section marker or conditional branch in `get_ittybitty_instructions()` where this should be inserted.

**4f. `--timeout` argument parsing in `cmd_listen()`**

Line 185 says `# ... parse --timeout arg ...` without showing the implementation. This is straightforward but the plan could show it for completeness, especially given the careful argument parsing shown for `cmd_notify()`.

*Severity: Very low.* Standard `while/case/shift` pattern, well-established in the codebase.

## Summary

### Issues Found

| # | Issue | Severity | Category |
|---|-------|----------|----------|
| 1 | No guard against multiple simultaneous listeners | Medium | Missing edge case |
| 2 | `count_active_agents` helper undefined | Low-Medium | Implementation gap |
| 3 | Hook identification for liveness check under-specified | Low-Medium | Implementation gap |
| 4 | `get_ittybitty_instructions()` insertion point unclear | Medium | Implementation gap |
| 5 | Queue unbounded growth / disk full not addressed | Low | Missing edge case |
| 6 | Claude Code killing background task behavior undocumented | Low | Missing edge case |
| 7 | `--timeout` parsing not shown | Very Low | Implementation gap |

### Overall Assessment

**The plan is in good shape.** All 8 user decisions are correctly reflected. No stale artifacts from the old FIFO-based plan remain. The core design (polling + queue + atomic mv drain) is sound and well-documented.

The main gap is the lack of a guard against multiple simultaneous listeners (#1), which is a trivial fix but would prevent confusing behavior in practice. The implementation gaps (#2-4, #7) are minor — they would slow down a mechanical implementer but wouldn't lead to incorrect code.

No correctness bugs were found in the specified logic. The `set -e` safety analysis is thorough. The Bash 3.2 compatibility table covers everything used. The JSON escaping is complete for the documented character set.
