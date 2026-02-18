# Fresh Eyes Review: Simplicity & Clarity

Reviewer: agent-b48c13f2 (reading notification-plan.md cold)

---

## 1. Confusing or Ambiguous Passages

### 1a. "Primary Claude" vs "agents" — role context unclear early on

The Overview (line 7) says "The primary Claude spawns `ib listen` as a background bash task" but doesn't clarify where this instruction is *taught* to Claude. You have to scroll all the way to the SessionStart Hook section (line 441) to find that the instructions go into `get_ittybitty_instructions()`. A one-line forward reference ("see §SessionStart Hook for bootstrap instructions") would help.

### 1b. Liveness hook type is ambiguous (line 152)

> "the PreToolUse/PostToolUse hook injects:"

Which is it — PreToolUse or PostToolUse? The implementation section (line 474) clarifies it's `cmd_hooks_inject_status()` (PostToolUse/UserPromptSubmit), but the "What Claude Sees" section says "PreToolUse/PostToolUse" without resolving which. An implementer would be confused about which hook to modify.

### 1c. `$agent_count` provenance (lines 480-482)

The comment says `$agent_count is already computed earlier in cmd_hooks_inject_status()` with a reference to "lines ~13039-13073 of ib script." These line numbers will drift. More importantly, the variable name `agent_count` is not defined anywhere in the plan itself. An implementer must go spelunking in the existing code to discover what variable to use and what it counts (all agents? active only? running only?). The plan should define what counts and what the exact variable name is (or say "use whatever variable the existing loop provides").

### 1d. `json_get` in test function (line 852)

`cmd_test_notify_format()` uses `json_get()` to extract fields from fixture JSON. This function isn't mentioned anywhere else in the plan, and it's not in the JSON Escaping section or the "Use existing" callout for `json_escape_string()`. An implementer would need to verify `json_get()` exists and understand its behavior (does it handle nested objects? does it unescape?). If it's an existing ib helper, a brief callout like the one for `json_escape_string()` would help.

### 1e. The `drain-empty.jsonl` fixture behavior (lines 940-945)

The code says "If fixture is empty, leave queue_path missing — tests empty/missing case." But `drain_and_print()` calls `mv "$queue_path" "$drain_file"` on a non-existent file. The `|| true` swallows the error, and then `[[ -s "$drain_file" ]]` is false, so nothing prints. This works but the *intent* is unclear: are we testing "queue file doesn't exist" or "queue file exists but is empty"? These are different edge cases. The fixture is named `drain-empty.jsonl` (suggesting an empty file exists), but the test code skips creating it if empty. This mismatch could confuse an implementer.

Then line 951 checks `if [[ -f "$queue_path" ]]` and errors — but if the queue file never existed, this check passes vacuously. If the queue file *was* created but was empty, `mv` would move it, so it also wouldn't exist. Both cases pass the same way but test different things.

---

## 2. Contradictions Between Sections

### 2a. Queue file path: `listener.pid` vs `pid`

The File Paths diagram (line 65) shows:
```
├── notify/
│   ├── queue
│   └── listener.pid
```

But all code references use `listener.pid` as the variable name `pid_path` — this is consistent. **No actual contradiction**, just noting the tree diagram says `listener.pid` which matches the code.

### 2b. "What Claude Sees" timeout output vs `cmd_listen()` timeout output

"What Claude Sees" (line 145):
```
No messages received. Background listener has stopped. Please restart with: ib listen
```

`cmd_listen()` (line 215):
```
echo "No messages received. Background listener has stopped. Please restart with: ib listen"
```

**Match confirmed.** Good.

### 2c. Stop Hook table (line 396) vs code snippet (line 411-412)

The table says for "complete (root manager, no children)": `Add: ib notify --from "$ID" --type complete "Manager $ID completed its goal"`

The code snippet (line 412) shows:
```bash
ib notify --from "$ID" --type complete "Manager $ID completed its goal" || true  # NEW
```

**Match confirmed** (the `|| true` is expected for `set -e` safety).

### 2d. Stop Hook table missing "complete (manager WITH children)" case

The table at line 394 shows four states: complete-worker, complete-root-manager-no-children, waiting-worker, waiting-root-manager. But the existing Stop hook has logic for managers with unfinished children (the "... existing unfinished children check ..." comment on line 410). The plan doesn't specify whether to notify in that case. An implementer would wonder: if a manager completes but has running children, do we notify? The plan implies "no" by only mentioning "no children" but never explicitly says "skip notification if children are still running."

### 2e. No mention of "complete (non-root manager)" case

The table only covers workers and root managers. What about a mid-level manager (has a manager parent AND has workers)? Should it notify? The existing `ib send` presumably handles this, but the plan doesn't specify whether `ib notify` should also fire for non-root managers. Given the data flow diagram shows notifications going to the *primary Claude*, and a non-root manager's completion would be interesting to the primary Claude too, this seems like a gap.

---

## 3. Unnecessary Repetition

### 3a. Polling rationale stated 4 times

The "why polling not FIFO" rationale appears in:
1. Line 54 — "Why polling, not FIFO" paragraph
2. Line 237 — "Polling, not FIFO" in key design decisions
3. Lines 570-571 — Scope Boundaries table
4. Lines 960-970 — Design Rationale section

Each adds slightly different detail, but the core message ("polling is simpler, 2s latency is negligible") is repeated verbatim or near-verbatim. If any detail changes (e.g., poll interval changes from 2s to 1s), all four locations must be updated. **Recommendation:** Keep the detailed rationale in one place (the Design Rationale section at the end) and have other locations briefly reference it.

### 3b. `|| true` on `ib notify` explained in 3 places

- Line 240 ("Always exit 0")
- Line 408/419/422 (code comments)
- Line 603 (`set -e` Safety section)

The `set -e` Safety section is the canonical place. The inline code comments `# NEW` are fine, but the separate explanation at line 240 about "always exit 0" is about `cmd_listen`, not `ib notify` — this isn't really repetition, just adjacent concepts.

### 3c. Liveness mechanism described in 3 places

- Lines 152-158 (What Claude Sees section)
- Lines 470-518 (Hook Changes section — the implementation)
- Lines 525-526 (Edge Cases — "Listener not running")

The "What Claude Sees" version and the Edge Cases version are user-facing descriptions; the Hook Changes section is the implementation. This is reasonable layering, not problematic repetition.

---

## 4. Are Code Snippets Complete Enough to Implement?

### 4a. `cmd_notify()` — YES, complete and copy-pasteable

The argument parsing loop, type validation, auto-detect logic, JSON building, and atomic append are all present. The only stub is `--help` text (reasonable to leave as exercise). Good.

### 4b. `cmd_listen()` — YES, complete

Includes PID management, trap, polling loop, timeout, drain call. Ready to implement.

### 4c. `drain_and_print()` — YES, complete

Three lines of logic. Clear.

### 4d. `is_listener_alive()` — YES, complete

PID check with process name verification. Clean.

### 4e. Hook integration snippets — PARTIAL

The Stop hook snippets (lines 404-423) show where `ib notify` lines go but use `# ... existing unfinished children check ...` as a stub. An implementer must find the right insertion points in the actual code. The `# In the complete+worker branch` comment helps, but the exact location (what line? after what specific existing code?) is left to the implementer to figure out. The Placement table (line 743) gives line numbers for new functions but NOT for the hook modifications.

The liveness check snippet (lines 483-503) is complete but depends on knowing where `status_content` is defined in the existing code. The comment "line ~13172 of ib" helps but will drift.

### 4f. `cmd_test_notify_format()` — YES, complete

### 4g. `cmd_test_notify_drain()` — YES, complete

### 4h. Integration test in `tests/test-notify.sh` — PARTIAL

Only the integration test is shown (lines 649-668). The fixture-based tests (format-* and drain-*) are described in tables but no test runner code is provided. An implementer needs to write the test runner that:
- Iterates over fixtures in `tests/fixtures/notify/`
- Extracts expected behavior from filename
- Runs `ib test-notify-format` or `ib test-notify-drain`
- Compares output

The existing test pattern (from `tests/test-parse-state.sh` etc.) is well-documented in CLAUDE.md, so this is followable but not copy-pasteable.

---

## 5. Document Structure — Would I Reorder?

The current order is:
1. Overview → Data Flow → File Paths → Queue Format → What Claude Sees → Commands → Hook Changes → Edge Cases → Relationship to Existing → Scope Boundaries → Bash 3.2 → set -e → Tests → Implementation Order → Design Rationale

**One issue:** The Implementation Order (line 679) comes very late, after all the edge cases and compatibility sections. If I'm an implementer, I'd want to see the implementation order *before* diving into edge cases. I'd suggest moving the Implementation Order section to right after the Commands section (after line 376), before Hook Changes. This way the reader gets: "here's what we're building" → "here's the code" → "here's the order to build it" → "here's the hooks to modify" → "here's the edge cases."

**Minor:** The Design Rationale section at the very end feels like it should be near the top (after Overview), since it justifies the fundamental architecture. But this is a style preference — having it at the end as an appendix also works.

---

## 6. Gaps — Things an Implementer Would Need to Figure Out

### 6a. No `--help` text for `ib listen` or `ib notify`

The plan specifies `ib listen --help` should exist (line 734, Phase 4) but doesn't provide the help text content. Same for `ib notify --help` (partially sketched in cmd_notify with a `# ... help text ...` stub). The test commands have full help text but the main commands don't.

### 6b. `require_git_repo` and `ROOT_REPO_PATH` assumed but not explained

Both `cmd_listen()` and `cmd_notify()` call `require_git_repo` and use `$ROOT_REPO_PATH`. These are existing ib helpers/globals, but the plan doesn't mention them in its dependencies. An implementer unfamiliar with the codebase would need to discover these. A brief "Prerequisites: calls `require_git_repo` which sets `$ROOT_REPO_PATH`" would help.

### 6c. How does the primary Claude know to start `ib listen` initially?

The SessionStart hook section (line 441) adds instructions to `get_ittybitty_instructions()` for the `primary` role section. But the plan doesn't specify:
- What exactly is the "primary role section"?
- Is there a conditional that distinguishes primary from agents?
- Where in the function does this text get inserted?

An implementer would need to read `get_ittybitty_instructions()` to understand its structure. A brief pointer would help.

### 6d. No mention of `ib --help` integration

Line 734 says "Add to help text — `ib --help`" but doesn't specify what text to add or where in the help output it should appear. Minor, but noted.

### 6e. What happens if `ib notify` is called outside a git repo?

`cmd_notify()` calls `require_git_repo` which presumably exits with an error. This is fine but worth noting — notifications from agents will always be in a worktree (which is a git repo), so this should always succeed. But if someone calls `ib notify` from outside a repo for testing, they'd get an unhelpful error.

### 6f. The `\r` (carriage return) in the JSON escaping table (line 99)

The table says carriage return is escaped as `\r`. The plan says to use `json_escape_string()`, which presumably handles this. But it's worth verifying that `json_escape_string()` actually handles `\r` — if it only handles `\n`, `"`, and `\`, this would be a gap. The plan doesn't confirm what `json_escape_string()` currently escapes.

### 6g. Cleanup of notify directory on `ib kill` / `ib merge`

Phase 4 mentions cleanup in `cmd_nuke()` but not in `cmd_kill()` or `cmd_merge()`. Since `cmd_nuke()` is for emergency stop of all agents, what happens to the notify directory during normal kill/merge operations? It presumably persists (which is fine — the listener is per-repo, not per-agent). But this should be stated explicitly: "The notify directory persists across agent kill/merge since it belongs to the repo, not to any individual agent."

---

## Summary

**Overall quality: High.** The plan is thorough, well-structured, and the code snippets are mostly implementation-ready. The main issues are:

1. **Moderate:** The polling rationale is repeated 4 times — consolidate to reduce sync risk.
2. **Moderate:** Mid-level manager notification behavior is unspecified (only workers and root managers are covered in the Stop Hook table).
3. **Minor:** The "PreToolUse/PostToolUse" ambiguity in the "What Claude Sees" section — should just say "PostToolUse/UserPromptSubmit."
4. **Minor:** `json_get()` and `require_git_repo` / `ROOT_REPO_PATH` are used without introduction.
5. **Minor:** The `drain-empty.jsonl` test conflates "file missing" and "file empty" cases.
6. **Minor:** Implementation Order section would be better placed earlier in the document.
7. **Nitpick:** Line number references (e.g., "~line 13039") will drift and become misleading.
