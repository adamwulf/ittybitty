# Review: Bash 3.2 Compatibility & Correctness

**Reviewer:** agent-7c609748
**Document:** notification-plan.md (v2)
**Focus:** Bash 3.2 compat, logic correctness, portability, path safety, race conditions

---

## 1. Bash 4.0+ Features

**No issues found.** The plan explicitly avoids all Bash 4.0+ features:
- No `${var,,}` / `${var^^}`
- No `declare -A`
- No `mapfile` / `readarray`
- No `&>>` or `|&`
- No `${arr[-1]}`
- No `coproc`

All parameter expansions used (`${str//pat/rep}`, `${var%%:*}`, `$((arithmetic))`) are valid in Bash 3.2. The compatibility table in the plan (line 519-533) is accurate.

---

## 2. Polling Loop Correctness on macOS Bash 3.2

### Issue 2a: `sleep` accumulates drift, `elapsed` is inaccurate

**Severity:** NICE TO HAVE

**Snippet (lines 199-209):**
```bash
local elapsed=0
while [[ $elapsed -lt $timeout ]]; do
    if [[ -s "$queue_path" ]]; then
        drain_and_print "$notify_dir" "$queue_path"
        exit 0
    fi
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
done
```

**What's wrong:** `elapsed` only tracks the `sleep` time, not the time spent in `[[ -s ]]` checks, `drain_and_print`, or shell overhead. Over 570 seconds (~285 iterations), this drift is negligible for correctness but means the actual timeout will be slightly longer than 570 seconds. This is harmless — the timeout is approximate by design (the plan says "~9.5 minutes").

**Verdict:** Acceptable as-is. No fix needed.

---

## 3. Liveness Detection (`kill -0`)

### Issue 3a: PID reuse false positive

**Severity:** SHOULD FIX

**Snippet (lines 328-340):**
```bash
is_listener_alive() {
    local pid_path="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener.pid"
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

**What's wrong:** `kill -0` only checks if a process with that PID exists and you have permission to signal it. On macOS, PIDs are recycled. If the listener exits without cleaning up (e.g., `kill -9`, machine crash), a stale PID file could reference a *different* process that now occupies that PID. `kill -0` would return true, falsely indicating the listener is alive.

In practice, this is low-risk because:
1. `trap EXIT` handles most cleanup cases (normal exit, SIGTERM, SIGINT)
2. PID reuse is unlikely within the ~10 minute timeout window
3. The worst case is that the liveness warning doesn't appear for one cycle — the listener is still dead, messages accumulate in the queue, and the next `ib listen` picks them up

**Fix:** Validate the PID belongs to an `ib listen` process. For example:
```bash
# After kill -0 succeeds, verify it's actually our listener
local cmd_check
cmd_check=$(ps -p "$pid" -o args= 2>/dev/null) || true
if [[ "$cmd_check" == *"ib listen"* ]]; then
    return 0  # alive and verified
fi
```

Alternatively, the plan could document this as a known limitation and accept it, since the consequences are benign (delayed restart, not data loss).

### Issue 3b: `kill -0` portability

**Severity:** No issue.

`kill -0` is POSIX-specified and works correctly on macOS, Linux, and all common Unix systems. The plan's assessment (line 525) is correct.

---

## 4. Hook Injection Output

### Issue 4a: The `listener_warning` string uses `\n` in single quotes

**Severity:** MUST FIX

**Snippet (lines 443-444):**
```bash
listener_warning='\n\n[ib] WARNING: Notification listener is not running. Restart it now:\nBash(command: \"ib listen\", run_in_background: true)'
```

**What's wrong:** In Bash, single-quoted strings do NOT interpret escape sequences. The literal characters `\n` will appear in the output, not newlines. The double-backslash escapes `\"` will also be literal `\"`, not actual escaped quotes.

The plan likely intends this string to be interpolated by the JSON building step downstream (since `additionalContext` is a JSON string field). However, the way it's presented is ambiguous — if this string is concatenated into `status_content` and then passed through `json_escape_string()`, the `\n` literals would be double-escaped to `\\n`.

**Fix:** Use `$'...'` syntax for actual newlines, or use `printf`, depending on how `status_content` is later serialized:

If the downstream code JSON-escapes the string:
```bash
listener_warning=$'\n\n[ib] WARNING: Notification listener is not running. Restart it now:\nBash(command: "ib listen", run_in_background: true)'
```

If the string is already being placed inside a JSON string directly (no further escaping):
```bash
listener_warning='\n\n[ib] WARNING: Notification listener is not running. Restart it now:\nBash(command: \"ib listen\", run_in_background: true)'
```

The implementer must check how `cmd_hooks_inject_status()` builds its JSON output (line 13164 of `ib` uses `json_escape_string "$status_content"`) and ensure the escaping is consistent. The plan should clarify which path is intended.

### Issue 4b: `count_active_agents` doesn't exist

**Severity:** MUST FIX

**Snippet (lines 441-442):**
```bash
local agent_count
agent_count=$(count_active_agents)  # existing helper or simple ls count
```

**What's wrong:** There is no `count_active_agents` function in the current `ib` script (verified by searching). The comment says "existing helper or simple ls count" — this is a TODO disguised as code. The implementer would need to write this.

**Fix:** The plan should specify the implementation. A simple approach:
```bash
local agent_dirs
agent_dirs=$(ls "$AGENTS_DIR" 2>/dev/null) || true
local agent_count=0
for dir in $agent_dirs; do
    if [[ -f "$AGENTS_DIR/$dir/meta.json" ]]; then
        agent_count=$((agent_count + 1))
    fi
done
```

Or even simpler, just check if the `AGENTS_DIR` has any subdirectories. The exact implementation matters for `set -e` safety.

---

## 5. File Path Safety with Spaces

### Issue 5a: All paths are properly quoted

**Severity:** No issue.

All file path variables in the plan are enclosed in double quotes:
- `"$queue_path"`, `"$pid_path"`, `"$notify_dir"`, `"$drain_file"`
- `mkdir -p "$notify_dir"`
- `mv "$queue_path" "$drain_file"`
- `cat "$drain_file"`

This is correct and handles spaces in paths.

### Issue 5b: `echo $$ > "$pid_path"` — missing quotes around `$$`

**Severity:** NICE TO HAVE

**Snippet (line 196):**
```bash
echo $$ > "$pid_path"
```

**What's wrong:** `$$` is just a number, so the missing quotes don't cause a functional issue. However, for consistency with the project's quoting conventions, it should be `echo "$$"`. This is purely cosmetic.

**Fix:** `echo "$$" > "$pid_path"`

---

## 6. Race Conditions and Edge Cases

### Issue 6a: `drain_and_print` + `cat` race with concurrent writer

**Severity:** NICE TO HAVE

**Snippet (lines 217-230):**
```bash
drain_and_print() {
    local notify_dir="$1"
    local queue_path="$2"
    local drain_file="$notify_dir/queue.drain.$$"
    mv "$queue_path" "$drain_file" 2>/dev/null || true
    if [[ -f "$drain_file" && -s "$drain_file" ]]; then
        cat "$drain_file"
        rm -f "$drain_file"
    fi
}
```

**Analysis:** The plan correctly identifies (lines 480-482) that `mv` is atomic and that writes to an already-open fd complete to the old inode. However, there's a subtle edge case: a writer could have the fd open, `mv` completes, then the writer's `echo` flushes *after* `cat` has already read the drain file. In that case, the late-written data sits in the drain file, which is then `rm -f`'d, causing message loss.

**How likely:** Very unlikely. `echo "..." >> file` on a short line is essentially atomic — the kernel write completes in microseconds. The window between `cat` starting and `rm -f` executing is also microseconds. For this to happen, a writer would need to hold an open fd across the `mv` *and* delay its write until after `cat` completes. In practice with `echo >>`, the fd is opened, written, and closed in a single shell operation.

**Verdict:** Theoretical concern only. The plan's analysis is sound. No fix needed for v1.

### Issue 6b: Multiple listeners — PID file overwrite

**Severity:** SHOULD FIX

**Snippet (lines 195-197):**
```bash
echo $$ > "$pid_path"
trap 'rm -f "$pid_path"' EXIT
```

**What's wrong:** If a second `ib listen` starts while the first is still running, it overwrites `listener.pid` with its own PID. When the *first* listener exits, its `trap EXIT` deletes the PID file — which now contains the *second* listener's PID. Now `is_listener_alive()` will report no listener because the file is gone, even though the second listener is running.

**Fix:** Before writing the PID file, check if a listener is already alive:
```bash
if is_listener_alive; then
    echo "Error: listener already running (PID $(cat "$pid_path"))" >&2
    exit 1
fi
echo "$$" > "$pid_path"
# Only remove PID file if it still contains our PID
trap 'if [[ -f "$pid_path" ]] && [[ "$(<"$pid_path")" == "$$" ]]; then rm -f "$pid_path"; fi' EXIT
```

The plan acknowledges multiple listeners in the edge cases section (line 493) as "not ideal but safe," but the PID file corruption is not mentioned. The data flow is safe (only one listener gets the `mv`), but the liveness check breaks.

### Issue 6c: No cleanup of stale `queue.drain.*` files

**Severity:** NICE TO HAVE

**Snippet (line 220):**
```bash
local drain_file="$notify_dir/queue.drain.$$"
```

**What's wrong:** If the listener is killed between `mv` and `rm -f "$drain_file"` (e.g., `kill -9`), the drain file is left behind. It's named with `$$` so it won't collide with future listeners, but it accumulates over time. These would contain already-processed (or partially-processed) messages.

**Fix:** Add cleanup of old drain files at listener startup:
```bash
# Clean up any stale drain files from previous crashes
rm -f "$notify_dir"/queue.drain.* 2>/dev/null || true
```

### Issue 6d: The plan's PIPE_BUF claim of 512 bytes on macOS

**Severity:** NICE TO HAVE

**Snippet (line 318):**
```bash
# Append to queue (>> is atomic for lines < PIPE_BUF = 512 bytes on macOS)
```

**What's wrong:** The `PIPE_BUF` constant (512 bytes) applies to writes to *pipes*, not regular files. For regular files with `O_APPEND`, POSIX guarantees that the seek+write is atomic regardless of size. So the atomicity guarantee is actually *stronger* than the plan claims. The `echo >>` to a regular file is atomic for any reasonable line length on macOS's HFS+/APFS.

That said, if the queue file were ever on NFS, `O_APPEND` atomicity is not guaranteed. This is unlikely for `.ittybitty/` which lives in the repo root.

**Verdict:** The conclusion (no corruption) is correct, but the reasoning (`PIPE_BUF`) is slightly wrong. The actual guarantee comes from `O_APPEND` semantics on regular files, not `PIPE_BUF`. This is a documentation-only issue.

### Issue 6e: `cmd_notify` argument parsing — missing `shift` in catch-all

**Severity:** MUST FIX

**Snippet (lines 269-275):**
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

**What's wrong:** Actually, this is correct — there IS a `shift` on line 275. I initially missed it but it's there. No issue.

**Updated severity:** No issue.

### Issue 6f: `json_escape_notify` duplicates existing `json_escape_string`

**Severity:** SHOULD FIX

**Snippet (lines 106-114):**
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

**What's wrong:** The `ib` script already has `json_escape_string()` (line 407) that does exactly the same thing. The plan introduces a duplicate function `json_escape_notify()` with identical logic but uses `echo` instead of `printf '%s'`.

Using `echo` instead of `printf '%s'` has a subtle bug: if the escaped string starts with `-n`, `-e`, or `-E`, `echo` will interpret it as a flag rather than printing it. `printf '%s'` avoids this.

**Fix:** Reuse the existing `json_escape_string()` function instead of creating `json_escape_notify()`. If a separate function is preferred for modularity, at minimum use `printf '%s' "$str"` instead of `echo "$str"`.

---

## Summary

| # | Issue | Severity | Category |
|---|-------|----------|----------|
| 3a | PID reuse false positive in `is_listener_alive()` | SHOULD FIX | Liveness detection |
| 4a | `listener_warning` uses single-quoted `\n` — won't produce newlines | MUST FIX | Hook injection |
| 4b | `count_active_agents` function doesn't exist | MUST FIX | Hook injection |
| 6b | Multiple listeners corrupt PID file via trap EXIT | SHOULD FIX | Race condition |
| 6f | `json_escape_notify` duplicates `json_escape_string`, uses `echo` instead of `printf '%s'` | SHOULD FIX | Code duplication / bug |
| 3b | `kill -0` portability | No issue | — |
| 5a | Path quoting | No issue | — |
| 5b | `echo $$` unquoted | NICE TO HAVE | Style |
| 6a | drain + cat race with concurrent writer | NICE TO HAVE | Theoretical |
| 6c | Stale `queue.drain.*` files after crash | NICE TO HAVE | Cleanup |
| 6d | PIPE_BUF reasoning is incorrect (should cite O_APPEND) | NICE TO HAVE | Documentation |
| 2a | sleep drift in elapsed counter | NICE TO HAVE | Precision |

**MUST FIX (2):** Listener warning string escaping, missing `count_active_agents` implementation.
**SHOULD FIX (3):** PID reuse validation, multiple-listener PID file corruption, duplicate json_escape function.
**NICE TO HAVE (4):** Minor quoting, theoretical race, stale drain files, PIPE_BUF documentation.

Overall, the plan is well-designed and thoughtful about Bash 3.2 compatibility. The polling+queue approach is simple and correct. The main gaps are in the hook injection details and PID file management.
