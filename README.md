# ittybitty (ib)

A minimal multi-agent orchestration tool for Claude Code.

## Motivation

Running multiple Claude Code agents in parallel is useful for:
- Breaking large tasks into parallel subtasks
- Long-running research that doesn't need constant supervision
- Isolating experimental work in separate git worktrees

Most multi-agent frameworks are over-engineered. This tool takes a different approach: **just use tmux**.

Claude already knows how to:
- Ask questions and wait for input
- Continue when it gets an answer
- Work autonomously on bounded tasks

We don't need elaborate protocols or message queues. We just need:
1. A way to spawn agents in background tmux sessions
2. A way to see what they're doing
3. A way to send them input
4. A way to read their output

That's it. Four primitives. Everything else is composition.

## Installation

```bash
# Clone the repo
git clone <repo-url> /path/to/ittybitty

# Add to PATH (add to ~/.zshrc or ~/.bashrc)
export PATH="/path/to/ittybitty:$PATH"

# Or symlink to a directory already in PATH
ln -s /path/to/ittybitty/ib /usr/local/bin/ib
```

**Requirements:**
- tmux
- jq (for JSON handling)
- git (for worktree support)

### Adding ib to Your Project

To make Claude aware of `ib` in your project, add this to your project's `CLAUDE.md`:

```markdown
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
2. **Monitor**: `ib list` — see all agents and their status (running/waiting/done)
3. **Watch**: `ib watch <id>` — view an agent's recent Claude history
4. **Close**: When done, summarize the agent's work and ask the user:
   - `ib merge <id>` — merge the agent's work into main and close
   - `ib kill <id>` — close without merging

### Key Differences from Task Tool

| Task Tool | ib Agents |
|-----------|-----------|
| Blocks until complete | Runs in background |
| Shares your context | Isolated conversation |
| No git isolation | Own branch + worktree |
| Cannot spawn children | Can manage sub-agents |
</ittybitty>
```

## Architecture

```
You (human)
  ↕ conversation
Primary Agent (responsive, strategic)
  ↓ uses ib to spawn
Task Agent (planner, runs in tmux)
  ↕ can ask questions (waits for stdin)
  ↓ uses ib to spawn
Worker Agents (do specific tasks)
```

**Key insight**: Agents communicate via tmux's stdin/stdout. No files, no protocols—just text.

- Parent reads child's output: `ib watch <child-id>`
- Parent sends answer: `ib send <child-id> "the answer"`
- Child receives it as normal stdin, continues working

## How ib Agents Differ from Claude Subagents

Claude Code's built-in Task tool spawns **ephemeral subagents**—they run, return a result, and disappear. They share context with the parent and block until complete.

ib agents are different:

| | Task Tool Subagents | ib Agents |
|---|---|---|
| **Lifetime** | Ephemeral (single task) | Long-running (persistent tmux session) |
| **Context** | Shared with parent | Isolated (own conversation, own git branch) |
| **Blocking** | Parent waits for result | Parent continues working |
| **Communication** | Automatic return value | Manual via `ib watch`/`ib send` |
| **Git isolation** | None | Own worktree and branch |
| **Can spawn children** | No | Yes (hierarchical teams) |

ib agents are **stable Claude Code instances** that can spawn, coordinate, and manage their own agent teams to accomplish complex tasks.

## Communication Model

**Important**: Communication is poll-based, not push-based.

When you spawn an agent from your primary Claude session, that agent **cannot interrupt you**. Your primary session is actively being used, so the agent's messages don't automatically appear. Instead:

1. **You must check on agents**: Use `ib list` to see all agents and `ib watch <id>` to see their output
2. **You must answer questions**: Use `ib send <id> "answer"` to respond when they're waiting
3. **Agents wait for input**: If an agent asks a question, it blocks until answered

```bash
# Spawn agents
ib new-agent --name task1 "research competitor pricing"
ib new-agent --name task2 "audit documentation links"

# Check on them periodically
ib list                    # Shows all agents with STATE and PARENT columns
ib watch task1 --lines 20   # See recent output
ib watch task2 --lines 20
```

The `ib list` output shows a PARENT column—agents spawned by the top-level Claude show `-`, while sub-agents spawned by other ib agents show their parent's ID.

## Agent Lifecycle

Here's the typical flow for managing a task with ib:

### 1. Spawn the agent

```bash
ib new-agent --name research "Research competitor pricing and summarize findings"
```

The agent starts in a tmux session with its own git worktree on branch `agent/research`.

### 2. Monitor progress

```bash
# Check if it's running or waiting
ib list

# Read recent output
ib watch research

# Watch live (Ctrl+b d to detach)
ib watch research --follow
```

### 3. Answer questions

If the agent is waiting for input:

```bash
ib send research "Focus on the top 3 competitors only"
```

### 4. Review work

```bash
# See what commits the agent made
ib status research

# View the full diff
ib diff research
```

### 5. Merge and cleanup

```bash
# Merge agent's branch into main and remove worktree
ib merge research```

Or if you want to discard the work:

```bash
ib kill research --cleanup --force
```

## Usage

**Important:** Must be run from the root of a git repository.

### Spawn an agent

```bash
# Basic spawn (creates worktree on branch agent/<id>)
ib new-agent "verify all citations in docs/comparison.md"

# With custom name (branch will be agent/citation-checker)
ib new-agent --name citation-checker "verify citations"

# Without git worktree (work directly in repo root)
ib new-agent --no-worktree "quick analysis"

# Limit tools available to the agent
ib new-agent --deny-tools Bash,Write "research only, no changes"

# One-shot mode (runs and exits, no interaction)
ib new --print "list all TODO comments in src/"

# Full autonomy - skip all permission prompts
ib new-agent --yolo "research and update the pricing page"

# Track parent relationship
ib new-agent --parent task-abc "subtask for task-abc"

# Leaf/worker agent (no sub-agent spawning capability)
ib new-agent --leaf --parent coordinator "check link #1"
```

### List agents

```bash
# Show running agents
ib list

# Include finished agents
ib list --all

# Filter by parent
ib list --parent task-abc

# JSON output (for scripting)
ib list --json
```

Output:
```
ID                   STATE      AGE    PARENT          PROMPT
task-a1b2c3d4        running    12m    -               verify all citations in docs/compa
worker-x1y2z3a4      waiting    3m     task-a1b2c3d4   check citation #3: https://exampl
```

### Watch agent output

```bash
# Recent output (last 50 lines)
ib watch task-abc

# More history
ib watch task-abc --lines 200

# Full scrollback
ib watch task-abc --all

# Watch live (attaches to tmux session, Ctrl+b d to detach)
ib watch task-abc --follow
```

### Send input to an agent

```bash
# Send a message
ib send task-abc "Option 2 - just verify links, skip quote accuracy"

# Pipe from file
ib send task-abc < answer.txt

# Pipe from command
echo "yes" | ib send task-abc

# Explicitly specify sender (adds "[sent by agent worker-1]: " prefix)
ib send --from worker-1 coordinator "I finished checking link #3"
```

**Auto-prefixing**: When `ib send` is run from within an agent's worktree, messages are automatically prefixed with `[sent by agent <agent-id>]:` so recipients know who sent it.

### Check agent's git work

```bash
# Show commits and changes summary
ib status task-abc

# Output:
# Agent: agent-abc123
# Branch: agent/agent-abc123
# Worktree: .ittybitty/agents/agent-abc123/repo
#
# ═══ Commits (2) vs main ═══
#   ef2f424 Add summary document
#   abc1234 Fix typo in README
#
# ═══ Files Changed ═══
#   2 files changed, 100 insertions(+), 5 deletions(-)
```

### Show full diff

```bash
# Full diff of agent's work vs main
ib diff task-abc

# Just the diffstat
ib diff task-abc --stat
```

### Merge agent work

```bash
# Merge agent's branch into main
ib merge task-abc

# Merge and cleanup worktree/data
ib merge task-abc
# Merge into a specific branch
ib merge task-abc --into develop

# Skip confirmation
ib merge task-abc --cleanup --force
```

The merge command:
1. Checks for uncommitted changes (fails if any)
2. Shows commits that will be merged
3. Merges the agent's branch into the target
4. Optionally cleans up worktree and branch

### Kill an agent

```bash
# Stop the agent (keeps data)
ib kill task-abc

# Stop and cleanup worktree/data
ib kill task-abc
# Skip confirmation
ib kill task-abc --cleanup --force
```

## Agent Context

When an agent starts, it receives a context prefix with its prompt that includes:
- Its own agent ID
- Parent agent ID (if any)
- Git worktree/branch information
- Instructions for `ib` commands (unless `--leaf` mode)
- Instructions for committing and exiting

This context helps agents understand their role and how to manage sub-agents.

Example prompt (stored in `.ittybitty/agents/<id>/prompt.txt`):
```
[AGENT CONTEXT]
You are running as agent task-abc123 in a git worktree on branch agent/task-abc123.
Your parent agent is: coordinator

You have access to the 'ib' tool for multi-agent coordination:
  ib new-agent --parent task-abc123 "task"   Spawn a sub-agent
  ib list --parent task-abc123               List your sub-agents
  ...

When your task is complete:
1. Commit any changes you made (git add && git commit)
2. Exit normally - the orchestrator will handle merging your branch

[USER TASK]
Your actual task prompt here...
```

## How Communication Works

Agents don't need special protocols. They just ask questions naturally:

**Task Agent (in tmux):**
```
I found 15 citations in the document. Should I:
1. Just verify links resolve
2. Also verify sources support the claims
3. Full audit including quote accuracy

Which level?
_
```

**Primary Agent checks on it:**
```bash
$ ib watch task-abc | tail -10
# Sees the question

$ ib send task-abc "Option 2"
# Task agent receives this as stdin, continues
```

### Detecting "waiting for input"

The `ib list` command shows agents as "waiting" if their recent output ends with a question mark. This is a heuristic—you can also just check periodically with `ib watch`.

## Git Worktrees

By default, each agent gets its own git worktree with an isolated branch:

```
.ittybitty/agents/
  agent-a1b2c3d4/
    meta.json       # Agent metadata (id, prompt, parent, created, worktree, leaf)
    prompt.txt      # Full prompt with context prefix
    start.sh        # Startup script for tmux session
    exit-check.sh   # Exit handler for uncommitted changes
    repo/           # Git worktree (branch: agent/agent-a1b2c3d4)
    output.log      # Captured output (after agent finishes)
```

**Benefits:**
- Agents can't step on each other's changes
- Each agent works on its own `agent/<id>` branch
- Easy to review/merge work from each agent
- Clean rollback if an agent makes bad changes

**Merging agent work:**
```bash
# Recommended: use ib merge
ib merge agent-a1b2c3d4
# Or manually
git checkout main
git merge agent/agent-a1b2c3d4

# Cleanup (removes worktree and branch)
ib kill agent-a1b2c3d4```

### Exit Handler

When an agent's Claude session ends, an exit handler automatically runs that:
1. Checks for uncommitted changes and prompts to commit
2. Checks for unpushed commits (if remote exists) and prompts to push
3. Displays the branch name and merge instructions

This ensures work isn't lost when agents complete their tasks.

## Example: Citation Verification

```bash
# You're talking to your primary Claude instance
> Please verify all citations in vs-freeform.md

# Primary spawns a task agent
$ id=$(ib new-agent "Verify all citations in docs/vs-freeform.md are valid.
For each citation: check link resolves, verify it's a primary source,
confirm it supports the claim. Report issues found.")

# Primary responds to you immediately
"I've handed that off to a research agent ($id). I'll check on it
periodically. What else would you like to discuss?"

# Later, primary checks status
$ ib list
task-a1b2c3d4  running  5m  -  Verify all citations...

$ ib watch task-a1b2c3d4 | tail -20
# Sees progress or questions

# If agent has a question
$ ib send task-a1b2c3d4 "Focus on the Apple and Concepts citations first"
```

## Example: Parallel Research

```bash
# Spawn multiple research agents
ib new-agent --name research-apple "Research Apple Freeform: features, pricing, recent updates"
ib new-agent --name research-miro "Research Miro: features, pricing, recent updates"
ib new-agent --name research-figma "Research FigJam: features, pricing, recent updates"

# Monitor all
ib list

# Collect results when done
ib watch research-apple --all > apple-research.md
ib watch research-miro --all > miro-research.md
ib watch research-figma --all > figma-research.md

# Cleanup
ib kill research-apple --cleanup --force
ib kill research-miro --cleanup --force
ib kill research-figma --cleanup --force
```

## Hierarchical Agents

Task agents can spawn their own workers:

```bash
# Task agent (spawned by primary) might do:
$ ib new-agent --parent $MY_ID "Check citation 1: https://..."
$ ib new-agent --parent $MY_ID "Check citation 2: https://..."
$ ib new-agent --parent $MY_ID "Check citation 3: https://..."

# Then monitor them
$ ib list --parent $MY_ID
```

The `--parent` flag is just metadata for tracking—it doesn't create any special behavior.

## Permissions

By default, agents inherit your permission settings:
- `.claude/settings.local.json` is copied to each worktree
- `Bash(ib:*)` is automatically added so agents can coordinate sub-agents
- Agents get the same approved tools as your main session
- Non-allowed tools are auto-rejected (no prompts blocking automation)

### Permission Modes

**Default mode** - auto-rejects non-allowed tools, auto-accepts workspace trust:
```bash
ib new-agent "do the task"
```

**Yolo mode** - auto-accepts everything (full autonomy):
```bash
ib new-agent --yolo "do whatever it takes"
```

Use `--yolo` only when you need full autonomy (with caution).

### Agent Types

**Regular agents** (default) can spawn and manage sub-agents:
- `Bash(ib:*)` permissions are added to settings
- Prompt includes instructions for `ib` commands
- Can create hierarchical task breakdowns

**Leaf/worker agents** (`--leaf` or `--worker`) are focused workers:
- No `ib` permissions added - cannot spawn sub-agents
- Prompt excludes sub-agent management instructions
- Ideal for parallel tasks that don't need coordination

```bash
# Regular agent that coordinates workers
ib new-agent --name coordinator "break this into subtasks and delegate"

# Leaf agents for actual work
ib new-agent --leaf --parent coordinator "check citation 1"
ib new-agent --leaf --parent coordinator "check citation 2"
```

## Limitations

**No automatic coordination**: Agents don't know about each other unless you tell them.

**Manual merge resolution**: If multiple agents modify the same files, you handle conflicts.

**Crude "done" detection**: We check if the tmux session is still running. For `--print` mode agents, "done" means the session ended.

**Context limits**: Long-running agents will hit context windows. For very long tasks, consider breaking into smaller sequential agents.

**No retry/recovery**: If an agent crashes or gets stuck, you kill it and start over.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ITTYBITTY_DIR` | `.ittybitty` | Base directory (contains `agents/` and `archive/`) |

## Tips

1. **Name your agents** - Use `--name` for agents you'll reference repeatedly
2. **Use --print for one-shots** - Simple queries don't need interactive sessions
3. **Check often early** - New agents might have questions in the first few minutes
4. **Limit tools for safety** - Use `--deny-tools` for agents that shouldn't make changes
5. **Review archived output** - Agent output is saved to `.ittybitty/archive/` when closed

## Philosophy

This tool exists because multi-agent orchestration doesn't need to be complicated.

Claude is already good at:
- Breaking down tasks
- Asking for clarification
- Working autonomously

tmux is already good at:
- Managing multiple sessions
- Capturing output
- Routing input

We just connect them with a single bash script (~1300 lines, mostly argument parsing and help text).
