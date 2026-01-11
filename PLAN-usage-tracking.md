# Plan: Add Session and Weekly Usage Tracking to ittybitty

## Overview
Add Claude API usage monitoring to `ib` to track session (5-hour) and weekly (7-day) usage percentages. This will help prevent agents from running when quotas are near exhaustion and provide visibility into resource consumption.

## Background

### Current State
- `ib` manages multiple Claude agents via tmux sessions
- Each agent can spawn sub-agents (manager/worker hierarchy)
- Watchdog system monitors agent state every 6 seconds
- Hooks intercept events (Stop, PermissionRequest)
- No current usage tracking or quota awareness

### API Details (from exploration)
- **Endpoint**: `https://api.anthropic.com/api/oauth/usage`
- **Authentication**: OAuth token from macOS Keychain (`Claude Code-credentials`)
- **Required header**: `anthropic-beta: oauth-2025-04-20`
- **Response format**:
```json
{
  "five_hour": {
    "utilization": 39.0,  // percentage 0-100
    "resets_at": "2025-12-12T20:59:59.707736+00:00"
  },
  "seven_day": {
    "utilization": 27.0,
    "resets_at": "2025-12-16T03:59:59.707754+00:00"
  }
}
```

### Reference Implementation
Claude Code's `~/.claude/statusline-command.sh` (148 lines) shows working implementation of:
- Keychain token retrieval
- ISO 8601 timestamp parsing
- Time remaining calculations
- Null-safe error handling

## Design Decisions (From User)

### 1. **Two-Threshold System**
- **Warning threshold** (default 80% session): Send warnings to managers, continue spawning
- **Critical threshold** (default 90% session): Block new spawns + force-stop all running agents
- Both configurable in `.ittybitty.json`

### 2. **Display Integration**
Usage stats displayed in:
- `ib watch` footer: `usage: 45%/62%`
- `ib list` header: Session/weekly % and reset times
- New `ib usage` command: Detailed view with `--json` support
- Watchdog tracks usage as its first task

### 3. **Centralized Usage Checking**
- Single "usage watchdog" runs when any agents are active
- Checks every 2 minutes (not per-agent, to avoid duplicate API calls)
- Updates shared cache `.ittybitty/usage-cache.json`
- Stops when last agent terminates

### 4. **Lifecycle**
- Auto-starts with first agent spawn
- Auto-stops when last agent dies
- Only runs when agents are active (no polling when idle)

## Proposed Architecture

### Component 1: Usage Fetcher (`fetch_usage`)
**Location**: New function in `ib` (~line 100, near other helper functions)

**Responsibilities**:
- Retrieve OAuth token from Keychain
- Call Anthropic usage API
- Parse JSON response
- Cache results to `.ittybitty/usage-cache.json`
- Return utilization percentages + reset times

**Caching strategy**:
- Cache file format:
```json
{
  "fetched_at": 1768111539,
  "five_hour": {
    "utilization": 39.0,
    "resets_at": "2025-12-12T20:59:59.707736+00:00",
    "resets_at_epoch": 1768111599
  },
  "seven_day": {
    "utilization": 27.0,
    "resets_at": "2025-12-16T03:59:59.707754+00:00",
    "resets_at_epoch": 1768415999
  }
}
```
- Cache TTL: 120 seconds (2 minutes)
- Refresh on cache miss or expiry

### Component 2: Usage Checker (`check_usage_limits`)
**Location**: New function called before agent spawn + by usage watchdog

**Responsibilities**:
- Read cached usage from `.ittybitty/usage-cache.json`
- Compare against two thresholds (warning + critical)
- Return status: OK | WARN | CRITICAL
- At spawn time: Block if CRITICAL
- In watchdog: Send warnings to managers (WARN), kill all agents (CRITICAL)

**Two-Threshold Logic**:
```bash
check_usage_limits() {
    local warn_threshold="${USAGE_WARN_THRESHOLD:-80}"
    local critical_threshold="${USAGE_CRITICAL_THRESHOLD:-90}"

    # Read from cache (watchdog keeps it fresh)
    local session=$(jq -r '.five_hour.utilization // 0' .ittybitty/usage-cache.json 2>/dev/null)

    if [[ $(echo "$session >= $critical_threshold" | bc) -eq 1 ]]; then
        echo "CRITICAL"
        return 2
    elif [[ $(echo "$session >= $warn_threshold" | bc) -eq 1 ]]; then
        echo "WARN"
        return 1
    fi
    echo "OK"
    return 0
}
```

**Spawn-time behavior**:
- OK: Spawn normally
- WARN: Log warning, spawn normally
- CRITICAL: Block spawn with error message

**Watchdog behavior**:
- OK: Continue monitoring
- WARN: Send notification to all manager agents (once per threshold cross)
- CRITICAL: Send urgent notification + kill all agents with `ib nuke --force`

### Component 3: Display Integration

#### A. `ib watch` Footer
**Location**: `watch_render_footer()` (~line 5040)

Add after `bg:Xs` status:
```
bg:5s  usage: 45%/62%  frame: 12ms  10:45:30 PM
```

Format: `usage: {session}%/{weekly}%`

#### B. `ib list` Output
**Location**: `cmd_list()` (~line 2100)

Add optional `--usage` flag to show usage in header:
```
AGENTS (Session: 45% | Weekly: 62% | resets in 2h 15m / 3d 12h):
```

#### C. New `ib usage` Command
**Location**: New `cmd_usage()` function

Detailed output:
```bash
$ ib usage
Session (5-hour rolling):  45% (resets in 2h 15m)
Weekly (7-day rolling):    62% (resets in 3d 12h)

Last checked: 30 seconds ago
```

With `--json` flag for programmatic access.

### Component 4: Usage Watchdog (`cmd_usage_watchdog`)
**Location**: New command function, auto-spawned with first agent

**Key Innovation**: Single centralized usage monitor (not per-agent watchdog)

**Lifecycle**:
1. **Start**: First agent spawn → check if usage watchdog exists → spawn if not
2. **Run**: Loop every 120 seconds:
   - Call `fetch_usage()` to refresh cache
   - Call `check_usage_limits()` to evaluate thresholds
   - Take action based on status (WARN/CRITICAL)
3. **Stop**: Detects when last agent terminates → exit cleanly

**Implementation approach**:
```bash
cmd_usage_watchdog() {
    local last_state="OK"

    while true; do
        # Check if any agents still running
        if ! list_running_agents | grep -q .; then
            # No agents left, exit watchdog
            exit 0
        fi

        # Refresh usage cache
        fetch_usage

        # Check thresholds
        local status=$(check_usage_limits)

        case "$status" in
            CRITICAL)
                if [[ "$last_state" != "CRITICAL" ]]; then
                    # First time crossing critical threshold
                    notify_all_managers "CRITICAL: Usage at critical level. Nuking all agents..."
                    ib nuke --force &
                fi
                last_state="CRITICAL"
                ;;
            WARN)
                if [[ "$last_state" == "OK" ]]; then
                    # First time crossing warning threshold
                    notify_all_managers "WARNING: Usage approaching limits (${session}%)"
                fi
                last_state="WARN"
                ;;
            OK)
                last_state="OK"
                ;;
        esac

        sleep 120
    done
}
```

**Storage**:
- PID stored in `.ittybitty/usage-watchdog.pid`
- Prevents duplicate usage watchdogs
- Allows clean shutdown

**Manager notifications**:
```bash
notify_all_managers() {
    local message="$1"
    # Find all manager agents (agents with manager=null)
    ib list --json | jq -r '.[] | select(.manager == null) | .id' | while read id; do
        ib send "$id" "[Usage Monitor] $message" >/dev/null 2>&1
    done
}
```

### Component 5: Configuration
**Location**: `.ittybitty.json`

New fields:
```json
{
  "usage": {
    "enabled": true,
    "warn_threshold": 80,
    "critical_threshold": 90,
    "check_interval": 120,
    "notify_managers": true,
    "auto_nuke_on_critical": true
  }
}
```

**Defaults** (if not in config):
- `enabled`: true
- `warn_threshold`: 80 (session %)
- `critical_threshold`: 90 (session %)
- `check_interval`: 120 seconds
- `notify_managers`: true
- `auto_nuke_on_critical`: true

## Implementation Steps

### Phase 1: Core Usage Fetcher
1. Add `fetch_usage()` function (~line 100)
   - Token retrieval from Keychain via `security find-generic-password`
   - API call with proper headers: `anthropic-beta: oauth-2025-04-20`
   - JSON parsing with jq
   - Cache write to `.ittybitty/usage-cache.json`
   - Error handling (missing token, API failures, network errors)

2. Add timestamp utilities
   - `parse_iso8601()` - convert ISO 8601 to epoch (handle macOS date format)
   - `format_time_remaining()` - convert epoch diff to "2h 15m" or "3d 12h"

3. Test fetcher standalone
   - Create test script to verify API access
   - Validate cache file format
   - Test error cases (no token, API down)

### Phase 2: Usage Checker & Config
4. Add `check_usage_limits()` function
   - Read thresholds from config (defaults: 80% warn, 90% critical)
   - Compare cached session % against thresholds
   - Return OK/WARN/CRITICAL status

5. Add config parsing
   - Read `.ittybitty.json` usage section
   - Set global variables: `USAGE_WARN_THRESHOLD`, `USAGE_CRITICAL_THRESHOLD`, etc.
   - Defaults if config missing

### Phase 3: Usage Watchdog
6. Add `cmd_usage_watchdog()` function
   - Background loop (every 120s)
   - Call `fetch_usage()` to refresh cache
   - Call `check_usage_limits()` to check thresholds
   - Send notifications to managers on threshold cross
   - Auto-nuke on CRITICAL if configured
   - Exit when last agent terminates

7. Add `start_usage_watchdog()` helper
   - Check if PID file exists (`.ittybitty/usage-watchdog.pid`)
   - Verify process is still running
   - Spawn new usage watchdog in background if needed
   - Store PID in file

8. Integrate into `cmd_new_agent()` (~line 1700)
   - Before spawn: Check if CRITICAL (block if so)
   - After spawn: Start usage watchdog if first agent
   - Log usage status at spawn time

### Phase 4: Display Integration
9. Update `watch_render_footer()` (~line 5040)
   - Read from cache: `.ittybitty/usage-cache.json`
   - Add `usage: X%/Y%` after bg status
   - Color code if WARN (yellow) or CRITICAL (red)

10. Update `cmd_list()` (~line 2100)
    - Add usage stats to header
    - Show reset times with `format_time_remaining()`
    - Display warning if approaching thresholds

11. Add `cmd_usage()` command
    - Detailed usage display with reset times
    - Show last checked timestamp
    - JSON output with `--json` flag
    - Force refresh with `--refresh` flag

### Phase 5: Testing & Polish
12. Add `notify_all_managers()` helper
    - Find all root agents (manager=null)
    - Send message via `ib send`
    - Log notifications to usage-watchdog log

13. Add `--ignore-usage` flag to `new-agent`
    - Allow emergency spawns even when CRITICAL
    - Log override decision to agent.log

14. Add cleanup on `ib nuke`
    - Kill usage watchdog
    - Remove PID file

## Critical Files

### Modified Files
- `/Users/adamwulf/Developer/bash/ittybitty/ib` - All implementation
  - Lines ~100-400: Add usage helper functions
    - `fetch_usage()` - API call and caching
    - `parse_iso8601()` - Timestamp conversion
    - `format_time_remaining()` - Human-readable time
    - `check_usage_limits()` - Two-threshold checker
    - `notify_all_managers()` - Send warnings
    - `start_usage_watchdog()` - Spawn/check watchdog
  - Lines ~1700: Modify `cmd_new_agent()`
    - Check CRITICAL before spawn (block if true)
    - Start usage watchdog after first spawn
    - Log usage status
  - Lines ~2100: Modify `cmd_list()`
    - Add usage header with reset times
    - Color code warnings
  - Lines ~3000: Add `cmd_usage_watchdog()`
    - New command for centralized usage monitoring
  - Lines ~3100: Add `cmd_usage()`
    - New command for usage display
  - Lines ~5040: Modify `watch_render_footer()`
    - Add `usage: X%/Y%` display
    - Color coding
  - Main command router: Add `usage` and `usage-watchdog` cases

### New Files
- `.ittybitty/usage-cache.json` - Runtime cache (gitignored)
  - Stores session/weekly % and reset times
  - Updated every 2 minutes by usage watchdog
- `.ittybitty/usage-watchdog.pid` - PID file for usage watchdog
  - Prevents duplicate watchdogs
  - Cleaned up on nuke

### Reference Files (Read-only)
- `~/.claude/statusline-command.sh` - Token retrieval pattern, timestamp parsing
- `~/.claude/settings.json` - Keychain service name verification

## Verification

### Manual Testing
1. **Fetch usage**: `ib usage` displays current stats
2. **Watch footer**: `ib watch` shows usage in bottom bar
3. **List header**: `ib list` shows usage in header
4. **Spawn blocking**: Try spawning when usage > threshold
5. **Cache behavior**: Run usage check twice, verify second is cached
6. **Token failure**: Rename keychain entry, verify graceful error
7. **Config override**: Test with `--ignore-usage` flag

### Edge Cases
- Missing OAuth token in Keychain
- API rate limiting or failures
- Expired cache with no network
- Invalid ISO 8601 timestamps
- Usage at exactly 100%
- Config file missing or malformed

### Integration Tests
1. Spawn agent with low usage - succeeds
2. Mock high usage (edit cache) - spawn blocked
3. Use `--ignore-usage` - spawn succeeds despite high usage
4. Kill all agents - usage stats still display
5. Watch multiple agents - usage updates in footer

## Summary

This plan adds comprehensive usage tracking to `ib` with:
- **Two-threshold system**: 80% warning, 90% critical (configurable)
- **Centralized monitoring**: Single usage watchdog (not per-agent)
- **Smart actions**: Warnings to managers at 80%, auto-nuke at 90%
- **Universal display**: Watch footer, list header, dedicated `ib usage` command
- **Efficient polling**: Every 2 minutes, only when agents running

Key technical decisions:
- Reuse OAuth token from Claude Code's Keychain entry
- Cache results in `.ittybitty/usage-cache.json` to minimize API calls
- Usage watchdog auto-starts with first agent, auto-stops with last agent
- Manager agents get notifications before critical actions

Ready to implement incrementally, testing each phase before moving forward.
