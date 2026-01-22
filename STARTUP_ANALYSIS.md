# ib watch Startup Performance Analysis

## Executive Summary

The `ib watch` command takes 1+ seconds to start due to excessive subprocess spawning during initialization. The primary bottleneck is **repeated JSON parsing calls** - the current implementation makes 28+ separate `jq` invocations during config loading alone, each taking ~30ms.

**Key Finding**: Subprocess spawning overhead on macOS is ~25-65ms per call. The startup code spawns 50+ subprocesses before rendering the first frame.

**Potential Improvement**: By consolidating subprocess calls, startup time could be reduced from 1+ seconds to ~200-300ms.

## Startup Sequence Analysis

### Pre-cmd_watch (ib:20776-20812)
1. `check_dependencies` - 3× `command -v` calls (git, tmux, claude) → ~75ms
2. `init_paths` - 3× git subprocesses + file read → ~100ms
3. `enforce_command_access` - up to 3 checks, including `tmux display-message` → ~30ms

### Inside cmd_watch (ib:12593+)
4. `ensure_ittybitty_dirs` - `mkdir -p` → ~25ms
5. `init_feedback_state` - file check → ~5ms
6. `increment_feedback_session` - file read + sed subprocess → ~60ms
7. `validate_agent_metadata` - **O(n) json_get calls for n agents** → ~35ms × n agents
8. `load_config` - **14 config keys × 2 files × 2 operations = up to 56 jq calls** → ~800ms+
9. `watch_check_all_setup` - 4 checks with file reads and grep/jq → ~150ms
10. `watch_refresh_usage` - security keychain + curl + 4× json_get + 2× perl → ~400ms+

### Total Estimated Startup Time: 1,500-2,000+ ms

## Detailed Bottleneck Analysis

### 1. Config Loading (load_config) - ~800ms

**Problem**: For each of 14 config keys, `_config_get()` calls:
- `json_has()` on project file (if exists) - 1 jq/osascript call
- `json_get()` on project file (if key exists) - 1 jq/osascript call
- OR `json_has()` on user file - 1 jq/osascript call
- AND `json_get()` on user file (if key exists) - 1 jq/osascript call

This results in up to 56 subprocess invocations, each taking ~30ms.

**Measured**: 28 jq calls × 29ms avg = 828ms just for config loading!

**Solution**: Read each config file ONCE and extract all values in a single jq call.

```bash
# Current approach: 56 subprocess calls
CONFIG_FPS=$(_config_get "fps" "10" "$user_file" "$project_file")
CONFIG_MODEL=$(_config_get "model" "" "$user_file" "$project_file")
# ... repeat for each key

# Optimized approach: 2 subprocess calls (one per file)
load_config_optimized() {
    local project_file=".ittybitty.json"
    local user_file="$HOME/.ittybitty.json"

    # Read project config once
    if [[ -f "$project_file" ]]; then
        eval "$(jq -r '
            "CONFIG_FPS=" + (.fps // "10" | @sh) + "\n" +
            "CONFIG_MODEL=" + (.model // "" | @sh) + "\n" +
            "CONFIG_MAX_AGENTS=" + (.maxAgents // "10" | @sh) + "\n" +
            # ... all other keys
        ' "$project_file")"
    fi

    # Fill in missing values from user config
    if [[ -f "$user_file" ]]; then
        eval "$(jq -r '
            # Only output values not already set
            ...
        ' "$user_file")"
    fi
}
```

**Estimated savings**: 800ms → 60ms = **740ms saved**

### 2. Usage API Fetch (watch_refresh_usage) - ~400ms

**Problem**: Synchronously fetches usage data from Anthropic API on every startup:
- `security find-generic-password` - 64ms
- `json_get` for token parsing - 30ms
- `curl` to API - 100-500ms network latency
- 4× `json_get` for response parsing - 120ms
- 2× `perl` for timestamp parsing - 90ms

**Solution**: Move to background/async fetch or cache with TTL.

```bash
# Option 1: Background fetch (non-blocking)
watch_refresh_usage_async() {
    (
        fetch_claude_usage
        # Write results to cache file
        echo "$_USAGE_SESSION_PCT|$_USAGE_WEEKLY_PCT|..." > "$CACHE_FILE"
    ) &
    USAGE_FETCH_PID=$!
}

# Option 2: Cache with 60-second TTL
watch_refresh_usage_cached() {
    local cache_file="$ITTYBITTY_DIR/usage-cache"
    local cache_age=0
    if [[ -f "$cache_file" ]]; then
        cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file") ))
    fi
    if [[ $cache_age -lt 60 ]]; then
        # Use cached values
        IFS='|' read -r USAGE_SESSION_PCT USAGE_WEEKLY_PCT ... < "$cache_file"
        return 0
    fi
    # Otherwise fetch (but consider doing this async)
}
```

**Estimated savings**: 400ms → 0ms (deferred) = **400ms saved**

### 3. Setup Checks (watch_check_all_setup) - ~150ms

**Problem**: Each check runs subprocesses:
- `cmd_hooks_status` → 2× JSON checks (jq/osascript)
- `watch_check_ib_instructions` → file read + 2× grep
- `watch_check_gitignore` → file read + grep/filter

**Solution**: Consolidate file reads and use pure bash pattern matching.

```bash
# Instead of grep for pattern matching:
check_claude_md_has_ittybitty_block() {
    local content="$1"
    [[ "$content" == *$'\n<ittybitty>'$'\n'* && "$content" == *$'\n</ittybitty>'$'\n'* ]]
}
```

**Estimated savings**: 150ms → 30ms = **120ms saved**

### 4. Agent Metadata Validation - ~35ms × n agents

**Problem**: For each agent, calls `json_get` to check `created_epoch` field.

**Solution**: Use bash regex parsing instead of jq for simple field extraction.

```bash
validate_agent_metadata() {
    for agent_dir in "$AGENTS_DIR"/*/; do
        [[ -f "$agent_dir/meta.json" ]] || continue
        local content=$(<"$agent_dir/meta.json")

        # Use bash regex instead of json_get
        if [[ "$content" =~ \"created_epoch\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
            local created_epoch="${BASH_REMATCH[1]}"
            # Valid
        else
            errors+=("Missing created_epoch")
        fi
    done
}
```

**Estimated savings**: 35ms × n agents → ~0ms (pure bash)

### 5. Feedback State Updates - ~60ms

**Problem**: `increment_feedback_session` uses `sed` subprocess.

**Solution**: Use pure bash string manipulation.

```bash
# Instead of sed:
set_feedback_field() {
    local content=$(<"$FEEDBACK_STATE_FILE")
    # Use bash regex to find and replace
    if [[ "$content" =~ ^(.*)\"session_count\"[[:space:]]*:[[:space:]]*[0-9]+(.*)$ ]]; then
        content="${BASH_REMATCH[1]}\"session_count\":$value${BASH_REMATCH[2]}"
    fi
    echo "$content" > "$FEEDBACK_STATE_FILE"
}
```

**Estimated savings**: 60ms → 5ms = **55ms saved**

## Subprocess Overhead Measurements

| Operation | Time (ms) | Count in Startup | Total Impact |
|-----------|-----------|------------------|--------------|
| `jq` query | 29-42 | 28+ | 800+ ms |
| `osascript` (fallback) | 60-100 | 28+ if no jq | 1,700+ ms |
| `security` (keychain) | 64 | 1 | 64 ms |
| `curl` (network) | 100-500 | 1 | 100-500 ms |
| `perl` | 46 | 2 | 92 ms |
| `git` commands | 31-33 | 3-4 | 100+ ms |
| `grep` | 34-39 | 2-4 | 70-150 ms |
| `sed` | ~30 | 1-2 | 30-60 ms |
| `command -v` | 25 | 3 | 75 ms |
| `tmux` command | 32 | 1 | 32 ms |

## Optimization Priority (by Impact)

| Priority | Optimization | Savings | Effort |
|----------|--------------|---------|--------|
| **1** | Consolidate config loading | ~740ms | Medium |
| **2** | Async/cache usage fetch | ~400ms | Low |
| **3** | Pure bash setup checks | ~120ms | Low |
| **4** | Pure bash metadata validation | ~35ms/agent | Low |
| **5** | Pure bash feedback updates | ~55ms | Low |

## Implementation Recommendations

### Phase 1: Quick Wins (Low Effort, High Impact)

1. **Defer usage fetch**: Move `watch_refresh_usage` to after first frame renders, or run in background.

2. **Cache setup checks**: The hooks/gitignore/CLAUDE.md checks don't change during a session. Check once, cache result.

### Phase 2: Config Loading Optimization (Medium Effort, Highest Impact)

1. **Single-pass config read**: Modify `load_config()` to read each file once and extract all values in one jq call.

2. **Consider pure bash JSON for simple cases**: For simple key-value extraction, bash regex is faster than jq subprocess.

### Phase 3: Eliminate Remaining Subprocesses (Low Effort, Moderate Impact)

1. **Replace `grep` with bash `=~`** for pattern matching
2. **Replace `sed` with bash string ops** for simple substitutions
3. **Replace perl timestamp parsing** with pure bash or single call

## Testing Methodology

The profiling was done by timing individual subprocess calls:

```bash
time_ms() {
    local start=$(python3 -c "import time; print(int(time.time() * 1000))")
    "$@" >/dev/null 2>&1 || true
    local end=$(python3 -c "import time; print(int(time.time() * 1000))")
    echo $((end - start))
}
```

See `profile-startup.sh` and `profile-config.sh` for detailed profiling scripts.

## Conclusion

The 1+ second startup time is primarily caused by:
1. **828ms** - Config loading (28 jq subprocess calls)
2. **400ms** - Usage API fetch (network + parsing)
3. **150ms** - Setup checks (file reads + grep/jq)
4. **100ms** - Git operations
5. **Remaining** - Various small subprocess calls

By implementing the recommended optimizations, startup time could be reduced to ~200-300ms, a **4-5x improvement**.
