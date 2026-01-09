# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ittybitty (`ib`) is a minimal multi-agent orchestration tool for Claude Code. It uses tmux sessions and git worktrees to spawn and manage multiple Claude agents in parallel. The entire tool is a single bash script (`ib`, ~1400 lines).

## Architecture

```
You (human)
  ↕ conversation
Primary Agent (responsive, strategic)
  ↓ uses ib to spawn
Task Agent (runs in tmux, has worktree)
  ↕ can ask questions (waits for stdin)
  ↓ uses ib to spawn
Leaf Agents (focused workers, no sub-agents)
```

**Key insight**: Agents communicate via tmux stdin/stdout. No files, no protocols—just text.

- Each agent gets its own git worktree on branch `agent/<id>`
- Agent data stored in `.ittybitty/agents/<id>/` (meta.json, prompt.txt, start.sh, repo/)
- Messages between agents are prefixed with `[sent by agent <id>]:`

## Script Structure

The `ib` script is organized into commands, each with its own section:

| Line | Command | Purpose |
|------|---------|---------|
| 222 | `new-agent` | Spawn new agent with worktree/tmux session |
| 607 | `list` | Show running/finished agents |
| 717 | `send` | Send input to agent's stdin |
| 831 | `look` | Watch agent's tmux output |
| 922 | `status` | Show agent's git commits/changes |
| 1049 | `diff` | Show full diff of agent's work |
| 1137 | `kill` | Close agent without merging |
| 1241 | `resume` | Restart a stopped agent's session |
| 1398 | `merge` | Merge agent's branch and close |

Helper functions are at the top (lines 1-221): `load_config`, `build_agent_settings`, `resolve_agent_id`, `get_state`, etc.

## Configuration

`.ittybitty.json` configures permissions for spawned agents:
- `permissions.task.allow/deny` - tools for regular agents
- `permissions.leaf.allow/deny` - tools for leaf/worker agents
- `Bash(ib:*)` and `Bash(./ib:*)` are always added automatically

## Testing

No formal test suite. Test manually by spawning agents:

```bash
# Test basic spawn
./ib new-agent --name test "echo hello and exit"

# Test communication
./ib send test "hello"
./ib look test

# Cleanup
./ib kill test --force
```

## Key Implementation Details

- Agent state detection (`get_state`): checks tmux session existence and output patterns
- States: `running` (actively processing), `waiting` (idle), `complete` (signaled done), `stopped` (no session)
- "Complete" detection: looks for exact phrase "I HAVE COMPLETED THE GOAL" in recent output
- Session persistence: each agent gets a UUID (`session_id` in meta.json) enabling `claude --resume`
- Exit handler (`exit-check.sh`): prompts for uncommitted changes when agent session ends
- Send timing: message and Enter key sent separately with 0.1s delay to handle busy agents

<ittybitty>
## Multi-Agent Orchestration (ittybitty)

You have access to `ib` for spawning long-running background agents. Unlike Claude's built-in Task tool (which spawns ephemeral subagents that block until complete), ib agents are **persistent Claude Code instances** that run in isolated git worktrees and can work autonomously for extended periods.

### When to Use

- Large or complex tasks that benefit from isolation
- Long-running research or analysis
- When the user explicitly requests background agents
- Tasks that can run while you continue other work

### Workflow

1. **Spawn**: `ib new-agent "clearly defined goal"` — returns the new agent's ID
2. **Monitor**: `ib list` — check agent states periodically
3. **Interact**: If `waiting`, use `ib look <id>` then `ib send <id> "answer"`
4. **Close**: When `complete`, check work with `ib look/diff <id>`. If done, `ib merge <id>` or `ib kill <id>`. If not done, `ib send <id> "what's wrong and how to continue"`
5. **Recover**: If `stopped`, STOP and notify the user. Offer to check work with `ib status/diff <id>`, then let user choose: `ib resume <id>`, `ib merge <id>`, or `ib kill <id>`

### All Commands

| Command               | Description                                 |
| --------------------- | ------------------------------------------- |
| `ib new-agent "goal"` | Spawn a new agent, returns its ID           |
| `ib list`             | Show all agents and their status            |
| `ib look <id>`        | View an agent's recent output               |
| `ib send <id> "msg"`  | Send input to an agent                      |
| `ib status <id>`      | Show agent's git commits and changes        |
| `ib diff <id>`        | Show full diff of agent's work vs main      |
| `ib merge <id>`       | Merge agent's work and permanently close it |
| `ib kill <id>`        | Permanently close agent without merging     |
| `ib resume <id>`      | Restart a stopped agent's session           |

### Agent States

| State      | Meaning                                                 |
| ---------- | ------------------------------------------------------- |
| `running`  | Agent is actively processing                            |
| `waiting`  | Agent is idle, may need input                           |
| `complete` | Agent signaled task completion (merge or kill to close) |
| `stopped`  | Session ended unexpectedly, needs user intervention     |

### Key Differences from Claude's Task Tool

| Task Tool             | ib Agents                |
| --------------------- | ------------------------ |
| Blocks until complete | Runs in background       |
| Shares your context   | Isolated conversation    |
| No git isolation      | Own branch + worktree    |
| Cannot spawn children | Can manage sub-agents    |
| Lost on crash         | Resumable via session ID |

</ittybitty>
