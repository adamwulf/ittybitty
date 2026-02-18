# Reviewer 1 — End-to-End Walkthrough Review

## 1. Implementation Walkthrough

Walking through the Implementation Order section step by step, asking "Do I have everything I need to write this code?" at each phase.

### Phase 1, Step 1: `cmd_notify()`

The specification is thorough. Argument parsing, type validation, auto-detection of sender from worktree path, JSON formatting, and atomic append are all clearly described with complete code.

- **NOTE**: The auto-detect block uses `read_meta_field()` which is referenced as an existing function. The plan does not define it, implying it already exists in the `ib` script. An implementer should verify this function exists and takes the described arguments (`file`, `field`, `default`). Given the plan consistently references existing helpers (like `json_escape_string()` at ~line 407), this is likely fine.

- **NOTE**: The `require_git_repo` call is documented as setting `ROOT_REPO_PATH`. The plan correctly notes this is an existing function at ~line 3657. No gap here.

- **SHOULD FIX**: The plan says to add `notify) shift; cmd_notify "$@" ;;` to the dispatcher but does not specify what happens if `ib notify` is called from *inside an agent worktree* vs the main repo. The `require_git_repo` call will set `ROOT_REPO_PATH` — but will it resolve to the *main* repo root or the *worktree* root? Since `.ittybitty/notify/queue` lives under the main repo's `.ittybitty/` directory, `ROOT_REPO_PATH` must resolve to the main repo. The plan should explicitly confirm this works from agent worktrees. If `require_git_repo` resolves to the worktree root, `ib notify` from a Stop hook (which runs in an agent's worktree) would write to a nonexistent `.ittybitty/notify/queue` inside the worktree. This is potentially a **BLOCKING** issue depending on how `require_git_repo` works. The Stop hook calls `ib notify` — if it runs from an agent worktree context, the queue file path could be wrong.

  **Update after further reading**: The `cmd_notify` code includes `require_git_repo` which sets `ROOT_REPO_PATH`. In git worktrees, `git rev-parse --show-toplevel` returns the *worktree* root, not the main repo root. However, looking at how the Stop hook works: `cmd_hooks_agent_status` is called via `ib hooks agent-status <id>` — the `ib` command would be run from whatever directory the hook is invoked from. Hooks fire from within the agent's Claude Code session, which has its cwd set to the agent's worktree repo. So `ROOT_REPO_PATH` would point to the agent's worktree, and `.ittybitty/notify/queue` would not exist there. **BLOCKING**: The plan needs to specify how `ib notify` resolves the main repo path when called from an agent worktree. Either `cmd_notify` needs to walk up to find the main repo (e.g., via `git worktree list --porcelain` or by reading the `.git` file), or the Stop hook needs to pass the main repo path explicitly.

### Phase 1, Step 2: `is_listener_alive()`

Well-specified. Uses the global variable pattern (`_LISTENER_ALIVE`) to avoid `set -e` issues. PID validation with `kill -0` plus process name check via `ps -p PID -o args=` is solid.

- **SHOULD FIX**: The function references `$ROOT_REPO_PATH` for the pid file path: `local pid_path="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener.pid"`. This means `require_git_repo` must be called before `is_listener_alive()`. The function does not call it itself. When called from `cmd_hooks_inject_status()`, is `ROOT_REPO_PATH` already set? The plan says the status injection hook already scans agent directories, so presumably it has already called `require_git_repo` or equivalent. But this dependency is implicit and should be documented.

- **NOTE**: The `ps -p PID -o args=` check looks for `"ib listen"` in the command string. If the user has `ib` aliased or installed under a different name, this could fail. This is an acceptable edge case for v1.

### Phase 1, Step 3: `cmd_listen()` + `drain_and_print()`

Complete specification with clear code. The polling loop, PID management, and atomic drain are well-defined.

- **SHOULD FIX**: The `drain_and_print()` function uses `cat "$drain_file"` to print the drained contents. The CLAUDE.md performance guidelines say to prefer `$(<"$file")` over `cat`, but since this is not in the render hot path (it runs once per drain, not per frame), `cat` is fine for clarity. However, there is a subtle issue: `cat` preserves trailing newlines from the file, while `$(<"$file")` strips them. Since JSONL lines each end with `\n` from `echo`, using `cat` is actually the correct choice here. No change needed, but worth noting the rationale.

- **NOTE**: The `rm -f "$notify_dir"/queue.drain.* 2>/dev/null || true` cleanup at listener startup could remove a drain file that is actively being processed by a dying listener. In practice this is harmless because the dying listener is already dead (we checked `is_listener_alive()`), but the window between the liveness check and the `rm` is theoretically non-zero. Acceptable for v1.

- **NOTE**: The `--timeout` argument parsing is shown as `# ... parse --timeout arg ...` (elided). An implementer needs to write the argument parsing loop. The pattern is standard and used throughout the `ib` script, so this is not a gap — just a note that it is not provided verbatim.

### Phase 2, Step 5: Modify `cmd_hooks_agent_status()`

The plan clearly shows where to add `ib notify` calls, with code snippets showing the exact insertion points relative to existing `ib send` calls.

- **BLOCKING**: As noted in Step 1 above, the Stop hook runs in an agent worktree context. The `ib notify` call from the Stop hook will resolve `ROOT_REPO_PATH` to the agent's worktree, not the main repo. The queue file `.ittybitty/notify/queue` does not exist inside agent worktrees. This is the same path resolution issue from Step 1 and must be addressed.

- **NOTE**: The `|| true` suffix on all `ib notify` calls is correct — notification failure must not break the Stop hook. Good defensive practice.

### Phase 2, Step 6: Modify `cmd_ask()`

Brief and clear. One line addition.

- **SHOULD FIX**: Same path resolution concern as above — `cmd_ask()` is called by agents from their worktree. The `ib notify` call will need to resolve the main repo path correctly.

### Phase 2, Step 7: Modify `cmd_hooks_inject_status()`

The plan shows where to add the liveness check, uses the existing `$agent_count` variable, and correctly notes the escaping chain for `additionalContext`.

- **NOTE**: The plan says to check `$agent_count -gt 0` before warning, and notes that `$agent_count` is already computed earlier in the function. This is good — it avoids warning when no agents exist.

- **SHOULD FIX**: The plan references `$agent_count` as "already computed earlier in cmd_hooks_inject_status()" but does not show the variable name verbatim from the existing code. An implementer needs to verify the exact variable name in the existing function. If it is named differently (e.g., `$active_count` or `$num_agents`), the code will not work.

### Phase 2, Step 8: Modify `get_ittybitty_instructions()`

Clear markdown block to add to the `primary` role section.

- **NOTE**: The instructions tell Claude to "IMMEDIATELY re-spawn" after processing notifications. This is important — if Claude forgets, the liveness check will remind it. Good layered approach.

### Phase 3: Tests

- **SHOULD FIX**: The `cmd_test_notify_format()` function uses `json_get()` to extract fields from the fixture JSON. The plan references `json_get()` at ~line 183 as an existing helper. An implementer should verify this function exists and handles the described usage pattern (extracting a field from a JSON string).

- **NOTE**: The `cmd_test_notify_drain()` function uses clever fixture filename conventions (`drain-missing-*` and `drain-empty-*`) to distinguish between "queue file does not exist" and "queue file exists but is empty". This is a clean approach that extends the existing naming convention.

### Phase 4: Cleanup

- **NOTE**: The `cmd_nuke()` cleanup is straightforward. Kill listener, remove notify directory. Good.

## 2. Cross-Reference Check

Checking that every function referenced in one section is fully defined in another.

| Function | Defined in plan? | Called from | Status |
|----------|-----------------|------------|--------|
| `cmd_notify()` | Yes, full code | Stop hook, cmd_ask, manual use | OK |
| `cmd_listen()` | Yes, full code | Primary Claude (background) | OK |
| `drain_and_print()` | Yes, full code | cmd_listen() | OK |
| `is_listener_alive()` | Yes, full code | cmd_listen(), cmd_hooks_inject_status() | OK |
| `cmd_test_notify_format()` | Yes, full code | test-notify.sh | OK |
| `cmd_test_notify_drain()` | Yes, full code | test-notify.sh | OK |
| `json_escape_string()` | Referenced as existing (~line 407) | cmd_notify() | **Assumed existing** |
| `json_get()` | Referenced as existing (~line 183) | cmd_test_notify_format() | **Assumed existing** |
| `require_git_repo()` | Referenced as existing (~line 3657) | cmd_notify(), cmd_listen() | **Assumed existing** |
| `read_meta_field()` | Referenced as existing | cmd_notify() auto-detect | **Assumed existing** |
| `log_agent()` | Referenced as existing | Stop hook additions | **Assumed existing** |

- **NOTE**: All referenced existing functions are well-known ib helpers mentioned in CLAUDE.md or the plan's own comments. No orphaned references found.

- **BLOCKING**: `drain_and_print()` is called from `cmd_test_notify_drain()`, but `drain_and_print()` is defined as a standalone function, not nested inside `cmd_listen()`. The placement section says to put `drain_and_print()` "immediately before `cmd_listen()`." This means it is accessible globally, which is correct for both `cmd_listen()` and `cmd_test_notify_drain()` to call it. However, `drain_and_print()` does not call `require_git_repo` — it takes `$notify_dir` and `$queue_path` as parameters. This is fine because callers pass these values. No issue here.

  Actually, on re-reading: `cmd_test_notify_drain()` calls `drain_and_print "$tmp_dir" "$queue_path"` — this works because `drain_and_print` takes the directory and queue path as parameters. Cross-reference is clean.

## 3. Hook Injection Format Verification

### PostToolUse/UserPromptSubmit liveness warning

The plan injects the warning via `additionalContext` in the hook response. The warning text is:

```
[ib] WARNING: Notification listener is not running. Restart it now:
Bash(command: "ib listen", run_in_background: true)
```

- **SHOULD FIX**: The injected text includes `Bash(command: "ib listen", run_in_background: true)` — this is showing Claude the *tool invocation syntax* as a hint. However, Claude Code tool invocations are not triggered by text in `additionalContext`. Claude sees this as a suggestion and must decide to call the tool itself. This is fine as a hint, but the plan should clarify that this is a *prompt* for Claude to act, not an automatic tool invocation. The current framing in the plan ("inject a reminder") is correct but could be misread as "automatically restarts the listener."

- **NOTE**: The escaping chain described in the plan is: raw newlines in bash string -> `json_escape_string()` converts to literal `\n` -> placed in JSON `additionalContext` field -> Claude Code parses JSON, `\n` becomes real newlines. This is the same pattern used by the existing status injection, so it should work correctly.

- **SHOULD FIX**: The plan appends `listener_warning` to `status_content` with `status_content="${status_content}${listener_warning}"`. This means the warning appears at the end of the normal agent status injection text. Will Claude actually notice it there? If the status context is long (many agents), the warning could be buried. Consider prepending the warning instead, or adding visual separators. This is a usability concern, not a correctness issue.

### Stop hook notification format

The Stop hook additions call `ib notify --from "$ID" --type complete "message"`. This writes to the queue file. The listener reads and prints JSONL. Claude Code delivers the output. The format chain is:

1. Message string with agent ID embedded
2. `json_escape_string()` escapes it
3. Appended as JSONL to queue
4. `cat` prints it (preserving format)
5. Claude Code delivers as background task output

- **NOTE**: No escaping issues found. The `json_escape_string()` function handles the necessary escaping, and agent IDs are alphanumeric with hyphens (no special characters).

## 4. Test Coverage Assessment

### Format tests

The six format fixtures cover: basic, quotes, newlines, tabs, carriage returns, and backslashes. This covers all the escaped characters documented in the JSON Escaping table.

- **SHOULD FIX**: Missing test case for a message containing all special characters combined. A `format-mixed.json` fixture with `"msg":"line1\nline2\t\"quoted\"\\path"` would catch escaping-order bugs (e.g., double-escaping backslashes if they are not escaped first).

- **SHOULD FIX**: Missing test case for empty message string. What happens if `ib notify --type complete ""` is called? The plan says `if [[ -z "$message" ]]` exits with error, but there is no fixture testing this error path.

- **NOTE**: Missing test for very long messages (e.g., 10KB). Not critical for v1 since agent status messages are short, but worth noting.

### Drain tests

Four fixtures: single, multiple, missing queue file, empty queue file. Good coverage of the primary paths.

- **SHOULD FIX**: Missing test for the drain race condition: what happens when `drain_and_print` is called but the queue file is removed between the `-s` check in `cmd_listen()` and the `mv` in `drain_and_print()`? The `mv ... || true` handles this, but there is no test verifying the behavior. A `drain-vanished.jsonl` fixture could simulate this by having the test remove the queue file before calling `drain_and_print`.

  Actually, this is hard to test deterministically with fixtures. The `|| true` on `mv` and the `-s` check on the drain file handle this. Downgrading to **NOTE**.

### Fixture naming convention

- `format-basic.json` — does this follow the convention `{expected-output}-{description}.ext`? The "expected output" here would be "valid JSON" which is not a simple prefix. Looking at the test script description, it says the runner verifies that `from`, `type`, and `msg` fields match after unescaping, and that `ts` varies. So the expected output is not encoded in the filename the same way as `complete-simple.txt` for parse-state tests.

- **SHOULD FIX**: The fixture naming convention for notify format tests does not follow the established pattern of `{expected-output}-{description}`. The test script uses a different verification approach (checking field values rather than comparing against an expected output prefix). This is acceptable but should be explicitly documented in the test script comments to avoid confusion with the standard convention. Alternatively, the fixtures could be renamed to follow a pattern like `valid-basic.json`, `valid-quotes.json` to encode the expected validation result.

### Integration test

The integration test in `tests/test-notify.sh` is well-designed: spawn listener, send notification, verify output. The `trap` cleanup and `wait` with `|| true` handle edge cases.

- **NOTE**: The integration test uses `sleep 1` between listener start and notification send. If the machine is slow, the listener might not have started yet. A more robust approach would be to wait until the PID file exists. Not critical for CI, but could cause flaky tests on slow machines.

### Missing test areas

- **SHOULD FIX**: No test for `is_listener_alive()`. A fixture-based test could verify: (a) returns false when no PID file exists, (b) returns false when PID file contains a dead PID, (c) returns true when PID file contains a live PID of a process with "ib listen" in its args. This function is critical for the liveness mechanism.

- **NOTE**: No test for the `--timeout` argument parsing in `cmd_listen()`. This is a minor gap since the pattern is standard.

## 5. Liveness Detection Analysis

Walking through the full lifecycle: listener starts -> listener dies -> hook detects -> Claude sees warning -> Claude respawns.

### Happy path

1. Claude runs `ib listen` in background
2. Agent completes, Stop hook calls `ib notify`
3. Listener finds message within 2 seconds, prints JSONL, exits
4. Claude Code notifies: "Background task completed"
5. Claude processes notification, re-spawns `ib listen`

This works cleanly. No issues.

### Listener dies unexpectedly (kill -9, OOM, etc.)

1. Listener is killed. PID file remains (trap does not fire on SIGKILL)
2. Next tool call triggers `cmd_hooks_inject_status()`
3. `is_listener_alive()` reads PID file, `kill -0` fails, returns false, cleans up PID file
4. Warning injected into Claude's context
5. Claude sees warning, re-spawns `ib listen`

This works. The stale PID file is cleaned up by `is_listener_alive()`.

### Listener times out (no messages for ~9.5 min)

1. Listener exits with "No messages received" reminder
2. Claude Code notifies: "Background task completed"
3. Claude sees reminder, re-spawns `ib listen`

This works. Clean heartbeat cycle.

### Claude is busy and does not process background task notification

1. Listener exits (timeout or messages)
2. Claude Code queues the notification
3. Claude is in the middle of a long operation (e.g., large file edit)
4. Meanwhile, new notifications arrive via `ib notify` — they accumulate in queue file
5. Eventually Claude finishes, sees the background task notification
6. Claude processes it, re-spawns `ib listen`
7. New listener immediately finds accumulated messages

**No message loss.** The queue file acts as a buffer. Good design.

### Claude never processes the background task notification

This is the most concerning scenario:

1. Listener exits
2. Claude Code delivers notification
3. Claude is in a very long conversation, context is full, notification is lost in the noise
4. No listener running. Messages accumulate in queue.
5. On every tool call, liveness warning is injected
6. Eventually Claude acts on the warning and re-spawns

- **NOTE**: The persistent liveness warning on every tool call is the safety net here. Even if Claude ignores the background task notification, it cannot ignore the warning that appears in every tool result. This is a robust design.

### What if the hook itself is not installed?

- **SHOULD FIX**: The plan describes adding liveness checking to `cmd_hooks_inject_status()`, which is the PostToolUse/UserPromptSubmit hook. But what if the user has not installed hooks via `ib hooks install`? The plan does not address this. If hooks are not installed, there is no liveness check, and the only mechanism to keep the listener alive is (a) the timeout heartbeat (~9.5 min cycle) and (b) Claude remembering from the instructions. The timeout heartbeat is reliable, so the listener will at most be dead for ~10 minutes. The instructions in `get_ittybitty_instructions()` tell Claude to re-spawn after processing notifications. This is acceptable but should be noted as a known limitation.

  Actually, re-reading the plan: the status injection hook is for the *primary Claude*, not agent hooks. The primary Claude's hook installation is separate from agent hooks. The plan should clarify whether the primary Claude's PostToolUse hook is always installed when using ib, or if it requires manual setup. If it requires `ib hooks install`, the liveness check depends on the user having done that setup.

### PID reuse scenario

1. Listener dies (PID 12345)
2. OS reuses PID 12345 for an unrelated process (e.g., `vim`)
3. `is_listener_alive()` reads PID 12345, `kill -0` succeeds
4. `ps -p 12345 -o args=` returns `vim somefile.txt`
5. Does not contain `"ib listen"` — detected as stale
6. PID file cleaned up, `_LISTENER_ALIVE` set to false

This works correctly. The process name check is the critical guard. Good.

### Race condition: two listeners start simultaneously

1. Claude runs `ib listen` (Listener A)
2. Before A writes PID, Claude runs `ib listen` again (Listener B)
3. Both check `is_listener_alive()` — no PID file yet, both proceed
4. A writes PID, B overwrites PID with its own
5. Both poll the same queue. First to `mv` gets messages.
6. A exits, trap checks if PID file contains A's PID — it doesn't (B overwrote it), so A does not remove it
7. B continues running normally

- **NOTE**: This race is acknowledged in the Edge Cases section. The behavior is correct — the surviving listener keeps running and its PID is in the file. Messages are not lost. The only waste is one extra `sleep 2` poll cycle for the listener that lost the `mv` race. Acceptable.

### Scenario: `ib notify` called when no listener exists and no agents are tracked

1. Some external script calls `ib notify "test"`
2. Message is appended to queue file
3. No listener running — message sits in queue indefinitely
4. Next time a listener starts, it finds and delivers the message

- **NOTE**: Not a problem. Messages are durable in the queue file. No special handling needed.

### Scenario: Listener starts, immediately finds stale messages from hours ago

1. Previous session left messages in queue (listener died, session ended)
2. New session starts, Claude runs `ib listen`
3. Listener immediately finds old messages, prints them, exits
4. Claude processes stale notifications (e.g., "Agent X completed" but X was killed hours ago)

- **SHOULD FIX**: Stale messages could confuse Claude. It might try to `ib merge` an agent that no longer exists. The plan does not address message staleness. A simple mitigation: add a timestamp check in `cmd_listen()` that drops messages older than N minutes, or add a note in the instructions that Claude should verify agent existence before acting. Alternatively, `cmd_nuke()` cleanup (Phase 4, Step 13) removes the notify directory, which also removes stale messages. But if the user just ends their Claude session without nuking, stale messages persist.

  Downgrading to **SHOULD FIX** rather than BLOCKING because Claude should gracefully handle "agent not found" errors from `ib look`/`ib merge`, and the queue is cleaned by `cmd_nuke()`.

## Summary

### BLOCKING Issues

1. **Path resolution from agent worktrees**: `ib notify` uses `require_git_repo` to find `ROOT_REPO_PATH`, but when called from the Stop hook inside an agent worktree, `git rev-parse --show-toplevel` returns the worktree root, not the main repo root. The queue file `.ittybitty/notify/queue` lives under the main repo's `.ittybitty/` directory. Either `cmd_notify` needs special handling to resolve the main repo path from a worktree, or the Stop hook needs to pass the correct path. This affects all notification calls from agent hooks (Steps 5 and 6 in Phase 2).

### SHOULD FIX Issues

1. **Verify `$agent_count` variable name**: The plan references this as already computed in `cmd_hooks_inject_status()` but does not confirm the exact variable name in existing code.

2. **`is_listener_alive()` depends on `ROOT_REPO_PATH` being set**: The function does not call `require_git_repo` itself. Document this prerequisite or add a guard.

3. **Missing test for mixed special characters**: Add a `format-mixed.json` fixture combining multiple escape sequences.

4. **Missing test for `is_listener_alive()`**: This critical function has no dedicated test fixtures.

5. **Missing test for empty message error path**: No fixture verifies the error when `ib notify ""` is called.

6. **Fixture naming convention mismatch**: The notify format fixtures do not follow the `{expected-output}-{description}` convention used elsewhere. Document the alternative approach or rename.

7. **Stale message handling**: Messages from previous sessions persist in the queue. Claude could act on outdated notifications. Consider documenting this limitation or adding a staleness check.

8. **Liveness warning position in status context**: The warning is appended at the end of potentially long status text. Consider prepending or adding separators for visibility.

9. **Hook installation prerequisite unclear**: The plan does not clarify whether the primary Claude's PostToolUse hook (which hosts the liveness check) is automatically installed or requires manual `ib hooks install`.

10. **`cmd_ask()` worktree path resolution**: Same as the BLOCKING issue — `cmd_ask()` is called from agent worktrees and the `ib notify` call will have the wrong path.

### NOTES

1. `read_meta_field()` assumed to exist — verify before implementation.
2. `cat` vs `$(<file)` in `drain_and_print()` is intentionally correct (preserves trailing newlines).
3. `--timeout` argument parsing is elided but follows standard pattern.
4. `ps` check for "ib listen" may fail with aliased/renamed installations — acceptable for v1.
5. Race between two simultaneous listeners is handled correctly by `mv` atomicity and PID file guard in trap.
6. Integration test `sleep 1` could be flaky on slow machines — consider waiting for PID file.
7. The persistent liveness warning on every tool call is a robust safety net that makes the system resilient to Claude ignoring individual notifications.
8. The decision to use polling over FIFO is well-justified given the 2-second latency tolerance and simplicity gains.
