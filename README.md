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

- Parent reads child's output: `ib read <child-id>`
- Parent sends answer: `ib send <child-id> "the answer"`
- Child receives it as normal stdin, continues working

## Installation

```bash
# Clone the repo
git clone <repo-url> ~/Developer/bash/ittybitty

# Add to PATH (add to ~/.zshrc or ~/.bashrc)
export PATH="$HOME/Developer/bash/ittybitty:$PATH"

# Or symlink to a directory already in PATH
ln -s ~/Developer/bash/ittybitty/ib /usr/local/bin/ib
```

**Requirements:**
- tmux
- jq (for JSON handling)
- git (for worktree support)

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

### Read agent output

```bash
# Recent output (last 50 lines)
ib read task-abc

# More history
ib read task-abc --lines 200

# Full scrollback
ib read task-abc --all

# Watch live (attaches to tmux session, Ctrl+b d to detach)
ib read task-abc --follow
```

### Send input to an agent

```bash
# Send a message
ib send task-abc "Option 2 - just verify links, skip quote accuracy"

# Pipe from file
ib send task-abc < answer.txt

# Pipe from command
echo "yes" | ib send task-abc
```

### Kill an agent

```bash
# Stop the agent (keeps data)
ib kill task-abc

# Stop and cleanup worktree/data
ib kill task-abc --cleanup

# Skip confirmation
ib kill task-abc --cleanup --force
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
$ ib read task-abc | tail -10
# Sees the question

$ ib send task-abc "Option 2"
# Task agent receives this as stdin, continues
```

### Detecting "waiting for input"

The `ib list` command shows agents as "waiting" if their recent output ends with a question mark. This is a heuristic—you can also just check periodically with `ib read`.

## Git Worktrees

By default, each agent gets its own git worktree with an isolated branch:

```
.agents/
  agent-a1b2c3d4/
    meta.json       # Agent metadata
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
# After agent finishes
git checkout main
git merge agent/agent-a1b2c3d4

# Or cherry-pick specific commits
git cherry-pick <commit>

# Cleanup (removes worktree and branch)
ib kill agent-a1b2c3d4 --cleanup
```

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

$ ib read task-a1b2c3d4 | tail -20
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
ib read research-apple --all > apple-research.md
ib read research-miro --all > miro-research.md
ib read research-figma --all > figma-research.md

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
- Agents get the same approved tools as your main session

For fully autonomous agents that shouldn't be blocked by permission prompts:
```bash
ib new-agent --yolo "do whatever it takes"
```

This adds `--dangerously-skip-permissions` to the claude command. Use with caution.

## Limitations

**No automatic coordination**: Agents don't know about each other unless you tell them.

**Manual merge resolution**: If multiple agents modify the same files, you handle conflicts.

**Crude "done" detection**: We check if the tmux session is still running. For `--print` mode agents, "done" means the session ended.

**Context limits**: Long-running agents will hit context windows. For very long tasks, consider breaking into smaller sequential agents.

**No retry/recovery**: If an agent crashes or gets stuck, you kill it and start over.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTS_DIR` | `.agents` | Where agent data is stored |

## Tips

1. **Name your agents** - Use `--name` for agents you'll reference repeatedly
2. **Use --print for one-shots** - Simple queries don't need interactive sessions
3. **Check often early** - New agents might have questions in the first few minutes
4. **Limit tools for safety** - Use `--deny-tools` for agents that shouldn't make changes
5. **Clean up finished agents** - Use `ib kill --cleanup` to remove worktrees

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

We just connect them with a single bash script (~600 lines, mostly argument parsing and help text).
