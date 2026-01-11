# ib Code Duplication Refactoring Plan

## Executive Summary

After analyzing the `ib` script (~3900 lines), I've identified 7 major categories of code duplication that can be refactored to improve maintainability while keeping the codebase easy to understand and modify.

## Duplication Categories

### 1. **Command Argument Parsing** (HIGH IMPACT)
**Problem:** 13 commands have nearly identical argument parsing loops with:
- `while [[ $# -gt 0 ]]` loop
- `case "$1" in` with `--help`, `--force`, etc.
- ID validation (`if [[ -z "$ID" ]]`)
- Error handling for unknown options/arguments

**Locations:** All `cmd_*` functions (~lines 1460, 2038, 2228, 2357, 2446, 2574, 2662, 2752, 3002, 3186, 3515, 3599, 3815, 3875)

**Examples:**
```bash
# Pattern repeated in cmd_send, cmd_look, cmd_status, cmd_diff, cmd_kill, cmd_merge, etc.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) cat <<EOF ... EOF; exit 0 ;;
        --force) FORCE=true; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) if [[ -z "$ID" ]]; then ID="$1"; else echo "Unknown argument: $1" >&2; exit 1; fi; shift ;;
    esac
done
if [[ -z "$ID" ]]; then echo "Error: agent ID required" >&2; exit 1; fi
```

**Proposed Solution:**
Create `parse_command_args()` helper that takes:
- Allowed options (e.g., `--force`, `--into`, `--manager`)
- Required/optional positional args (e.g., `ID`, `MESSAGE`)
- Help text
Returns: parsed values in global vars or associative array

**Benefits:**
- Reduces ~400 lines of duplicated parsing code
- Standardizes error messages across commands
- Makes adding new commands easier

---

### 2. **Agent Validation & Resolution** (MEDIUM-HIGH IMPACT)
**Problem:** 11 commands repeat the same pattern:
1. `ID=$(resolve_agent_id "$ID") || exit 1`
2. `AGENT_DIR="$AGENTS_DIR/$ID"`
3. Check if agent exists (directory or tmux session)
4. Different validation messages per command

**Locations:** Lines 2286, 2407, 2490, 2619, 2708, 2804, 3050, 3244, 3440, 3588, 3629

**Examples:**
```bash
# cmd_look
ID=$(resolve_agent_id "$ID") || exit 1
AGENT_DIR="$AGENTS_DIR/$ID"
TMUX_SESSION=$(session_name "$ID")
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "Error: agent '$ID' not running" >&2; exit 1
fi

# cmd_status
ID=$(resolve_agent_id "$ID") || exit 1
AGENT_DIR="$AGENTS_DIR/$ID"
if [[ ! -d "$AGENT_DIR" ]]; then
    echo "Error: agent '$ID' not found" >&2; exit 1
fi
```

**Proposed Solution:**
Create `validate_agent()` helper:
```bash
validate_agent() {
    local id="$1"
    local require_session="${2:-false}"  # needs tmux?
    local require_worktree="${3:-false}" # needs worktree?

    # Resolve, set AGENT_ID, AGENT_DIR, TMUX_SESSION globals
    # Exit with error if validation fails
}
```

**Benefits:**
- Reduces ~150 lines of duplicated validation
- Centralizes agent existence checks
- Easier to add new validation requirements

---

### 3. **Interactive Confirmation Prompts** (MEDIUM IMPACT)
**Problem:** `cmd_kill`, `cmd_merge`, `cmd_nuke` all have identical:
- `--force` flag handling
- Agent mode detection (`is_running_as_agent`)
- Interactive `read -p` prompts
- Yes/no validation

**Locations:** Lines 2721-2734 (kill), 3326-3339 (merge), similar in nuke

**Examples:**
```bash
if [[ "$FORCE" != true ]]; then
    if is_running_as_agent; then
        echo "Error: Cannot use interactive confirmation in agent mode." >&2
        echo "Use: ib kill $ID --force" >&2
        exit 1
    fi
    local confirm
    read -p "Kill agent '$ID' and remove all data? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Cancelled."; exit 0
    fi
fi
```

**Proposed Solution:**
Create `confirm_action()` helper:
```bash
confirm_action() {
    local prompt="$1"
    local force="${2:-false}"
    # Returns 0 if confirmed/forced, 1 if cancelled
    # Handles agent mode detection automatically
}
```

**Benefits:**
- Reduces ~60 lines of duplicated confirmation code
- Standardizes confirmation behavior
- Easier to improve UX (e.g., add color, timeouts)

---

### 4. **Tmux Capture Operations** (MEDIUM IMPACT)
**Problem:** 10 different locations capture tmux output with slight variations:
- Full history: `tmux capture-pane -t "$SESSION" -p -S -`
- Last N lines: `tmux capture-pane -t "$SESSION" -p -S -"$LINES"`
- With head: `tmux capture-pane ... | head -50`

**Locations:** Lines 37, 196, 697, 761, 792, 833, 2432, 2434, 3377, 5281, 5734

**Examples:**
```bash
# Full history for archiving (lines 37, 196, 3377)
tmux capture-pane -t "$SESSION" -p -S - > "$AGENT_DIR/output.log" 2>/dev/null || true

# Recent output for state detection (line 697)
LAST_TMUX_CAPTURE=$(tmux capture-pane -t "$session" -p -S "-$lines" 2>/dev/null) || true

# Top output for startup detection (lines 761, 792)
local top_output=$(tmux capture-pane -t "$TMUX_SESSION" -p -S - 2>/dev/null | head -50)
```

**Proposed Solution:**
Enhance existing `capture_tmux()` function:
```bash
capture_tmux() {
    local session="$1"
    local mode="${2:-recent}"  # recent|full|top
    local lines="${3:-20}"
    # Sets LAST_TMUX_CAPTURE (already does this)
}
```

**Benefits:**
- Consolidates tmux capture patterns
- Reduces risk of typos in tmux commands
- Already partially implemented (capture_tmux exists)

---

### 5. **Meta.json Field Reading** (MEDIUM-LOW IMPACT)
**Problem:** 20+ locations read fields from `meta.json` with identical patterns:
- `jq -r '.field // ""' "$meta_file" 2>/dev/null`
- `jq -r '.field // false'` for booleans
- Null handling: `if [[ "$VAR" == "null" ]]; then VAR=""; fi`

**Locations:** Lines 160, 263, 375-390, 1560, 1579, 2110-2113, 2314, 2809, 2816, 2842, 3086, 3094, 3457, 3566, 3572, 3640, 4657

**Examples:**
```bash
# Reading manager field
local manager=$(jq -r '.manager // ""' "$meta_file" 2>/dev/null)

# Reading worker boolean
local is_worker=$(jq -r '.worker // false' "$AGENT_DIR/meta.json" 2>/dev/null)

# Reading model with null check
CONFIG_MODEL=$(jq -r '.model // ""' "$config_file" 2>/dev/null)
if [[ "$CONFIG_MODEL" == "null" ]]; then CONFIG_MODEL=""; fi
```

**Proposed Solution:**
Create `read_meta_field()` helper:
```bash
read_meta_field() {
    local meta_file="$1"
    local field="$2"
    local default="${3:-}"
    # Returns field value or default, handles null
}
```

**Benefits:**
- Reduces ~40 lines of jq calls
- Centralizes null handling
- Easier to optimize (caching, error handling)

---

### 6. **Git Operations on Agent Worktrees** (MEDIUM-LOW IMPACT)
**Problem:** Multiple locations perform git operations on agent worktrees:
- `git -C "$WORKTREE_PATH" status --porcelain`
- `git worktree remove "$AGENT_DIR/repo" --force`
- `git branch -D "agent/$ID"`
- `git checkout`, `git merge` with error handling

**Locations:** Lines 217-224 (teardown), 3276-3282 (merge check), 3347-3372 (merge execution), 3399-3408 (cleanup)

**Examples:**
```bash
# Checking for uncommitted changes (repeated in merge, resume)
if [[ -n $(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null) ]]; then
    echo "Error: agent '$ID' has uncommitted changes:" >&2
    git -C "$WORKTREE_PATH" status --short >&2
    exit 1
fi

# Removing worktree (in teardown_agent and cmd_merge)
git worktree remove "$AGENT_DIR/repo" --force 2>/dev/null || {
    log_agent "$ID" "Warning: could not remove worktree, removing directory manually"
    rm -rf "$AGENT_DIR/repo"
}
git branch -D "agent/$ID" 2>/dev/null
```

**Proposed Solution:**
Create git operation helpers:
```bash
check_worktree_clean() { ... }
remove_agent_worktree() { ... }
merge_agent_branch() { ... }
```

**Benefits:**
- Reduces ~80 lines of git operations
- Centralizes error handling for git failures
- Easier to add logging/debugging

---

### 7. **Child/Descendant Traversal** (LOW-MEDIUM IMPACT)
**Problem:** 3 locations iterate through agents to find children/descendants:
- `get_unfinished_children()` (line 146)
- `get_descendants()` in cmd_nuke (line 2832)
- Agent counting in cmd_nuke (line 2813)

**Examples:**
```bash
# get_unfinished_children (line 146)
for agent_dir in "$AGENTS_DIR"/*/; do
    [[ -d "$agent_dir" ]] || continue
    local child_id=$(basename "$agent_dir")
    local meta_file="$agent_dir/meta.json"
    [[ -f "$meta_file" ]] || continue
    local manager=$(jq -r '.manager // ""' "$meta_file" 2>/dev/null)
    if [[ "$manager" == "$MANAGER_ID" ]]; then
        # ... check state, add to list
    fi
done

# Similar pattern in cmd_nuke for counting children
for agent_dir in "$AGENTS_DIR"/*/; do
    [[ -d "$agent_dir" ]] || continue
    [[ -f "$agent_dir/meta.json" ]] || continue
    local manager=$(jq -r '.manager // ""' "$agent_dir/meta.json" 2>/dev/null)
    if [[ "$manager" == "$TARGET_ID" ]]; then
        ((child_count++))
    fi
done
```

**Proposed Solution:**
Create unified child traversal helpers:
```bash
get_children() {
    local manager_id="$1"
    local include_state="${2:-all}"  # all|unfinished|running
    # Returns space-separated child IDs
}

get_descendants_recursive() {
    local manager_id="$1"
    # Returns all descendants in depth-first order
}
```

**Benefits:**
- Reduces ~60 lines of iteration code
- Centralizes child relationship logic
- More efficient (could cache metadata)

---

## Implementation Strategy

### Phase 1: Low-Risk Helpers (Recommended Start)
1. **Meta.json reading** (#5) - pure extraction, no behavior change
2. **Tmux capture consolidation** (#4) - enhances existing function
3. **Child traversal** (#7) - isolated utility functions

**Rationale:** These refactorings are low-risk because they:
- Don't change command behavior
- Are easy to test incrementally
- Have clear success criteria

### Phase 2: Medium-Risk Consolidation
4. **Git operations** (#6) - consolidates error handling
5. **Agent validation** (#2) - standardizes validation across commands

**Rationale:** These change some error messages but improve consistency.

### Phase 3: High-Impact Refactoring
6. **Interactive confirmations** (#3) - changes UX slightly
7. **Argument parsing** (#1) - largest impact, most lines saved

**Rationale:** Save the biggest refactorings for last when confidence is high.

---

## Testing Approach

For each refactoring:
1. **Before:** Document current behavior (what errors, what messages)
2. **Refactor:** Extract helper, update 1-2 callers
3. **Test:** Run `ib new-agent`, `ib kill`, `ib merge` manually
4. **Migrate:** Update remaining callers one at a time
5. **Validate:** Ensure error messages unchanged (or improved)

**No formal test suite exists**, so testing is manual with these scenarios:
- Basic agent lifecycle: `new-agent → send → look → merge`
- Error cases: invalid IDs, missing agents, uncommitted changes
- Edge cases: agent mode, partial IDs, stopped agents

---

## Expected Impact

| Category | Lines Saved | Complexity Reduction | Risk Level |
|----------|-------------|---------------------|------------|
| #1 Argument Parsing | ~400 | High | Medium |
| #2 Agent Validation | ~150 | Medium | Medium |
| #3 Confirmations | ~60 | Low | Low |
| #4 Tmux Capture | ~30 | Low | Low |
| #5 Meta Reading | ~40 | Low | Very Low |
| #6 Git Operations | ~80 | Medium | Medium |
| #7 Child Traversal | ~60 | Medium | Low |
| **Total** | **~820 lines** | **21% reduction** | **Manageable** |

---

## Recommendations

**Prioritize:**
1. **Meta.json reading** (#5) - easiest, immediate benefit for code clarity
2. **Child traversal** (#7) - clear wins, used in critical paths
3. **Tmux capture** (#4) - small enhancement to existing function
4. **Agent validation** (#2) - standardizes most commands
5. **Argument parsing** (#1) - biggest impact but requires careful migration

**Skip/Defer:**
- Don't over-engineer: keep helpers simple and bash-native
- Don't create abstractions for single-use patterns
- Don't refactor code that's likely to change soon (e.g., experimental features)

**Success Metrics:**
- Commands still work identically
- Error messages are same or better
- New commands are easier to add
- Code is easier to navigate and understand
