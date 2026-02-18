# Reviewer 1: Integration & Completeness

## (1) Placement Guidance — Line Number Accuracy

### `cmd_notify()` placement: "After `cmd_log()` at ~line 13812"

- **ACCURATE.** `cmd_log()` ends at line 13812. `cmd_ask()` begins at line 13818. Placing `cmd_notify()` between them (after line 13812, before line 13814's section comment) is correct and makes sense — notification is a sibling of logging.

### `cmd_test_notify_format()` placement: "After `cmd_test_questions()` at ~line 11256"

- **ACCURATE.** `cmd_test_questions()` ends at line 11256. `cmd_test_filter_questions()` begins at line 11264. The plan says "after existing test commands (~line 11256, after `cmd_test_questions()`)" — this is the right spot if grouping with question-related tests. However, the plan also says "after `cmd_test_questions()`" but then the dispatcher section says "after `test-json-array-contains)` at ~line 23458" which is a completely different location in the dispatcher. **The function placement and dispatcher placement are independent and both are correct** — functions can live anywhere before the dispatcher.

### Status injection hook: "lines ~13039-13073 of ib script"

- **ACCURATE.** The `agent_count` variable is computed at lines 13039-13044, and the agent state counting loop runs 13060-13073. The plan correctly references these.

### Dispatcher entries: "`log)` entry at ~line 23497"

- **OFF BY 3.** The `log)` entry is at line 23494, not 23497. The `;;` terminator is at ~23497. The `ask)` entry immediately follows at line 23498. Minor discrepancy but functionally correct — inserting `notify)` and `listen)` between `log)` block and `ask)` is the right location.

### Dispatcher entries: "`test-json-array-contains)` at ~line 23458"

- **OFF BY 3.** `test-json-array-contains)` is at line 23455 with its `;;` at line 23458. `test-agent-worktree)` starts at line 23459. Functionally correct placement.

**Verdict: All placement guidance is accurate within ±3 lines. All surrounding function names are correct.**

## (2) Dispatcher Entries

### Pattern check against existing dispatcher

Existing pattern (e.g., lines 23494-23501):
```bash
    log)
        shift
        cmd_log "$@"
        ;;
    ask)
        shift
        cmd_ask "$@"
        ;;
```

Plan's proposed entries:
```bash
    notify)
        shift
        cmd_notify "$@"
        ;;
    listen)
        shift
        cmd_listen "$@"
        ;;
```

- **CORRECT.** Exact same pattern: `command)` / `shift` / `cmd_function "$@"` / `;;`.

Plan's proposed test entries:
```bash
    test-notify-format)
        shift
        cmd_test_notify_format "$@"
        ;;
    test-notify-drain)
        shift
        cmd_test_notify_drain "$@"
        ;;
```

- **CORRECT.** Matches existing test dispatcher entries exactly (e.g., `test-questions)` at line 23387).

**Verdict: Dispatcher entries are correct and consistent.**

## (3) Test Command Function Bodies — Pattern Comparison

### Compared against: `cmd_test_format_age()` (line 9986) and `cmd_test_questions()` (line 11199)

#### Argument parsing pattern

| Aspect | `cmd_test_format_age` | `cmd_test_questions` | Plan's `cmd_test_notify_format` | Match? |
|--------|----------------------|---------------------|-------------------------------|--------|
| `while [[ $# -gt 0 ]]` loop | Yes | Yes | Yes | OK |
| `-h\|--help` with heredoc | Yes | Yes | Yes | OK |
| `-*` unknown option rejection | Yes | Yes | Yes | OK |
| `*` positional arg capture | Yes | Yes | Yes | OK |
| `shift` on positional | Yes (implicit via loop) | Yes | Yes | OK |

#### Error handling pattern

| Aspect | Existing | Plan | Match? |
|--------|----------|------|--------|
| Missing file check | `echo "Error: ..." >&2; exit 1` | Same | OK |
| File not found check | `echo "Error: file not found: $input_file" >&2; exit 1` | Same | OK |

#### Output pattern

| Aspect | `cmd_test_format_age` | `cmd_test_questions` | Plan's functions |
|--------|----------------------|---------------------|-----------------|
| Output method | `echo` result | `echo` count | `echo` JSON line / `cat` drain output |

**ISSUE: `cmd_test_notify_format` uses `json_get` for field extraction.** The plan calls `json_get "$input" "from"` where `$input` is the raw file contents. Looking at `json_get()` (line 183), it needs verification that it works with inline JSON strings (not just file paths). The existing `json_get` signature is `json_get(json_or_file, key, default)` — when the first arg doesn't start with `-` and is not a file path, it should work with inline JSON. **This is likely fine** since `json_get` supports both modes, but worth noting.

**ISSUE: `cmd_test_notify_drain` calls `drain_and_print()` directly.** This is correct — the function is a standalone helper. However, `drain_and_print()` uses `cat` (line 231 in plan). Under `set -e`, if the drain file is empty, `cat` on an empty file returns 0, so that's fine. But the `mv` has `|| true` already. **OK.**

**ISSUE: `cmd_test_notify_drain` sets `trap 'rm -rf "$tmp_dir"' EXIT`.** If `cmd_test_notify_drain` is called within the `ib` script process (not a subshell), this trap replaces the global EXIT trap. In practice, `ib test-notify-drain <file>` runs as a top-level command that will `exit`, so the trap is fine — it's the last thing before exit. But **if `drain_and_print` were to call `exit`** (it doesn't), the trap would fire. This matches existing patterns — `cmd_test_format_age` doesn't use traps, but `cmd_listen` does. **Acceptable.**

**Verdict: Test function bodies follow existing patterns closely. Minor differences are acceptable.**

## (4) References to Functions/Variables That Don't Exist Yet

### `json_escape_string` — line 407
- **EXISTS.** Confirmed at line 407. Plan's reference to "~line 407" is exact.

### `read_meta_field` — line 5846
- **EXISTS.** Confirmed at line 5846. Used in plan's `cmd_notify()` for auto-detect sender.

### `require_git_repo` — line 3657
- **EXISTS.** Confirmed at line 3657. Sets `ROOT_REPO_PATH`, `AGENTS_DIR`, `ARCHIVE_DIR`.

### `ROOT_REPO_PATH` — line 18
- **EXISTS.** Declared at line 18, populated by `require_git_repo()` at line 3639.

### `ITTYBITTY_DIR` — line 11
- **EXISTS.** Defined at line 11 as `${ITTYBITTY_DIR:-.ittybitty}`.

### `drain_and_print` — defined in plan
- **DOES NOT EXIST YET.** Defined in the plan as a new function. This is expected — Phase 1 creates it. The plan correctly identifies it as new and provides the full implementation.

### `is_listener_alive` — defined in plan
- **DOES NOT EXIST YET.** Defined in the plan as a new function. This is expected — Phase 1 creates it.

### `agent_count` variable in `cmd_hooks_inject_status`
- **EXISTS.** Confirmed at line 13039: `local agent_count=0` with the loop at lines 13040-13044. The plan's comment "NOTE: $agent_count is already computed earlier" is accurate. The plan correctly says "Do NOT call a separate count_active_agents helper — it doesn't exist" — `count_agents()` exists (line 3397) but it's a different function that counts via a loop, not the local variable in `cmd_hooks_inject_status`.

### `json_get` — used in test function
- **EXISTS.** Confirmed at line 183.

### `get_unfinished_children` — referenced indirectly in Stop hook section
- **EXISTS** (used at line 9273 in current code). Plan references existing code correctly.

**Verdict: All referenced functions/variables either exist or are explicitly created by the plan. No phantom references.**

## (5) Implementation Order — Phase Independence

### Phase 1: Core Commands (standalone, testable)

1. `cmd_notify()` — Only depends on: `json_escape_string` (exists), `read_meta_field` (exists), `require_git_repo` (exists). **Self-contained.**

2. `is_listener_alive()` — Only depends on: `ROOT_REPO_PATH` / `ITTYBITTY_DIR` (exist). **Self-contained.**

3. `cmd_listen()` + `drain_and_print()` — Depends on: `is_listener_alive` (created in step 2), `require_git_repo` (exists). **Depends on step 2 being done first, which the plan correctly orders.**

4. Manual testing — Depends on steps 1-3. **Correct order.**

### Phase 2: Hook Integration

5. Modify `cmd_hooks_agent_status()` — Adds `ib notify` calls. Since `cmd_notify` is created in Phase 1, this works. The `|| true` guards prevent hook breakage if `ib notify` fails. **Correct dependency.**

6. Modify `cmd_ask()` — Adds `ib notify` call. Same dependency on Phase 1. **Correct.**

7. Modify `cmd_hooks_inject_status()` — Adds `is_listener_alive()` call. Created in Phase 1 step 2. **Correct.**

8. Modify `get_ittybitty_instructions()` — Documentation-only change. No code dependency. **Correct.**

### Phase 3: Tests

9-12. Test commands and fixtures — Depend on `cmd_notify`, `drain_and_print`, `json_get` all existing. **Correct order after Phase 1.**

### Phase 4: Cleanup

13-16. Cleanup, help, docs — No dependencies beyond Phases 1-3. **Correct.**

**ISSUE: Within Phase 1, the plan says step 2 (`is_listener_alive`) should be placed "immediately before `drain_and_print()`" and step 3 creates `drain_and_print` + `cmd_listen`. But the placement table says `is_listener_alive` goes before `drain_and_print` which goes before `cmd_listen`. This means all three functions are created in steps 2-3 and placed together. If someone implements step 2 alone, `is_listener_alive` references `$ROOT_REPO_PATH` which is only set after `require_git_repo()` is called. The function itself doesn't call `require_git_repo()` — it relies on the caller having called it. This is fine because `cmd_listen()` calls `require_git_repo()` before `is_listener_alive()`, and `cmd_hooks_inject_status()` also calls `require_git_repo()` (via the main startup path). But `is_listener_alive()` should document this assumption.**

**Verdict: Implementation order is correct. Each phase works standalone before the next begins.**

## Summary

| Check | Status | Notes |
|-------|--------|-------|
| Line numbers accurate? | PASS | All within ±3 lines, all surrounding functions correct |
| Dispatcher entries correct? | PASS | Exact match with existing patterns |
| Test function patterns match? | PASS | Minor acceptable differences |
| Phantom references? | PASS | All referenced items exist or are explicitly created |
| Implementation order? | PASS | Correct dependency chain across all phases |

### Minor Issues Found

1. **Line numbers off by ±3** in dispatcher references (23497 vs 23494, 23458 vs 23455). Functionally harmless but could confuse a literal implementer.

2. **`is_listener_alive()` assumes `ROOT_REPO_PATH` is set** but doesn't call `require_git_repo()` itself. All callers do set it first, but the assumption should be documented in a comment.

3. **`cmd_test_notify_drain()` trap** replaces the global EXIT trap. Acceptable because it's a top-level command, but differs from simpler test commands that don't use traps.

4. **The plan's `cmd_notify` uses `read_meta_field` with `|| true`** (line 312 of plan). This is correct for `set -e` safety. The existing `cmd_hooks_agent_status` uses the same pattern (line 9171 of ib) without `|| true` but inside an `if` block. The plan's approach (outside an `if` with `|| true`) is also valid but slightly different style.

### No Blocking Issues Found

The plan integrates cleanly with the existing codebase. All references are valid, all patterns are consistent, and the implementation order is sound.
