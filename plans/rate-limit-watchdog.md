# Analysis: Rate Limit Detection and Automatic Recovery

## Executive Summary

This document analyzes how to implement automatic rate limit detection and recovery for ittybitty agents. When Claude hits a rate limit, the system should detect the rate limit screen in tmux, bypass it, and automatically resume the agent with a new session once usage refreshes.

## Existing Capabilities

### 1. Tmux Output Detection (`parse_state` / `get_state`)

**Location:** `ib:1131-1245` (parse_state), `ib:1250-1301` (get_state)

The system already has sophisticated tmux output parsing:

| Pattern | Detection Method |
|---------|------------------|
| Running | `(esc to interrupt)`, `⎿  Running`, spinners |
| Complete | `I HAVE COMPLETED THE GOAL` |
| Waiting | Standalone `WAITING` |
| Creating | Permission prompts + no Claude logo |

**How it works:**
```bash
capture_tmux "$tmux_session" 20  # Get last 20 lines
parse_state "$recent"            # Pattern match for state
```

### 2. Usage Data Fetching (`fetch_claude_usage`)

**Location:** `ib:577-625`

Already implemented:
- OAuth token retrieval from macOS Keychain
- API call to `https://api.anthropic.com/api/oauth/usage`
- Returns session (5-hour) and weekly (7-day) utilization percentages
- Global variables: `_USAGE_SESSION_PCT`, `_USAGE_WEEKLY_PCT`

```bash
fetch_claude_usage() {
    # Gets token from Keychain
    # Calls API with Bearer token
    # Sets _USAGE_SESSION_PCT and _USAGE_WEEKLY_PCT
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

**Location:** `ib:7933-8161`

Already implemented:
- Monitors agent state every 5 seconds
- Exponential backoff notifications
- Notifies manager on state changes (waiting, complete, unknown)
- Continues until agent worktree is removed

### 5. Agent Resume (`cmd_resume`)

**Location:** `ib:4159-4338`

Already implemented:
- Resumes stopped agents using `claude --resume <session_id>`
- Recreates tmux session
- Auto-accepts workspace trust dialogs

---

## What Needs to Be Built

### 1. Rate Limit Screen Detection

**Critical Gap:** We don't know exactly what the rate limit screen looks like in Claude Code.

**Research Needed:**
1. Capture actual rate limit screen text from Claude Code
2. Identify unique patterns that won't appear in normal output
3. Likely patterns to look for:
   - "rate limit" (case insensitive)
   - "usage limit"
   - "Try again in X minutes/hours"
   - "session limit reached"
   - Reset time information
   - Any special UI elements (boxes, indicators)

**Detection Strategy:**

Add a new state `rate_limited` to the state machine:

```bash
# In parse_state(), before other checks:
# Check for rate limit screen (priority over other states)
if [[ "$last_lines" =~ rate.?limit|usage.?limit|Try\ again\ in ]]; then
    # Verify this is the actual rate limit screen, not discussion text
    if [[ "$last_lines" =~ reset|wait|limit.*reached ]]; then
        echo "rate_limited"
        return
    fi
fi
```

### 2. Rate Limit Bypass

**Approach:** Similar to `auto_accept_workspace_trust`

When rate limit screen detected:
1. Send key to dismiss the rate limit dialog (likely Escape, Enter, or 'q')
2. Wait for screen to change
3. Verify Claude is back to normal prompt

```bash
auto_bypass_rate_limit() {
    local TMUX_SESSION="$1"
    local max_attempts=5
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        # Check if rate limit screen is showing
        capture_tmux "$TMUX_SESSION" 20
        if ! [[ "$LAST_TMUX_CAPTURE" =~ rate.?limit ]]; then
            return 0  # Already bypassed
        fi

        # Send key to dismiss (TBD: need to determine correct key)
        tmux send-keys -t "$TMUX_SESSION" Enter  # or Escape or 'q'
        sleep 2
        attempt=$((attempt + 1))
    done

    return 1  # Failed to bypass
}
```

### 3. Rate Limit Watchdog Enhancement

**Option A: Enhance Existing Watchdog**

Add `rate_limited` handling to `cmd_watchdog`:

```bash
case "$state" in
    rate_limited)
        if [[ "$prev_state" != "rate_limited" ]]; then
            log_agent "$AGENT_ID" "[watchdog] Rate limit detected"
        fi

        # Check if usage has refreshed
        fetch_claude_usage
        if [[ "$_USAGE_SESSION_PCT" -lt 90 ]]; then
            # Usage refreshed, try to bypass
            auto_bypass_rate_limit "$TMUX_SESSION"

            # Send message to wake agent
            ib send "$AGENT_ID" "[watchdog]: Rate limit cleared. Please continue your task."
        fi
        ;;
esac
```

**Option B: Dedicated Rate Limit Monitor**

Create a separate process that:
1. Periodically checks all agents for rate limit state
2. Monitors usage API for refresh
3. Bypasses and notifies when safe

### 4. Usage Reset Time Tracking

**Enhancement:** Track when usage will reset

```bash
# In fetch_claude_usage, also capture reset time:
_USAGE_SESSION_RESET=$(echo "$response" | jq -r '.five_hour.resets_at // empty')

# Convert to epoch for comparison
_USAGE_SESSION_RESET_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${_USAGE_SESSION_RESET%.*}" "+%s" 2>/dev/null)
```

This enables smart waiting - instead of polling, wait until the known reset time.

---

## Implementation Architecture

### Component 1: Detection Function

```bash
# Detect if agent is on rate limit screen
# Returns: 0 if rate limited, 1 if not
is_rate_limited() {
    local session="$1"
    capture_tmux "$session" 30

    # Pattern match for rate limit indicators
    # TBD: Exact patterns once screen is captured
    if [[ "$LAST_TMUX_CAPTURE" =~ RATE_LIMIT_PATTERN ]]; then
        return 0
    fi
    return 1
}
```

### Component 2: Bypass Function

```bash
# Attempt to bypass rate limit screen
# Returns: 0 on success, 1 on failure
bypass_rate_limit() {
    local session="$1"

    # Send dismissal key
    tmux send-keys -t "$session" KEY_TBD
    sleep 2

    # Verify bypass worked
    if ! is_rate_limited "$session"; then
        return 0
    fi
    return 1
}
```

### Component 3: Recovery Function

```bash
# Full rate limit recovery flow
recover_from_rate_limit() {
    local agent_id="$1"
    local session=$(session_name "$agent_id")

    # 1. Bypass the rate limit screen
    if ! bypass_rate_limit "$session"; then
        log_agent "$agent_id" "[rate-limit] Failed to bypass screen"
        return 1
    fi

    # 2. Send continuation message
    ib send "$agent_id" "[rate-limit]: Usage has refreshed. Please continue your task."

    log_agent "$agent_id" "[rate-limit] Recovery complete"
    return 0
}
```

### Component 4: Watchdog Integration

Two approaches:

**Approach A: Per-Agent Monitoring**
- Each agent's watchdog checks for rate limit state
- On detection, enters waiting loop until usage refreshes
- Triggers recovery

**Approach B: Central Rate Limit Monitor**
- Single background process monitors all agents
- More efficient (one usage API call serves all agents)
- Coordinates recovery for multiple agents

Recommendation: **Approach B** - Central monitor is more efficient when multiple agents hit limits simultaneously.

---

## Risks and Edge Cases

### 1. Pattern Detection Accuracy

**Risk:** False positives from discussion text containing "rate limit"

**Mitigation:**
- Use multiple pattern indicators (not just one phrase)
- Check for rate limit UI elements (boxes, specific formatting)
- Require pattern to appear in last N lines only
- Verify absence of running/thinking indicators

### 2. Bypass Key Unknown

**Risk:** We don't know the correct key to dismiss rate limit screen

**Research Needed:**
- Manually trigger rate limit in Claude Code
- Document the dismissal key (Escape? Enter? 'q'? 'c'?)
- Test on macOS

### 3. Race Conditions

**Risk:** Agent continues working, then rate limit screen appears mid-output

**Mitigation:**
- Only detect rate limit when no running indicators present
- Use recent output window (last 5-10 lines) not full history
- Add debounce (require rate limit for 2+ consecutive checks)

### 4. Session Invalidation

**Risk:** After rate limit, session might be invalidated

**Mitigation:**
- Check if `claude --resume` still works after rate limit
- If not, need to handle starting fresh session
- Preserve conversation history if possible

### 5. Timing Complexity

**Risk:** Usage refresh timing varies, hard to predict when safe to continue

**Mitigation:**
- Use usage API to check actual current usage
- Wait until below threshold (e.g., 80%) before resuming
- Implement exponential backoff if recovery fails

### 6. Multiple Agents Rate Limited

**Risk:** All agents hit rate limit simultaneously, all try to resume

**Mitigation:**
- Stagger recovery attempts
- Central monitor coordinates recovery order
- Prioritize root managers, then cascade to workers

### 7. Infinite Loop Prevention

**Risk:** Agent immediately hits rate limit again after recovery

**Mitigation:**
- Track recovery attempts per agent
- Implement cooldown period
- Notify manager/user after N failed recoveries

---

## Testing Strategy

### 1. Unit Tests for Detection

Create test fixtures in `tests/fixtures/rate-limit/`:

```
tests/fixtures/
├── ratelimit-simple.txt          # Basic rate limit screen
├── ratelimit-with-timer.txt      # Screen showing reset countdown
├── running-mentions-ratelimit.txt # Discussion text (should NOT detect)
├── unknown-ratelimit-in-history.txt # Rate limit in scroll history
```

Run with:
```bash
ib parse-state tests/fixtures/ratelimit-simple.txt
# Expected: rate_limited
```

### 2. Integration Tests

Manual testing scenarios:

| Test | Steps | Expected |
|------|-------|----------|
| Detection | Hit rate limit, run `ib list` | Shows "rate_limited" state |
| Bypass | Hit rate limit, check `ib watch` | Shows rate limit, then recovery |
| Recovery | Let usage refresh naturally | Agent continues automatically |
| False positive | Agent discusses rate limits | Should NOT show rate_limited |

### 3. Mocking for Automated Tests

Create `test-rate-limit-detect`:
```bash
cmd_test_rate_limit_detect() {
    local input
    if [[ -n "$1" && -f "$1" ]]; then
        input=$(cat "$1")
    else
        input=$(cat)
    fi

    if is_rate_limit_screen "$input"; then
        echo "rate_limited"
    else
        echo "not_rate_limited"
    fi
}
```

### 4. End-to-End Testing

1. **Simulated rate limit**: Create test fixture that mimics rate limit screen
2. **Real rate limit**: Intentionally exhaust rate limit (expensive but thorough)
3. **Recovery verification**: Monitor that agent continues task after recovery

---

## Implementation Steps

### Phase 1: Research (HIGH PRIORITY)
1. **Capture actual rate limit screen** - Need real text to base detection on
2. **Document bypass key** - Which key dismisses the rate limit dialog
3. **Test session persistence** - Does `--resume` work after rate limit?

### Phase 2: Detection
1. Add `rate_limited` state to `parse_state()`
2. Create test fixtures for rate limit patterns
3. Add test command `test-rate-limit-detect`
4. Run `tests/test-parse-state.sh` to verify no regressions

### Phase 3: Bypass
1. Implement `is_rate_limited()` helper
2. Implement `bypass_rate_limit()` function
3. Test bypass manually
4. Add bypass retry logic

### Phase 4: Watchdog Integration
1. Add `rate_limited` case to `cmd_watchdog`
2. Implement wait-for-refresh logic
3. Trigger recovery when usage drops
4. Send notification message to agent

### Phase 5: Central Monitor (Optional)
1. Create `cmd_rate_limit_monitor` if needed
2. Coordinate multi-agent recovery
3. Add to `ib watch` display

### Phase 6: Polish
1. Add rate limit status to `ib watch` UI
2. Add `--skip-rate-limit` flag to `new-agent` (for testing)
3. Document in CLAUDE.md
4. Add to error cache system

---

## Configuration Options

Add to `.ittybitty.json`:

```json
{
  "rateLimit": {
    "autoRecover": true,           // Enable automatic recovery
    "recoveryThreshold": 80,       // Resume when usage drops below this %
    "maxRecoveryAttempts": 3,      // Max tries before giving up
    "recoveryMessage": "[rate-limit]: Usage refreshed. Please continue."
  }
}
```

---

## Summary

**What we have:**
- Tmux output parsing infrastructure
- Usage API access
- Message sending
- Watchdog monitoring
- Agent resume capability

**What we need:**
1. Rate limit screen text patterns (research required)
2. Bypass key for rate limit dialog (research required)
3. New `rate_limited` state in state machine
4. Recovery function with usage checking
5. Watchdog integration or central monitor

**Key risks:**
- Unknown rate limit screen appearance
- Unknown bypass mechanism
- False positives from discussion text
- Session invalidation after rate limit
- Multi-agent coordination

**Next steps:**
1. Manually trigger rate limit in Claude Code
2. Capture exact screen text
3. Document bypass key
4. Create test fixtures
5. Implement detection
6. Implement recovery
