# Watch Mode Helper Functions - Code Review

**Reviewer:** agent-3ca21e26
**Date:** 2026-01-11
**Scope:** Helper functions for watch command (ib:912-1397, 4179-4214)

---

## Executive Summary

The watch mode implementation demonstrates **excellent engineering discipline** with a clear focus on performance optimization. The code uses sophisticated caching strategies and pure bash implementations to avoid subprocess spawning. While there are minor style inconsistencies and some tech debt, the architecture is sound and the optimizations are well-justified.

**Key Strengths:**
- Comprehensive multi-layer caching strategy (meta cache, state cache, tree order cache, tmux cache, log cache)
- Pure bash implementations to eliminate subprocess overhead
- Background processing offloads expensive work from the main loop
- Thoughtful round-robin refresh patterns

**Key Concerns:**
- Some redundant operations and variable assignments
- Inconsistent code formatting in places
- ANSI stripping done twice (background and potentially in main loop)
- Some cache invalidation logic could be simplified

---

## 1. Code Style and Formatting Issues

### 1.1 Inconsistent Blank Line Usage

**Issue:** Inconsistent use of blank lines between logical sections.

**Examples:**
- Line 942: Two blank lines before "PASS 1" comment (excessive)
- Line 1021: Two blank lines before "Compute tree order" comment (excessive)
- Line 1053: Two blank lines before "PASS 2" comment (excessive)

**Recommendation:** Use single blank line to separate logical sections for consistency.

---

### 1.2 Comment Style Inconsistencies

**Issue:** Mixed comment styles for section headers.

**Examples:**
- Line 945: `# === PASS 1: Get agent data from cache or disk ===` (good, boxed style)
- Line 1023: `# === Compute tree order (with caching) ===` (same good style)
- Line 1055: `# === PASS 2: Write tmpfile in TREE ORDER ===` (same good style)
- Line 922: `# Cache epoch time, refresh every 5 frames` (regular comment, not boxed)

**Observation:** The boxed style with `===` is used for major sections, regular comments for inline explanations. This is actually **intentional and good** - no change needed.

---

### 1.3 Variable Naming Conventions

**Issue:** Inconsistent prefix usage for "private" variables.

**Examples:**
- Line 958: `local _ci` (underscore prefix for loop counter)
- Line 1085: `local _sci` (underscore prefix for loop counter)
- Line 1036: `local i` (no underscore for loop counter)
- Line 1231: `local _INFO=""` (underscore for function-local return value - good)
- Line 1232: `local _CHILDREN=""` (same)

**Observation:** Underscore prefix appears to indicate:
1. Disposable loop counters that shouldn't shadow outer variables
2. Function-local "return" variables to avoid polluting script globals

**Recommendation:** This is **intentional and reasonable**. Consider documenting this convention in a code style guide.

---

### 1.4 String Parsing Pattern Inconsistency

**Issue:** Two different patterns used for parsing pipe-delimited data.

**Pattern A (using IFS read):**
```bash
# Line 1284
IFS='|' read -r _id _manager state age model prompt <<< "$_INFO"
```

**Pattern B (using bash parameter expansion):**
```bash
# Lines 969-974
manager="${cached%%|*}"
local rest="${cached#*|}"
created_epoch="${rest%%|*}"
rest="${rest#*|}"
model="${rest%%|*}"
prompt="${rest#*|}"
```

**Analysis:**
- Pattern A is cleaner and more readable
- Pattern B is more flexible when you need to skip fields or handle variable field counts
- Pattern A is used when all fields are needed
- Pattern B is used when parsing from cache with intermediate steps

**Recommendation:** Both patterns are appropriate for their use cases. No change needed, but consider documenting when to use each pattern.

---

## 2. Code Cleanup Opportunities

### 2.1 Redundant Variable Assignment

**Location:** Line 1015

```bash
# Handle empty manager
[[ -z "$manager" ]] && manager=""
```

**Issue:** This is a no-op. If `$manager` is empty, assigning empty string to it changes nothing.

**Context:** Line 993 already handles this: `[[ "$manager" == "null" ]] && manager=""`

**Recommendation:** **Remove line 1015** as it serves no purpose.

---

### 2.2 Redundant Age Variable Initialization

**Location:** Lines 1001-1011

```bash
# Calculate age (must be fresh each time)
local age
if [[ -n "$created_epoch" ]]; then
    # ... age calculation ...
else
    age="?"
fi
```

**Issue:** `local age` declares the variable but doesn't initialize it. If `created_epoch` is empty, `age` is set to "?". If `created_epoch` is non-empty, `age` is always set. There's no path where `age` remains uninitialized.

**Recommendation:** This is fine as-is. The declaration is clear about intent.

---

### 2.3 Duplicate Session Check Logic

**Location:** Lines 931-942 (build_agent_data_file)

```bash
# Get active tmux sessions (from background monitor file, or fallback to direct call)
local active_sessions
if [[ -n "$SESSIONS_FILE" && -f "$SESSIONS_FILE" ]]; then
    # Read from async background monitor (bash read, no subprocess)
    read -r active_sessions < "$SESSIONS_FILE" 2>/dev/null || true
elif [[ $((STATE_FRAME_COUNT % 3)) -eq 0 || -z "$CACHED_SESSIONS" ]]; then
    # Fallback: call tmux directly, cache every 3 frames
    local tmux_output
    tmux_output=$(tmux list-sessions -F '#{session_name}' 2>/dev/null) || true
    CACHED_SESSIONS="${tmux_output//$'\n'/|}"
    active_sessions="$CACHED_SESSIONS"
else
    active_sessions="$CACHED_SESSIONS"
fi
```

**Observation:** This implements a sophisticated three-tier strategy:
1. Read from background monitor file (fastest, preferred)
2. Call tmux directly and cache (fallback, throttled to every 3 frames)
3. Use cached value (when throttling prevents direct call)

**Recommendation:** This is **excellent design**. No cleanup needed.

---

### 2.4 Linear Search in build_agent_data_file

**Location:** Lines 1063-1068

```bash
# Find cached data for this ID (linear search - fine for ~10 agents)
local data=""
local j
for ((j=0; j<${#all_ids[@]}; j++)); do
    if [[ "${all_ids[$j]}" == "$id" ]]; then
        data="${all_data[$j]}"
        break
    fi
done
```

**Issue:** Linear O(n) search for each agent in tree order.

**Analysis:**
- Comment explicitly acknowledges this: "fine for ~10 agents"
- Typical usage: 3-10 agents
- Complexity: O(n²) for full tree traversal
- For 10 agents: 100 comparisons
- Bash associative arrays would require bash 4.0+, which breaks macOS compatibility

**Recommendation:** **Keep as-is**. The comment shows this is intentional. For the expected scale (< 10 agents), the overhead is negligible compared to tmux operations.

---

### 2.5 Cache Lookup Pattern Duplication

**Location:** Lines 956-964 (meta cache) and 1083-1091 (state cache)

Both use identical inline linear search pattern:
```bash
local cache_idx=-1
local _ci
for ((_ci=0; _ci<${#CACHE_IDS[@]}; _ci++)); do
    if [[ "${CACHE_IDS[$_ci]}" == "$id" ]]; then
        cache_idx=$_ci
        break
    fi
done
```

**Issue:** Duplicated code that could be extracted to a helper function.

**Analysis:**
- Would require passing array names as arguments
- Bash 3.2 doesn't support nameref (`local -n`)
- Would need to use `eval` which is dangerous
- Current duplication is only 8 lines, 2 occurrences

**Recommendation:** **Keep as-is**. The duplication is limited and extraction would require `eval` which is worse than duplication. The inline approach is clearer and safer.

---

### 2.6 ANSI Stripping Architecture

**Location:** Lines 4191-4194 (background cache) and 4082 (main loop)

**Background process:**
```bash
tmux capture-pane -t "$session" -p -S -500 2>/dev/null | \
    sed 's/\x1b\[[0-9;]*m//g' > "$tmux_cache_dir/$agent_id.tmp" && \
    mv "$tmux_cache_dir/$agent_id.tmp" "$tmux_cache_dir/$agent_id" 2>/dev/null || true
```

**Main loop:**
```bash
# Line 4082: Extract visible lines and truncate (ANSI already stripped by background process)
visible_tmux_lines+=("${all_tmux_lines[$tmux_idx]:0:$left_pane_width}")
```

**Issue:** Comment at line 4077 claims "ANSI already stripped by background process", but:
1. Background process uses `sed` (subprocess) for stripping
2. There's a pure bash `_strip_ansi()` function (line 659) that's unused in watch mode
3. If cache is unavailable, fallback direct capture (line 4021) doesn't strip ANSI

**Analysis:**
- Background `sed` stripping is acceptable since it runs async
- Main loop correctly assumes cache has pre-stripped content
- **BUG**: Fallback path at line 4021 doesn't strip ANSI codes!

**Recommendation:**
1. **Fix fallback path** at line 4021 to strip ANSI (either call `sed` or use `_strip_ansi`)
2. Consider whether `_strip_ansi()` should be used in background process for consistency
3. Document why `sed` is acceptable in background but avoided in main loop

---

## 3. Background Caching Architecture Assessment

### 3.1 Overall Design: EXCELLENT

**Architecture Overview:**

```
Background Monitor Process (lines 4179-4215)
├─ Session List Cache (updates: continuous)
│  └─ Writes to $SESSIONS_FILE (pipe-delimited)
├─ Tmux Output Cache (updates: every 0.15s)
│  ├─ Captures 500 lines per session
│  ├─ Strips ANSI codes via sed
│  └─ Writes to $TMUX_CACHE_DIR/$agent_id (atomic via .tmp + mv)
└─ Agent Log Cache (updates: every 0.15s)
   ├─ Reads last 200 lines
   ├─ Wraps to current width via fold
   └─ Writes to $LOG_CACHE_DIR/$agent_id (atomic via .tmp + mv)

Main Loop (lines 4243-4274)
├─ Calls build_agent_data_file (reads SESSIONS_FILE)
├─ Reads TMUX_CACHE_DIR for tmux output
├─ Reads LOG_CACHE_DIR for agent logs
└─ Renders at ~50 FPS (0.02s sleep)
```

**Strengths:**
1. **Atomic writes** via temp file + rename prevent torn reads
2. **Async offloading** moves expensive operations (tmux capture, sed, fold) out of main loop
3. **Cache miss handling** gracefully falls back to direct reads
4. **Width adaptation** for log wrapping via shared file
5. **Decoupled update rate** (background: 0.15s, render: 0.02s)

**Weaknesses:**
1. **No cache staleness detection** - if background process dies, main loop uses stale data indefinitely
2. **No cleanup verification** - temp files may accumulate if `mv` fails
3. **Background process has no health monitoring** - silent failure is possible

---

### 3.2 Cache Refresh Strategy: SOPHISTICATED

**Multi-Tier Refresh Rates:**

| Cache Type | Refresh Strategy | Rationale |
|------------|------------------|-----------|
| Epoch time | Every 5 frames (line 924) | Time changes slowly |
| Session list | Background file (0.15s) or every 3 frames (line 934) | Sessions change rarely |
| Meta cache | Read once, cache forever (line 966) | Static data (prompt, model) |
| State cache | Round-robin: 1 agent per frame modulo 5 (line 1096) | Expensive tmux reads |
| Tree order | Invalidate on agent add/remove (line 1029) | Deterministic based on IDs |
| Tmux output | Background capture every 0.15s (line 4213) | Balanced freshness/cost |
| Log cache | Background wrap every 0.15s (line 4213) | Pre-wrapped for fast render |
| Log parse | Reparse on agent change or content length change (line 4042) | Avoid redundant parsing |

**Analysis:** This is **exceptionally well-designed**. Each cache has a refresh strategy tuned to its volatility and cost.

**One Concern:**
Line 1096: Round-robin state refresh logic
```bash
if [[ $((STATE_FRAME_COUNT % 5)) -eq $visible_offset || $state_cache_idx -lt 0 ]]; then
```

**Issue:** `visible_offset = idx - visible_start`. If visible window is [5-9] and we have 10 agents:
- Frame 0: agent at visible_offset=0 (idx=5) refreshes
- Frame 1: agent at visible_offset=1 (idx=6) refreshes
- ...
- Frame 5: agent at visible_offset=0 (idx=5) refreshes again
- But agents 0-4 (not visible) never refresh!

**Impact:** States for scrolled-off agents can become stale. When scrolling back, may show outdated state for up to 5 frames.

**Recommendation:** This is **acceptable** because:
1. Only visible agents need fresh state for UX
2. Non-visible agents will refresh when scrolled into view
3. The `|| $state_cache_idx -lt 0` ensures initial refresh

Document this behavior as intentional.

---

### 3.3 Cache Invalidation: MOSTLY GOOD

**Invalidation Events:**

1. **Meta Cache:** Never invalidated (correct - static data)
2. **State Cache:** Updated on refresh, never invalidated (correct - always valid)
3. **Tree Order Cache:** Invalidated when agent IDs change (line 1029)
4. **Log Parse Cache:** Invalidated on agent change or content length change (line 4042)

**Tree Order Cache Invalidation:**
```bash
local id_key="${all_ids[*]}"  # Line 1026
if [[ "$id_key" == "$TREE_ORDER_KEY" && ${#TREE_ORDER_CACHE[@]} -gt 0 ]]; then
```

**Issue:** Uses joined string of IDs as cache key. This means:
- Adding agent "foo" then "bar" = "foo bar"
- Adding agent "foobar" = "foobar"
- **Different agent sets can hash to same key!**

**Wait, no:** The glob order is deterministic within a session, and the IDs themselves contain unique prefixes. This is **actually safe** because:
1. Agent IDs are unique (UUIDs or prefixes)
2. Filesystem glob order is stable within a session
3. Any add/remove changes the joined string

**Recommendation:** This is correct. Consider adding a comment explaining why this is safe.

---

### 3.4 Background Process Lifecycle: WEAK

**Startup:** Line 4179-4216 spawns background process

**Shutdown:** Lines 4219-4228 cleanup function
```bash
watch_cleanup_reader() {
    kill $reader_pid 2>/dev/null
    kill $session_monitor_pid 2>/dev/null
    rm -f "$keyfile" "$sessionfile" "$log_width_file"
    rm -rf "$tmux_cache_dir" "$log_cache_dir"
    # ...
}
trap 'watch_cleanup_reader; watch_cleanup' EXIT
```

**Issues:**
1. **No verification that kills succeed** - processes may become orphaned
2. **No handling of background process crashes** - main loop continues with stale data
3. **No logging when background process fails**

**Recommendation:**
1. Add `wait` after `kill` to ensure processes terminate
2. Add a heartbeat file that background process touches every iteration
3. Main loop should detect stale heartbeat and warn user

---

## 4. Performance Optimizations vs Tech Debt

### 4.1 Performance Optimizations (Keep These!)

| Line(s) | Optimization | Benefit |
|---------|-------------|---------|
| 659-673 | Pure bash `_strip_ansi()` | Eliminates `sed` subprocess |
| 606-627 | Pure bash `_tail_file()` | Eliminates `tail` subprocess |
| 629-653 | Pure bash `_fold_text()` | Eliminates `fold` subprocess |
| 680-698 | Background cache for `capture_tmux()` | Eliminates tmux subprocess in hot path |
| 922-927 | Epoch time cache (refresh every 5 frames) | Eliminates `date` subprocess |
| 931-942 | Session list cache | Eliminates tmux subprocess |
| 956-999 | Meta.json cache | Eliminates disk reads and jq subprocess |
| 1023-1052 | Tree order cache | Eliminates expensive tree computation |
| 1083-1109 | State cache with round-robin refresh | Amortizes expensive state detection |
| 1096 | Round-robin refresh (1 agent per frame) | Spreads expensive operations across frames |
| 4179-4215 | Background monitor process | Offloads all expensive I/O from main loop |
| 4035-4058 | Log parse cache with length-based invalidation | Avoids redundant string splitting |

**Assessment:** These optimizations are **well-justified** and should be preserved.

---

### 4.2 Tech Debt (Consider Cleaning Up)

| Line(s) | Issue | Priority |
|---------|-------|----------|
| 1015 | Redundant `[[ -z "$manager" ]] && manager=""` | Low - harmless |
| 4021 | Missing ANSI stripping in fallback path | **HIGH - Bug** |
| 4191-4194 | Uses `sed` in background when pure bash `_strip_ansi()` exists | Medium - inconsistency |
| 956-964, 1083-1091 | Duplicated cache lookup pattern | Low - extraction is complex |
| 1063-1068 | O(n²) linear search | Low - acceptable for scale |

---

### 4.3 Oddities That Are Actually Smart

**1. Empty field in tree line format (line 1313)**
```bash
_BUILD_TREE_LINES+=("${tree_part}|${state}|${age}|${model}||${prompt}")
#                                                           ^^ empty field
```
**Reason:** Reserved for future data (e.g., orphan note) without breaking parser. Smart!

**2. Visible range parameter to build_agent_data_file (line 913)**
```bash
build_agent_data_file "$TREE_SCROLL" "$((TREE_SCROLL + 4))"
```
**Reason:** Only refresh state for visible agents. Brilliant optimization!

**3. Frame count modulo arithmetic everywhere**
```bash
if [[ $((STATE_FRAME_COUNT % 5)) -eq 0 || $CACHED_NOW -eq 0 ]]; then
```
**Reason:** Spreads refresh load evenly across frames. Prevents lag spikes!

**4. Temp file + atomic rename (line 4193)**
```bash
> "$tmux_cache_dir/$agent_id.tmp" && mv "$tmux_cache_dir/$agent_id.tmp" "$tmux_cache_dir/$agent_id"
```
**Reason:** Prevents torn reads in main loop. Critical for correctness!

---

## 5. Prioritized Recommendations

### 5.1 Critical (Fix Now)

**P0: Fix ANSI stripping in fallback path**
- **Location:** Line 4021
- **Issue:** Direct tmux capture doesn't strip ANSI codes, but main loop assumes clean data
- **Fix:** Add ANSI stripping after direct capture
```bash
# Current (line 4021):
tmux_output=$(tmux capture-pane -t "$tmux_session" -p -S -"$capture_lines" 2>/dev/null) || true

# Recommended:
local raw_output
raw_output=$(tmux capture-pane -t "$tmux_session" -p -S -"$capture_lines" 2>/dev/null) || true
if [[ -n "$raw_output" ]]; then
    # Strip ANSI codes using pure bash function
    _strip_ansi "$raw_output"
    tmux_output="$_STRIP_ANSI_RESULT"
else
    tmux_output=""
fi
```

---

### 5.2 High (Fix Soon)

**P1: Add background process health monitoring**
- **Location:** Lines 4179-4228
- **Issue:** If background monitor crashes, main loop continues with stale data
- **Fix:** Add heartbeat file and staleness detection

---

### 5.3 Medium (Improve When Convenient)

**P2: Unify ANSI stripping approach**
- **Location:** Lines 4191-4194 (uses `sed`) vs line 659 (pure bash)
- **Issue:** Inconsistent tooling, though both work
- **Fix:** Use `_strip_ansi()` in background process for consistency

**P3: Document cache key safety**
- **Location:** Line 1026
- **Issue:** Not obvious why joined string is safe for tree order cache key
- **Fix:** Add comment explaining deterministic glob order and unique IDs

---

### 5.4 Low (Nice to Have)

**P4: Remove redundant empty string assignment**
- **Location:** Line 1015
- **Issue:** `[[ -z "$manager" ]] && manager=""` is a no-op
- **Fix:** Delete line 1015

**P5: Add process kill verification**
- **Location:** Lines 4220-4221
- **Issue:** No verification that background processes actually terminate
- **Fix:** Add `wait` after `kill` to ensure cleanup

---

## 6. Conclusion

This code demonstrates **exceptional attention to performance and correctness**. The multi-layer caching strategy is sophisticated and well-tuned. The use of pure bash implementations to avoid subprocess spawning is exactly the right approach for a high-frequency render loop.

**The only critical issue is the missing ANSI stripping in the fallback path (P0).** Everything else is either minor tech debt or intentional optimizations that should be preserved.

### Final Assessment

- **Code Quality:** A-
- **Performance Engineering:** A+
- **Correctness:** B+ (docked for P0 bug)
- **Maintainability:** A- (some complexity, but well-commented)

**Overall:** This is **high-quality systems programming** in bash. The author clearly understands performance profiling and optimization trade-offs.

---

## Appendix: Line Number Reference

### Functions Reviewed

| Function | Lines | Purpose |
|----------|-------|---------|
| `build_agent_data_file()` | 912-1130 | Collect agent metadata with multi-tier caching |
| `build_tree_lines()` | 1214-1359 | Build tree structure for display (pure bash) |
| `format_tree_lines()` | 1365-1397 | Align columns for tree display (pure bash) |
| Background monitor | 4179-4215 | Async cache refresher for tmux/log data |

### Helper Functions Referenced

| Function | Lines | Purpose |
|----------|-------|---------|
| `_tail_file()` | 606-627 | Pure bash tail implementation |
| `_fold_text()` | 629-653 | Pure bash fold implementation |
| `_strip_ansi()` | 659-673 | Pure bash ANSI code stripper |
| `capture_tmux()` | 680-698 | Cached tmux pane capture |
| `get_state()` | 703-743 | Agent state detection from tmux output |

### Cache Variables

| Variable | Lines | Purpose |
|----------|-------|---------|
| `META_CACHE_IDS/DATA` | 857-858 | Cache for meta.json data |
| `TREE_ORDER_CACHE/KEY` | 863-864 | Cache for tree traversal order |
| `STATE_CACHE_IDS/DATA` | 868-869 | Cache for agent states |
| `STATE_FRAME_COUNT` | 870 | Frame counter for round-robin refresh |
| `CACHED_NOW` | 873 | Cached epoch time |
| `CACHED_SESSIONS` | 876 | Cached tmux session list |
| `TMUX_CACHE_DIR` | 4171 | Background cache for tmux output |
| `LOG_CACHE_DIR` | 4172 | Background cache for wrapped logs |

---

**End of Report**
