# Plan: CLAUDE.md Status Node for User-Claude Communication

## Overview

Enable background agents to communicate status updates and messages to the user's primary Claude instance (running in a normal terminal) by dynamically updating an `<ittybitty-status>` node inside the `<ittybitty>` section of CLAUDE.md.

## Problem Statement

Currently, when a user's Claude instance spawns background agents via `ib`, it has no automatic visibility into agent activity:

1. **No automatic notifications**: Watchdog notifications only work agent-to-agent. The user's Claude isn't managed by `ib`, so it receives no stdin notifications.
2. **Requires polling**: User's Claude must manually run `ib list` or `ib tree` to check on agents.
3. **No message channel**: Background agents cannot send questions or status updates to the user's Claude.

**User experience gap**: When working with Claude in a terminal, the user spawns agents and must remember to ask "how are my agents doing?" - there's no proactive visibility.

## Proposed Solution

### Core Concept

Add a machine-readable `<ittybitty-status>` node inside CLAUDE.md's `<ittybitty>` section that gets updated by watchdogs:

```markdown
<ittybitty>
## Multi-Agent Orchestration (ittybitty)
... existing documentation ...

<ittybitty-status>
<!-- Auto-updated by ittybitty watchdogs. Do not edit manually. -->
{
  "last_updated": "2026-01-11T15:30:00Z",
  "root_agents": [
    {
      "id": "manager-abc",
      "state": "running",
      "age": "5m",
      "prompt": "Implement dark mode feature",
      "children": 2,
      "children_complete": 1
    },
    {
      "id": "worker-xyz",
      "state": "complete",
      "age": "12m",
      "prompt": "Fix login bug"
    }
  ],
  "messages": [
    {
      "id": "msg-1736610600-abc",
      "from": "manager-abc",
      "timestamp": "2026-01-11T15:30:00Z",
      "type": "question",
      "content": "Should I use CSS variables or a theme provider for dark mode?"
    }
  ]
}
</ittybitty-status>
</ittybitty>
```

### Why CLAUDE.md?

1. **Claude reads it automatically**: CLAUDE.md is loaded into context for every Claude Code session, including the user's primary session.
2. **Project-scoped**: Status is specific to the project, not global.
3. **No special tooling needed**: Claude can read the status just by having CLAUDE.md in context.
4. **Survives restarts**: File persists even if Claude is restarted.

### Components

1. **`<ittybitty-status>` node**: JSON status embedded in CLAUDE.md
2. **Status watchdog**: Background process that monitors all root agents and updates the status node
3. **`ib send user-claude "message"`**: New special-case command to queue messages for user's Claude
4. **`ib acknowledge <message-id>`**: Command for user's Claude to clear acknowledged messages
5. **`.ittybitty/user-messages.json`**: Persistent message queue (source of truth for messages section)

## Detailed Design

### 1. The `<ittybitty-status>` Node Format

**Location**: Inside the existing `<ittybitty>` node in CLAUDE.md

**JSON Schema**:
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "last_updated": {
      "type": "string",
      "format": "date-time",
      "description": "ISO 8601 timestamp of last update"
    },
    "root_agents": {
      "type": "array",
      "description": "Agents without a manager (controlled by user)",
      "items": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "state": { "enum": ["running", "waiting", "complete", "stopped"] },
          "age": { "type": "string", "description": "Human-readable age like '5m', '2h'" },
          "prompt": { "type": "string", "description": "First 60 chars of prompt" },
          "children": { "type": "integer", "description": "Total child agent count" },
          "children_complete": { "type": "integer", "description": "Completed children count" }
        },
        "required": ["id", "state", "age", "prompt"]
      }
    },
    "messages": {
      "type": "array",
      "description": "Messages from agents to user's Claude",
      "items": {
        "type": "object",
        "properties": {
          "id": { "type": "string", "description": "Unique message ID for acknowledgement" },
          "from": { "type": "string", "description": "Agent ID that sent the message" },
          "timestamp": { "type": "string", "format": "date-time" },
          "type": { "enum": ["question", "status", "alert", "complete"] },
          "content": { "type": "string" }
        },
        "required": ["id", "from", "timestamp", "type", "content"]
      }
    }
  },
  "required": ["last_updated", "root_agents", "messages"]
}
```

**Message Types**:
| Type | Purpose | Example |
|------|---------|---------|
| `question` | Agent needs user input | "Should I use library X or Y?" |
| `status` | Progress update | "Completed 3 of 5 tasks" |
| `alert` | Warning or error | "Rate limit hit, pausing..." |
| `complete` | Task finished | "Dark mode implemented, ready for review" |

### 2. Status Watchdog (`cmd_status_watchdog`)

A single background process that monitors all root agents and updates the status node.

**Lifecycle**:
1. **Start**: Auto-starts when first root agent is spawned (agent with no manager)
2. **Run**: Loop every 10 seconds:
   - Find all root agents (agents without manager)
   - Get state, age, children counts for each
   - Read messages from `.ittybitty/user-messages.json`
   - Update `<ittybitty-status>` node in CLAUDE.md
3. **Stop**: Exit when no root agents exist

**Implementation approach**:
```bash
cmd_status_watchdog() {
    local UPDATE_INTERVAL=10  # seconds

    # Store PID for later cleanup
    echo $$ > "$ITTYBITTY_DIR/status-watchdog.pid"

    while true; do
        # Check if any root agents exist
        local root_agents=$(find_root_agents)
        if [[ -z "$root_agents" ]]; then
            # No root agents, clean up and exit
            rm -f "$ITTYBITTY_DIR/status-watchdog.pid"
            exit 0
        fi

        # Build status JSON
        local status_json=$(build_status_json)

        # Update CLAUDE.md
        update_claude_md_status "$status_json"

        sleep "$UPDATE_INTERVAL"
    done
}

find_root_agents() {
    # Find agents where manager is null or empty
    for agent_dir in "$AGENTS_DIR"/*/; do
        [[ -d "$agent_dir" ]] || continue
        [[ -f "$agent_dir/meta.json" ]] || continue

        local manager=$(jq -r '.manager // ""' "$agent_dir/meta.json")
        if [[ -z "$manager" || "$manager" == "null" ]]; then
            echo "$(basename "$agent_dir")"
        fi
    done
}

build_status_json() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local agents_json="[]"
    local messages_json="[]"

    # Build root agents array
    for agent_id in $(find_root_agents); do
        local agent_dir="$AGENTS_DIR/$agent_id"
        local meta="$agent_dir/meta.json"

        local state=$(get_state "$agent_id")
        local created=$(jq -r '.created' "$meta")
        local age=$(format_age "$created")
        local prompt=$(jq -r '.prompt // ""' "$meta" | head -1 | cut -c1-60)

        # Count children
        local children=$(get_children "$agent_id" "all" | wc -w | tr -d ' ')
        local children_complete=$(get_children "$agent_id" "complete" | wc -w | tr -d ' ')

        # Add to agents array
        agents_json=$(echo "$agents_json" | jq --arg id "$agent_id" \
            --arg state "$state" --arg age "$age" --arg prompt "$prompt" \
            --argjson children "$children" --argjson complete "$children_complete" \
            '. += [{id: $id, state: $state, age: $age, prompt: $prompt, children: $children, children_complete: $complete}]')
    done

    # Read messages from file
    if [[ -f "$ITTYBITTY_DIR/user-messages.json" ]]; then
        messages_json=$(cat "$ITTYBITTY_DIR/user-messages.json")
    fi

    # Combine into final JSON
    jq -n --arg ts "$timestamp" --argjson agents "$agents_json" --argjson msgs "$messages_json" \
        '{last_updated: $ts, root_agents: $agents, messages: $msgs}'
}

update_claude_md_status() {
    local status_json="$1"
    local claude_md="CLAUDE.md"

    # Check if <ittybitty-status> node exists
    if grep -q "<ittybitty-status>" "$claude_md"; then
        # Replace existing node
        # Use awk to replace content between <ittybitty-status> and </ittybitty-status>
        awk -v new_content="$status_json" '
            /<ittybitty-status>/ { print; in_status=1; print "<!-- Auto-updated by ittybitty watchdogs. Do not edit manually. -->"; print new_content; next }
            /<\/ittybitty-status>/ { in_status=0 }
            !in_status { print }
        ' "$claude_md" > "$claude_md.tmp"
        mv "$claude_md.tmp" "$claude_md"
    else
        # Insert new node before </ittybitty>
        sed -i '' 's|</ittybitty>|<ittybitty-status>\n<!-- Auto-updated by ittybitty watchdogs. Do not edit manually. -->\n'"$(echo "$status_json" | sed 's/\\/\\\\/g; s/&/\\&/g; s/|/\\|/g')"'\n</ittybitty-status>\n\n</ittybitty>|' "$claude_md"
    fi
}
```

**Key considerations**:
- Use `awk` for robust multi-line replacement (not sed)
- Handle special characters in JSON (escape properly)
- Atomic file updates (write to .tmp then mv)
- Single process (prevent duplicates via PID file)

### 3. Message Queue System

**File**: `.ittybitty/user-messages.json`

This file is the source of truth for messages. The status watchdog reads from it; `ib send user-claude` writes to it; `ib acknowledge` removes from it.

**Format**:
```json
[
  {
    "id": "msg-1736610600-manager-abc",
    "from": "manager-abc",
    "timestamp": "2026-01-11T15:30:00Z",
    "type": "question",
    "content": "Should I use CSS variables or a theme provider for dark mode?"
  },
  {
    "id": "msg-1736610700-worker-xyz",
    "from": "worker-xyz",
    "timestamp": "2026-01-11T15:31:40Z",
    "type": "complete",
    "content": "Fixed login bug - ready for merge"
  }
]
```

**Message ID format**: `msg-<epoch>-<agent-id>` ensures uniqueness.

### 4. `ib send user-claude "message"` Command

Special-case handling in `cmd_send` when target is `user-claude`:

```bash
cmd_send() {
    # ... existing argument parsing ...

    # Special case: sending to user's Claude
    if [[ "$TARGET_ID" == "user-claude" || "$TARGET_ID" == "user" ]]; then
        send_to_user_claude "$MESSAGE" "$FROM_ID"
        return
    fi

    # ... existing send logic for real agents ...
}

send_to_user_claude() {
    local message="$1"
    local from_id="$2"
    local msg_file="$ITTYBITTY_DIR/user-messages.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local epoch=$(date +%s)
    local msg_id="msg-${epoch}-${from_id:-unknown}"

    # Determine message type from prefix or default to "status"
    local msg_type="status"
    case "$message" in
        "?"*|"QUESTION:"*)
            msg_type="question"
            message="${message#\?}"
            message="${message#QUESTION:}"
            message=$(echo "$message" | sed 's/^[[:space:]]*//')
            ;;
        "!"*|"ALERT:"*)
            msg_type="alert"
            message="${message#!}"
            message="${message#ALERT:}"
            message=$(echo "$message" | sed 's/^[[:space:]]*//')
            ;;
        "COMPLETE:"*|"DONE:"*)
            msg_type="complete"
            message="${message#COMPLETE:}"
            message="${message#DONE:}"
            message=$(echo "$message" | sed 's/^[[:space:]]*//')
            ;;
    esac

    # Initialize file if doesn't exist
    if [[ ! -f "$msg_file" ]]; then
        echo "[]" > "$msg_file"
    fi

    # Add message to queue
    local new_msg=$(jq -n \
        --arg id "$msg_id" \
        --arg from "${from_id:-unknown}" \
        --arg ts "$timestamp" \
        --arg type "$msg_type" \
        --arg content "$message" \
        '{id: $id, from: $from, timestamp: $ts, type: $type, content: $content}')

    jq --argjson msg "$new_msg" '. += [$msg]' "$msg_file" > "$msg_file.tmp"
    mv "$msg_file.tmp" "$msg_file"

    echo "Queued message for user's Claude: $msg_type"

    # Log to sender's log
    if [[ -n "$from_id" ]]; then
        log_agent "$from_id" "Sent message to user-claude: $message"
    fi
}
```

**Usage by agents**:
```bash
# Ask a question
ib send user-claude "? Should I implement caching or proceed without it?"

# Status update
ib send user-claude "Completed 3 of 5 migration tasks"

# Alert
ib send user-claude "! Rate limit hit, pausing for 5 minutes"

# Completion notification
ib send user-claude "COMPLETE: Dark mode implementation ready for review"
```

### 5. `ib acknowledge <message-id>` Command

New command for user's Claude to mark messages as handled:

```bash
cmd_acknowledge() {
    local msg_id=""
    local all_flag=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                all_flag=true
                shift
                ;;
            -h|--help)
                cat <<EOF
Usage: ib acknowledge <message-id>
       ib acknowledge --all

Remove acknowledged messages from the user-messages queue.

Arguments:
  message-id    The ID of the message to acknowledge (e.g., msg-1736610600-abc)

Options:
  --all         Acknowledge and remove all messages
  -h, --help    Show this help

Examples:
  ib acknowledge msg-1736610600-manager-abc
  ib acknowledge --all
EOF
                exit 0
                ;;
            *)
                msg_id="$1"
                shift
                ;;
        esac
    done

    local msg_file="$ITTYBITTY_DIR/user-messages.json"

    if [[ ! -f "$msg_file" ]]; then
        echo "No messages to acknowledge"
        exit 0
    fi

    if $all_flag; then
        # Clear all messages
        echo "[]" > "$msg_file"
        echo "Acknowledged all messages"
    elif [[ -n "$msg_id" ]]; then
        # Remove specific message
        local count_before=$(jq 'length' "$msg_file")
        jq --arg id "$msg_id" 'map(select(.id != $id))' "$msg_file" > "$msg_file.tmp"
        mv "$msg_file.tmp" "$msg_file"
        local count_after=$(jq 'length' "$msg_file")

        if [[ "$count_before" == "$count_after" ]]; then
            echo "Message not found: $msg_id"
            exit 1
        else
            echo "Acknowledged message: $msg_id"
        fi
    else
        echo "Error: message-id required (or use --all)" >&2
        exit 1
    fi
}
```

### 6. Starting the Status Watchdog

Integrate into `cmd_new_agent` to auto-start when a root agent is spawned:

```bash
start_status_watchdog() {
    local pid_file="$ITTYBITTY_DIR/status-watchdog.pid"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            # Already running
            return 0
        else
            # Stale PID file
            rm -f "$pid_file"
        fi
    fi

    # Check if this agent is a root agent (no manager)
    # Only start watchdog for root agents

    # Start watchdog in background
    ib status-watchdog > "$ITTYBITTY_DIR/status-watchdog.log" 2>&1 &
    echo "Started status watchdog (PID: $!)"
}
```

In `cmd_new_agent`, after agent creation:
```bash
# If this is a root agent (no manager), start status watchdog
if [[ -z "$MANAGER" || "$MANAGER" == "null" ]]; then
    start_status_watchdog
fi
```

### 7. Cleanup Integration

**In `cmd_kill` / `cmd_merge` / `cmd_nuke`**:
- After removing last root agent, kill status watchdog
- Clean up `status-watchdog.pid`
- Optionally remove `<ittybitty-status>` node from CLAUDE.md

```bash
cleanup_status_watchdog() {
    local pid_file="$ITTYBITTY_DIR/status-watchdog.pid"

    # Check if any root agents remain
    if [[ -z "$(find_root_agents)" ]]; then
        # Kill watchdog if running
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            kill "$pid" 2>/dev/null || true
            rm -f "$pid_file"
            echo "Stopped status watchdog"
        fi

        # Optionally clear status node from CLAUDE.md
        # (or leave it with "no agents" state)
    fi
}
```

## User's Claude Workflow

When the user's Claude has the updated CLAUDE.md in context, it can:

1. **See agent status passively**: The `<ittybitty-status>` node shows all root agents and their states.

2. **Receive messages**: The `messages` array shows pending communications from agents.

3. **Respond to questions**: When an agent asks a question, user's Claude can:
   - Discuss with the user
   - Use `ib send <agent-id> "answer"` to respond
   - Use `ib acknowledge <msg-id>` to clear the message

4. **Take action on completions**: When an agent completes:
   - Review with `ib diff <agent-id>`
   - Merge with `ib merge <agent-id>` or kill with `ib kill <agent-id>`
   - Acknowledge the completion message

**Example interaction**:
```
User: "How are my agents doing?"

Claude: *reads <ittybitty-status> from context*
"You have 2 background agents running:

1. **manager-abc** (running, 15m) - 'Implement dark mode feature'
   - 2 child workers, 1 complete
   - Has a question: 'Should I use CSS variables or a theme provider?'

2. **worker-xyz** (complete, 22m) - 'Fix login bug'
   - Ready for review

What would you like me to do?"

User: "Use CSS variables for dark mode, and show me the login fix diff"

Claude: *runs commands*
$ ib send manager-abc "Use CSS variables for dark mode"
$ ib acknowledge msg-1736610600-manager-abc
$ ib diff worker-xyz
```

## Implementation Steps

### Phase 1: Core Infrastructure
1. Add `cmd_status_watchdog()` function
2. Add `find_root_agents()` helper
3. Add `build_status_json()` helper
4. Add `update_claude_md_status()` helper
5. Add status watchdog auto-start in `cmd_new_agent`

### Phase 2: Message System
6. Add `.ittybitty/user-messages.json` file handling
7. Modify `cmd_send` to handle `user-claude` target
8. Add `send_to_user_claude()` function
9. Add `cmd_acknowledge()` command

### Phase 3: Lifecycle Management
10. Add `start_status_watchdog()` helper
11. Add `cleanup_status_watchdog()` helper
12. Integrate cleanup into `cmd_kill`, `cmd_merge`, `cmd_nuke`

### Phase 4: Testing & Polish
13. Add `--help` documentation for new commands
14. Update CLAUDE.md documentation
15. Test full workflow end-to-end

## Critical Files

### Modified Files
- `/ib` - Main script
  - Add `cmd_status_watchdog()` (~50 lines)
  - Add `cmd_acknowledge()` (~40 lines)
  - Modify `cmd_send()` for user-claude target (~30 lines)
  - Add helper functions (~100 lines)
  - Integrate lifecycle management (~20 lines)
  - Update command router

### New Runtime Files (gitignored)
- `.ittybitty/user-messages.json` - Message queue
- `.ittybitty/status-watchdog.pid` - Watchdog PID
- `.ittybitty/status-watchdog.log` - Watchdog output

### Modified at Runtime
- `CLAUDE.md` - Status node updated by watchdog

## Configuration

Add to `.ittybitty.json`:
```json
{
  "status_node": {
    "enabled": true,
    "update_interval": 10,
    "max_messages": 50,
    "include_children_count": true
  }
}
```

**Defaults**:
- `enabled`: true
- `update_interval`: 10 seconds
- `max_messages`: 50 (older messages trimmed)
- `include_children_count`: true

## Edge Cases & Considerations

### File Locking
- Multiple watchdogs could conflict (prevented by PID file)
- User editing CLAUDE.md while watchdog updates (atomic writes with .tmp + mv)

### CLAUDE.md Formats
- Status node must be inside `<ittybitty>` tags
- Handle case where `<ittybitty>` doesn't exist (skip or create?)
- Preserve existing CLAUDE.md formatting

### Message Volume
- Cap messages at `max_messages` (FIFO eviction)
- Large messages truncated in status node (full content in JSON file)

### Agent Churn
- Rapid agent creation/destruction could cause frequent updates
- Consider debouncing or rate limiting updates

### No Root Agents
- When all root agents are killed/merged:
  - Kill status watchdog
  - Either remove status node or show "No active agents"

## Alternative Approaches Considered

### 1. Separate Status File
**Idea**: Use `.ittybitty/status.json` instead of modifying CLAUDE.md
**Pro**: Cleaner separation, no risk of corrupting CLAUDE.md
**Con**: User's Claude would need to explicitly read the file; not automatic

### 2. Poll-Based (No Status Node)
**Idea**: Just improve `ib list` output and rely on user asking
**Pro**: Simpler implementation
**Con**: Doesn't solve the core problem of proactive visibility

### 3. System Notifications
**Idea**: Use macOS notifications or similar
**Pro**: True push notifications
**Con**: Requires separate tooling, doesn't help Claude instance directly

### 4. Shared Memory / Named Pipes
**Idea**: More sophisticated IPC
**Pro**: Real-time communication
**Con**: Complex, not portable, doesn't persist across restarts

**Conclusion**: CLAUDE.md modification is the best balance of simplicity and effectiveness for enabling agent-to-user-Claude communication.

## Verification

### Manual Testing
1. **Status updates**: Spawn agent, verify status appears in CLAUDE.md
2. **Message sending**: `ib send user-claude "test"`, verify appears in status
3. **Acknowledgement**: `ib acknowledge <id>`, verify message removed
4. **Lifecycle**: Kill all agents, verify watchdog stops
5. **Restart resilience**: Restart user's Claude, verify status still visible

### Edge Case Testing
1. Multiple root agents spawning simultaneously
2. Rapid agent creation/destruction
3. Large message content
4. Concurrent CLAUDE.md edits
5. Missing `<ittybitty>` node in CLAUDE.md

## Summary

This plan enables background agents to communicate with the user's primary Claude instance by:

1. **Embedded status node**: `<ittybitty-status>` in CLAUDE.md provides always-visible agent status
2. **Message queue**: Agents can send questions, alerts, and status updates
3. **Acknowledgement system**: User's Claude can mark messages as handled
4. **Automatic lifecycle**: Status watchdog starts/stops with root agents

**Key benefits**:
- User's Claude sees agent activity without polling
- Agents can ask questions and get answers
- Clean separation of concerns (file-based, no special IPC)
- Survives Claude restarts

**Implementation complexity**: Medium
- ~250 lines of new bash code
- Well-defined file formats
- Clear lifecycle management

Ready to implement in phases, starting with the core status watchdog.
