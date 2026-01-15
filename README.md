# ittybitty (`ib`)

A minimal multi-agent orchestration tool for Claude Code. Spawn persistent background agents that work in isolated git worktrees while you continue your conversation.

**How simple can multi-agent orchestration be?** Just four features: agents that spawn agents, inter-agent communication, status tracking, and isolated git worktrees.

`ib` uses only `claude`, `tmux`, `jq`, and `git` to provide a single CLI for spawning and coordinating background agents.

## How It Works

When you spawn an agent with `ib`, it:

1. Creates a **git worktree** on a new branch (`agent/<id>`) - isolated from your main working tree
2. Starts a **tmux session** running Claude Code in that worktree
3. Monitors the agent's state (running, waiting, complete, stopped)

Agents can spawn sub-agents, creating a hierarchy. Manager agents coordinate work; worker agents execute focused tasks. When an agent completes, you review its changes and merge them back to your branch.

```
You (human)
  ↕ conversation
Primary Claude (your main session)
  ↓ spawns via ib
Manager Agent (can spawn sub-agents)
  ↓ spawns via ib
Worker Agents (focused execution, no sub-agents)
```

## Installation

### Prerequisites

- **tmux** - terminal multiplexer
- **jq** - JSON processor
- **git** - version control
- **claude** - Claude Code CLI

### Add to PATH

```bash
# Clone the repository
git clone https://github.com/anthropics/ittybitty /path/to/ittybitty

# Add to PATH (add to your shell profile for persistence)
export PATH="/path/to/ittybitty:$PATH"

# Or symlink to a directory already in PATH
ln -s /path/to/ittybitty/ib /usr/local/bin/ib
```

### Project Setup

Run `ib watch` in your project directory and press `h` to open the setup dialog:

```bash
cd your-project
ib watch
# Press 'h' to open setup dialog
```

The setup dialog configures:

| Option | Purpose |
|--------|---------|
| **Safety hooks** | Prevents your main Claude from `cd`-ing into agent worktrees |
| **ib instructions** | Adds `<ittybitty>` block to CLAUDE.md so Claude knows how to use `ib` |
| **STATUS.md import** | Enables visibility into agent questions via `@.ittybitty/STATUS.md` |
| **.gitignore** | Adds `.ittybitty/` to your .gitignore |

Toggle options with number keys. All options should be enabled for full functionality.

## Your First Agent

### Spawn an Agent

```bash
# Basic usage
ib new-agent "Refactor the authentication module to use JWT tokens"

# With a custom name
ib new-agent --name auth-refactor "Refactor authentication to use JWT"

# Using a specific model
ib new-agent --model haiku "Write unit tests for the utils module"
```

The command returns an agent ID (or uses your `--name`) that you'll use for all subsequent commands.

### Monitor Progress

**Interactive dashboard (recommended):**

```bash
ib watch
```

The watch UI shows all agents, their states, and recent activity. Press `?` for keyboard shortcuts.

**Command-line monitoring:**

```bash
ib list                     # Show all agents and their states
ib look <id>                # View agent's recent output
ib status <id>              # Show agent's git commits and changes
```

### Agent States

| State | Meaning |
|-------|---------|
| `creating` | Agent is starting up |
| `running` | Actively working |
| `waiting` | Idle, may need input |
| `complete` | Agent signaled it finished |
| `stopped` | Session ended (crashed or user killed) |

### Interact with Agents

```bash
# Send input to an agent (answers questions, provides guidance)
ib send <id> "Focus on the login flow first"

# View what the agent has done
ib diff <id>                # Full diff of changes
ib status <id>              # Commits and file changes
```

### Merge or Discard Work

```bash
# Review changes first
ib diff <id>

# Merge agent's branch into your current branch
ib merge <id>

# Or discard the agent's work
ib kill <id>
```

Use `--force` to skip confirmation prompts.

## Using with Claude Code

Once you've run the setup dialog (`ib watch` → `h`), Claude can spawn agents during your conversation:

**You:** "Refactor the API layer. This is a big task, so spawn some agents to help."

**Claude:** *spawns agents using `ib new-agent`*

Claude will tell you to run `ib watch` in another terminal to monitor progress. Agents work in the background while your conversation continues.

### Agent Questions

Agents can ask questions that appear in your Claude conversation (via the STATUS.md import). When you see a question:

```bash
ib questions               # List pending questions
ib acknowledge <q-id>      # Mark question as handled
ib send <agent-id> "answer"  # Send your response
```

## Configuration

### Quick Config with `ib config`

```bash
# View a setting (returns default if not set)
ib config get maxAgents

# Change a setting
ib config set maxAgents 20
ib config set model sonnet
```

### Configuration File

Create `.ittybitty.json` in your project root for full configuration:

```json
{
  "maxAgents": 10,
  "model": "sonnet",
  "fps": 10,
  "createPullRequests": false,
  "allowAgentQuestions": true,
  "noFastForward": false,
  "autoCompactThreshold": 80,
  "externalDiffTool": "",
  "permissions": {
    "manager": {
      "allow": ["Bash(npm:*)"],
      "deny": []
    },
    "worker": {
      "allow": [],
      "deny": ["WebSearch"]
    }
  }
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `maxAgents` | 10 | Maximum concurrent agents (safety limit) |
| `model` | (none) | Default model for new agents (opus, sonnet, haiku) |
| `fps` | 10 | Refresh rate for `ib watch` |
| `createPullRequests` | false | Create PRs instead of leaving changes on branch |
| `allowAgentQuestions` | true | Allow root managers to ask user questions via `ib ask` |
| `noFastForward` | false | Always create merge commits with `--no-ff` |
| `autoCompactThreshold` | (none) | Context % to trigger `/compact` (1-100, unset=auto) |
| `externalDiffTool` | (none) | External diff tool for reviewing agent changes |
| `permissions.manager.allow` | [] | Additional tools to allow for manager agents |
| `permissions.manager.deny` | [] | Tools to deny for manager agents |
| `permissions.worker.allow` | [] | Additional tools to allow for worker agents |
| `permissions.worker.deny` | [] | Tools to deny for worker agents |

### Spawn Options

```bash
ib new-agent [options] "prompt"

Options:
  --name <name>      Custom agent name (default: auto-generated)
  --worker           Worker agent that cannot spawn sub-agents
  --model <model>    Model to use (opus, sonnet, haiku)
  --no-worktree      Work in repo root instead of isolated worktree
  --yolo             Full autonomy, skip all permission prompts
  --print            One-shot mode: run and exit
```

## Extensibility

### Custom Agent Prompts

Add project-specific instructions to agents by creating markdown files in `.ittybitty/prompts/`:

| File | Applied To |
|------|------------|
| `all.md` | All agents |
| `manager.md` | Manager agents only |
| `worker.md` | Worker agents only |

**Example `.ittybitty/prompts/all.md`:**
```markdown
## Project Standards
- Use TypeScript strict mode
- Run `npm test` before committing
- Follow existing code style
```

### User Hooks

Run custom scripts when agents are created:

```bash
# Create the hooks directory
mkdir -p .ittybitty/hooks

# Create your hook
cat > .ittybitty/hooks/post-create-agent << 'EOF'
#!/bin/bash
echo "[$(date -Iseconds)] Agent $IB_AGENT_ID ($IB_AGENT_TYPE)" >> .ittybitty/creation.log
EOF

# Make it executable
chmod +x .ittybitty/hooks/post-create-agent
```

Available environment variables in hooks:

| Variable | Description |
|----------|-------------|
| `IB_AGENT_ID` | Agent's unique ID |
| `IB_AGENT_TYPE` | "manager" or "worker" |
| `IB_AGENT_DIR` | Path to agent's data directory |
| `IB_AGENT_BRANCH` | Git branch name |
| `IB_AGENT_MANAGER` | Parent manager ID (if any) |
| `IB_AGENT_PROMPT` | The task prompt |
| `IB_AGENT_MODEL` | Model being used |

## Command Reference

### Agent Lifecycle

| Command | Description |
|---------|-------------|
| `ib new-agent "prompt"` | Spawn a new agent |
| `ib resume <id>` | Restart a stopped agent |
| `ib kill <id>` | Close agent without merging |
| `ib merge <id>` | Merge agent's work and close |

### Monitoring

| Command | Description |
|---------|-------------|
| `ib watch` | Interactive dashboard |
| `ib list` | Show all agents |
| `ib look <id>` | View agent's output |
| `ib status <id>` | Show git commits/changes |
| `ib diff <id>` | Full diff of agent's work |
| `ib info <id>` | Show agent configuration |

### Communication

| Command | Description |
|---------|-------------|
| `ib send <id> "msg"` | Send input to agent |
| `ib questions` | List pending questions |
| `ib acknowledge <id>` | Mark question as handled |

### Configuration

| Command | Description |
|---------|-------------|
| `ib config get <key>` | Get a config value |
| `ib config set <key> <value>` | Set a config value |
| `ib hooks status` | Check hook installation |
| `ib hooks install` | Install safety hooks |

## Emergency Stop

If agents spawn out of control:

```bash
ib nuke
```

This kills ALL active agents without merging, archives their output, and cleans up. Use `--force` to skip confirmation.

## Troubleshooting

### Agent stuck in "creating" state

The agent may be waiting on a workspace trust prompt. Check with `ib look <id>`.

### "Path violation" errors in agent logs

The agent tried to access files outside its worktree. This is expected behavior - agents are isolated to their own worktree.

### Merge conflicts

If `ib merge` fails due to conflicts, you can:
1. Resolve manually in your working tree
2. Use `ib kill <id>` to discard the agent's work

### View agent logs

```bash
# Each agent has a log file
cat .ittybitty/agents/<id>/agent.log

# Archived agents (after kill/merge)
ls .ittybitty/archive/
```
