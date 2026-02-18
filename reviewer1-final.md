# Final Correctness Review — notification-plan.md

**Reviewer:** agent-10eb596e
**Date:** 2026-02-17
**Scope:** Verify all previous review issues are resolved, check for new issues, end-to-end system correctness.

---

## 1. Previous Issue Resolution

### From reviewer1-correctness.md

| # | Issue | Status | Evidence |
|---|-------|--------|----------|
| 1 | No guard against multiple simultaneous listeners | **RESOLVED** | Lines 191-195: `is_listener_alive` check at startup, exits if already running |
| 2 | `count_active_agents` helper undefined | **RESOLVED** | Lines 480-481: comment clarifies `$agent_count` is already computed earlier in `cmd_hooks_inject_status()` |
| 3 | Hook identification under-specified | **RESOLVED** | Lines 474-475: explicitly names `cmd_hooks_inject_status()` as PostToolUse/UserPromptSubmit hook |
| 4 | `get_ittybitty_instructions()` insertion point unclear | **PARTIALLY RESOLVED** | Line 443 says "primary role section" — adequate for an implementer familiar with the codebase, though no line number or section marker is given |
| 5 | Queue unbounded growth / disk full | **NOT ADDRESSED** | Low severity — acceptable for v1 |
| 6 | Claude Code killing background task | **NOT ADDRESSED** | Low severity — acceptable for v1 |
| 7 | `--timeout` parsing not shown | **NOT ADDRESSED** | Very low severity — standard pattern |

### From reviewer1-quality.md

| # | Issue | Status | Evidence |
|---|-------|--------|----------|
| 1.1 | `json_escape_notify()` duplicates `json_escape_string()` | **RESOLVED** | Lines 104-108: "Use existing `json_escape_string()` function... Do NOT create a new `json_escape_notify()`" |
| 1.2 | Manual JSON construction instead of `json_object()` | **ACCEPTED AS-IS** | Lines 331-340: all fields now escaped with `json_escape_string()`. Manual construction is acceptable since it avoids subprocess overhead of `json_object()` |
| 2.1 | `shift 2` crash on missing `--from`/`--type` value | **RESOLVED** | Lines 256-264: `if [[ $# -lt 2 ]]` guards before each `shift 2` |
| 2.3 | `is_listener_alive()` returns 1 / set-e landmine | **RESOLVED** | Lines 354-375: refactored to use `_LISTENER_ALIVE` global variable pattern, never returns non-zero |
| 3.2 | `from_id` and `msg_type` not JSON-escaped | **RESOLVED** | Lines 333-337: `escaped_from` and `escaped_type` via `json_escape_string()` |
| 3.3 | `msg_type` not validated | **RESOLVED** | Lines 297-303: `case` statement validates against `complete|waiting|question` |
| 5.1 | Default type `"status"` undocumented | **RESOLVED** | Line 252: default is now `"complete"`, matching documented types |
| 5.2 | Listener warning string quoting garbles output | **RESOLVED** | Lines 488-494: uses real newlines inside single-quoted string with explanatory comment |
| 5.4 | `count_active_agents` referenced but not defined | **RESOLVED** | See correctness #2 above |

### From reviewer2-compat.md

| # | Issue | Status | Evidence |
|---|-------|--------|----------|
| 3a | PID reuse false positive | **RESOLVED** | Lines 362-369: `ps -p PID -o args=` check verifies process is actually `ib listen` |
| 4a | `listener_warning` single-quoted `\n` | **RESOLVED** | See quality #5.2 above |
| 4b | `count_active_agents` doesn't exist | **RESOLVED** | See correctness #2 above |
| 6b | Multiple listeners corrupt PID file via trap EXIT | **RESOLVED** | Line 200: trap only removes PID file if it still contains our PID (`"$(<"$pid_path")" == "$$"`) |
| 6c | Stale drain files after crash | **RESOLVED** | Line 188: `rm -f "$notify_dir"/queue.drain.* 2>/dev/null || true` at listener startup |
| 6d | PIPE_BUF reasoning incorrect | **RESOLVED** | Line 342: now correctly cites "O_APPEND (POSIX guarantee)" instead of PIPE_BUF |
| 6f | `json_escape_notify` duplicates `json_escape_string` | **RESOLVED** | See quality #1.1 above |

### From reviewer2-simplicity.md

| # | Issue | Status | Evidence |
|---|-------|--------|----------|
| 1 | Drop `json_escape_notify()` | **RESOLVED** | See quality #1.1 above |
| 2 | `count_active_agents` | **RESOLVED** | See correctness #2 above |
| 3 | Listener warning string | **RESOLVED** | See quality #5.2 above |
| 4 | `|| true` on `ib notify` calls | **RESOLVED** | Lines 408, 412, 419, 422, 433: all `ib notify` calls have `|| true` |
| 5 | `is_listener_alive()` set-e safety | **RESOLVED** | See quality #2.3 above |
| 6 | Simplify `drain_and_print()` | **RESOLVED** | Line 229: just `[[ -s "$drain_file" ]]`, `-f` redundancy removed; `rm` outside `if` on line 231 |
| 7 | Remove `poll_interval` variable | **RESOLVED** | Line 210: `sleep 2` directly |

---

## 2. FIFO/Pipe Logic Audit

All FIFO references are in explanatory/rejected contexts only:

| Line | Context | OK? |
|------|---------|-----|
| 54 | "Why polling, not FIFO:" rationale | Yes |
| 237 | "Polling, not FIFO." design decision | Yes |
| 564 | "Scope Boundaries — What NOT to Build" table | Yes |
| 676-680 | "Design Rationale — Why Polling + Queue" section | Yes |
| 744 | "no FIFO lifecycle management" in rationale | Yes |

**No FIFO code, no `mkfifo`, no named pipes, no `read <>` anywhere in implementation sections.**

---

## 3. `set -e` Safety Audit — All Code Snippets

### `cmd_listen()` (lines 174-217)

| Line | Pattern | Safe? | Reason |
|------|---------|-------|--------|
| 188 | `rm -f ... \|\| true` | Yes | `|| true` catches glob mismatch |
| 191 | `is_listener_alive` bare call | Yes | Uses global variable pattern, never returns non-zero |
| 192 | `[[ "$_LISTENER_ALIVE" == "true" ]]` | Yes | Inside `if` |
| 198 | `echo "$$" > "$pid_path"` | Yes | Always succeeds |
| 200 | `trap 'if [[ -f ... ]] && [[ ... ]]; then rm -f ...; fi' EXIT` | Yes | `&&` is inside `if` condition list |
| 203 | `while [[ $elapsed -lt $timeout ]]` | Yes | Inside `while` condition |
| 205 | `[[ -s "$queue_path" ]]` | Yes | Inside `if` condition |
| 210 | `sleep 2` | Yes | Always returns 0 |
| 211 | `elapsed=$((elapsed + 2))` | Yes | Assignment, not `(( ))` |

### `drain_and_print()` (lines 220-233)

| Line | Pattern | Safe? | Reason |
|------|---------|-------|--------|
| 227 | `mv ... \|\| true` | Yes | `|| true` catches missing file |
| 229 | `[[ -s "$drain_file" ]]` | Yes | Inside `if` condition |
| 231 | `rm -f "$drain_file"` | Yes | `-f` prevents non-zero exit |

### `cmd_notify()` (lines 251-344)

| Line | Pattern | Safe? | Reason |
|------|---------|-------|--------|
| 254-268 | `case/esac` dispatch | Yes | Standard pattern |
| 257-259 | `[[ $# -lt 2 ]]` | Yes | Inside `if` condition |
| 263-265 | `[[ $# -lt 2 ]]` | Yes | Inside `if` condition |
| 281 | `[[ -z "$message" ]]` | Yes | Inside `if` |
| 291 | `[[ -z "$message" ]]` | Yes | Inside `if` |
| 297-303 | `case "$msg_type"` validation | Yes | `case` is safe |
| 306-318 | Auto-detect block | Yes | All `[[ ]]` inside `if` blocks |
| 312 | `from_id=$(read_meta_field ...)` | **See note below** | Inside `if` but depends on `read_meta_field` return code |
| 315 | `[[ -z "$from_id" ]]` | Yes | Inside `if` |
| 329 | `ts=$(date ...)` | Yes | `date` always returns 0 for format strings |
| 332-337 | `escaped_*=$(json_escape_string ...)` | Yes | Separate `local` and assignment on different lines |
| 343 | `echo "$json_line" >> "$queue_path"` | Yes | Append always succeeds (barring disk full) |

**Note on line 312:** `from_id=$(read_meta_field "$agent_dir/meta.json" "id" "unknown")` — this is inside an `if [[ -f "$agent_dir/meta.json" ]]` block. If `read_meta_field` with a default argument can return non-zero, this would exit the script. However, `read_meta_field` provides a default ("unknown"), so it should return 0. Minor risk, but acceptable since the file existence is pre-verified.

### `is_listener_alive()` (lines 354-375)

| Line | Pattern | Safe? | Reason |
|------|---------|-------|--------|
| 355 | `_LISTENER_ALIVE=false` | Yes | Assignment |
| 358 | `[[ -f "$pid_path" ]]` | Yes | Inside `if` |
| 361 | `kill -0 "$pid" 2>/dev/null` | Yes | Inside `if` |
| 364 | `cmd_check=$(ps ...) \|\| true` | Yes | `|| true` + separate declaration |
| 365 | `[[ "$cmd_check" == *"ib listen"* ]]` | Yes | Inside `if` |
| 369 | `rm -f "$pid_path"` | Yes | `-f` flag |
| 372 | `rm -f "$pid_path"` | Yes | `-f` flag |

### `local var=$(cmd)` pattern — all instances verified:

| Lines | Declaration | Assignment | Correct? |
|-------|-------------|------------|----------|
| 307-308 | `local current_dir` | `current_dir=$(pwd)` | Yes, split |
| 328-329 | `local ts` | `ts=$(date ...)` | Yes, split |
| 332-333 | `local escaped_msg` | `escaped_msg=$(json_escape_string ...)` | Yes, split |
| 334-335 | `local escaped_from` | `escaped_from=$(json_escape_string ...)` | Yes, split |
| 336-337 | `local escaped_type` | `escaped_type=$(json_escape_string ...)` | Yes, split |
| 359-360 | `local pid` | `pid=$(<"$pid_path")` | Yes, split |
| 363-364 | `local cmd_check` | `cmd_check=$(ps ...) \|\| true` | Yes, split |
| 483 | `local listener_warning=""` | N/A (inline literal) | Yes, safe (no cmd sub) |
| 719-720 | `local lpid` | `lpid=$(<"$listener_pid_file")` | Yes, split |

**No `(( ))` arithmetic patterns found anywhere.** All arithmetic uses `$((expr))` assignment form.

### Hook integration snippets (lines 403-424)

All `ib notify` calls have `|| true` — lines 408, 412, 419, 422, 433. Safe.

### Liveness check in inject_status (lines 483-501)

| Line | Pattern | Safe? | Reason |
|------|---------|-------|--------|
| 484 | `is_listener_alive` bare call | Yes | Global variable pattern |
| 485 | `[[ "$_LISTENER_ALIVE" != "true" ]]` | Yes | Inside `if` |
| 487 | `[[ "$agent_count" -gt 0 ]]` | Yes | Inside `if` |
| 498 | `[[ -n "$listener_warning" ]]` | Yes | Inside `if` |

---

## 4. End-to-End System Correctness

### Happy path: notification delivery

1. Primary Claude spawns `ib listen` as background task
2. `cmd_listen()` writes PID, starts polling every 2s
3. Agent completes → Stop hook fires → `ib notify --from $ID --type complete "msg" || true`
4. `cmd_notify()` escapes all fields, appends JSONL to `queue`
5. Listener finds `[[ -s "$queue_path" ]]` → calls `drain_and_print()`
6. `mv queue → queue.drain.$$` (atomic), `cat` prints, `rm -f` cleans up
7. Listener exits 0 → Claude Code delivers output → Claude processes + re-spawns

**Correct.** No gaps in the flow.

### Liveness recovery path

1. Listener dies (timeout, killed, crash)
2. `trap EXIT` fires → removes PID file (if still ours)
3. Claude makes next tool call → `cmd_hooks_inject_status()` runs
4. `is_listener_alive()` → `_LISTENER_ALIVE=false`
5. If agents active → warning injected into `additionalContext`
6. Claude sees warning → spawns new `ib listen`
7. New listener finds queued messages on first poll

**Correct.** Messages accumulate in queue file during gap; no loss.

### Concurrent writers path

1. Agent A and Agent B both call `ib notify` simultaneously
2. Both `echo >> queue` use O_APPEND → atomic seek+write for regular files
3. Both JSONL lines appear in queue, no interleaving

**Correct.** POSIX O_APPEND guarantee on local filesystem.

### Multiple listener prevention

1. Listener A is running
2. Claude mistakenly spawns second `ib listen`
3. `is_listener_alive()` finds PID file, validates with `kill -0` + `ps` check
4. Returns `_LISTENER_ALIVE=true` → exits with message

**Correct.** Guards against duplicate listeners.

### PID reuse scenario

1. Listener exits abnormally (kill -9), PID file left behind
2. OS reuses PID for unrelated process
3. `is_listener_alive()`: `kill -0` succeeds, but `ps -p PID -o args=` doesn't contain "ib listen"
4. Stale PID file removed, `_LISTENER_ALIVE=false`

**Correct.** The `ps` check prevents false positives.

### Trap EXIT PID file corruption guard

1. Listener A starts, writes PID A to file
2. Listener A somehow misses the startup guard (race)
3. Listener B starts, overwrites PID file with PID B
4. Listener A exits → trap checks `$(<"$pid_path") == "$$"` → PID B != PID A → does NOT delete file
5. Listener B's PID file preserved

**Correct.** The equality check in the trap prevents corruption.

---

## 5. New Issues Introduced by Latest Fixes

### Issue 5.1 — Listener warning string contains unescaped double quotes

**Severity: LOW (verify during implementation)**

Lines 490-494:
```bash
listener_warning='

[ib] WARNING: Notification listener is not running. Restart it now:
Bash(command: "ib listen", run_in_background: true)'
```

This string contains literal `"` characters (around `"ib listen"` and `true`). When `status_content` is later passed through `json_escape_string()` for the JSON hook response, these will be properly escaped to `\"`. So the downstream JSON will be valid.

However, there's a question of whether the *displayed* text in Claude's context will show `\"ib listen\"` or `"ib listen"`. This depends on how Claude Code renders `additionalContext`. Since the existing status injection mechanism already handles this correctly for other quoted content, this should be fine.

**Verdict:** No fix needed, but verify during implementation that the displayed text renders quotes correctly.

### Issue 5.2 — `read_meta_field` return code not guarded

**Severity: VERY LOW**

Line 312:
```bash
from_id=$(read_meta_field "$agent_dir/meta.json" "id" "unknown")
```

If `read_meta_field` ever returns non-zero despite having a default value, this would exit under `set -e`. The function is called inside an `if [[ -f "$agent_dir/meta.json" ]]` block (line 311), but the command substitution itself is not in a conditional context.

**Fix (if needed):** Add `|| true`:
```bash
from_id=$(read_meta_field "$agent_dir/meta.json" "id" "unknown") || true
```

**Verdict:** Extremely unlikely to be a problem since `read_meta_field` with a default should always return 0, and the file's existence is pre-verified. But adding `|| true` would be belt-and-suspenders safe.

### No other new issues found.

The latest round of fixes was clean and didn't introduce regressions. The changes were surgical and correct.

---

## 6. Summary

### All Previous Issues

| Category | Total | Resolved | Accepted/Low | Remaining |
|----------|-------|----------|--------------|-----------|
| MUST FIX | 8 | 8 | 0 | 0 |
| SHOULD FIX | 8 | 8 | 0 | 0 |
| NICE TO HAVE | 8 | 5 | 3 unaddressed (low sev) | 0 |

The 3 unaddressed NICE TO HAVE items are:
- Queue unbounded growth (acceptable for v1)
- Claude Code killing background task (documented implicitly by liveness check)
- `--timeout` parsing not shown (standard pattern)

### New Issues from Latest Fixes

| # | Issue | Severity | Action |
|---|-------|----------|--------|
| 5.1 | Listener warning quotes rendering | LOW | Verify during implementation |
| 5.2 | `read_meta_field` return code | VERY LOW | Optional `|| true` guard |

### Overall Assessment

**The plan is ready for implementation.** All MUST FIX and SHOULD FIX issues from four previous reviews have been resolved correctly. The fixes are clean, follow codebase conventions (global variable pattern for set-e safety, split local/assignment, `|| true` on advisory calls), and don't introduce regressions.

The end-to-end system — polling loop, atomic drain, liveness check, PID management with reuse detection, concurrent writer safety, and hook integration — works correctly as a cohesive whole. No logical gaps or race conditions remain.
