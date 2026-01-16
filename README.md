# ittybitty (`ib`)

A single bash script that lets you spawn, organize, and control multiple Claude Code agents.

Benefits:

- Staying safe (Tool use is auto-denied unless pre-approved. Yolo mode is optional, not required.)
- Simple command line interface to start, stop, monitor, merge, and kill agents. Simple for Claude to understand and use within your normal Claude sessions. Use Claude to spawn teams of Claude agents!
- View and control any agent, use `$ ib watch` to view and control all agents running in a repo
- Each agent gets its own git worktree (keep working in your normal git repo while agents fix bugs for you.)
- Agents can spawn helper agents and message each other
- Optional custom prompt for all new agents
- Automatic notifications to agents when their dependencies complete
- Agents can even resume after a system reboot and pick up where they left off
- Minimal dependencies, only requires `claude`, `tmux`, and `git`

## How It Works

When you spawn an agent with `ib`, it:

1. Creates a **git worktree** on a new branch (`agent/<id>`) - isolated from your main working tree (inside `.ittybitty/agents/[agent-id]/`)
2. Starts a **tmux session** running Claude Code in that worktree
3. Monitors the agent's state (running, waiting, complete, stopped)

Agents can spawn sub-agents, creating a hierarchy. Manager agents coordinate work; worker agents execute focused tasks. When an agent completes, you review its changes and merge them back to your branch.

```
You (human)
  ↕ conversation
Primary Claude (your normal main session)
  ↓ spawns via ib
Manager Agent (can spawn sub-agents)
  ↓ spawns via ib
Worker Agents (focused execution, no sub-agents)
```

You don't need to change your workflow to use `ittybitty`. You can think of its agents as _just_ another Claude Code terminal that can work independently, stays within allowed tool permissions, and can spawn message other agents. You can view, merge, or kill any agent at any time.

## Installation

### Prerequisites

- **tmux** - terminal multiplexer
- **git** - version control
- **claude** - Claude Code CLI

### Add to PATH

```bash
# Clone the repository
git clone https://github.com/anthropics/ittybitty /path/to/ittybitty

# Add to PATH (add to your shell profile for persistence)
export PATH="/path/to/ittybitty:$PATH"

# Run ib to see its help
ib
```

### Project Setup

All setup steps are optional (but recommended). You can test `ib ` just by downloading and running it.

Run `ib watch` in your project directory and press `h` to open the setup dialog:

```bash
cd your-project
# open realtime ib console
ib watch
# Press 'h' to open setup dialog
```

The setup dialog lets you configure:

| Option | Purpose |
|--------|---------|
| **Safety hooks** | Prevents your main Claude from `cd`-ing into agent worktrees. Stop Claude from getting confused about its whereabouts. |
| **ib instructions** | Adds `<ittybitty>` block to CLAUDE.md so Claude knows how to use `ib` |
| **.gitignore** | Adds `.ittybitty/` to your .gitignore |
| **Config file** | Creates `.ittybitty.json` for `ib config` settings |

Toggle options with Space or Enter. The first four options should be enabled for full functionality.

## Your First Agent

Spawning a new agent is easy. By default, all new agents are managers, which means they can also spawn agents. You can force a worker agent by adding `--worker` to any of the `new-agent` commands below.

```bash
# Basic usage
ib new-agent "Refactor the authentication module to use JWT tokens"

# With a custom name
ib new-agent --name auth-refactor "Refactor authentication to use JWT"

# Using a specific model
ib new-agent --model haiku "Write unit tests for the utils module"
```

The command returns an agent ID (or uses your `--name`) that you'll use for all subsequent commands.

Next, monitor your agent with the **Interactive dashboard (recommended):**

```bash
ib watch
```

The watch UI show?s all agents, their states, and recent activity. Keyboard shortcuts are listed in the UIs footer.

You can also monitor with the command line. This makes it easy to integrate `ib` into other tools.

```bash
ib list                     # Show all agents and their states
ib look <id>                # View agent's recent output
ib status <id>              # Show agent's git commits and changes
```

As you monitor agents, each agent will move between these states:

| State | Meaning |
|-------|---------|
| `creating` | Agent is starting up |
| `running` | Actively working |
| `waiting` | Idle, may need input |
| `complete` | Agent signaled it finished |
| `stopped` | Session ended (eg from system reboot), use `ib resume` to continue |
| `compacting` | The claude session is compacting and will resume soon |
| `rate_limited` | The 5 hour session or weekly limit has been reached, and claude is paused. |
| `unknown` | In rare cases, the status cannot be determined. This is treated as a `waiting` status. |

You can interact with agents by sending messages, and viewing their git status, git diff, or even their `Claude` session

```bash
# Send input to an agent (answers questions, provides guidance)
ib send <id> "Focus on the login flow first"

# View what the agent has done
ib diff <id>                # Full diff of changes
ib status <id>              # Commits and file changes

# View the agent's running claude session
ib look <id>
```

Once you're happy (or sad!) with an agent's work, you can merge or kill the agent. `ib merge` will merge the agent's work into your currently active branch. The merge will preemptively fail if there is a merge conflict. This keeps your git status clean, and you can tell an agent to fix any merge conflicts and try again when it's finished.

```bash
# Check if the merge would succeed
ib merge-check <id>

# Merge agent's branch into your current branch
ib merge <id>

# Or discard the agent's work
ib kill <id>
```

Use `--force` to skip confirmation prompts.

## Safety Comes First

**Tools**

`ittybitty` is built for safety first, and does not require `--yolo` mode. Any tool that is not explicitly allowed in Claude's normal settings.json will be auto-denied. This keeps you in control of what agents can and can't do.

Some tools are required for `ib` to function properly, and will always be enabled:

**Hooks**

`ittybitty` uses hooks to prevent agents from moving into other agent's worktrees, including the primary repository. All agent worktrees are located in `.ittybitty/agents/[agent-id]`.

**Archives**

All Claude sessions go through the normal archive process that is managed by Claude. In addition, `ittybitty` archives the full Claude session log, the `ittybitty` agent log, which includes sent messages and status updates, metadata about the agent including its model and creation time.

**Simplicity**

The safest systems are the ones you can understand. `ittybitty` runs normal Claude in normal terminal sessions, and sends them commands just like you do when you type in a `claude` session. You have full visibility into the running agents, their state, and their relationships. You have full control and visibility into agents you already understand.

**Nuke it from orbit**

If for some reason your agents get out of control, you can run `ib nuke` to immediately kill and archive all agents. All of their session history and logs are archived in `.ittybitty/archives/[timestamp]-[agent]` so you can review exactly what happened, if you ever need to.

## Using with Claude Code

Once you've run the setup dialog (`ib watch` → `h`), Claude will know how to spawn agents during your conversation:

**You:** "Refactor the API layer. This is a big task, so spawn some agents to help."

**Claude:** *spawns agents using `ib new-agent`*

Claude will tell you to run `ib watch` in another terminal to monitor progress. Agents work in the background while your conversation continues.

Agents can ask questions that appear in your Claude conversation (via the STATUS.md import). When you see a question:

```bash
ib questions               # List pending questions
ib acknowledge <q-id>      # Mark question as handled
ib send <agent-id> "answer"  # Send your response
```

This is done by auto-importing the running agent's status and messages into the `CLAUDE.md` with an `@./ittybitty/STATUS.md` import. This does let Claude see status and messages, but it also _only_ updates at the start of a new conversation.

You can always ask Claude to check on agents, and it will `ib list` to see their status, and can check on them and message them if needed.

## Configuration

### Quick Config with `ib config`

```bash
# View a setting (returns default if not set)
# maxAgents defaults to 10
ib config get maxAgents

# Change a setting
ib config set maxAgents 20
ib config set model sonnet
```

View all configuration options with `ib conflg list`

### Configuration File

Create `.ittybitty.json` in your project root for full configuration. You can setup a default `.ittybitty.json` file with `ib watch` and then enter its setup with `h` hotkey. This json file stores the configuration that you can also view and edit with `ib config`

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

### Agent Creation Hooks

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

## Troubleshooting

### Agent stuck in "creating" state

The agent may be waiting on a workspace trust prompt. Check with `ib look <id>`.

### "Path violation" errors in agent logs

The agent tried to access files outside its worktree. This is expected behavior - agents are isolated to their own worktree.

### Merge conflicts

If `ib merge` fails due to conflicts, you can ask the agent to fix the conflicts and try to merge again when it's done.
### View agent logs

```bash
# Each agent has a log file
cat .ittybitty/agents/<id>/agent.log

# Archived agents (after kill/merge)
ls .ittybitty/archive/
```

Agent logs are also the default visible pane when launching `ib watch`.

## Enjoying `ittybitty`?

[Buy me a coffee](https://github.com/sponsors/adamwulf) ☕️
