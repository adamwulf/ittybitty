# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ittybitty (`ib`) is a minimal multi-agent orchestration tool for Claude Code. It uses tmux sessions and git worktrees to spawn and manage multiple Claude agents in parallel. The entire tool is a single bash script (`ib`, ~2000 lines).

## Architecture

```
You (human)
  ↕ conversation
Primary Agent (responsive, strategic)
  ↓ uses ib to spawn
Manager Agent (runs in tmux, has worktree)
  ↑ can ask questions (send to another agent's stdin)
  ↓ can receive answers (as stdin from another agent)
  ↓ uses ib to spawn
Worker Agents (focused workers, no sub-agents)
```

**Key insight**: Agents communicate via tmux stdin/stdout. No files, no protocols—just text.

- Each agent gets its own git worktree on branch `agent/<id>`
- Agent data stored in `.ittybitty/agents/<id>/` (meta.json, prompt.txt, start.sh, repo/, agent.log)
- Messages between agents are prefixed with `[sent by agent <id>]:`

## Script Structure

The `ib` script is organized into commands, each implemented as a function:

| Function | Command | Purpose |
|----------|---------|---------|
| `cmd_new_agent` | `new-agent` | Spawn new agent with worktree/tmux session |
| `cmd_list` | `list` | Show running/finished agents |
| `cmd_send` | `send` | Send input to agent's stdin |
| `cmd_look` | `look` | Watch agent's tmux output |
| `cmd_status` | `status` | Show agent's git commits/changes |
| `cmd_diff` | `diff` | Show full diff of agent's work |
| `cmd_kill` | `kill` | Close agent without merging |
| `cmd_resume` | `resume` | Restart a stopped agent's session |
| `cmd_merge` | `merge` | Merge agent's branch and close |
| `cmd_log` | `log` | Write timestamped entry to agent's log |
| `cmd_nuke` | `nuke` | Emergency stop: kill all or a manager tree |

Key helper functions: `log_agent`, `get_state`, `archive_agent_output`, `kill_agent_process`, `wait_for_claude_start`, `auto_accept_workspace_trust`, etc.

## Configuration

`.ittybitty.json` configures permissions for spawned agents:
- `permissions.manager.allow/deny` - tools for manager agents
- `permissions.worker.allow/deny` - tools for worker agents
- `Bash(ib:*)` and `Bash(./ib:*)` are always added automatically

## Agent Hooks

Each spawned agent automatically gets Claude Code hooks configured in their `settings.local.json`:

| Hook | Purpose |
|------|---------|
| `Stop` | Calls `ib hook-status <id>` when agent stops to update state tracking |
| `PermissionRequest` | Logs denied tool requests to agent.log and auto-denies them |

### PermissionRequest Hook

When an agent tries to use a tool not in its `allow` list, the `PermissionRequest` hook:
1. Reads the tool name and input from JSON stdin (`tool_name` and `tool_input` fields)
2. Logs the denied request to `agent.log` via `ib log --quiet`, including truncated tool parameters
3. Returns the proper hook output format to auto-deny the tool

This provides visibility into what tools agents are attempting to use without showing permission dialogs. The log entry format:
```
[2026-01-10T15:05:06-06:00] Permission denied: Bash (command: curl https://this-is..., description: Execute curl request...)
```

Each tool input parameter is truncated to 20 characters with `...` appended for readability.

**Note**: Folder/location permission prompts (e.g., "allow access to /tmp/") bypass PermissionRequest hooks. These are contextual permissions shown when an allowed tool needs file system access, not tool denials.

To review denied permissions for an agent:
```bash
grep "Permission denied" .ittybitty/agents/<id>/agent.log
```

## Logging System

Each agent has an `agent.log` file at `.ittybitty/agents/<id>/agent.log` that captures timestamped events.

### How Logging Works

The `log_agent` helper function (ib:62) both writes to the log file AND echoes to stdout:
```bash
log_agent "$ID" "message"           # logs and prints
log_agent "$ID" "message" --quiet   # logs only, no stdout
```

### What Gets Logged

| Event | Command | Logged Message |
|-------|---------|----------------|
| Agent creation | `new-agent` | "Agent created (manager: X, prompt: Y)" |
| Message received | `send` | "Received message from X: Y" (recipient's log) |
| Message sent | `send` | "Sent message to X: Y" (sender's log) |
| Permission denied | hook | "Permission denied: TOOL_NAME" |
| Kill initiated | `kill` | "Agent killed" |
| Process terminated | `kill/merge` | "Terminated Claude process" |
| Session killed | `kill/merge` | "Killed tmux session" |
| Branch deleted | `kill/merge` | "Deleted branch agent/X" |
| Merge completed | `merge` | "Agent merged into BRANCH (N commits)" |
| Agent resumed | `resume` | "Agent resumed" |

### Archive Structure

When agents are killed/merged/nuked, logs are archived to `.ittybitty/archive/`:
```
.ittybitty/archive/
  20260110-011339-agent-name/
    output.log           # Full tmux scrollback
    agent.log            # Timestamped event log
    meta.json            # Agent config (prompt, model, session_id, manager, etc.)
    settings.local.json  # Permissions and hooks configuration
```

The teardown order ensures complete logs:
1. Log all teardown events (kill, session stop, branch delete)
2. Archive (captures complete log)
3. Remove agent directory

### Using `ib log` for Debugging

Agents can write to their own log during execution:
```bash
ib log "Starting task analysis"
ib log "Found 5 files to process"
ib log --quiet "Silent debug info"  # no stdout
```

### Debugging with tmux Output

For deep debugging, you can capture tmux output to the agent log:
```bash
# Capture current visible pane
tmux capture-pane -t "$SESSION" -p >> "$AGENT_DIR/agent.log"

# Capture full scrollback history
tmux capture-pane -t "$SESSION" -p -S - >> "$AGENT_DIR/agent.log"
```

## Process and Session Management

### Process Hierarchy

```
tmux session (ittybitty-<agent-id>)
  └── bash shell (pane_pid)
        └── claude process (claude_pid)
```

### Finding Process IDs

The `kill_agent_process` function uses two strategies:

1. **Dynamic lookup (preferred)**: Find Claude via tmux pane PID
   ```bash
   PANE_PID=$(tmux list-panes -t "$SESSION" -F '#{pane_pid}')
   CLAUDE_PID=$(pgrep -P "$PANE_PID" -f "claude")
   ```

2. **Fallback**: Read from `meta.json` (set at startup via start.sh)
   ```bash
   PID=$(jq -r '.claude_pid' "$AGENT_DIR/meta.json")
   ```

### Agent State Detection

The `get_state` function (ib:424) reads recent tmux output to determine state:

| State | Detection Method |
|-------|------------------|
| `stopped` | tmux session doesn't exist |
| `running` | Output contains "esc to interrupt", "ctrl+b ctrl+b", or "⎿  Running" |
| `complete` | Last 15 lines contain "I HAVE COMPLETED THE GOAL" |
| `waiting` | Last 15 lines contain standalone "WAITING" |
| `unknown` | Session exists but no clear indicators |

**Important**: Check for `running` indicators FIRST, before completion phrases, because the completion phrase may exist in context/history while the agent is still working.

### Graceful Process Shutdown

When killing agents:
1. Send SIGTERM to Claude process
2. Wait up to 2 seconds for graceful shutdown
3. Send SIGKILL if still running
4. Kill tmux session

### Orphan Detection

The `scan_and_kill_orphans` function finds Claude processes whose working directory is a deleted agent directory. Safety checks:
- Process cwd must contain `/.ittybitty/agents/`
- The agent directory must NOT exist (truly orphaned)

## Claude Startup and Permission Screen

### The Permission Screen Problem

When Claude starts in a new worktree, it may show a "Do you trust the files in this folder?" permission screen. If we send Enter too early or when not needed, it can:
- Trigger tab-completion if Claude has already started
- Send an unintended command to Claude's input

### Detection Strategy

The `wait_for_claude_start` function (ib:471) waits for EITHER:
1. **Logo** ("Claude Code v") - Claude started, no permissions needed
2. **Permissions screen** ("Enter to confirm" + "trust") - needs acceptance

This is stored in `CLAUDE_STARTED_WITH` global variable.

### Handling Flow

```
wait_for_claude_start()
  ├── Logo detected first → Done (no Enter needed)
  └── Permissions detected → send Enter → wait_for_claude_logo()
```

The `auto_accept_workspace_trust` function (ib:525):
1. Waits for Claude to start (logo OR permissions)
2. If logo appeared first → return immediately
3. If permissions screen → send Enter, wait 4s, verify logo appears
4. Retry up to 5 times if permissions persist

### Key Lessons Learned

1. **Wait before sending Enter**: Always detect what screen is showing first
2. **Check for logo after permissions**: Verify Claude actually started after accepting
3. **Use delays between retries**: 4 second delay allows Claude to process
4. **Don't send Enter blindly**: Only send when permissions screen is confirmed

## Testing

No formal test suite. Test manually by spawning agents:

```bash
# Test basic spawn
ib new-agent --name test "echo hello and exit"

# Test communication
ib send test "hello"
ib look test

# Cleanup
ib kill test --force
```

**Note**: Always use `ib` (not `./ib`) to ensure you run the current version from PATH. This is especially important in worktrees where `./ib` would run a stale checkout.

## Key Implementation Details

- **State detection**: See "Process and Session Management" section above for detailed `get_state` behavior
- **Logging**: All commands log to `agent.log`; see "Logging System" section
- **Permission handling**: See "Claude Startup and Permission Screen" section for startup flow
- **Session persistence**: Each agent gets a UUID (`session_id` in meta.json) enabling `claude --resume`
- **Exit handler** (`exit-check.sh`): Prompts for uncommitted changes when agent session ends
- **Send timing**: Message and Enter key sent separately with 0.1s delay to handle busy agents
- **Orphan cleanup**: `scan_and_kill_orphans` runs after kill/merge to clean up stray Claude processes

<ittybitty>
## Multi-Agent Orchestration (ittybitty)

You have access to `ib` for spawning long-running background agents. Unlike Claude's built-in Task tool (which spawns ephemeral subagents that block until complete), `ib` agents are **persistent Claude Code instances** that run in isolated git worktrees and can work autonomously for extended periods.

### When to Use

- Large or complex tasks that benefit from isolation
- Long-running research or analysis
- When the user explicitly requests background agents
- Tasks that can run while you continue other work

### Automatic Notifications (Agent-to-Agent Only)

**IMPORTANT**: Watchdog notifications only work between agents, not between user and agent.

- If **Manager Agent A** spawns **Worker Agent B**: Agent A gets automatic watchdog notifications about Agent B
- If **you (user)** spawn **Agent A**: You will NOT get automatic notifications, even if Agent A spawns children
- **Primary agents in user conversations** must actively poll with `ib list` to check on their children

When agent spawns child agent (agent-to-agent):
- A watchdog is automatically spawned to monitor the child
- The watchdog notifies the manager agent when:
  - Child is waiting for >30 seconds (needs input)
  - Child completes (ready to review/merge)
- Manager agents should enter WAITING mode after spawning children
- No need for agents to poll `ib list` - watchdogs ensure timely notifications

### Workflow

**If you are a primary agent in a user conversation (no watchdog notifications):**
1. **Spawn**: `ib new-agent "clearly defined goal"` — returns agent ID
2. **Poll actively**: Use `ib list` regularly to check agent states (you won't get notifications!)
3. **Check status**: When agent shows `waiting` or `complete`, use `ib look <id>` to review
4. **Interact**: If `waiting` and needs input, use `ib send <id> "answer"`
5. **Merge/kill**: When `complete`, check with `ib diff <id>` then `ib merge <id>` or `ib kill <id>`

**If you are a background agent spawning sub-agents (automatic watchdog notifications):**
1. **Spawn**: `ib new-agent "clearly defined goal"` — agent auto-detects manager, watchdog auto-spawns
2. **Enter WAITING**: Enter WAITING mode after spawning sub-agents (use `read` or similar)
3. **Auto-notify**: Watchdog monitors each child and notifies you when:
   - Child has been waiting >30s (needs input)
   - Child completes (ready to merge/review)
4. **Review & merge**: When notified, check work with `ib look/diff <id>`, then `ib merge <id>` or `ib kill <id>`

### All Commands

| Command               | Description                                                  |
| --------------------- | ------------------------------------------------------------ |
| `ib new-agent "goal"` | Spawn a new agent, returns its ID                            |
| `ib list`             | Show all agents and their status                             |
| `ib look <id>`        | View an agent's recent output                                |
| `ib send <id> "msg"`  | Send input to an agent                                       |
| `ib status <id>`      | Show agent's git commits and changes                         |
| `ib diff <id>`        | Show full diff of agent's work vs main                       |
| `ib merge <id>`       | Merge agent's work and permanently close it                  |
| `ib kill <id>`        | Permanently close agent without merging                      |
| `ib resume <id>`      | Restart a stopped agent's session                            |
| `ib log "msg"`        | Write timestamped message to agent's log (auto-detects agent) |
| `ib watchdog <id>`    | Monitor agent and notify manager (auto-spawned for child agents) |

### Spawn Options

When creating agents with `ib new-agent`, you can customize behavior with these flags:

| Flag | Description |
| ---- | ----------- |
| `--name <name>` | Custom agent name (default: auto-generated ID) |
| `--manager <id>` | Track manager relationship for hierarchical coordination |
| `--worker` | Create a worker agent that cannot spawn sub-agents |
| `--yolo` | **Yolo mode**: Skip all permission prompts for full autonomy |
| `--model <model>` | Use a specific model (opus, sonnet, haiku) |
| `--no-worktree` | Work in repo root instead of isolated worktree |
| `--allow-tools <list>` | Only allow these tools (comma-separated) |
| `--deny-tools <list>` | Deny these tools (comma-separated) |
| `--print` | One-shot mode: run and exit, no interaction |

#### Yolo Mode (`--yolo`)

Yolo mode enables full autonomous operation by passing `--dangerously-skip-permissions --permission-mode bypassPermissions` to Claude CLI. This mode:

- **Skips all tool permission prompts** - agent can use any tool without approval
- **Bypasses workspace trust dialogs** - no need for auto-acceptance
- **Requires manual confirmation** - Claude CLI shows a one-time "Bypass Permissions" warning that must be accepted interactively
- **Persists across resume** - yolo setting is stored in `start.sh` and preserved when resuming

**Use with caution**: Only use yolo mode in sandboxed environments or when you fully trust the agent's task.

**Example:**
```bash
ib new-agent --yolo "research latest React patterns and update our components"
```

**Note**: Even with `--yolo`, the agent will show a one-time warning screen asking to confirm bypass permissions mode. This is a safety feature built into Claude CLI and requires manual confirmation (select option 2: "Yes, I accept").

### Agent States

| State      | Meaning                                                 |
| ---------- | ------------------------------------------------------- |
| `running`  | Agent is actively processing                            |
| `waiting`  | Agent is idle, may need input                           |
| `complete` | Agent signaled task completion (merge or kill to close) |
| `stopped`  | Session ended unexpectedly, needs user intervention     |

### Key Differences from Claude's Task Tool

| Task Tool             | `ib` Agents              |
| --------------------- | ------------------------ |
| Blocks until complete | Runs in background       |
| Shares your context   | Isolated conversation    |
| No git isolation      | Own branch + worktree    |
| Cannot spawn children | Can manage sub-agents    |
| Lost on crash         | Resumable via session ID |

<ittybitty-status>
</ittybitty-status>

</ittybitty>
