# Code Quality & Safety Review — notification-plan.md

Reviewer: agent-a0bd21e7
Date: 2026-02-17

---

## 1. Duplicate Code / Logic That Should Use a Shared Helper

### Issue 1.1 — `json_escape_notify()` duplicates `json_escape_string()`

**Severity: MUST FIX**

The plan proposes a new function (lines 106–114):

```bash
json_escape_notify() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}
```

The existing `json_escape_string()` in `ib` (lines 407–421) does the **exact same escaping** with the same logic and order. The only difference is `echo "$str"` vs `printf '%s' "$str"` — and `printf '%s'` is strictly better (avoids `-e` interpretation risk on some shells, no trailing newline).

**Fix:** Delete `json_escape_notify()` entirely. Replace all calls with `json_escape_string()`.

### Issue 1.2 — Manual JSON string construction instead of using `json_object()`

**Severity: SHOULD FIX**

The plan (line 316) constructs JSON by hand:

```bash
local json_line="{\"ts\":\"$ts\",\"from\":\"$from_id\",\"type\":\"$msg_type\",\"msg\":\"$escaped_msg\"}"
```

The codebase already has `json_object()` (ib line 447) which safely builds JSON objects from key-value pairs with proper escaping. Manual JSON construction is error-prone — if any field contains unescaped characters, the JSON breaks silently.

**Fix:** Use the existing helper:

```bash
local json_line
json_line=$(json_object "ts" "$ts" "from" "$from_id" "type" "$msg_type" "msg" "$message")
```

This also eliminates the need for a separate `json_escape_notify()` / `json_escape_string()` call since `json_object()` handles escaping internally via `json_escape()`.

**Note:** `json_object()` calls `json_escape()` which uses either `jq` or `osascript` — both spawn subprocesses. Since `ib notify` runs once per agent state change (not in a hot render loop), this overhead is acceptable and trades ~50ms for correctness. If profiling shows otherwise, the manual approach with `json_escape_string()` is the fallback.

### Issue 1.3 — `is_listener_alive()` PID file read pattern is reused

**Severity: NICE TO HAVE**

The PID-file-read-then-kill-0 pattern appears in both `is_listener_alive()` (lines 328–341) and the `cmd_nuke()` cleanup snippet (lines 661–668). Both do: read PID from file, `kill -0`/`kill` the PID, `rm -f` the file. This is a minor duplication — the nuke cleanup is simple enough that extraction isn't strictly needed, but if more PID-file consumers appear, a shared `check_and_kill_pidfile()` helper would be warranted.

**Fix:** No change needed for v1. Note for future refactoring.

---

## 2. `set -e` Safety

### Issue 2.1 — `cmd_notify()` argument parsing missing `shift` after bare `*)`

**Severity: MUST FIX**

In the argument parser (lines 269–275):

```bash
            *)
                if [[ -z "$message" ]]; then
                    message="$1"
                else
                    message="$message $1"
                fi
                shift
                ;;
```

The `[[ -z "$message" ]]` is inside an `if` block, so it is safe from `set -e`. However, there is a subtler problem: the `while [[ $# -gt 0 ]]` loop (line 251) uses `shift 2` for `--from` and `--type`, but if `--from` or `--type` is the **last** argument (no value given), `shift 2` will fail because there's only 1 argument left. Under `set -e`, this would crash.

**Fix:** Add argument count validation before `shift 2`:

```bash
            --from)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --from requires a value" >&2
                    exit 1
                fi
                from_id="$2"
                shift 2
                ;;
```

Same for `--type`.

### Issue 2.2 — `local var=$(cmd)` pattern in `cmd_notify()`

**Severity: MUST FIX**

Line 313:

```bash
    local escaped_msg
    escaped_msg=$(json_escape_notify "$message")
```

This is **already correctly split** — the declaration and assignment are on separate lines. Good. However, there's another instance at line 309:

```bash
    local ts
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
```

Also correctly split. No issue here — just confirming the plan follows the pattern.

### Issue 2.3 — `is_listener_alive()` returns 1 outside an `if` block

**Severity: MUST FIX**

Lines 338–339:

```bash
    fi
    return 1  # not alive
```

If `is_listener_alive` is called outside an `if` block (e.g., bare call or in `[[ ]] && action` pattern), the `return 1` triggers `set -e` and crashes the script. The plan's own usage at line 438 is:

```bash
if ! is_listener_alive; then
```

This is safe. But the function is a public helper — any future caller who writes `is_listener_alive && echo "alive"` will crash the script when the listener is dead, because the `&&` short-circuits and the overall expression returns 1.

**Fix:** Document that this function must only be called inside `if`/`while` blocks, or change callers to always use `if` form. The plan's current usage is correct, but add a comment to the function:

```bash
# NOTE: Must be called inside if/while due to set -e (returns 1 when not alive)
is_listener_alive() {
```

### Issue 2.4 — `kill -0 "$pid"` without `|| true` and outside `if`

**Severity: SHOULD FIX (potential issue)**

Line 334:

```bash
        if kill -0 "$pid" 2>/dev/null; then
```

This is inside an `if` block — safe. The plan's `set -e` safety section (line 540) confirms this. No issue.

### Issue 2.5 — No `set -e` issue in listener loop

The `while [[ ]]` and `if [[ -s ]]` patterns are all used as loop/conditional tests. The `sleep` command always returns 0. The arithmetic `$((elapsed + poll_interval))` is an assignment, not `(( ))`. All safe.

**No issues found in the listener loop.**

---

## 3. Variable Quoting / Command Injection

### Issue 3.1 — Unquoted `$$` in drain file path

**Severity: SHOULD FIX**

Line 220:

```bash
    local drain_file="$notify_dir/queue.drain.$$"
```

`$$` expands to the PID (a number), so it's safe from word splitting. However, `$notify_dir` could theoretically contain spaces. The full variable is inside double quotes, so this is actually fine.

**No issue — correctly quoted.**

### Issue 3.2 — `from_id` is user-controlled and injected into JSON

**Severity: SHOULD FIX**

In `cmd_notify()`, the `--from` value (line 254) is user-supplied and goes directly into the JSON line (line 316):

```bash
local json_line="{\"ts\":\"$ts\",\"from\":\"$from_id\",\"type\":\"$msg_type\",\"msg\":\"$escaped_msg\"}"
```

The `from_id` value is **not escaped**. If someone calls `ib notify --from 'foo","evil":"inject' "msg"`, the JSON is corrupted:

```json
{"ts":"...","from":"foo","evil":"inject","type":"status","msg":"msg"}
```

This allows arbitrary JSON field injection in the notification queue.

**Fix:** Escape `from_id` and `msg_type` the same way as `message`:

```bash
local escaped_from
escaped_from=$(json_escape_string "$from_id")
local escaped_type
escaped_type=$(json_escape_string "$msg_type")
```

Or better — use `json_object()` which escapes all string fields automatically (see Issue 1.2).

### Issue 3.3 — `msg_type` is not validated

**Severity: SHOULD FIX**

The `--type` argument (line 258) accepts any string. The plan says only `complete`, `waiting`, and `question` are valid (line 86), but there's no validation. While this is a minor concern (it's an internal tool, not a public API), a simple validation prevents typos and unexpected behavior:

```bash
case "$msg_type" in
    complete|waiting|question|status) ;;
    *)
        echo "Error: unknown type: $msg_type (expected: complete, waiting, question)" >&2
        exit 1
        ;;
esac
```

### Issue 3.4 — `ts` from `date` command is safe

The timestamp on line 309 comes from `date +%Y-%m-%dT%H:%M:%S%z`. This format produces only digits, colons, hyphens, plus signs, and the letter T. No injection risk.

**No issue.**

---

## 4. Functions That Do Too Much / Should Be Split

### Issue 4.1 — `cmd_notify()` has reasonable complexity

**Severity: No issue**

`cmd_notify()` does: argument parsing, auto-detect sender, format JSON, append to file. This is straightforward and each step is simple. No need to split.

### Issue 4.2 — `cmd_listen()` has reasonable complexity

**Severity: No issue**

`cmd_listen()` does: parse timeout arg, set up PID file + trap, poll loop, timeout message. `drain_and_print()` is already extracted. Clean separation.

### Issue 4.3 — Hook integration keeps changes minimal

**Severity: No issue**

The plan adds `ib notify` calls alongside existing `ib send` calls in hooks. This is additive and doesn't bloat the existing functions.

---

## 5. Dead Code / Unused Variables / Unnecessary Complexity

### Issue 5.1 — Default type `"status"` is not in the documented types

**Severity: SHOULD FIX**

Line 249:

```bash
    local from_id="" msg_type="status" message=""
```

The default type is `"status"`, but the documented types (line 86) are: `complete`, `waiting`, `question`. The `status` type is never mentioned in the plan. Callers always pass `--type` explicitly in the hook integration (lines 365, 369, 376, 379, 389).

**Fix:** Either:
- Add `status` to the documented types, or
- Remove the default and require `--type` to be specified (better — prevents accidental omission)

### Issue 5.2 — Listener warning string has quoting issues

**Severity: MUST FIX**

Lines 443–444:

```bash
        listener_warning='\n\n[ib] WARNING: Notification listener is not running. Restart it now:\nBash(command: \"ib listen\", run_in_background: true)'
```

This is single-quoted, so `\n` is literal two characters (backslash + n), not a newline. And `\"` is literal backslash + quote. When this string is later appended to `status_content` and passed through `json_escape_string()` for the hook response, the literal backslashes will be double-escaped, producing garbled output.

**Fix:** Use `$'...'` quoting or real newlines:

```bash
        listener_warning=$'\n\n[ib] WARNING: Notification listener is not running. Restart it now:\nBash(command: "ib listen", run_in_background: true)'
```

Or build with actual newlines:

```bash
        listener_warning="

[ib] WARNING: Notification listener is not running. Restart it now:
Bash(command: \"ib listen\", run_in_background: true)"
```

### Issue 5.3 — Integration test uses `/tmp` without cleanup on failure

**Severity: NICE TO HAVE**

Line 587–603: The integration test writes to `/tmp/listen-output.$$` and cleans up at the end, but if the test script is killed between creation and cleanup, the temp file persists.

**Fix:** Add a trap at the top of the integration test:

```bash
trap 'rm -f /tmp/listen-output.$$' EXIT
```

### Issue 5.4 — `count_active_agents` referenced but not defined

**Severity: SHOULD FIX**

Line 441:

```bash
    agent_count=$(count_active_agents)  # existing helper or simple ls count
```

The comment says "existing helper or simple ls count" — but `count_active_agents` does not exist in the codebase (confirmed via grep). The implementation plan needs to either define this function or specify the inline logic (e.g., `ls "$ROOT_REPO_PATH/$ITTYBITTY_DIR/agents/" 2>/dev/null | wc -l`).

**Fix:** Define the implementation. A simple approach:

```bash
local agent_dirs
agent_dirs=("$ROOT_REPO_PATH/$ITTYBITTY_DIR/agents"/*)
local agent_count=${#agent_dirs[@]}
```

Or use an existing mechanism if the codebase has one for listing active agents.

---

## Summary

| # | Issue | Severity | Category |
|---|-------|----------|----------|
| 1.1 | `json_escape_notify()` duplicates `json_escape_string()` | MUST FIX | Duplication |
| 1.2 | Manual JSON construction instead of `json_object()` | SHOULD FIX | Duplication |
| 2.1 | `shift 2` crash on missing `--from`/`--type` value | MUST FIX | `set -e` safety |
| 2.3 | `is_listener_alive()` needs caller guidance for `set -e` | MUST FIX | `set -e` safety |
| 3.2 | `from_id` and `msg_type` not JSON-escaped — injection risk | SHOULD FIX | Injection |
| 3.3 | `msg_type` not validated against known types | SHOULD FIX | Input validation |
| 5.1 | Default type `"status"` undocumented / not in type list | SHOULD FIX | Dead code |
| 5.2 | Listener warning string single-quote escaping will garble output | MUST FIX | Quoting |
| 5.4 | `count_active_agents` referenced but not defined | SHOULD FIX | Missing code |
| 1.3 | PID file pattern minor duplication | NICE TO HAVE | Duplication |
| 5.3 | Integration test temp file not cleaned on failure | NICE TO HAVE | Cleanup |

**MUST FIX: 4 issues** — These would cause bugs, crashes, or garbled output if implemented as written.
**SHOULD FIX: 5 issues** — These are correctness/safety improvements that prevent subtle bugs.
**NICE TO HAVE: 2 issues** — Minor improvements for robustness.
