# Review: Simplicity & Bash Compatibility

Reviewer focus: simplicity audit, Bash 3.2 compatibility, `set -e` safety, and hook injection feasibility.

---

## 1. Simplicity Audit

### `json_escape_notify()` — Duplicate of existing function

The plan proposes a new `json_escape_notify()` function (lines 106-114) that is **character-for-character identical** to the existing `json_escape_string()` at `ib:407-421`, except it uses `echo` instead of `printf '%s'`.

**Recommendation:** Drop `json_escape_notify()` entirely. Use the existing `json_escape_string()`. The only difference is `echo "$str"` vs `printf '%s' "$str"` — and `printf '%s'` is actually better (no trailing newline, no `-e` interpretation risk). Creating a second copy of the same logic is unnecessary duplication.

In `cmd_notify()`, change:
```bash
escaped_msg=$(json_escape_notify "$message")
```
to:
```bash
escaped_msg=$(json_escape_string "$message")
```

### `drain_and_print()` — Worth keeping as a function

Despite its small size, `drain_and_print()` encapsulates the atomic-mv-then-cat logic, which is a distinct operation from the polling loop. If it were inlined, `cmd_listen()` would mix polling concerns with draining concerns. **Verdict: keep it.** But it could be slightly simplified.

Current code does:
```bash
if [[ -f "$drain_file" && -s "$drain_file" ]]; then
    cat "$drain_file"
    rm -f "$drain_file"
fi
```

The `-f` check is redundant since `-s` implies the file exists. And after a successful `mv`, the file definitely exists. Simplify to:
```bash
if [[ -s "$drain_file" ]]; then
    cat "$drain_file"
fi
rm -f "$drain_file"
```

Move the `rm` outside the `if` to clean up even if the file is empty (shouldn't happen, but cleaner).

### `--timeout` argument on `ib listen` — Probably unnecessary for v1

The default of 570 seconds is well-chosen. The only user of `ib listen` is Claude's background task. Nobody will manually run `ib listen --timeout 30` in production. The test suite integration test does use `--timeout 5`, but that could just as easily be an environment variable or a shorter poll loop.

**Recommendation:** Keep `--timeout` since it's trivial to implement and useful for testing, but don't overthink the argument parsing.

### Polling interval — Consider making it a constant, not a variable

`poll_interval=2` is defined as a local variable but never parameterized. There's no `--interval` flag. Just use `sleep 2` directly in the loop. One less variable.

### `cmd_notify` auto-detection block — Duplicated pattern

Lines 286-298 of the plan duplicate the same worktree-path-to-agent-ID extraction pattern found in `cmd_log()` and `cmd_ask()`. This isn't a problem for the plan itself (it's the existing codebase pattern), but worth noting that all three use slightly different regex/sed approaches to extract the agent ID from `pwd`. The plan's version uses `[[ "$current_dir" =~ ... ]]` + `BASH_REMATCH` (consistent with best practices), which is good.

### `count_active_agents` — Not defined anywhere

The liveness check section (line 441) references `count_active_agents` with a comment "(existing helper or simple ls count)" — but **this function does not exist in the codebase**. The inject_status function counts agents with a for loop over `$AGENTS_DIR/*/`.

**Recommendation:** Don't introduce a new helper for this. Inline a simple count:
```bash
local agent_count=0
for d in "$AGENTS_DIR"/*/; do
    [[ -d "$d" && -f "$d/meta.json" ]] && agent_count=$((agent_count + 1))
done
```

Or even simpler — if the inject_status hook is already running and counting agents, the liveness check runs in that same context, so you could just check `$agent_count` from the earlier loop. But see the hook injection feasibility section below for issues with this approach.

### Overall simplicity verdict

The plan is refreshingly simple. Polling + queue file + mv drain is the right call. The scope boundaries are clear. The only real simplicity issue is the duplicated JSON escape function.

---

## 2. Bash 3.2 Compatibility

### All code snippets pass

I checked every snippet in the plan:

| Pattern | Verdict |
|---------|---------|
| `${str//\\/\\\\}` (parameter expansion) | Works in Bash 3.2 |
| `$'\n'`, `$'\r'`, `$'\t'` (ANSI-C quoting) | Works in Bash 3.2 |
| `[[ "$current_dir" =~ pattern ]]` + `BASH_REMATCH` | Works in Bash 3.2 |
| `$((elapsed + poll_interval))` | Works in Bash 3.2 |
| `echo $$ > "$pid_path"` | Works in Bash 3.2 |
| `$(<"$pid_path")` (file read) | Works in Bash 3.2 |
| `trap 'cmd' EXIT` | Works in Bash 3.2 |
| `kill -0 "$pid" 2>/dev/null` | Works in Bash 3.2 |
| `while [[ $elapsed -lt $timeout ]]` | Works in Bash 3.2 |
| `local parts=()` / array appending | Works in Bash 3.2 |
| No `declare -A`, `mapfile`, `${var,,}`, `&>>`, negative indices | Correct |

### `date +%Y-%m-%dT%H:%M:%S%z` on macOS

**This works.** macOS's BSD `date` supports `%z` for timezone offset (e.g., `-0600`). Verified:
- `%Y-%m-%dT%H:%M:%S%z` produces `2026-02-17T14:30:05-0600` on macOS
- Note: this is NOT the same as `%Z` (which gives timezone abbreviation like `CST`)
- Also NOT the same as `date -Iseconds` (GNU-only flag)

The plan correctly uses `%z` throughout. No issues.

### `json_escape_notify` uses `echo` instead of `printf '%s'`

As noted in the simplicity section, the plan's `json_escape_notify()` uses `echo "$str"` which adds a trailing newline. The existing `json_escape_string()` uses `printf '%s' "$str"` which does not. Since the result is captured via `$()`, the trailing newline is stripped by command substitution in both cases, so this is functionally equivalent. But using the existing function avoids the question entirely.

**No Bash 3.2 compatibility issues found.**

---

## 3. `set -e` Safety

### `drain_and_print()` — The `mv` is protected correctly

```bash
mv "$queue_path" "$drain_file" 2>/dev/null || true
```

This is correct. If the queue file doesn't exist (race condition: another listener grabbed it first), `mv` fails, `|| true` catches it, and the subsequent `-s` check handles the empty case.

### `cmd_listen()` polling loop — Safe

```bash
while [[ $elapsed -lt $timeout ]]; do
    if [[ -s "$queue_path" ]]; then
```

Both `[[ ]]` conditions are inside `while` / `if` control flow. Safe under `set -e`.

### `sleep "$poll_interval"` — Safe

`sleep` always returns 0 unless killed by a signal. If killed, the trap handles cleanup. No issue.

### `trap 'rm -f "$pid_path"' EXIT` — Safe

`trap EXIT` works correctly under `set -e`. The `-f` flag on `rm` ensures no error if the file is already gone.

### `is_listener_alive()` — Has a subtle `set -e` issue

```bash
is_listener_alive() {
    local pid_path="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener.pid"
    if [[ -f "$pid_path" ]]; then
        local pid
        pid=$(<"$pid_path")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$pid_path"
    fi
    return 1  # not alive
}
```

**Issue:** `return 1` at the end of the function. Under `set -e`, calling `is_listener_alive` in a bare context (not inside `if`) would cause the script to exit. The plan shows it used inside `if ! is_listener_alive; then` which is safe. But if anyone ever calls it outside an `if`, it's a landmine.

**Recommendation:** Add a comment: `# MUST be called inside if/while — returns 1 on failure`

Or refactor to set a global variable (like `_GET_STATE_RESULT` pattern used elsewhere):
```bash
is_listener_alive() {
    _LISTENER_ALIVE=false
    local pid_path="$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener.pid"
    if [[ -f "$pid_path" ]]; then
        local pid
        pid=$(<"$pid_path")
        if kill -0 "$pid" 2>/dev/null; then
            _LISTENER_ALIVE=true
        else
            rm -f "$pid_path"
        fi
    fi
}
```

This follows the existing codebase pattern (see `get_state` → `_GET_STATE_RESULT`) and is completely `set -e` safe.

### `cmd_notify()` — `local` + command substitution

```bash
local escaped_msg
escaped_msg=$(json_escape_notify "$message")
```

Wait — actually the plan shows this on **one line** at line 313:
```bash
escaped_msg=$(json_escape_notify "$message")
```

But the variable is declared separately at the top? Let me recheck... No, looking again at lines 312-313:
```bash
local escaped_msg
escaped_msg=$(json_escape_notify "$message")
```

This is the correct two-line pattern that exposes the exit code. **Safe.**

However, `local ts` and `ts=$(date ...)` at lines 308-309 also use the two-line pattern. **Safe.**

### `cmd_notify()` auto-detection — `read_meta_field` could fail

```bash
from_id=$(read_meta_field "$agent_dir/meta.json" "id" "unknown")
```

If `read_meta_field` fails, this would exit the script under `set -e`. But `read_meta_field` has a default parameter ("unknown"), so it should return that instead. Need to verify `read_meta_field` always returns 0. Looking at the codebase, `read_meta_field` is likely a wrapper around `json_get` which does return 0. **Probably safe, but worth verifying during implementation.**

### Liveness check in `cmd_hooks_inject_status()` — The `if` is safe

```bash
if ! is_listener_alive; then
```

This is inside an `if` block. The `!` negation works correctly with `set -e` because the whole thing is in a conditional context. **Safe.**

### Missing `|| true` on `ib notify` calls in stop hook

The plan adds `ib notify` calls to `cmd_hooks_agent_status()`:
```bash
ib notify --from "$ID" --type complete "Agent $ID completed (worker of $manager)"
```

**Potential issue:** If `ib notify` fails for any reason (e.g., disk full, permission issue), this bare command would cause the script to exit under `set -e`. The existing `ib send` calls on the lines just above don't have `|| true` either — but `ib send` is a critical operation. `ib notify` is advisory. A notification failure should not prevent the stop hook from completing.

**Recommendation:** Add `|| true` to all `ib notify` calls in the stop hook:
```bash
ib notify --from "$ID" --type complete "Agent $ID completed (worker of $manager)" || true
```

Same for the `ib notify` in `cmd_ask()`.

---

## 4. Hook Injection Feasibility

### Will `is_listener_alive()` work from `cmd_hooks_inject_status()`?

**Yes, with caveats.** `cmd_hooks_inject_status()` calls `require_git_repo` indirectly (it references `$ROOT_REPO_PATH`, `$AGENTS_DIR`). These are initialized by `init_paths()` which runs via `require_git_repo`. Looking at the existing code, `cmd_hooks_inject_status` already uses `$AGENTS_DIR` and `$ROOT_REPO_PATH` (lines 13033-13034), so these globals are available.

`is_listener_alive()` uses `$ROOT_REPO_PATH/$ITTYBITTY_DIR/notify/listener.pid` — both `ROOT_REPO_PATH` and `ITTYBITTY_DIR` are global variables that would be set by the time `cmd_hooks_inject_status` runs. **This works.**

### Does the additionalContext format match?

The plan proposes appending to `status_content`:
```bash
status_content="${status_content}${listener_warning}"
```

Looking at `cmd_hooks_inject_status()` line 13172, the output is:
```bash
printf '    "additionalContext": "<ittybitty-status>\\n%s\\n</ittybitty-status>"\n' "$escaped_context"
```

So `status_content` gets wrapped in `<ittybitty-status>` tags. The listener warning would appear **inside** those tags, which is fine — Claude will see it in context.

**However**, there's a problem with the proposed warning format:

```bash
listener_warning='\n\n[ib] WARNING: Notification listener is not running. Restart it now:\nBash(command: \"ib listen\", run_in_background: true)'
```

This uses single quotes, so `\n` is literal two characters, not a newline. When the string is later passed through `json_escape_string()`, the `\n` literals get double-escaped. This is actually correct for JSON output — the `\n` will become a newline when Claude's JSON parser processes it. But it's confusing.

**More concerning:** The `\"` inside the single-quoted string is also literal. Since this string goes through `json_escape_string()` which escapes `"` to `\"`, the literal `\"` will become `\\\"` — which in JSON renders as `\"`, not `"`. This would produce garbled output.

**Fix:** Use the actual characters and let `json_escape_string()` handle escaping:
```bash
listener_warning=$'\n\n[ib] WARNING: Notification listener is not running. Restart it now:\nBash(command: "ib listen", run_in_background: true)'
```

Or even simpler, just set it as a plain string with a real newline:
```bash
local nl=$'\n'
listener_warning="${nl}${nl}[ib] WARNING: Notification listener is not running. Restart it now:${nl}Bash(command: \"ib listen\", run_in_background: true)"
```

Wait, but the quoting here gets tricky. Actually, the simplest approach:
```bash
listener_warning='

[ib] WARNING: Notification listener is not running. Restart it now:
Bash(command: "ib listen", run_in_background: true)'
```

Let `json_escape_string()` handle the newlines and quotes. That's what it's for.

### Will the warning actually appear in Claude's context?

Yes. The `additionalContext` field in hook output is injected into Claude's conversation context. This is the same mechanism used for `<ittybitty-status>` tags today. Claude sees the text as if it were part of the tool result.

**But:** The warning is inside `<ittybitty-status>` tags, which Claude may parse as status information rather than an actionable directive. It might be better to put it in a separate field or outside the tags. However, since this is a v1 and the mechanism works, this is a minor concern.

### Skipping agents — the CWD check

`cmd_hooks_inject_status()` at line 12946 checks:
```bash
if [[ -n "$cwd" && "$cwd" == */.ittybitty/agents/*/repo* ]]; then
    exit 0
fi
```

This means agents in worktrees skip the entire inject-status hook, including the liveness check. **This is correct behavior** — only the primary Claude needs the listener. Agents don't need it.

### `count_active_agents` doesn't exist

As noted in the simplicity section, this function doesn't exist. But in context, the liveness check runs **after** the agent counting loop (lines 13039-13073), so `$agent_count` is already available. Just use that variable directly:

```bash
if ! is_listener_alive; then
    if [[ $agent_count -gt 0 ]]; then
        ...
    fi
fi
```

This is cleaner than calling a separate function.

---

## Summary of Issues

### Must fix
1. **Drop `json_escape_notify()`** — use existing `json_escape_string()` instead
2. **`count_active_agents` doesn't exist** — use the `$agent_count` variable already computed in `cmd_hooks_inject_status()`
3. **Listener warning string quoting** — single-quoted `\n` and `\"` will double-escape through `json_escape_string()`. Use real newlines and let the escape function handle it.
4. **Add `|| true` to all `ib notify` calls** in the stop hook and `cmd_ask()` — notification failure should not kill the hook

### Should fix
5. **`is_listener_alive()` returns non-zero** — use the `_VARIABLE` result pattern (like `_GET_STATE_RESULT`) to be `set -e` safe regardless of call context
6. **Simplify `drain_and_print()` conditional** — `-f && -s` is redundant, just use `-s`

### Nice to have
7. **Remove `poll_interval` variable** — just use `sleep 2` directly
8. **Document that `--timeout` exists mainly for testing** — prevents feature creep later
