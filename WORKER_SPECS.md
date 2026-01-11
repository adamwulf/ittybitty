# Worker Agent Specifications

This document defines the specific tasks, completion criteria, and implementation details for each refactoring worker agent.

---

## Worker 1: Meta.json Reading Consolidation

### Task
Extract all `jq -r '.field // default'` patterns into a reusable `read_meta_field()` helper function.

### Completion Criteria
1. New function `read_meta_field()` exists near line 900 (with other meta-related helpers)
2. Function signature:
   ```bash
   read_meta_field() {
       local meta_file="$1"
       local field="$2"
       local default="${3:-}"
       # Returns field value or default, handles "null" as empty string
   }
   ```
3. All 20+ jq calls for meta.json reading are replaced with calls to this function
4. Script still works: `ib new-agent "test" && ib list && ib kill test --force` succeeds
5. No change in error messages or behavior

### Specific Locations to Update
- Line 160: `.manager` field
- Line 263: `.claude_pid` field
- Lines 375-390: config file reading (`.permissions.*`, `.createPullRequests`, `.maxAgents`, `.model`)
- Line 1560: `.id` field
- Line 1579: `.worker` field
- Lines 2110-2113: `.prompt`, `.manager`, `.created`, `.model` fields
- Line 2314: `.id` field
- Line 2809: `.worker` field
- Lines 2816, 2842: `.manager` field
- Line 3086: `.session_id` field
- Line 3094: `.model` field
- Line 3457: `.manager` field
- Lines 3566, 3572: `.id` field
- Line 3640: `.manager` field
- Line 4657: `.model` field from config

### Implementation Notes
- Handle both `// ""` (string default) and `// false` (boolean default)
- Strip "null" strings automatically (many locations do this)
- Add error handling: if jq fails, return default silently
- Keep function simple - no caching or complexity

### Files Changed
- `ib` (single file)

### Test Plan
1. Run `ib new-agent --name test "echo hello"`
2. Verify agent appears in `ib list` with correct metadata
3. Run `ib status test` - should show prompt, manager, etc.
4. Run `ib kill test --force`
5. Check that all metadata fields are read correctly throughout lifecycle

---

## Worker 2: Child Traversal Consolidation

### Task
Consolidate 3 different child/descendant traversal loops into unified helper functions.

### Completion Criteria
1. New helper `get_children()` exists near line 146 (with `get_unfinished_children`)
2. Function signature:
   ```bash
   get_children() {
       local manager_id="$1"
       local filter="${2:-all}"  # all|unfinished|running|waiting|complete
       # Echoes space-separated child IDs
   }
   ```
3. New helper `get_descendants_recursive()` exists below `get_children()`
4. Function signature:
   ```bash
   get_descendants_recursive() {
       local manager_id="$1"
       # Echoes all descendants (children, grandchildren, etc.) in depth-first order
   }
   ```
5. `get_unfinished_children()` is replaced by `get_children "$1" "unfinished"`
6. `cmd_nuke` child counting (line 2813) uses `get_children` + wc
7. `cmd_nuke` `get_descendants()` local function (line 2832) is replaced with call to `get_descendants_recursive()`
8. Script still works: `ib nuke` correctly identifies and kills all descendants

### Specific Locations to Update
- Lines 146-176: `get_unfinished_children()` - refactor to use `get_children`
- Lines 2813-2820: child counting in cmd_nuke - use `get_children "$TARGET_ID" "all" | wc -w`
- Lines 2832-2852: `get_descendants()` local function - replace with `get_descendants_recursive()`
- Line 2855: call `get_descendants_recursive "$TARGET_ID"` directly

### Implementation Notes
- Both functions should iterate `$AGENTS_DIR/*/` directories
- Read `.manager` field from `meta.json` to find relationships
- `get_children()` with "unfinished" filter checks state via `get_state()`
- `get_descendants_recursive()` calls itself recursively for each child
- Return results as space-separated string (bash array-friendly)

### Files Changed
- `ib` (single file)

### Test Plan
1. Create manager: `ib new-agent --manager root --name manager "WAITING"`
2. Create worker: `ib new-agent --manager manager --worker --name worker "WAITING"`
3. Verify `ib list --manager root` shows manager
4. Verify `ib list --manager manager` shows worker
5. Run `ib nuke manager --force` - should kill both manager and worker
6. Verify both agents are gone: `ib list` shows empty

---

## Worker 3: Tmux Capture Enhancement

### Task
Enhance existing `capture_tmux()` function to handle all tmux capture patterns in the codebase.

### Completion Criteria
1. Function `capture_tmux()` (line 680) is updated with new signature:
   ```bash
   capture_tmux() {
       local session="$1"
       local mode="${2:-recent}"  # recent|full|top
       local lines="${3:-20}"
       # Sets LAST_TMUX_CAPTURE global variable
   }
   ```
2. All 10 tmux capture locations use `capture_tmux()` instead of direct tmux commands
3. Modes:
   - `recent`: Last N lines (current behavior) - `-S -"$lines"`
   - `full`: All history - `-S -`
   - `top`: Top N lines - `-S - | head -N`
4. Script still works: `ib look` shows recent output correctly

### Specific Locations to Update
- Line 37: `tmux capture-pane -t "$SESSION" -p -S -` → `capture_tmux "$SESSION" "full"`
- Line 196: same pattern → `capture_tmux "$TMUX_SESSION" "full"`
- Line 697: already uses `capture_tmux` - no change needed
- Line 761: `tmux capture-pane ... | head -50` → `capture_tmux "$TMUX_SESSION" "top" 50`
- Line 792: same pattern → `capture_tmux "$TMUX_SESSION" "top" 50`
- Line 833: `tmux capture-pane -t "$TMUX_SESSION" -p -S -50` → `capture_tmux "$TMUX_SESSION" "recent" 50`
- Line 2432: `tmux capture-pane -t "$TMUX_SESSION" -p -S -` → `capture_tmux "$TMUX_SESSION" "full"`
- Line 2434: `tmux capture-pane -t "$TMUX_SESSION" -p -S -"$LINES"` → `capture_tmux "$TMUX_SESSION" "full" "$LINES"`
- Line 3377: `tmux capture-pane -t "$TMUX_SESSION" -p -S -` → `capture_tmux "$TMUX_SESSION" "full"`
- Line 5281: `tmux capture-pane -t "$tmux_session" -p -S -"$capture_lines"` → `capture_tmux "$tmux_session" "recent" "$capture_lines"`

### Implementation Notes
- Keep existing cache logic (lines 685-693) unchanged
- Add mode handling after cache check
- For "full" mode: `LAST_TMUX_CAPTURE=$(tmux capture-pane -t "$session" -p -S - 2>/dev/null) || true`
- For "top" mode: `LAST_TMUX_CAPTURE=$(tmux capture-pane -t "$session" -p -S - 2>/dev/null | head -"$lines") || true`
- For "recent" mode: existing behavior (lines 697)

### Files Changed
- `ib` (single file)

### Test Plan
1. Create agent: `ib new-agent --name test "echo hello && WAITING"`
2. Wait for agent to reach WAITING state
3. Run `ib look test` - should show recent output
4. Run `ib look test -n 100` - should show more lines
5. Verify startup detection still works (top 50 lines)
6. Kill agent: `ib kill test --force`

---

## Worker 4: Agent Validation Consolidation

### Task
Extract repeated agent validation patterns into a reusable `validate_agent()` helper.

### Completion Criteria
1. New function `validate_agent()` exists near line 473 (with `resolve_agent_id`)
2. Function signature:
   ```bash
   validate_agent() {
       local id="$1"
       local require_session="${2:-false}"  # must have running tmux session?
       local require_worktree="${3:-false}" # must have worktree directory?
       # Sets global vars: AGENT_ID, AGENT_DIR, TMUX_SESSION
       # Exits with error message if validation fails
   }
   ```
3. All 11 locations that do `resolve_agent_id` + directory/session checks are updated
4. Error messages remain consistent or improve in clarity
5. Script still works: `ib status invalid-agent` shows proper error

### Specific Locations to Update
- Line 2286: cmd_send - requires session
- Line 2407: cmd_look - requires session
- Line 2490: cmd_status - requires directory
- Line 2619: cmd_diff - requires directory + worktree
- Line 2708: cmd_kill - requires directory OR session
- Line 2804: cmd_nuke - requires directory
- Line 3050: cmd_resume - requires directory
- Line 3244: cmd_merge - requires directory
- Line 3440: cmd_hook_status - requires directory
- Line 3588: cmd_log - optional resolve (handle differently)
- Line 3629: cmd_watchdog - requires directory

### Implementation Notes
- Call `resolve_agent_id "$id"` internally
- Set globals: `AGENT_ID="$resolved_id"`, `AGENT_DIR="$AGENTS_DIR/$AGENT_ID"`, `TMUX_SESSION=$(session_name "$AGENT_ID")`
- If `require_session=true`: check `tmux has-session -t "$TMUX_SESSION"`
- If `require_worktree=true`: check `[[ -d "$AGENT_DIR/repo" ]]`
- Always check: directory OR session exists (unless require_* forces one)
- Use consistent error messages: "Error: agent '$id' not found"

### Files Changed
- `ib` (single file)

### Test Plan
1. Test with valid agent: `ib new-agent --name test "WAITING"`
2. Test error cases:
   - `ib look invalid` - should error "agent not found"
   - `ib status invalid` - should error "agent not found"
   - `ib diff invalid` - should error "agent not found"
3. Test partial ID matching: `ib look te` - should match "test"
4. Test ambiguous partial: create "test2", run `ib look te` - should error "matches multiple"
5. Clean up: `ib kill test --force && ib kill test2 --force`

---

## Worker 5: Interactive Confirmation Consolidation

### Task
Extract repeated interactive confirmation patterns into a reusable `confirm_action()` helper.

### Completion Criteria
1. New function `confirm_action()` exists near line 134 (with `is_running_as_agent`)
2. Function signature:
   ```bash
   confirm_action() {
       local prompt="$1"
       local force="${2:-false}"
       local command_hint="${3:-}"  # e.g., "ib kill agent-id --force"
       # Returns: 0 if confirmed/forced, 1 if cancelled
       # Exits with error if in agent mode and not forced
   }
   ```
3. All 3 commands that do interactive confirmation are updated:
   - `cmd_kill` (lines 2721-2734)
   - `cmd_merge` (lines 3326-3339)
   - `cmd_nuke` (similar pattern)
4. Behavior unchanged: still blocks on confirmation unless --force
5. Agent mode error still triggers with helpful message

### Specific Locations to Update
- Lines 2721-2734: cmd_kill confirmation
- Lines 3326-3339: cmd_merge confirmation
- cmd_nuke confirmation (find similar pattern)

### Implementation Notes
- Check `is_running_as_agent` first
- If agent mode and not forced: echo error, echo command_hint, exit 1
- If forced: return 0 immediately
- Otherwise: `read -p "$prompt [y/N]" confirm`
- Return 0 if yes, 1 if no/cancelled
- Accept "y", "Y", "yes", "YES" (case insensitive)

### Files Changed
- `ib` (single file)

### Test Plan
1. Interactive mode:
   - `ib new-agent --name test "WAITING"`
   - `ib kill test` (without --force)
   - Type "n" - should cancel
   - `ib kill test` again, type "y" - should proceed
2. Force mode:
   - `ib new-agent --name test2 "WAITING"`
   - `ib kill test2 --force` - should skip confirmation
3. Agent mode (simulation):
   - Create agent in worktree, try to call `ib kill` without --force
   - Should error with hint to use --force

---

## Worker 6: Git Operations Consolidation

### Task
Extract repeated git worktree operations into reusable helper functions.

### Completion Criteria
1. New function `check_worktree_clean()` exists near line 517 (with git helpers)
2. Function signature:
   ```bash
   check_worktree_clean() {
       local worktree_path="$1"
       local agent_id="$2"  # for error messages
       # Returns: 0 if clean, exits with error if uncommitted changes
   }
   ```
3. New function `remove_agent_worktree()` exists below `check_worktree_clean()`
4. Function signature:
   ```bash
   remove_agent_worktree() {
       local agent_id="$1"
       local agent_dir="$2"
       local quiet="${3:-}"
       # Removes worktree and deletes branch, with error handling
   }
   ```
5. New function `merge_agent_branch()` exists below `remove_agent_worktree()`
6. Function signature:
   ```bash
   merge_agent_branch() {
       local agent_id="$1"
       local branch_name="$2"
       local target_branch="$3"
       # Performs checkout + merge with error handling, returns commit count
   }
   ```
7. All git operations in teardown, merge, resume use these helpers
8. Script still works: `ib merge` handles conflicts correctly

### Specific Locations to Update
- Lines 3276-3282: check_worktree_clean in cmd_merge
- Lines 215-225: remove_agent_worktree in teardown_agent
- Lines 3347-3372: merge_agent_branch in cmd_merge
- Lines 3399-3408: remove_agent_worktree in cmd_merge (redundant with teardown)
- Similar patterns in cmd_resume (check for uncommitted changes)

### Implementation Notes
- `check_worktree_clean`: check `git -C "$worktree_path" status --porcelain`
- If dirty: show `git status --short`, suggest commit or `ib send`, exit 1
- `remove_agent_worktree`: call `git worktree remove --force`, then `git branch -D`
- Handle errors gracefully: manual rm -rf if worktree remove fails
- `merge_agent_branch`: checkout target, merge source, return commit count
- Log all operations via `log_agent` for debugging

### Files Changed
- `ib` (single file)

### Test Plan
1. Clean merge:
   - `ib new-agent --name test "echo 'test' > test.txt && git add test.txt && git commit -m 'test' && I HAVE COMPLETED THE GOAL"`
   - Wait for completion
   - `ib merge test --force` - should succeed
2. Dirty worktree:
   - `ib new-agent --name test2 "echo 'test' > test2.txt"`
   - `ib merge test2` - should error "uncommitted changes"
3. Cleanup: `ib kill test2 --force`

---

## Worker 7: Argument Parsing Consolidation

### Task
Create a reusable argument parser to eliminate duplicated parsing loops across all commands.

### Completion Criteria
1. New function `parse_command_args()` exists near top of helpers section (line 25)
2. Function signature:
   ```bash
   parse_command_args() {
       local -n options_ref=$1     # associative array of allowed options
       local -n positional_ref=$2  # indexed array of positional arg names
       shift 2
       # Parses "$@", sets globals for each option/positional
       # Handles --help, unknown options, validates required args
   }
   ```
3. All 13 `cmd_*` functions use this parser instead of manual loops
4. Help text generation is standardized or kept per-command
5. Error messages are consistent across commands
6. Script still works: all commands parse args correctly

### Specific Locations to Update
All argument parsing blocks in:
- cmd_new_agent (line 1460)
- cmd_list (line 2038)
- cmd_send (line 2228)
- cmd_look (line 2357)
- cmd_status (line 2446)
- cmd_diff (line 2574)
- cmd_kill (line 2662)
- cmd_nuke (line 2752)
- cmd_resume (line 3002)
- cmd_merge (line 3186)
- cmd_log (line 3515)
- cmd_watchdog (line 3599)
- cmd_tree (line 3815)
- cmd_watch (line 3875)

### Implementation Notes
**COMPLEXITY WARNING:** This is the largest refactoring - consider breaking into 2 phases:
- Phase 1: Create parser, migrate 2-3 simple commands (look, status, diff)
- Phase 2: Migrate remaining commands

Parser should:
- Accept options map: `["--force"]="FORCE" ["--into"]="TARGET_BRANCH"`
- Accept positional names: `["ID" "MESSAGE"]`
- Loop through `"$@"`, match options, collect positionals
- Set global variables for each option/positional
- Handle `--help` by returning special code (let command show help)
- Validate required positionals at end
- Return 0 on success, >0 on error (let command handle exit)

### Files Changed
- `ib` (single file)

### Test Plan
1. Test all commands with valid args:
   - `ib new-agent "test"`
   - `ib list`
   - `ib send test "message"`
   - `ib look test`
   - etc.
2. Test error cases:
   - `ib kill` (missing ID)
   - `ib send test` (missing message)
   - `ib look --invalid-option`
3. Test --help on all commands
4. Test --force flag on kill/merge/nuke

---

## General Guidelines for All Workers

### Before Starting
1. Read the full `ib` script to understand context
2. Identify all locations listed in your spec
3. Document current behavior (error messages, edge cases)

### During Implementation
1. Create helper function first, test in isolation if possible
2. Update ONE caller at a time, test after each change
3. Keep error messages identical or improve clarity
4. Add comments explaining helper function purpose

### After Completion
1. Run full test plan from your spec
2. Run additional smoke tests: `ib new-agent "test" && ib list && ib look test && ib kill test --force`
3. Check that all locations listed in spec are updated
4. Search for any remaining instances of old pattern (use grep)

### Completion Signal
When done, output:
```
I HAVE COMPLETED THE GOAL
```

DO NOT complete until:
- All locations updated
- All tests pass
- No remaining duplicates of old pattern
- Script still behaves correctly
