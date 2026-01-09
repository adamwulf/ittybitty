# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ittybitty (`ib`) is a minimal multi-agent orchestration tool for Claude Code. It uses tmux sessions and git worktrees to spawn and manage multiple Claude agents in parallel. The entire tool is a single bash script (`ib`, ~1800 lines).

## Architecture

```
You (human)
  ↕ conversation
Primary Agent (responsive, strategic)
  ↓ uses ib to spawn
Task Agent (runs in tmux, has worktree)
  ↑ can ask questions (send to another agent's stdin)
  ↓ can receive answers (as stdin from another agent)
  ↓ uses ib to spawn
Leaf Agents (focused workers, no sub-agents)
```

**Key insight**: Agents communicate via tmux stdin/stdout. No files, no protocols—just text.

- Each agent gets its own git worktree on branch `agent/<id>`
- Agent data stored in `.ittybitty/agents/<id>/` (meta.json, prompt.txt, start.sh, repo/)
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

Helper functions at the top: `load_config`, `build_agent_settings`, `resolve_agent_id`, `get_state`, `archive_agent_output`, etc.

## Configuration

`.ittybitty.json` configures permissions for spawned agents:
- `permissions.task.allow/deny` - tools for regular agents
- `permissions.leaf.allow/deny` - tools for leaf/worker agents
- `Bash(ib:*)` and `Bash(./ib:*)` are always added automatically

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

- Agent state detection (`get_state`): checks tmux session existence and output patterns
- States: `running` (actively processing), `waiting` (idle), `complete` (signaled done), `stopped` (no session)
- "Complete" detection: looks for exact phrase "I HAVE COMPLETED THE GOAL" in recent output
- Session persistence: each agent gets a UUID (`session_id` in meta.json) enabling `claude --resume`
- Exit handler (`exit-check.sh`): prompts for uncommitted changes when agent session ends
- Send timing: message and Enter key sent separately with 0.1s delay to handle busy agents

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

- If **Agent A** spawns **Agent B**: Agent A gets automatic watchdog notifications about Agent B
- If **you (user)** spawn **Agent A**: You will NOT get automatic notifications, even if Agent A spawns children
- **Primary agents in user conversations** must actively poll with `ib list` to check on their children

When agent spawns child agent (agent-to-agent):
- A watchdog is automatically spawned to monitor the child
- The watchdog notifies the parent agent when:
  - Child is waiting for >30 seconds (needs input)
  - Child completes (ready to review/merge)
- Parent agents should enter WAITING mode after spawning children
- No need for agents to poll `ib list` - watchdogs ensure timely notifications

### Workflow

**If you are a primary agent in a user conversation (no watchdog notifications):**
1. **Spawn**: `ib new-agent "clearly defined goal"` — returns agent ID
2. **Poll actively**: Use `ib list` regularly to check agent states (you won't get notifications!)
3. **Check status**: When agent shows `waiting` or `complete`, use `ib look <id>` to review
4. **Interact**: If `waiting` and needs input, use `ib send <id> "answer"`
5. **Merge/kill**: When `complete`, check with `ib diff <id>` then `ib merge <id>` or `ib kill <id>`

**If you are a background agent spawning sub-agents (automatic watchdog notifications):**
1. **Spawn**: `ib new-agent "clearly defined goal"` — agent auto-detects parent, watchdog auto-spawns
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
| `ib watchdog <id>`    | Monitor agent and notify parent (auto-spawned for child agents) |

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

</ittybitty>
