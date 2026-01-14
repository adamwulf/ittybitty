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

**Add to .gitignore:** The `.ittybitty` directory stores agent data (worktrees, logs, metadata). Add it to your project's `.gitignore`:

```bash
echo ".ittybitty" >> .gitignore
```

## How `ib` Works

`ib` helps you manage two Claude agent types:

1. **Manager agents** — Can spawn other agents (both manager and/or worker). Analyze tasks and delegate work.
2. **Worker agents** — Cannot spawn new agents. Must complete their work themselves.

**Task sizing strategy (manager agents):**

When a manager agent receives a task, it thinks through what's needed and decides:

- **Small task** — Easy enough to be completed quickly by a single agent. Manager does it directly without spawning sub-agents.
- **Medium task** — Needs to be done by a few agents in parallel. Manager spawns sub-agents (manager or worker) to work concurrently.
- **Large task** — Needs to be done in stages with multiple agents. Manager spawns agents for each stage as the task progresses.

**Two ways to use `ib`:**

1. **Manual mode** — Run `ib` commands directly from your terminal at the repo root to create, list, merge, and kill agents.
2. **Integrated mode** — Copy the prompt from "Adding `ib` to Your Project" below into your project's `CLAUDE.md`. Then Claude can spawn and coordinate agents automatically during your normal Claude workflow.

**Managing subagents:**

When a manager spawns subagents, it will automatically track their progress and keep them working if they are stuck. This is done with a watchdog process that spawns in parallel to the child agent. This watchdog does not use Claude, which helps keep your Claude session use low when many agents are running and coordinating.

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

### Automatic Notifications (Agent-to-Agent Only)

**IMPORTANT**: Watchdog notifications only work between agents, not between user and agent.

- If **Manager Agent A** spawns **Worker Agent B**: Agent A gets automatic watchdog notifications about Agent B
- If **you (primary agent)** spawn **Agent A**: You will NOT get automatic notifications
- **Do NOT poll** with `ib list` - polling wastes tokens. Instead, tell the user that you've spawned agents and that you'll both need to check on them periodically. The user can run `ib watch` in another terminal to monitor agent status.

When agent spawns child agent (agent-to-agent):
- A watchdog is automatically spawned to monitor the child
- The watchdog notifies the manager agent when:
  - Child is waiting for >30 seconds (needs input)
  - Child completes (ready to review/merge)
- Manager agents should enter WAITING mode after spawning children

### Workflow

**If you are a primary agent in a user conversation (no watchdog notifications):**
1. **Spawn**: `ib new-agent "clearly defined goal"` — returns agent ID
2. **Inform the user**: Tell them you've spawned agents and suggest they run `ib watch` in another terminal
3. **Wait for user**: The user will tell you when agents need attention or are complete
4. **Check status**: Use `ib look <id>` to review output when the user notifies you
5. **Interact**: If agent needs input, use `ib send <id> "answer"`
6. **Respond to questions**: If agents ask questions (shown in STATUS.md), use `ib acknowledge <question-id>` then `ib send <agent-id> "answer"`
7. **Merge/kill**: When complete, check with `ib diff <id>` then `ib merge <id> --force` or `ib kill <id> --force`

**If you are a background agent spawning sub-agents (automatic watchdog notifications):**
1. **Spawn**: `ib new-agent "clearly defined goal"` — agent auto-detects manager, watchdog auto-spawns
2. **Enter WAITING**: Enter WAITING mode after spawning sub-agents (use `read` or similar)
3. **Auto-notify**: Watchdog monitors each child and notifies you when:
   - Child has been waiting >30s (needs input)
   - Child completes (ready to merge/review)
4. **Review & merge**: When notified, check work with `ib look/diff <id>`, then `ib merge <id> --force` or `ib kill <id> --force`

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
| `ib ask "question"`   | Ask the user-level Claude a question (top-level managers only) |
| `ib questions`        | List pending questions from agents                           |
| `ib acknowledge <id>` | Mark a question as handled (primary agent only, alias: `ack`) |

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
| `creating` | Agent is initializing (Claude starting up)              |
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

### User Questions (Agent-to-User Communication)

Top-level manager agents can ask questions of the user-level Claude using `ib ask`. Questions are stored in `.ittybitty/user-questions.json` and appear in STATUS.md via the @import.

**Communication hierarchy:**
- **Workers/sub-managers** → must ask their manager (via `ib send <manager> "question"`)
- **Top-level managers** → can ask the user directly (via `ib ask "question"`)

**Workflow for agents asking questions:**
```bash
# Top-level manager asks the user
ib ask "Should I proceed with option A or B?"
# Then enter WAITING mode until the user responds
```

**Workflow for user-level Claude responding (PRIMARY AGENT ONLY):**
1. See pending questions in STATUS.md (via @import)
2. `ib acknowledge <question-id>` to mark as handled
3. `ib send <agent-id> "your answer"` to respond to the agent

**Note**: Only the primary (user-level) Claude can use `ib acknowledge`. Background agents cannot acknowledge questions.

**IMPORTANT - Question Visibility Limitation:**
Questions from agents are stored in STATUS.md, which is imported at conversation start. If you spawn agents and continue working, you will NOT automatically see new questions that arrive mid-conversation.

To stay aware of agent questions:
- Periodically run `ib questions` to check for pending questions
- The user can run `ib watch` in another terminal for real-time monitoring
- If an agent seems stuck, check `ib questions` - it may be waiting for your answer

@.ittybitty/STATUS.md

</ittybitty>

```

**More examples:**
```bash
# Multi-file refactoring
ib new-agent "Refactor the authentication system. Spawn one agent per file that needs changes (api/auth.ts, components/Login.tsx, hooks/useAuth.ts). Each agent should complete its refactoring, then you review all changes and ensure consistency." --model haiku

# Parallel research
ib new-agent "Research best practices for React performance. Spawn 3 agents: one for React docs, one for community articles, one for benchmarking tools. Collect and synthesize their findings into a single report."
```

### Primary Agent Workflow

1. **Spawn root**: `ib new-agent "complete task description including structure"`
2. **Inform user**: Tell them you've spawned agents and suggest `ib watch` in another terminal
3. **Wait for user**: The user will notify you when agents need attention or are complete
4. **Check when notified**: Use `ib look <id>` to review agent output
5. **Interact if needed**: If agent needs input, use `ib send <id> "answer"`
6. **Respond to questions**: If agents ask questions (shown in STATUS.md), use `ib acknowledge <question-id>` then `ib send <agent-id> "answer"`
7. **Merge/kill**: When complete, check with `ib diff <id>` then `ib merge <id> --force` or `ib kill <id> --force`

### Responding to Agent Questions

Top-level manager agents can ask you questions using `ib ask`. These questions appear in `.ittybitty/STATUS.md` (visible via @import). To respond:

1. **See pending questions**: Check STATUS.md or run `ib questions`
2. **Acknowledge**: `ib acknowledge <question-id>` — marks the question as handled
3. **Respond**: `ib send <agent-id> "your answer"` — sends your answer to the agent

**Note**: Only YOU (the primary agent) can acknowledge questions. Background agents cannot use `ib acknowledge`.

**IMPORTANT - Question Visibility Limitation:**
Questions from agents are stored in STATUS.md, which is imported at conversation start. If you spawn agents and continue working, you will NOT automatically see new questions that arrive mid-conversation.

To stay aware of agent questions:
- Periodically run `ib questions` to check for pending questions
- The user can run `ib watch` in another terminal for real-time monitoring
- If an agent seems stuck, check `ib questions` - it may be waiting for your answer

### When to Use

- Large or complex tasks that benefit from isolation
- Long-running research or analysis
- When the user explicitly requests background agents
- Tasks that can run while you continue other work
- Hierarchical tasks that benefit from recursive delegation

---

## For Manager Agents

You were spawned via `ib new-agent` without the `--worker` flag. You run in a tmux session with your own git worktree.

**Key capabilities:**
- You CAN spawn child agents (manager or worker)
- You DO get automatic watchdog notifications for your children
- If you're a **top-level manager** (no manager above you), you can ask the user questions via `ib ask "question?"`
- You should signal completion when done (output "I HAVE COMPLETED THE GOAL")

### Manager Agent Workflow

1. **Understand your goal**: Your prompt contains your specific task
2. **Decide your approach**:
   - **Simple task?** Do it yourself without spawning children
   - **Complex task?** Spawn child agents for sub-tasks
   - **Need user input?** If you're a top-level manager, use `ib ask "question?"` then enter WAITING mode
3. **If spawning children**:
   - Spawn each child with a clear, focused goal
   - Use `--worker` for workers that should just execute (no sub-agents)
   - Don't use `--worker` for managers that may need to delegate further
   - Enter WAITING mode after spawning (`read` or similar)
4. **When notified about children**:
   - Use `ib look <id>` to review their work
   - Use `ib send <id> "message"` if they need input
   - Use `ib diff <id>` to see their changes
   - Use `ib merge <id> --force` to accept their work
   - Use `ib kill <id> --force` to reject and close them
5. **Signal completion**: When all children are merged and your work is done, output "I HAVE COMPLETED THE GOAL"

### Asking the User Questions (Top-Level Managers Only)

If you have NO manager above you, you can ask the primary (user-level) Claude questions:

```bash
ib ask "Should I proceed with approach A or B?"
```

Then enter WAITING mode. The user will see your question and respond via `ib send`.

**Note**: Sub-managers and workers cannot use `ib ask`. They should ask their manager via `ib send <manager-id> "question"`. However, if a manager has been merged/killed, orphaned agents are allowed to escalate to the user directly.

### Watchdog Notifications

When you spawn a child agent:
- A watchdog automatically monitors the child
- You'll be notified when:
  - Child has been waiting >30 seconds (may need input)
  - Child completes (ready to review/merge)
- No need to poll `ib list` - watchdogs handle it

---

## For Worker Agents

You were spawned via `ib new-agent --worker`. You run in a tmux session with your own git worktree.

**Key restrictions:**
- You CANNOT spawn child agents - you must complete the work yourself
- You should signal completion when done (output "I HAVE COMPLETED THE GOAL")

### Worker Agent Workflow

1. **Understand your goal**: Your prompt contains your specific task
2. **Do the work**: Use all available tools (Read, Edit, Write, Bash, etc.) to complete your task
3. **Signal completion**: When your work is done, output "I HAVE COMPLETED THE GOAL"

---

### All Commands

| Command | Description |
|---------|-------------|
| `ib new-agent "goal"` | Spawn a new agent, returns its ID |
| `ib list` | Show all agents and their status |
| `ib look <id>` | View an agent's recent output |
| `ib send <id> "msg"` | Send input to an agent |
| `ib status <id>` | Show agent's git commits and changes |
| `ib diff <id>` | Show full diff of agent's work vs main |
| `ib info <id>` | Show agent's meta.json configuration |
| `ib merge <id>` | Merge agent's work and permanently close it |
| `ib kill <id>` | Permanently close agent without merging |
| `ib resume <id>` | Restart a stopped agent's session |
| `ib watchdog <id>` | Monitor agent and notify manager (auto-spawned for child agents) |
| `ib ask "question"` | Ask user-level Claude a question (top-level managers only) |
| `ib questions` | List pending questions from agents |
| `ib acknowledge <id>` | Mark a question as handled (primary agent only, alias: `ack`) |

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

# Monitor in another terminal
ib watch                    # Interactive TUI showing all agent states

# Or check manually when needed
ib list                     # See state: running, waiting, complete, or stopped
ib look research            # View recent output

# If it's waiting with a question
ib send research "Focus on the top 3 competitors only"

# When complete, review and merge
ib diff research            # See what changed
ib merge research --force   # Merge branch into main and cleanup
```

Agents can spawn their own sub-agents for hierarchical task breakdown. Use `--worker` for worker agents that shouldn't spawn children.

## Eek! Too Many Agents!

If agents spawn out of control and you need to stop everything immediately:

```bash
ib nuke
```

This emergency command will:
- Kill **ALL** active agents without merging their work
- Show a warning with agent count and ask for confirmation
- Archive each agent's output for review
- Clean up all sessions, worktrees, branches, and directories

Use `ib nuke --force` to skip the confirmation prompt.

**Note:** This command is intentionally undocumented in `ib help` to prevent agents from casually using it, but it's available as a safety switch for humans.

## Configuration

**Spawn options:**
- `--name <name>` — Custom agent name (default: auto-generated ID)
- `--no-worktree` — Work in repo root instead of isolated worktree
- `--worker` — Worker agent that cannot spawn sub-agents
- `--manager <id>` — Track manager relationship for hierarchical coordination
- `--yolo` — Full autonomy, skip all permission prompts
- `--model <model>` — Use a specific model (opus, sonnet, haiku)
- `--print` — One-shot mode: run and exit, no interaction

**Permissions:** Agents inherit your `.claude/settings.local.json`. The `Bash(ib:*)` permission is automatically added so agents can coordinate sub-agents.

**Project config (`.ittybitty.json`):**
```json
{
  "maxAgents": 10,
  "createPullRequests": true,
  "allowAgentQuestions": true
}
```
- **`maxAgents`**: Maximum number of concurrent agents allowed (default: 10). This is a safety limit for the entire repository to prevent runaway agent spawning.
- **`createPullRequests`**: When enabled (and `gh` CLI is installed with a git remote configured), agents will create a pull request when their work is complete instead of leaving changes on their branch.
- **`allowAgentQuestions`**: Allow root managers to ask user questions via `ib ask` (default: true). Set to `false` to disable this feature.

**Environment:** Set `ITTYBITTY_DIR` to change the base directory (default: `.ittybitty`).

## Limitations

- **Merge conflicts**: If `ib merge` fails due to conflicts, the merging agent resolves them manually (edit files, `git add`, `git commit`)
- **Context limits**: Long-running agents may hit existing Claude context windows; break large tasks into smaller agents
