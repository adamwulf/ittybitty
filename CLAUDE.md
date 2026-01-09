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
| 184 | `new-agent` | Spawn new agent with worktree/tmux session |
| 547 | `list` | Show running/finished agents |
| 651 | `send` | Send input to agent's stdin |
| 765 | `watch` | Watch agent's tmux output |
| 856 | `status` | Show agent's git commits/changes |
| 983 | `diff` | Show full diff of agent's work |
| 1071 | `kill` | Close agent without merging |
| 1184 | `merge` | Merge agent's branch and close |

Helper functions are at the top (lines 1-183): `load_config`, `build_agent_settings`, `resolve_agent_id`, `get_agent_state`, etc.

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
./ib watch test

# Cleanup
./ib kill test --force
```

## Key Implementation Details

- Agent state detection (`get_agent_state`): checks tmux session existence and output patterns
- "Waiting" detection is heuristic: looks for `?` at end of recent output
- Exit handler (`exit-check.sh`): prompts for uncommitted changes when agent session ends
- Send timing: message and Enter key sent separately with 0.1s delay to handle busy agents
