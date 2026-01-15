# Analysis: Rate Limit Detection and Automatic Recovery

## Executive Summary

This document analyzes how to implement automatic rate limit detection and recovery for ittybitty agents. When Claude hits a rate limit, the system should detect the rate limit screen in tmux, bypass it, and automatically resume the agent with a new session once usage refreshes.

**Status: IMPLEMENTED** - See commit `6bbc773` on branch `agent/rate-limit-impl`.

## Existing Capabilities

### 1. Tmux Output Detection (`parse_state` / `get_state`)

**Location:** `ib:1219-1367` (parse_state), `ib:1369-1435` (get_state)

The system already has sophisticated tmux output parsing:

| Pattern | Detection Method |
|---------|------------------|
| Running | `(esc to interrupt)`, `⎿  Running`, spinners |
| Complete | `I HAVE COMPLETED THE GOAL` |
| Waiting | Standalone `WAITING` |
| Creating | Permission prompts + no Claude logo |
| **Rate Limited** | `usage limit reached`, `limit will reset at`, `rate_limit_error` |

**How it works:**
```bash
capture_tmux "$tmux_session" 20  # Get last 20 lines
parse_state "$recent"            # Pattern match for state
```

### 2. Usage Data Fetching (`fetch_claude_usage`)

**Location:** `ib:626-713`

Already implemented:
- OAuth token retrieval from macOS Keychain
- API call to `https://api.anthropic.com/api/oauth/usage`
- Returns session (5-hour) and weekly (7-day) utilization percentages
- Global variables: `_USAGE_SESSION_PCT`, `_USAGE_WEEKLY_PCT`, `_USAGE_SESSION_RESET`, `_USAGE_WEEKLY_RESET`

```bash
fetch_claude_usage() {
    # Gets token from Keychain
    # Calls API with Bearer token
    # Sets _USAGE_SESSION_PCT, _USAGE_WEEKLY_PCT, _USAGE_SESSION_RESET, _USAGE_WEEKLY_RESET
}
```

### 3. Message Sending (`cmd_send`)

**Location:** `ib:3317-3439`

Already implemented:
- Send text to agent's tmux stdin
- Auto-detection of sender agent (for prefixing)
- Proper timing (message first, Enter separately with 0.1s delay)

```bash
tmux send-keys -t "$TMUX_SESSION" "$MESSAGE"
sleep 0.1
tmux send-keys -t "$TMUX_SESSION" Enter
```

### 4. Watchdog System (`cmd_watchdog`)

**Location:** `ib:8191-8530`

Already implemented:
- Monitors agent state every 5 seconds
- Exponential backoff notifications
- Notifies manager on state changes (waiting, complete, unknown, **rate_limited**)
- Continues until agent worktree is removed

### 5. Agent Resume (`cmd_resume`)

**Location:** `ib:4159-4338`

Already implemented:
- Resumes stopped agents using `claude --resume <session_id>`
- Recreates tmux session
- Auto-accepts workspace trust dialogs

---

## Research Findings (CONFIRMED)

### Rate Limit Screen Patterns

**Source:** GitHub Issues #2087, #3169, #9046, #8620, #9236

**Confirmed Patterns:**
1. **Usage limit message:** `Claude usage limit reached. Your limit will reset at [TIME] ([TIMEZONE]).`
   - Examples:
     - `Claude usage limit reached. Your limit will reset at 3pm (America/Santiago).`
     - `Claude usage limit reached. Your limit will reset at Oct 7, 1am.`
     - `Claude usage limit reached. Your limit will reset at 1pm (Etc/GMT+5).`

2. **API error response:** `Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded the usage limit."}}`

**Detection Implementation:**
```bash
# In parse_state() - ib:1283-1302
# Check for rate_limit_error (exact match, case-sensitive)
if [[ "$last_lines" == *"rate_limit_error"* ]]; then
    echo "rate_limited"
    return
fi

# Case-insensitive check for usage limit patterns
shopt -s nocasematch
if [[ "$last_lines" == *"usage limit reached"* ]] || \
   [[ "$last_lines" == *"limit will reset at"* ]]; then
    echo "rate_limited"
    return
fi
```

### Bypass Mechanism

**Source:** User confirmation

**Confirmed:** Press **Enter** to dismiss the rate limit dialog.
- The first option shown is "Wait for limit reset" (or similar)
- After pressing Enter, Claude waits for usage to refresh
- Session remains valid - no need to restart

**Implementation:**
```bash
# bypass_rate_limit() - ib:1566-1603
bypass_rate_limit() {
    local TMUX_SESSION="$1"
    # Send Enter to dismiss (selects "Wait for limit reset")
    tmux send-keys -t "$TMUX_SESSION" Enter
    # Verify dismissal by checking state
    ...
}
```

### Recovery Flow

**Confirmed workflow:**
1. `parse_state()` detects `rate_limited` state
2. `bypass_rate_limit()` sends Enter key to dismiss dialog
3. Watchdog polls `fetch_claude_usage()` every 5 seconds
4. When `_USAGE_SESSION_PCT` drops below 80%, send nudge message
5. Agent receives: `[watchdog]: Usage has refreshed. Please continue your task.`

---

## Implementation (COMPLETE)

### Component 1: Detection in `parse_state()`

**Location:** `ib:1283-1302`

```bash
# Check for rate limit screen (high priority - blocks agent progress)
# These patterns appear when Claude hits usage limits:
# - "Claude usage limit reached. Your limit will reset at 3pm"
# - "Error: 429 {"type":"error","error":{"type":"rate_limit_error"..."
if [[ "$last_lines" == *"rate_limit_error"* ]]; then
    echo "rate_limited"
    return
fi
# Case-insensitive check for usage limit patterns
local old_nocasematch
old_nocasematch=$(shopt -p nocasematch 2>/dev/null || true)
shopt -s nocasematch
if [[ "$last_lines" == *"usage limit reached"* ]] || \
   [[ "$last_lines" == *"limit will reset at"* ]]; then
    eval "$old_nocasematch" 2>/dev/null || shopt -u nocasematch
    echo "rate_limited"
    return
fi
eval "$old_nocasematch" 2>/dev/null || shopt -u nocasematch
```

### Component 2: Bypass Function

**Location:** `ib:1566-1603`

```bash
# Bypass rate limit dialog by sending Enter (selects "wait for reset" option)
# Returns 0 if rate limit screen was dismissed, 1 if still showing
bypass_rate_limit() {
    local TMUX_SESSION="$1"
    local max_attempts=3
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        # Check if rate limit screen is still showing
        local recent_output
        recent_output=$(tmux capture-pane -t "$TMUX_SESSION" -p -S -20 2>/dev/null) || return 1

        # Use parse_state to check for rate_limited
        local state
        state=$(parse_state "$recent_output")
        if [[ "$state" != "rate_limited" ]]; then
            return 0  # Rate limit screen dismissed
        fi

        # Send Enter to dismiss (selects first option: "Wait for limit reset")
        tmux send-keys -t "$TMUX_SESSION" Enter
        attempt=$((attempt + 1))

        # Wait for screen to update
        sleep 2
    done

    # Check one more time after all attempts
    local final_output
    final_output=$(tmux capture-pane -t "$TMUX_SESSION" -p -S -20 2>/dev/null) || return 1
    local final_state
    final_state=$(parse_state "$final_output")
    if [[ "$final_state" != "rate_limited" ]]; then
        return 0
    fi

    return 1  # Failed to dismiss after max attempts
}
```

### Component 3: Watchdog Integration

**Location:** `ib:8452-8502`

```bash
rate_limited)
    # Agent hit a rate limit - need to bypass dialog and wait for usage to refresh
    local TMUX_SESSION
    TMUX_SESSION=$(session_name "$AGENT_ID")

    if [[ "$prev_state" != "rate_limited" ]]; then
        echo "[watchdog] Agent state: rate_limited (usage limit hit)"
        log_agent "$AGENT_ID" "[watchdog] Rate limit detected" --quiet

        # Attempt to bypass the rate limit dialog
        echo "[watchdog] Attempting to bypass rate limit dialog..."
        if bypass_rate_limit "$TMUX_SESSION"; then
            echo "[watchdog] Rate limit dialog dismissed, agent waiting for usage refresh"
            log_agent "$AGENT_ID" "[watchdog] Rate limit dialog dismissed" --quiet
        else
            echo "[watchdog] Warning: Could not dismiss rate limit dialog"
            log_agent "$AGENT_ID" "[watchdog] Warning: Rate limit dialog still showing" --quiet
        fi
    fi

    # Check usage API to see if we can resume
    # Recovery threshold: 80% (wait until usage drops below this)
    local recovery_threshold=80
    if fetch_claude_usage; then
        local session_pct="${_USAGE_SESSION_PCT:-100}"
        echo "[watchdog] Current usage: session=${session_pct}% (recovery at <${recovery_threshold}%)"

        if [[ -n "$session_pct" ]] && [[ "$session_pct" -lt "$recovery_threshold" ]]; then
            echo "[watchdog] Usage refreshed! Nudging agent to continue..."
            log_agent "$AGENT_ID" "[watchdog] Usage refreshed (${session_pct}%), sending nudge" --quiet

            # Send nudge message to agent
            ib send "$AGENT_ID" "[watchdog]: Usage has refreshed. Please continue your task."
        else
            # Log reset time if available
            if [[ -n "$_USAGE_SESSION_RESET" ]]; then
                echo "[watchdog] Usage still high, reset in: $_USAGE_SESSION_RESET"
            fi
        fi
    else
        echo "[watchdog] Warning: Could not fetch usage data"
    fi

    # Reset counters since we're handling this state specially
    waiting_counter=0
    notify_interval=6
    ;;
```

---

## Test Fixtures (COMPLETE)

**Location:** `tests/fixtures/`

| Fixture | Purpose |
|---------|---------|
| `rate_limited-api-error-429.txt` | API 429 error with rate_limit_error |
| `rate_limited-simple-usage-limit.txt` | Basic "usage limit reached" message |
| `rate_limited-usage-limit-with-date.txt` | Reset time with date format (Oct 7, 1am) |
| `rate_limited-usage-limit-with-timezone.txt` | Reset time with timezone (America/Santiago) |
| `unknown-mentions-rate-limit.txt` | False positive test (discussion text) |

Run tests:
```bash
./tests/test-parse-state.sh
# Expected: All rate_limited-*.txt fixtures return "rate_limited"
# Expected: unknown-mentions-rate-limit.txt returns "unknown"
```

---

## Risks and Mitigations

### 1. Pattern Detection Accuracy

**Risk:** False positives from discussion text containing "rate limit"

**Mitigation (IMPLEMENTED):**
- Use specific phrases: "usage limit reached", "limit will reset at"
- Check `rate_limit_error` for API errors (exact match)
- Test fixture `unknown-mentions-rate-limit.txt` ensures false positive prevention
- Detection in last 15 lines only, not full history

### 2. Bypass Key (RESOLVED)

**Confirmed:** Enter key dismisses the dialog. First option is "Wait for limit reset".

### 3. Race Conditions

**Risk:** Agent continues working, then rate limit screen appears mid-output

**Mitigation (IMPLEMENTED):**
- Rate limit detection happens after active running indicators check
- Only last 15 lines checked for rate limit patterns
- Watchdog polls every 5 seconds

### 4. Session Invalidation

**Status:** Not a concern - sessions remain valid after rate limit. The dialog just blocks interaction until dismissed.

### 5. Timing Complexity

**Mitigation (IMPLEMENTED):**
- Poll usage API to check actual current usage
- Wait until below 80% threshold before sending nudge
- Display reset time from API when available

### 6. Multiple Agents Rate Limited

**Current approach:** Each agent's watchdog handles its own rate limit independently.

**Future enhancement:** Central monitor could coordinate recovery order.

### 7. Infinite Loop Prevention

**Current approach:** After nudge is sent, agent continues. If it immediately hits rate limit again, the watchdog will detect and wait again.

**Future enhancement:** Track recovery attempts per agent, implement cooldown.

---

## Implementation Status

| Phase | Status |
|-------|--------|
| Phase 1: Research | ✅ COMPLETE - Patterns and bypass key confirmed |
| Phase 2: Detection | ✅ COMPLETE - `rate_limited` state in `parse_state()` |
| Phase 3: Bypass | ✅ COMPLETE - `bypass_rate_limit()` function |
| Phase 4: Watchdog Integration | ✅ COMPLETE - `rate_limited` case added |
| Phase 5: Central Monitor | ⏸ DEFERRED - Not needed for initial implementation |
| Phase 6: Polish | ⏸ DEFERRED - Can add UI enhancements later |

---

## Configuration Options

Currently hardcoded, could be added to `.ittybitty.json` in future:

```json
{
  "rateLimit": {
    "autoRecover": true,           // Enable automatic recovery (currently always on)
    "recoveryThreshold": 80,       // Resume when usage drops below this % (hardcoded)
    "maxRecoveryAttempts": 3,      // Max bypass attempts (hardcoded in bypass_rate_limit)
    "recoveryMessage": "[watchdog]: Usage has refreshed. Please continue your task."
  }
}
```

---

## Summary

**What's implemented:**
- ✅ Rate limit screen detection via `parse_state()` returning `rate_limited`
- ✅ Bypass function sending Enter key to dismiss dialog
- ✅ Watchdog integration polling usage API
- ✅ Automatic nudge message when usage refreshes below 80%
- ✅ Test fixtures for all known rate limit patterns
- ✅ False positive prevention test

**Sources:**
- GitHub Issues: #2087, #3169, #9046, #8620, #9236
- User confirmation of Enter key bypass mechanism
