# Plan: Per-Agent Token Tracking with Manager Rollup

## Overview
Track token usage per agent to answer "how expensive has this agent been?" with automatic rollup of worker costs to their managers. This provides visibility into which tasks consume the most quota.

## User Goal
> "I'd basically like to know 'how expensive has this agent been?' and have the 'expense' of a manager's workers roll up to the manager when they close out. This way, a user can see which tasks they've assigned are using how much of their session/weekly usage."

**Key difference from global usage tracking**: This tracks per-agent attribution, not total quota or thresholds.

## Background

### Claude Code Token Storage
Based on exploration (agent af1a67b), Claude Code stores detailed token usage:

**Session Files**: `~/.claude/projects/<project-path>/<session-id>.jsonl`
- Each API response contains usage data:
```json
{
  "message": {
    "usage": {
      "input_tokens": 10,
      "output_tokens": 5,
      "cache_read_input_tokens": 16136,
      "cache_creation_input_tokens": 7891,
      "cache_creation": {
        "ephemeral_5m_input_tokens": 7891,
        "ephemeral_1h_input_tokens": 0
      }
    }
  }
}
```

**Agent Session Mapping**: `.ittybitty/agents/<id>/meta.json` contains `session_id`
- Example: `"session_id": "f19fb57b-be70-4cad-93c5-bf4d24f5e5c2"`
- Maps to session file: `~/.claude/projects/-Users-adamwulf-Developer-bash-ittybitty--ittybitty-agents-<id>-repo/<session-id>.jsonl`

**Subagent Sessions**: When agents spawn via Task tool, tracked in parent's subagents directory
- Location: `~/.claude/projects/<parent-session>/subagents/agent-<id>.jsonl`

### Token Types
| Token Type | Description | Cost Impact |
|------------|-------------|-------------|
| `input_tokens` | New input tokens (non-cached) | Full cost |
| `output_tokens` | Generated response tokens | Full cost |
| `cache_read_input_tokens` | Tokens read from cache | ~10% cost |
| `cache_creation_input_tokens` | Tokens written to cache | Full cost + storage |

## Design

### Data Model

Add `tokens` section to `.ittybitty/agents/<id>/meta.json`:

```json
{
  "id": "manager-abc",
  "session_id": "f19fb57b-...",
  "manager": null,
  "tokens": {
    "direct": {
      "input": 5000,
      "output": 2000,
      "cache_read": 15000,
      "cache_creation": 7891,
      "api_calls": 12,
      "last_line": 145
    },
    "workers": {
      "input": 8000,
      "output": 3500,
      "cache_read": 25000,
      "cache_creation": 12000,
      "api_calls": 20,
      "agents": ["worker-1", "worker-2"]
    },
    "total": {
      "input": 13000,
      "output": 5500,
      "cache_read": 40000,
      "cache_creation": 19891,
      "api_calls": 32
    },
    "last_updated": 1768111539
  }
}
```

**Fields**:
- `direct`: This agent's own API calls
- `workers`: Cumulative total from all merged child agents
- `total`: `direct + workers` (computed on read)
- `last_line`: Last session JSONL line processed (for incremental updates)
- `last_updated`: Epoch timestamp of last token update

### When to Update Tokens

| Event | Action | Performance |
|-------|--------|-------------|
| **Watch screen refresh** | Update selected agent only (incremental read) | ~10ms per agent |
| **Agent merge** | Finalize worker tokens, rollup to manager | One-time cost |
| **`ib status <id>`** | Update and display token breakdown | On-demand |
| **`ib tokens <id>`** | Detailed token report | On-demand |

**Optimization**: Incremental session file reading
- Store `last_line` in meta.json
- Only read lines after `last_line` on updates
- Reduces I/O for long sessions

### Token Rollup on Merge

When `ib merge <worker-id>` executes:

```bash
cmd_merge() {
    # ... existing merge logic ...

    # BEFORE branch merge, after git operations:

    # 1. Finalize worker's token count
    update_agent_tokens "$AGENT_ID"

    # 2. Read worker's tokens
    local worker_tokens=$(jq '.tokens.total' "$AGENT_DIR/meta.json")

    # 3. Get manager ID
    local manager_id=$(jq -r '.manager' "$AGENT_DIR/meta.json")

    # 4. If has manager, rollup tokens
    if [[ "$manager_id" != "null" && -n "$manager_id" ]]; then
        rollup_tokens_to_manager "$AGENT_ID" "$manager_id"
    fi

    # ... continue with merge ...
}
```

**Rollup function**:
```bash
rollup_tokens_to_manager() {
    local worker_id="$1"
    local manager_id="$2"
    local manager_dir="$ITTYBITTY_DIR/agents/$manager_id"

    # Read worker's total tokens
    local worker_input=$(jq '.tokens.total.input // 0' "$ITTYBITTY_DIR/agents/$worker_id/meta.json")
    local worker_output=$(jq '.tokens.total.output // 0' "$ITTYBITTY_DIR/agents/$worker_id/meta.json")
    local worker_cache_read=$(jq '.tokens.total.cache_read // 0' "$ITTYBITTY_DIR/agents/$worker_id/meta.json")
    local worker_cache_creation=$(jq '.tokens.total.cache_creation // 0' "$ITTYBITTY_DIR/agents/$worker_id/meta.json")
    local worker_calls=$(jq '.tokens.total.api_calls // 0' "$ITTYBITTY_DIR/agents/$worker_id/meta.json")

    # Update manager's workers section
    jq --arg worker_id "$worker_id" \
       --argjson input "$worker_input" \
       --argjson output "$worker_output" \
       --argjson cache_read "$worker_cache_read" \
       --argjson cache_creation "$worker_cache_creation" \
       --argjson calls "$worker_calls" \
       '.tokens.workers.input += $input |
        .tokens.workers.output += $output |
        .tokens.workers.cache_read += $cache_read |
        .tokens.workers.cache_creation += $cache_creation |
        .tokens.workers.api_calls += $calls |
        .tokens.workers.agents += [$worker_id] |
        .tokens.workers.agents |= unique |
        .tokens.last_updated = now' \
       "$manager_dir/meta.json" > "$manager_dir/meta.json.tmp"

    mv "$manager_dir/meta.json.tmp" "$manager_dir/meta.json"

    log_agent "$manager_id" "Rolled up tokens from worker $worker_id: ${worker_input}in/${worker_output}out/${worker_cache_read}cache"
}
```

### Display Integration

#### A. Watch Screen - Agent Info Section

Current display (lines 5236-5294):
```
┌─ AGENT: my-agent ──────────────────┐
│ Model: sonnet                      │
│ Prompt: Fix the build errors      │
└────────────────────────────────────┘
```

Enhanced display:
```
┌─ AGENT: my-agent ──────────────────┐
│ Model: sonnet                      │
│ Prompt: Fix the build errors      │
│ Tokens: 5.0K in / 2.0K out (12 API)│
│ Workers: +8.0K in / +3.5K out      │
│ Total: 13.0K / 5.5K (32 API)       │
└────────────────────────────────────┘
```

**Format options**:
1. **Compact**: `tokens: 13K/5.5K (32 calls)` - single line, total only
2. **Standard**: Three lines (direct/workers/total) - full breakdown
3. **Detailed**: Include cache reads/creation

**Recommendation**: Start with Standard format, make configurable later.

#### B. `ib status <id>` Command

Current output:
```
Agent: my-agent
Branch: agent/my-agent
Status: 2 commits ahead

Recent commits:
  abc123 Fix build errors
  def456 Update tests
```

Enhanced output:
```
Agent: my-agent
Branch: agent/my-agent
Status: 2 commits ahead

Token Usage:
  Direct:  5.0K input / 2.0K output / 15K cache (12 API calls)
  Workers: 8.0K input / 3.5K output / 25K cache (20 API calls, 2 agents)
  Total:   13.0K input / 5.5K output / 40K cache (32 API calls)

  Cost estimate: ~$0.15 (approximate)

Recent commits:
  abc123 Fix build errors
  def456 Update tests
```

#### C. New `ib tokens <id>` Command

Detailed token breakdown:
```bash
$ ib tokens manager-abc

Agent: manager-abc (session: f19fb57b-...)
State: running
Last updated: 5 seconds ago

Direct API Calls (12 calls):
  Input tokens:          5,000
  Output tokens:         2,000
  Cache read:           15,000 (~10% cost)
  Cache creation:        7,891

Worker Agents (2 agents: worker-1, worker-2):
  Input tokens:          8,000
  Output tokens:         3,500
  Cache read:           25,000 (~10% cost)
  Cache creation:       12,000

Total:
  Input tokens:         13,000
  Output tokens:         5,500
  Cache read:           40,000
  Cache creation:       19,891
  Total API calls:          32

Estimated cost: $0.15 USD
```

With `--json` flag:
```json
{
  "agent_id": "manager-abc",
  "session_id": "f19fb57b-...",
  "state": "running",
  "last_updated": 1768111539,
  "direct": {
    "input": 5000,
    "output": 2000,
    "cache_read": 15000,
    "cache_creation": 7891,
    "api_calls": 12
  },
  "workers": {
    "input": 8000,
    "output": 3500,
    "cache_read": 25000,
    "cache_creation": 12000,
    "api_calls": 20,
    "agents": ["worker-1", "worker-2"]
  },
  "total": {
    "input": 13000,
    "output": 5500,
    "cache_read": 40000,
    "cache_creation": 19891,
    "api_calls": 32
  }
}
```

#### D. `ib list` - Optional Token Column

Add `--tokens` flag:
```bash
$ ib list --tokens

AGENTS:
ID          STATE      TOKENS (in/out)    WORKERS        MANAGER
manager-1   running    5.0K/2.0K          +8.0K/+3.5K    -
worker-1    complete   4.0K/1.5K          -              manager-1
worker-2    running    4.0K/2.0K          -              manager-1
```

## Implementation

### Phase 1: Core Token Reading

**Files to modify**: `ib` script

**New functions**:

```bash
# Read tokens from agent's session JSONL (incremental)
# Args: $1 = agent_id
# Sets: _SESSION_TOKENS (associative array)
read_session_tokens() {
    local agent_id="$1"
    local agent_dir="$ITTYBITTY_DIR/agents/$agent_id"

    # Get session ID and last processed line
    local session_id=$(jq -r '.session_id' "$agent_dir/meta.json")
    local last_line=$(jq -r '.tokens.direct.last_line // 0' "$agent_dir/meta.json")

    # Find session file
    local session_file=$(find ~/.claude/projects -name "${session_id}.jsonl" -type f | head -1)

    if [[ ! -f "$session_file" ]]; then
        echo "Warning: Session file not found for agent $agent_id" >&2
        return 1
    fi

    # Count total lines
    local total_lines=$(wc -l < "$session_file")

    # Read only new lines (after last_line)
    local new_lines=$((total_lines - last_line))
    if [[ $new_lines -le 0 ]]; then
        # No new data
        return 0
    fi

    # Extract tokens from new lines only
    tail -n "$new_lines" "$session_file" | jq -s '
      map(select(.message.usage)) |
      {
        input: map(.message.usage.input_tokens // 0) | add // 0,
        output: map(.message.usage.output_tokens // 0) | add // 0,
        cache_read: map(.message.usage.cache_read_input_tokens // 0) | add // 0,
        cache_creation: map(.message.usage.cache_creation_input_tokens // 0) | add // 0,
        api_calls: length,
        last_line: '$total_lines'
      }
    '
}

# Update agent's meta.json with current token usage
# Args: $1 = agent_id
update_agent_tokens() {
    local agent_id="$1"
    local agent_dir="$ITTYBITTY_DIR/agents/$agent_id"

    # Read incremental tokens
    local new_tokens=$(read_session_tokens "$agent_id")

    if [[ -z "$new_tokens" ]]; then
        return 1
    fi

    # Update meta.json (add to existing direct tokens)
    echo "$new_tokens" | jq --slurpfile meta "$agent_dir/meta.json" '
      . as $new | $meta[0] |
      .tokens.direct.input += $new.input |
      .tokens.direct.output += $new.output |
      .tokens.direct.cache_read += $new.cache_read |
      .tokens.direct.cache_creation += $new.cache_creation |
      .tokens.direct.api_calls += $new.api_calls |
      .tokens.direct.last_line = $new.last_line |
      .tokens.last_updated = now
    ' > "$agent_dir/meta.json.tmp"

    mv "$agent_dir/meta.json.tmp" "$agent_dir/meta.json"
}

# Compute total tokens (direct + workers)
# Args: $1 = agent_id
# Outputs: JSON with total tokens
compute_total_tokens() {
    local agent_id="$1"
    local agent_dir="$ITTYBITTY_DIR/agents/$agent_id"

    jq '.tokens.total = {
      input: (.tokens.direct.input // 0) + (.tokens.workers.input // 0),
      output: (.tokens.direct.output // 0) + (.tokens.workers.output // 0),
      cache_read: (.tokens.direct.cache_read // 0) + (.tokens.workers.cache_read // 0),
      cache_creation: (.tokens.direct.cache_creation // 0) + (.tokens.workers.cache_creation // 0),
      api_calls: (.tokens.direct.api_calls // 0) + (.tokens.workers.api_calls // 0)
    }' "$agent_dir/meta.json"
}

# Format tokens for display (human-readable)
# Args: $1 = token_count
format_token_count() {
    local count="$1"
    if [[ $count -ge 1000000 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $count/1000000}")M"
    elif [[ $count -ge 1000 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $count/1000}")K"
    else
        echo "$count"
    fi
}
```

### Phase 2: Display Integration

**Modify**: `watch_render_split_panes()` (~line 5236)

Add token display to agent info section:
```bash
# After printing model and prompt...

# Read tokens (with caching to avoid repeated reads)
if [[ "$selected_id" != "$_LAST_TOKEN_UPDATE_ID" ]] ||
   [[ $(($(date +%s) - ${_LAST_TOKEN_UPDATE_TIME:-0})) -gt 5 ]]; then
    update_agent_tokens "$selected_id" 2>/dev/null
    compute_total_tokens "$selected_id" > /tmp/ib-tokens-$selected_id.json
    _LAST_TOKEN_UPDATE_ID="$selected_id"
    _LAST_TOKEN_UPDATE_TIME=$(date +%s)
fi

# Display token breakdown
local tokens_file="/tmp/ib-tokens-$selected_id.json"
if [[ -f "$tokens_file" ]]; then
    local direct_in=$(jq -r '.tokens.direct.input // 0' "$tokens_file")
    local direct_out=$(jq -r '.tokens.direct.output // 0' "$tokens_file")
    local direct_calls=$(jq -r '.tokens.direct.api_calls // 0' "$tokens_file")
    local workers_in=$(jq -r '.tokens.workers.input // 0' "$tokens_file")
    local workers_out=$(jq -r '.tokens.workers.output // 0' "$tokens_file")
    local total_in=$(jq -r '.tokens.total.input // 0' "$tokens_file")
    local total_out=$(jq -r '.tokens.total.output // 0' "$tokens_file")
    local total_calls=$(jq -r '.tokens.total.api_calls // 0' "$tokens_file")

    # Format for display
    direct_in=$(format_token_count "$direct_in")
    direct_out=$(format_token_count "$direct_out")
    workers_in=$(format_token_count "$workers_in")
    workers_out=$(format_token_count "$workers_out")
    total_in=$(format_token_count "$total_in")
    total_out=$(format_token_count "$total_out")

    # Print token lines
    printf "│ Tokens: %s in / %s out (%d API)%*s│\n" \
           "$direct_in" "$direct_out" "$direct_calls" \
           "$((pane_width - 35))" ""

    if [[ $workers_in != "0" && $workers_out != "0" ]]; then
        printf "│ Workers: +%s in / +%s out%*s│\n" \
               "$workers_in" "$workers_out" \
               "$((pane_width - 30))" ""
    fi

    printf "│ Total: %s / %s (%d API)%*s│\n" \
           "$total_in" "$total_out" "$total_calls" \
           "$((pane_width - 32))" ""
fi
```

### Phase 3: Rollup on Merge

**Modify**: `cmd_merge()` (~line 3400)

Add token rollup before branch merge:
```bash
cmd_merge() {
    # ... existing validation ...

    # Archive agent output FIRST (captures complete state)
    archive_agent_output "$AGENT_ID"

    # Finalize token count
    update_agent_tokens "$AGENT_ID"
    compute_total_tokens "$AGENT_ID" > "$AGENT_DIR/meta.json"

    # Rollup to manager if exists
    local manager_id=$(jq -r '.manager' "$AGENT_DIR/meta.json")
    if [[ "$manager_id" != "null" && -n "$manager_id" ]]; then
        rollup_tokens_to_manager "$AGENT_ID" "$manager_id"
    fi

    # ... continue with git merge ...
}
```

**Also modify**: `cmd_kill()` - same token finalization (for archive)

### Phase 4: New Commands

**Add**: `cmd_tokens()` function

```bash
cmd_tokens() {
    local agent_id=""
    local json_output=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                json_output=true
                shift
                ;;
            -h|--help)
                cat <<EOF
Usage: ib tokens <agent-id> [--json]

Show detailed token usage for an agent.

Options:
  --json    Output in JSON format

Examples:
  ib tokens manager-abc
  ib tokens worker-1 --json
EOF
                exit 0
                ;;
            *)
                agent_id="$1"
                shift
                ;;
        esac
    done

    # Validate agent
    if [[ -z "$agent_id" ]]; then
        echo "Error: agent-id required" >&2
        exit 1
    fi

    local agent_dir="$ITTYBITTY_DIR/agents/$agent_id"
    if [[ ! -d "$agent_dir" ]]; then
        echo "Error: Agent '$agent_id' not found" >&2
        exit 1
    fi

    # Update tokens
    update_agent_tokens "$agent_id"
    compute_total_tokens "$agent_id" > "$agent_dir/meta.json"

    if $json_output; then
        # JSON output
        jq '{
          agent_id: .id,
          session_id: .session_id,
          state: .state,
          last_updated: .tokens.last_updated,
          direct: .tokens.direct,
          workers: .tokens.workers,
          total: .tokens.total
        }' "$agent_dir/meta.json"
    else
        # Human-readable output
        local session_id=$(jq -r '.session_id' "$agent_dir/meta.json")
        local state=$(jq -r '.state // "unknown"' "$agent_dir/meta.json")
        local last_updated=$(jq -r '.tokens.last_updated // 0' "$agent_dir/meta.json")
        local age=$(($(date +%s) - last_updated))

        echo "Agent: $agent_id (session: ${session_id:0:8}...)"
        echo "State: $state"
        echo "Last updated: ${age} seconds ago"
        echo

        # Direct tokens
        local d_in=$(jq -r '.tokens.direct.input // 0' "$agent_dir/meta.json")
        local d_out=$(jq -r '.tokens.direct.output // 0' "$agent_dir/meta.json")
        local d_cache=$(jq -r '.tokens.direct.cache_read // 0' "$agent_dir/meta.json")
        local d_create=$(jq -r '.tokens.direct.cache_creation // 0' "$agent_dir/meta.json")
        local d_calls=$(jq -r '.tokens.direct.api_calls // 0' "$agent_dir/meta.json")

        echo "Direct API Calls ($d_calls calls):"
        printf "  Input tokens:       %'10d\n" "$d_in"
        printf "  Output tokens:      %'10d\n" "$d_out"
        printf "  Cache read:         %'10d (~10%% cost)\n" "$d_cache"
        printf "  Cache creation:     %'10d\n" "$d_create"
        echo

        # Worker tokens (if any)
        local w_in=$(jq -r '.tokens.workers.input // 0' "$agent_dir/meta.json")
        if [[ $w_in -gt 0 ]]; then
            local w_out=$(jq -r '.tokens.workers.output // 0' "$agent_dir/meta.json")
            local w_cache=$(jq -r '.tokens.workers.cache_read // 0' "$agent_dir/meta.json")
            local w_create=$(jq -r '.tokens.workers.cache_creation // 0' "$agent_dir/meta.json")
            local w_calls=$(jq -r '.tokens.workers.api_calls // 0' "$agent_dir/meta.json")
            local w_agents=$(jq -r '.tokens.workers.agents | length' "$agent_dir/meta.json")

            echo "Worker Agents ($w_agents agents, $w_calls calls):"
            printf "  Input tokens:       %'10d\n" "$w_in"
            printf "  Output tokens:      %'10d\n" "$w_out"
            printf "  Cache read:         %'10d (~10%% cost)\n" "$w_cache"
            printf "  Cache creation:     %'10d\n" "$w_create"
            echo
        fi

        # Total
        local t_in=$(jq -r '.tokens.total.input // 0' "$agent_dir/meta.json")
        local t_out=$(jq -r '.tokens.total.output // 0' "$agent_dir/meta.json")
        local t_cache=$(jq -r '.tokens.total.cache_read // 0' "$agent_dir/meta.json")
        local t_create=$(jq -r '.tokens.total.cache_creation // 0' "$agent_dir/meta.json")
        local t_calls=$(jq -r '.tokens.total.api_calls // 0' "$agent_dir/meta.json")

        echo "Total:"
        printf "  Input tokens:       %'10d\n" "$t_in"
        printf "  Output tokens:      %'10d\n" "$t_out"
        printf "  Cache read:         %'10d\n" "$t_cache"
        printf "  Cache creation:     %'10d\n" "$t_create"
        printf "  Total API calls:    %'10d\n" "$t_calls"
        echo

        # Cost estimate (rough)
        # Sonnet 4.5: $3/MTok input, $15/MTok output, cache read ~10% of input
        local cost_in=$(awk "BEGIN {printf \"%.4f\", ($t_in * 3 + $t_create * 3) / 1000000}")
        local cost_out=$(awk "BEGIN {printf \"%.2f\", $t_out * 15 / 1000000}")
        local cost_cache=$(awk "BEGIN {printf \"%.4f\", $t_cache * 0.3 / 1000000}")
        local cost_total=$(awk "BEGIN {printf \"%.2f\", $cost_in + $cost_out + $cost_cache}")

        echo "Estimated cost: \$$cost_total USD (approximate)"
    fi
}
```

**Modify**: Main command router to add `tokens` case

### Phase 5: Archive Integration

When agents are killed/merged, preserve token data in archive:

**Modify**: `archive_agent_output()` (~line 300)

```bash
archive_agent_output() {
    # ... existing archive logic ...

    # Finalize tokens before archiving
    update_agent_tokens "$ID" 2>/dev/null
    compute_total_tokens "$ID" > "$AGENT_DIR/meta.json" 2>/dev/null

    # Archive includes updated meta.json with final tokens
    # ... continue with existing cp commands ...
}
```

This ensures archived agents retain their token usage data for historical analysis.

## Configuration

Add to `.ittybitty.json`:

```json
{
  "token_tracking": {
    "enabled": true,
    "show_in_watch": true,
    "show_cache_tokens": false,
    "update_interval": 5,
    "archive_tokens": true
  }
}
```

**Defaults**:
- `enabled`: true
- `show_in_watch`: true (display in agent info pane)
- `show_cache_tokens`: false (only show input/output by default)
- `update_interval`: 5 seconds (watch screen refresh rate)
- `archive_tokens`: true (preserve in archive)

## Performance Considerations

### Incremental Session Reading
- **Problem**: Session JSONL files can grow large (1000+ lines)
- **Solution**: Store `last_line` in meta.json, only read new lines
- **Impact**: O(new_lines) instead of O(total_lines)

### Watch Screen Updates
- **Frequency**: Every 5 seconds for selected agent only
- **Cache**: Store computed tokens in `/tmp/ib-tokens-<id>.json`
- **TTL**: 5 seconds (avoid redundant reads)

### Rollup Complexity
- **Single agent merge**: O(1) - just add worker's total to manager's workers
- **Deep hierarchies**: O(depth) - tokens bubble up one level at a time

## Testing

### Manual Tests

1. **Basic tracking**:
   ```bash
   ib new-agent --name test "echo hello and exit"
   ib watch  # Verify tokens appear in agent info
   ```

2. **Worker rollup**:
   ```bash
   # In primary agent:
   ib new-agent --name manager "spawn a worker and merge it"
   # Wait for manager to spawn worker and merge
   ib tokens manager  # Verify workers section populated
   ```

3. **Archive preservation**:
   ```bash
   ib new-agent --name temp "do some work"
   # Let agent do work
   ib kill temp
   cat .ittybitty/archive/*/meta.json | jq .tokens
   # Verify tokens preserved
   ```

4. **Incremental updates**:
   ```bash
   ib new-agent --name long "long running task"
   # Check meta.json last_line increases over time
   watch -n 5 "jq '.tokens.direct.last_line' .ittybitty/agents/long/meta.json"
   ```

### Edge Cases

- **Missing session file**: Handle gracefully (session not started yet)
- **Orphaned sessions**: Session exists but agent deleted (use session_id mapping)
- **Zero tokens**: New agent with no API calls yet
- **Large sessions**: 10K+ lines (verify incremental read performance)
- **Concurrent updates**: Multiple processes reading same session file

## Future Enhancements

### Phase 6 (Optional)
- **Cost estimates**: Convert tokens to USD based on model pricing
- **Usage graphs**: Show token trends over time
- **Budget alerts**: Warn when agent exceeds X tokens
- **Token leaderboard**: `ib tokens --top 10` - most expensive agents
- **Export**: `ib tokens --export csv` - all agent tokens to CSV

### Alternative Display Formats

**Compact mode** (single line):
```
Agent: manager-abc | tokens: 13K/5.5K (32 calls, 2 workers)
```

**Detailed mode** (with cache breakdown):
```
│ Tokens (direct):                   │
│   Input:     5.0K  Cache: 15K      │
│   Output:    2.0K  Create: 7.9K    │
│   API calls: 12                    │
│ Workers: +8.0K/+3.5K (2 agents)    │
```

## Summary

This plan implements per-agent token tracking with:
- **Direct tracking**: Each agent's own API calls
- **Worker rollup**: Costs bubble up to managers on merge
- **Incremental updates**: Only read new session lines
- **Universal display**: Watch screen, status, dedicated tokens command
- **Archive preservation**: Historical token data retained

**Key benefits**:
- Answer "how expensive was this task?"
- Identify token-heavy agents before they exhaust quota
- Understand true cost of manager/worker hierarchies
- Optimize prompts and workflows based on actual usage

Ready to implement in phases, starting with basic tracking in watch screen.
