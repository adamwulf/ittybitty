# ittybitty (`ib`)

How simple can multi-agent orchestration be? Just four features: agents that spawn agents, inter-agent communication, status tracking, and isolated git worktrees.

`ib` uses only `claude`, `tmux`, `jq`, and `git` to provide a single CLI for spawning and coordinating background agents. Use directly from command line or within a Claude Code session.

## Installation

```bash
# Clone and add to PATH
git clone <repo-url> /path/to/ittybitty
export PATH="/path/to/ittybitty:$PATH"

# Or symlink
ln -s /path/to/ittybitty/ib /usr/local/bin/ib
```

**Requirements:** tmux, jq, git

## Adding `ib` to Your Project

To make Claude aware of `ib`, add this to your project's `CLAUDE.md`:

```markdown
<ittybitty>
## Multi-Agent Orchestration (ittybitty)

You have access to `ib` for spawning long-running background agents. Unlike Claude's built-in Task tool (which spawns ephemeral subagents that block until complete), `ib` agents are **persistent Claude Code instances** that run in isolated git worktrees and can work autonomously for extended periods.

### When to Use

- Large or complex tasks that benefit from isolation
- Long-running research or analysis
- When the user explicitly requests background agents
- Tasks that can run while you continue other work

### Automatic Notifications

When an agent spawns a child agent:
- A watchdog is automatically spawned to monitor the child
- The watchdog notifies the parent when:
  - Child is waiting for >30 seconds (needs input)
  - Child completes (ready to review/merge)
- Parent agents should enter WAITING mode after spawning children
- No need to poll `ib list` - watchdogs ensure timely notifications

### Workflow

**For agents spawning sub-agents:**
1. **Spawn**: `ib new-agent "clearly defined goal"` — agent auto-detects parent, watchdog auto-spawns
2. **Enter WAITING**: Parent enters WAITING mode after spawning sub-agents
3. **Auto-notify**: Watchdog monitors each child and notifies parent when:
   - Child has been waiting >30s (needs input)
   - Child completes (ready to merge/review)
4. **Review & merge**: When notified, check work with `ib look/diff <id>`, then `ib merge <id>` or `ib kill <id>`

**For user-spawned agents:**
1. **Spawn**: `ib new-agent "goal"` — returns agent ID
2. **Monitor**: `ib list` — check agent states
3. **Interact**: If `waiting`, use `ib look <id>` then `ib send <id> "answer"`
4. **Complete**: When `complete`, check with `ib diff <id>` and `ib merge <id>`

### All Commands

| Command | Description |
|---------|-------------|
| `ib new-agent "goal"` | Spawn a new agent, returns its ID |
| `ib list` | Show all agents and their status |
| `ib look <id>` | View an agent's recent output |
| `ib send <id> "msg"` | Send input to an agent |
| `ib status <id>` | Show agent's git commits and changes |
| `ib diff <id>` | Show full diff of agent's work vs main |
| `ib merge <id>` | Merge agent's work and permanently close it |
| `ib kill <id>` | Permanently close agent without merging |
| `ib resume <id>` | Restart a stopped agent's session |
| `ib watchdog <id>` | Monitor agent and notify parent (auto-spawned for child agents) |

### Agent States

| State | Meaning |
|-------|---------|
| `running` | Agent is actively processing |
| `waiting` | Agent is idle, may need input |
| `complete` | Agent signaled task completion (merge or kill to close) |
| `stopped` | Session ended unexpectedly, needs user intervention |

### Key Differences from Claude's Task Tool

| Task Tool | `ib` Agents |
|-----------|-----------|
| Blocks until complete | Runs in background |
| Shares your context | Isolated conversation |
| No git isolation | Own branch + worktree |
| Cannot spawn children | Can manage sub-agents |
| Lost on crash | Resumable via session ID |

</ittybitty>
```

## Quick Example

```bash
# Spawn a research agent
ib new-agent --name research "Research competitor pricing and summarize findings"

# Check on it periodically
ib list                     # See state: running, waiting, complete, or stopped
ib look research            # View recent output

# If it's waiting with a question
ib send research "Focus on the top 3 competitors only"

# When complete, review and merge
ib diff research            # See what changed
ib merge research           # Merge branch into main and cleanup
```

Agents can spawn their own sub-agents for hierarchical task breakdown. Use `--leaf` for worker agents that shouldn't spawn children.

## Configuration

**Spawn options:**
- `--name <name>` — Custom agent name (default: auto-generated ID)
- `--no-worktree` — Work in repo root instead of isolated worktree
- `--leaf` — Worker agent that cannot spawn sub-agents
- `--parent <id>` — Track parent relationship for hierarchical coordination
- `--yolo` — Full autonomy, skip all permission prompts
- `--model <model>` — Use a specific model (opus, sonnet, haiku)
- `--print` — One-shot mode: run and exit, no interaction

**Permissions:** Agents inherit your `.claude/settings.local.json`. The `Bash(ib:*)` permission is automatically added so agents can coordinate sub-agents.

**Project config (`.ittybitty.json`):**
```json
{
  "createPullRequests": true
}
```
When enabled (and `gh` CLI is installed with a git remote configured), agents will create a pull request when their work is complete instead of leaving changes on their branch.

**Environment:** Set `ITTYBITTY_DIR` to change the base directory (default: `.ittybitty`).

## Limitations

- **Merge conflicts**: If `ib merge` fails due to conflicts, the merging agent resolves them manually (edit files, `git add`, `git commit`)
- **Context limits**: Long-running agents may hit existing Claude context windows; break large tasks into smaller agents
