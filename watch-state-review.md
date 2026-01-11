# Watch Command: State Management & Data Flow Analysis

**Reviewer:** agent-2d060686
**Date:** 2026-01-11
**Scope:** State variables (lines 3861-3867), watch_render (lines 3895-4098), main loop (lines 4237-4274)

---

## Executive Summary

The watch command implements a sophisticated multi-layer caching system with background processes to achieve smooth rendering at 50+ FPS. The architecture is **generally sound** with clear separation between state, caching, and rendering phases. However, there are **several synchronization issues, cache invalidation problems, and state consistency concerns** that could lead to bugs under certain conditions.

**Critical Issues Found:** 3
**Moderate Issues Found:** 5
**Minor Optimizations:** 4

---

## 1. State Management Assessment

### 1.1 Global State Variables (lines 857-887)

The watch command uses a two-tier state architecture:

**Persistent Global State (survives across frames):**
- `STATE_FRAME_COUNT` (line 870) - Frame counter for round-robin refresh
- `CACHED_NOW` (line 873) - Cached epoch time
- `CACHED_SESSIONS` (line 876) - Cached tmux session list
- `META_CACHE_IDS/DATA` (lines 857-858) - Agent metadata cache
- `STATE_CACHE_IDS/DATA` (lines 868-869) - Agent state cache
- `TREE_ORDER_CACHE/KEY` (lines 863-864) - Tree structure cache
- `LOG_PARSED_AGENT/LEN/LINES` (lines 885-887) - Parsed log cache
- Background process globals: `SESSIONS_FILE`, `TMUX_CACHE_DIR`, `LOG_CACHE_DIR`, `LOG_WIDTH_FILE` (lines 877-882)

**Local State (per-function or per-render):**
- `SELECTED_INDEX`, `PREV_SELECTED_INDEX` (lines 3863-3864)
- `AGENT_COUNT` (line 3865)
- `TREE_SCROLL`, `SCROLL_OFFSET` (lines 3866-3867)
- `TERM_LINES`, `TERM_COLS` (line 3862)

### 1.2 State Clarity Issues

**🔴 CRITICAL: STATE_FRAME_COUNT Never Reset**

```bash
# Line 1126 in build_agent_data_file
((STATE_FRAME_COUNT++))
```

**Problem:** `STATE_FRAME_COUNT` is initialized to 0 (line 870) and incremented every frame but **never reset**. This will eventually overflow after ~24 days at 50 FPS (2^31 / 50 / 86400 ≈ 24 days), causing bash arithmetic overflow.

**Impact:** Modulo operations using `STATE_FRAME_COUNT` will behave unpredictably after overflow:
- Line 924: `$((STATE_FRAME_COUNT % 5))` - Time refresh breaks
- Line 934: `$((STATE_FRAME_COUNT % 3))` - Session refresh breaks
- Line 1096: `$((STATE_FRAME_COUNT % 5))` - State refresh breaks
- Line 4035: `$((STATE_FRAME_COUNT % 7))` - Log parsing breaks

**Recommendation:** Implement wraparound at a reasonable boundary:
```bash
# Line 1126
((STATE_FRAME_COUNT++))
[[ $STATE_FRAME_COUNT -gt 10000 ]] && STATE_FRAME_COUNT=0
```

---

**🟡 MODERATE: Inconsistent Scope for TERM_LINES/TERM_COLS**

```bash
# Line 3862 - declared local to cmd_watch
local TERM_LINES TERM_COLS

# Lines 3889-3890 - assigned inside watch_render
TERM_LINES=$(tput lines)
TERM_COLS=$(tput cols)
```

**Problem:** These are declared `local` in `cmd_watch()` but assigned in nested function `watch_render()`. While bash allows this (child functions inherit parent locals), it's not immediately obvious from reading the code.

**Impact:** Minimal - works as intended but reduces code clarity.

**Recommendation:** Add a comment or move declaration closer to usage:
```bash
# watch_render function has access to parent scope locals
local TERM_LINES TERM_COLS
```

---

**🟢 GOOD: Clean State Transitions for SCROLL_OFFSET**

```bash
# Lines 3998-4002 - Reset scroll when agent changes
if [[ $SELECTED_INDEX -ne $PREV_SELECTED_INDEX ]]; then
    SCROLL_OFFSET=0
    PREV_SELECTED_INDEX=$SELECTED_INDEX
fi
```

This is well-designed - scroll state resets to "auto-scroll to bottom" when switching agents, preventing confusion.

---

### 1.3 State Consistency Analysis

**🔴 CRITICAL: Race Condition in Background Cache Writes**

```bash
# Lines 4192-4194 - Background tmux capture
tmux capture-pane -t "$session" -p -S -500 2>/dev/null | \
    sed 's/\x1b\[[0-9;]*m//g' > "$tmux_cache_dir/$agent_id.tmp" && \
    mv "$tmux_cache_dir/$agent_id.tmp" "$tmux_cache_dir/$agent_id" 2>/dev/null || true

# Lines 4208-4209 - Background log wrapping
tail -n 200 "$log_file" 2>/dev/null | fold -w "$wrap_width" > "$log_cache_dir/$agent_id.tmp" && \
    mv "$log_cache_dir/$agent_id.tmp" "$log_cache_dir/$agent_id" 2>/dev/null || true
```

**Problem:** The `mv` uses atomic rename, but the **read side has no synchronization**:

```bash
# Line 4018 - Main loop reads cache
tmux_output=$(<"$cache_file") 2>/dev/null || true
```

If the main loop reads `$cache_file` while `mv` is executing, there's a **tiny window** where:
1. Background process deletes old file
2. Main loop opens file descriptor → **ENOENT error**
3. Background process creates new file

**Impact:** Rare but possible empty reads when cache file is being replaced. The `|| true` masks the error, but results in blank pane content for one frame.

**Recommendation:** Use hardlinks for truly atomic swap:
```bash
ln "$tmux_cache_dir/$agent_id.tmp" "$tmux_cache_dir/$agent_id.new" && \
    mv "$tmux_cache_dir/$agent_id.new" "$tmux_cache_dir/$agent_id"
```

Or accept the tiny race (it's already mostly harmless).

---

**🟡 MODERATE: Cache Invalidation for LOG_PARSED_LINES**

```bash
# Lines 4035-4058 - Log cache invalidation logic
if [[ "$LOG_PARSED_AGENT" != "$selected_id" ]] || [[ $((STATE_FRAME_COUNT % 7)) -eq 0 ]]; then
    if [[ -n "$LOG_CACHE_DIR" && -f "$log_cache_file" ]]; then
        local log_content
        log_content=$(<"$log_cache_file") 2>/dev/null || true
        local content_len=${#log_content}

        # Reparse if agent changed or content length changed
        if [[ "$LOG_PARSED_AGENT" != "$selected_id" || "$LOG_PARSED_LEN" != "$content_len" ]]; then
            LOG_PARSED_LINES=()
            if [[ -n "$log_content" ]]; then
                while IFS= read -r line; do
                    LOG_PARSED_LINES+=("$line")
                done <<< "$log_content"
            fi
            LOG_PARSED_AGENT="$selected_id"
            LOG_PARSED_LEN=$content_len
        fi
```

**Problem:** Cache invalidation only checks **every 7 frames** (line 4035), but also checks on **agent change** (line 4042). However, if an agent's log file grows rapidly, there's a 7-frame delay (~140ms at 50 FPS) before detecting changes.

**Impact:** Log pane can lag behind reality by up to 140ms during high-activity periods.

**Recommendation:** Use file modification time instead of polling:
```bash
local log_mtime
log_mtime=$(stat -f %m "$log_cache_file" 2>/dev/null) || log_mtime=0
if [[ "$LOG_PARSED_MTIME" != "$log_mtime" ]]; then
    # Reparse
fi
```

---

## 2. Data Flow Analysis

### 2.1 Data Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│ Background Processes (async, 150ms cycle)              │
│                                                         │
│  Session Monitor                  Log Wrapper          │
│  ├─ tmux list-sessions           ├─ tail -n 200        │
│  ├─ Write to SESSIONS_FILE       └─ fold -w WIDTH      │
│  └─ capture-pane → TMUX_CACHE         ↓                │
│         ↓                         LOG_CACHE             │
└─────────┼─────────────────────────────┼─────────────────┘
          │                             │
          ▼                             ▼
┌─────────────────────────────────────────────────────────┐
│ Main Loop (50 FPS)                                      │
│                                                         │
│  1. watch_render()                                      │
│     ├─ build_agent_data_file()                          │
│     │  ├─ Read SESSIONS_FILE                           │
│     │  ├─ Read META_CACHE (disk → cache on miss)       │
│     │  ├─ Read STATE_CACHE (tmux → cache on miss)      │
│     │  └─ Read TREE_ORDER_CACHE                        │
│     │                                                   │
│     ├─ Read TMUX_CACHE (or direct capture)             │
│     ├─ Read LOG_CACHE → parse to LOG_PARSED_LINES      │
│     └─ Render to terminal                              │
│                                                         │
│  2. sleep 0.02                                          │
│  3. watch_process_key()                                 │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow Bottlenecks

**🟢 GOOD: Separation of Phases**

The `watch_render()` function clearly separates processing from rendering:

```bash
# Lines 4004-4098 - PHASE 1: COLLECT & PROCESS DATA
# Lines 4100-4127 - PHASE 2: RENDER (no processing, just print)
```

This is excellent design - makes it easy to profile and optimize each phase independently.

---

**🟡 MODERATE: Redundant Linear Searches**

```bash
# Lines 959-964 - Find agent in META_CACHE
for ((_ci=0; _ci<${#META_CACHE_IDS[@]}; _ci++)); do
    if [[ "${META_CACHE_IDS[$_ci]}" == "$id" ]]; then
        cache_idx=$_ci
        break
    fi
done

# Lines 1086-1091 - Find agent in STATE_CACHE (same pattern)
for ((_sci=0; _sci<${#STATE_CACHE_IDS[@]}; _sci++)); do
    if [[ "${STATE_CACHE_IDS[$_sci]}" == "$id" ]]; then
        state_cache_idx=$_sci
        break
    fi
done

# Lines 1063-1068 - Find agent in all_data (same pattern)
for ((j=0; j<${#all_ids[@]}; j++)); do
    if [[ "${all_ids[$j]}" == "$id" ]]; then
        data="${all_data[$j]}"
        break
    fi
done
```

**Problem:** Three separate O(n) linear searches per visible agent per frame. With 10 agents, that's potentially 30 linear scans per frame.

**Impact:** Minor - with typical agent counts (<20), this is fast enough. But scales poorly.

**Recommendation:** Use associative arrays (bash 4.0+):
```bash
declare -A META_CACHE  # id -> "manager|epoch|model|prompt"
declare -A STATE_CACHE # id -> "running|waiting|etc"
```

This would make lookups O(1) instead of O(n).

---

**🟢 GOOD: Lazy State Refresh**

```bash
# Lines 1078-1120 - State only computed for visible agents
if [[ $idx -ge $visible_start && $idx -le $visible_end ]]; then
    # ... only compute state for visible agents
fi
```

Excellent optimization - only captures tmux state for agents currently visible in the tree (5 agents max), not all agents.

---

**🔴 CRITICAL: tmpfile Cleanup Missing in Error Path**

```bash
# Line 3897
build_agent_data_file "$TREE_SCROLL" "$((TREE_SCROLL + 4))"
local tmpfile="$BUILD_AGENT_DATA_RESULT"

if [[ ! -s "$tmpfile" ]]; then
    AGENT_COUNT=0
    echo "No agents running."
    # ... render empty message ...
    rm -f "$tmpfile"  # ← Line 3913: cleanup HERE
    return
fi

# ... normal processing ...

rm -f "$tmpfile"  # ← Line 4126: cleanup HERE
```

**Problem:** If an error occurs between line 3914 and line 4126, the tmpfile is **not cleaned up**. Since `watch_render()` is called 50 times per second, this could leak 50 temp files per second.

**Impact:** Disk space exhaustion if rendering crashes repeatedly.

**Recommendation:** Use trap for guaranteed cleanup:
```bash
local tmpfile="$BUILD_AGENT_DATA_RESULT"
trap "rm -f '$tmpfile'" RETURN
```

---

### 2.3 Background Process Coordination

**🟢 GOOD: Separate Cache Directories**

```bash
# Lines 4171-4173
local tmux_cache_dir=$(mktemp -d)
local log_cache_dir=$(mktemp -d)
```

Each cache type gets its own directory - clean separation, easy to reason about.

---

**🟡 MODERATE: LOG_WIDTH_FILE Update Timing**

```bash
# Line 4031 - Main loop updates width
[[ -n "$LOG_WIDTH_FILE" ]] && echo "$right_pane_width" > "$LOG_WIDTH_FILE"

# Line 4200 - Background process reads width
read -r wrap_width < "$log_width_file" 2>/dev/null || wrap_width=80
```

**Problem:** Main loop writes `$LOG_WIDTH_FILE` **every frame** (50 times/sec), but background process only reads it **every 150ms** (6.67 times/sec). This is wasteful.

**Impact:** Unnecessary disk I/O (50 writes/sec when only 7 are needed).

**Recommendation:** Only write when width changes:
```bash
local width_changed=0
if [[ -n "$LOG_WIDTH_FILE" ]]; then
    local old_width
    read -r old_width < "$LOG_WIDTH_FILE" 2>/dev/null || old_width=0
    if [[ "$old_width" != "$right_pane_width" ]]; then
        echo "$right_pane_width" > "$LOG_WIDTH_FILE"
    fi
fi
```

---

## 3. Caching Effectiveness

### 3.1 Cache Hit Rate Analysis

The system uses **6 cache layers**:

| Cache Layer | Refresh Rate | Purpose | Effectiveness |
|------------|-------------|---------|---------------|
| `CACHED_NOW` | Every 5 frames | Epoch time | ✅ Excellent - eliminates 90% of `date` calls |
| `CACHED_SESSIONS` | Every 3 frames | tmux session list | ✅ Good - reduces expensive tmux calls |
| `META_CACHE` | On miss | Agent metadata | ✅ Excellent - disk reads only on new agents |
| `STATE_CACHE` | Round-robin (every 5 frames per agent) | Agent state | ⚠️ Complex - see below |
| `TREE_ORDER_CACHE` | On agent add/remove | Tree structure | ✅ Excellent - expensive computation cached |
| `LOG_PARSED_LINES` | Every 7 frames or content change | Parsed log | ✅ Good - avoids repeated parsing |

### 3.2 STATE_CACHE Complexity

**🟡 MODERATE: Round-Robin State Refresh Logic**

```bash
# Line 1096 - Refresh one agent per frame
if [[ $((STATE_FRAME_COUNT % 5)) -eq $visible_offset || $state_cache_idx -lt 0 ]]; then
    state=$(get_state "$id")
```

**Problem:** The round-robin logic is **clever but confusing**:
- Only **visible agents** (5 max) get state updates
- Each visible agent refreshes **every 5 frames** (10 FPS per agent)
- Uses `$visible_offset` to stagger refreshes across agents

This means:
- Frame 0: Agent at tree index 0 refreshes
- Frame 1: Agent at tree index 1 refreshes
- Frame 2: Agent at tree index 2 refreshes
- ...
- Frame 5: Agent at tree index 0 refreshes again

**Impact:** State can be **up to 100ms stale** (5 frames @ 50 FPS) for any given agent. This is usually acceptable, but could cause brief "stuck state" visual glitches during rapid transitions (e.g., agent goes from `running` → `complete` → `merged`, but UI shows `running` for extra 100ms).

**Recommendation:** Document this behavior clearly, or consider refreshing **all visible agents** every 3 frames instead of round-robin:
```bash
if [[ $((STATE_FRAME_COUNT % 3)) -eq 0 || $state_cache_idx -lt 0 ]]; then
    state=$(get_state "$id")
```

This trades 67% more tmux calls (refreshing 5 agents every 3 frames vs 1 agent per frame) for **3x faster state updates** (60ms max staleness vs 100ms).

---

### 3.3 Cache Invalidation Correctness

**🔴 CRITICAL: TREE_ORDER_CACHE Invalidation Bug**

```bash
# Lines 1024-1026 - Cache key is ALL agent IDs concatenated
local id_key="${all_ids[*]}"

# Lines 1029-1032 - Cache hit if key matches
if [[ "$id_key" == "$TREE_ORDER_KEY" && ${#TREE_ORDER_CACHE[@]} -gt 0 ]]; then
    tree_ids=("${TREE_ORDER_CACHE[@]}")
```

**Problem:** The cache key is a **space-separated concatenation** of all agent IDs. This creates a **false cache miss** if agents are discovered in a different filesystem order:

Example:
- Frame 1: `all_ids=(abc123 def456 ghi789)` → key="abc123 def456 ghi789"
- Frame 2: `all_ids=(abc123 ghi789 def456)` → key="abc123 ghi789 def456" ← **DIFFERENT!**

Even though the same agents exist, the key differs, causing unnecessary tree recomputation.

**Impact:** Tree order is recomputed more often than necessary (though still infrequent in practice).

**Recommendation:** Sort IDs before creating key:
```bash
local id_key
IFS=$'\n' id_key=$(printf '%s\n' "${all_ids[@]}" | sort | tr '\n' ' ')
```

Or use a hash:
```bash
local id_key
id_key=$(printf '%s\n' "${all_ids[@]}" | sort | md5)
```

---

**🟢 GOOD: LOG_PARSED_LINES Invalidation**

```bash
# Lines 4042-4051 - Invalidate if agent OR content length changes
if [[ "$LOG_PARSED_AGENT" != "$selected_id" || "$LOG_PARSED_LEN" != "$content_len" ]]; then
    LOG_PARSED_LINES=()
    # ... reparse ...
fi
```

This is correct - using content length as a cheap dirty-check works well for append-only log files.

---

## 4. Potential Bugs & Race Conditions

### Summary of Issues Found

| Severity | Issue | Line(s) | Impact |
|----------|-------|---------|--------|
| 🔴 Critical | `STATE_FRAME_COUNT` overflow after 24 days | 870, 1126 | Modulo operations break, refresh timings fail |
| 🔴 Critical | Race condition in background cache file writes | 4192-4194, 4018 | Rare blank pane flickers |
| 🔴 Critical | tmpfile leak on error path | 3897-4126 | Disk space exhaustion |
| 🔴 Critical | `TREE_ORDER_CACHE` invalidation false misses | 1024-1032 | Unnecessary recomputation |
| 🟡 Moderate | `LOG_PARSED_LINES` refresh lag (7 frames) | 4035 | 140ms log display lag |
| 🟡 Moderate | `LOG_WIDTH_FILE` written every frame | 4031 | Wasted disk I/O |
| 🟡 Moderate | Round-robin state refresh stale by 100ms | 1096 | Brief visual glitches on state transitions |
| 🟡 Moderate | Linear searches in cache lookups | 959-964, 1086-1091 | Scales poorly beyond ~50 agents |

---

## 5. Prioritized Recommendations

### 🔴 HIGH PRIORITY (Fix Now)

1. **Add `STATE_FRAME_COUNT` wraparound** (line 1126)
   ```bash
   ((STATE_FRAME_COUNT++))
   [[ $STATE_FRAME_COUNT -gt 10000 ]] && STATE_FRAME_COUNT=0
   ```

2. **Add trap for tmpfile cleanup** (line 3897)
   ```bash
   local tmpfile="$BUILD_AGENT_DATA_RESULT"
   trap "rm -f '$tmpfile'" RETURN
   ```

3. **Fix `TREE_ORDER_CACHE` key generation** (line 1026)
   ```bash
   local id_key
   IFS=$'\n' id_key=$(printf '%s\n' "${all_ids[@]}" | sort | tr '\n' ' ')
   ```

### 🟡 MEDIUM PRIORITY (Fix Soon)

4. **Optimize `LOG_WIDTH_FILE` writes** (line 4031)
   - Only write when width actually changes

5. **Replace linear searches with associative arrays** (lines 959-964, 1086-1091)
   - Use `declare -A META_CACHE` and `declare -A STATE_CACHE`

6. **Improve state refresh timing** (line 1096)
   - Consider refreshing all visible agents every 3 frames instead of round-robin every 5

### 🟢 LOW PRIORITY (Nice to Have)

7. **Use file mtime for log cache invalidation** (line 4035)
   - Replace length-based dirty checking with mtime

8. **Add comments for nested scope variables** (line 3862)
   - Clarify that `TERM_LINES/TERM_COLS` are assigned in child function

9. **Accept or document the background cache race** (lines 4192-4194)
   - Either use hardlink-swap or add comment explaining the acceptable tiny race

---

## 6. Performance Characteristics

### Current Performance

Based on code analysis:

- **Target frame rate:** 50 FPS (20ms per frame)
- **Sleep budget:** 20ms (`sleep 0.02` at line 4252)
- **Render time:** Varies, but optimized for speed:
  - Background caching reduces subprocess spawns
  - ANSI stripping done in background (line 4193)
  - Log wrapping done in background (line 4208)
  - State only computed for visible agents (lines 1080-1120)

### Optimization Wins

1. ✅ **Background session monitor** (lines 4179-4215) - Huge win, eliminates blocking tmux calls
2. ✅ **ANSI stripping in background** (line 4193) - Moves expensive sed to async process
3. ✅ **Round-robin state refresh** (line 1096) - Spreads tmux capture load over multiple frames
4. ✅ **Lazy visible-only state** (line 1080) - Only updates what's on screen
5. ✅ **Parsed log caching** (lines 4042-4051) - Avoids re-parsing 200 lines every frame

### Remaining Bottlenecks

1. ⚠️ **Linear cache searches** - O(n) per visible agent per frame (acceptable for n<50)
2. ⚠️ **File I/O on LOG_WIDTH_FILE** - 50 writes/sec when only 7 needed
3. ⚠️ **tmpfile creation every frame** (line 915) - 50 mktemp calls/sec (kernel handles this well, but wasteful)

---

## 7. Code Quality Assessment

### Strengths

- **Clear phase separation** (collect/process vs render)
- **Extensive use of caching** at multiple layers
- **Background processes** offload expensive work
- **Atomic writes** with tmp+mv pattern (mostly correct)
- **Good variable naming** (mostly clear what each cache does)

### Weaknesses

- **Complex round-robin logic** in state refresh (hard to reason about)
- **Many global variables** (13 globals just for caching)
- **No documentation** of cache invalidation rules
- **Linear searches** instead of hash tables
- **Missing error handling** on tmpfile cleanup
- **Race conditions** (minor but present)

---

## Conclusion

The watch command's state management is **sophisticated and mostly well-designed**, with an impressive multi-layer caching strategy that achieves smooth 50 FPS rendering. The background process architecture is a major win for performance.

However, there are **4 critical bugs** that should be fixed:
1. Frame counter overflow after 24 days
2. tmpfile leak on error paths
3. Background cache file race condition (minor but present)
4. Tree order cache false invalidations

The medium-priority optimizations (associative arrays, width file writes, state refresh timing) would improve efficiency but aren't blocking issues.

**Overall Grade: B+**
*Excellent architecture, but needs bug fixes and documentation before production-ready.*

---

## Appendix: Testing Recommendations

To validate fixes:

1. **Frame counter overflow:**
   ```bash
   STATE_FRAME_COUNT=2147483640  # Near overflow
   # Run watch for 10 seconds, verify no crashes
   ```

2. **tmpfile cleanup:**
   ```bash
   # Before fix:
   watch &
   PID=$!
   sleep 5
   kill -9 $PID  # Simulate crash
   ls /tmp/tmp.* | wc -l  # Should see leaked files
   ```

3. **Cache invalidation:**
   ```bash
   # Spawn 5 agents in different orders, verify tree doesn't flicker
   ```

4. **Background cache race:**
   ```bash
   # Run watch for 60 seconds, grep logs for empty pane renders
   # (This race is rare and mostly harmless - may accept as-is)
   ```
