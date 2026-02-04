# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ittybitty (`ib`) is a minimal multi-agent orchestration tool for Claude Code. It uses tmux sessions and git worktrees to spawn and manage multiple Claude agents in parallel. The entire tool is a single bash script (`ib`, ~2500 lines).

## Documentation Guidelines

**Keep README.md up to date with user-facing features.**

- **README.md** is the user-facing reference — users only read this file
- **CLAUDE.md** contains internal/developer documentation for Claude agents working on this codebase

When adding new user-facing features:
1. Document them in README.md first (concise, practical examples)
2. Add detailed implementation notes to CLAUDE.md if needed for development

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

## Version

The version is defined at the top of the `ib` script in the `VERSION` variable: `VERSION="x.y.z"`

When bumping the version, update only this line.

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

## Bash Version Compatibility

**Target version: Bash 3.2** (the default on macOS)

The `ib` script must work with Bash 3.2, which ships with macOS. This means avoiding Bash 4.0+ features:

| Feature | Bash 4.0+ | Bash 3.2 Alternative |
|---------|-----------|---------------------|
| Lowercase | `${var,,}` | `shopt -s nocasematch` for matching, or `tr '[:upper:]' '[:lower:]'` |
| Uppercase | `${var^^}` | `tr '[:lower:]' '[:upper:]'` |
| Associative arrays | `declare -A` | Use indexed arrays with naming conventions |
| `readarray`/`mapfile` | `mapfile -t arr` | `while read` loop |
| `&>>` append redirect | `cmd &>> file` | `cmd >> file 2>&1` |
| `|&` pipe stderr | `cmd |& cmd2` | `cmd 2>&1 | cmd2` |
| Negative array indices | `${arr[-1]}` | `${arr[${#arr[@]}-1]}` |
| `coproc` | `coproc NAME { cmd; }` | Named pipes or temp files |

**Note**: `&>` (overwrite) works in Bash 3.2, only `&>>` (append) requires Bash 4.0+.

When adding new code, always test on the system bash (`/bin/bash --version`) to ensure compatibility.

## Performance Considerations

**`ib watch` redraws frequently** (10+ FPS), so performance matters in render code. Follow these guidelines for code in the rendering hot path:

### Avoid Subprocess Spawning

Spawning subprocesses (`sed`, `awk`, `grep`, `tail`, `head`, etc.) has significant overhead. Prefer pure bash operations:

| Avoid | Prefer |
|-------|--------|
| `echo "$line" \| sed 's/x/y/'` | `${line//x/y}` (parameter expansion) |
| `echo "$line" \| grep -o 'pattern'` | `[[ "$line" =~ pattern ]]` + `BASH_REMATCH` |
| `echo "$line" \| cut -d: -f1` | `${line%%:*}` (parameter expansion) |
| `cat "$file"` | `$(<"$file")` (bash builtin) |

### Complexity Guidelines

Use `[[ "$str" =~ pattern ]]` + `BASH_REMATCH` instead of character-by-character loops.

| Context | Target | Example |
|---------|--------|---------|
| Per-line processing | O(1) or O(patterns) | Colorizing log lines |
| Per-frame operations | O(agents) | Building agent tree |
| Background processes | Can be slower | Collecting denials |

### Caching Strategies

- **Background collectors**: Run expensive operations (file scanning, grep) in background processes that write to cache files
- **Parse caching**: Cache parsed results and only reparse when content length changes
- **Frame skipping**: Check expensive conditions every N frames instead of every frame

## Bash Script Behavior (`set -e`)

The `ib` script uses `set -e` (exit on error), which means **any command returning non-zero will terminate the entire script**.

### Common Pitfalls and Solutions

| Pattern | Problem | Solution |
|---------|---------|----------|
| `grep "pattern" file` | Returns 1 if no matches | `grep "pattern" file \|\| true` or use in `if` |
| `(( count++ ))` | Returns 1 when count was 0 | `(( count++ )) \|\| true` or `count=$((count + 1))` |
| `[[ "$var" == "x" ]]` | Returns 1 if false | Only use inside `if` statements |
| `local var=$(cmd)` | Exit status is from `local`, not `cmd` | Declare first: `local var; var=$(cmd)` |
| `read -t 0.1 key` | Returns 1 on timeout | `read -t 0.1 key \|\| true` |
| `[[ cond ]] && action` | Returns 1 if condition false | `[[ cond ]] && action \|\| true` |

**Key rule**: Any `[[ ... ]] && ...` pattern MUST have `|| true` appended unless inside an `if` block.

**Debugging**: Add `set -x` temporarily to see which command failed, or look for `&&` patterns without `|| true`.

## Configuration

Configuration is loaded from two files with the following precedence:

| File | Scope | Priority |
|------|-------|----------|
| `.ittybitty.json` | Project (repo root) | Highest - overrides user settings |
| `~/.ittybitty.json` | User (home directory) | Lower - provides defaults |

**Key behavior**: If a key exists in project config, it's used. Otherwise, if a key exists in user config, that's used. Built-in defaults apply only when a key is not set in either file.

### Available Settings

- `permissions.manager.allow/deny` - tools for manager agents
- `permissions.worker.allow/deny` - tools for worker agents
- `allowAgentQuestions` - allow root managers to ask user questions via `ib ask` (default: true)
- `autoCompactThreshold` - context usage % at which watchdog sends `/compact` (1-100, unset = auto)
- `externalDiffTool` - external diff tool command for `ib diff --external`
- `Bash(ib:*)` and `Bash(./ib:*)` are always added automatically

### Managing Config with `ib config`

```bash
ib config list                    # Show all config with sources
ib config get maxAgents           # Get a value
ib config set maxAgents 20        # Set project config
ib config --global set key val    # Set user config
```

## Custom Prompts

Add custom instructions to agents via markdown files in `.ittybitty/prompts/`:

| File | Applied To |
|------|------------|
| `all.md` | All agents |
| `manager.md` | Manager agents only |
| `worker.md` | Worker agents only |

## User Hooks

You can run custom scripts when agents are created by placing executable scripts in `.ittybitty/hooks/`:

| Hook | Trigger | Use Case |
|------|---------|----------|
| `post-create-agent` | After agent is created | Logging, notifications, custom setup |

The hook receives agent information via environment variables:

| Variable | Description |
|----------|-------------|
| `IB_AGENT_ID` | The agent's unique ID |
| `IB_AGENT_TYPE` | "manager" or "worker" |
| `IB_AGENT_DIR` | Path to agent's data directory |
| `IB_AGENT_BRANCH` | Git branch name (e.g., "agent/abc123") |
| `IB_AGENT_MANAGER` | Parent manager ID (empty for root managers) |
| `IB_AGENT_PROMPT` | The user task prompt |
| `IB_AGENT_MODEL` | Model being used (e.g., "sonnet") |

**Example `.ittybitty/hooks/post-create-agent`:**
```bash
#!/bin/bash
echo "[$(date -Iseconds)] Agent $IB_AGENT_ID created (type: $IB_AGENT_TYPE)" >> .ittybitty/creation.log
```

Make sure to make the hook executable: `chmod +x .ittybitty/hooks/post-create-agent`

Hook output is appended to the agent's `agent.log` file.

## Agent Hooks

Each spawned agent automatically gets Claude Code hooks configured in their `settings.local.json`:

| Hook | Purpose |
|------|---------|
| `Stop` | Calls `ib hooks agent-status <id>` when agent stops to update state tracking |
| `PreToolUse` | Calls `ib hooks agent-path <id>` to enforce path isolation |
| `PermissionRequest` | Logs denied tool requests to agent.log and auto-denies them |

### Main Repo Hooks

To prevent the main repo's Claude from `cd`-ing into agent worktrees:

```bash
ib hooks status      # Check if installed
ib hooks install     # Install PreToolUse hook
ib hooks uninstall   # Remove hook
```

The hook only blocks `cd` commands into `.ittybitty/agents/*/repo` paths. Read/Write/Edit and other tools still work.

In `ib watch`, press `h` to open the setup dialog for easy install/uninstall of hooks and other setup options.

### PermissionRequest Hook

When an agent tries to use a tool not in its `allow` list, the `PermissionRequest` hook:
1. Reads the tool name and input from JSON stdin (`tool_name` and `tool_input` fields)
2. Logs the denied request to `agent.log` via `ib log --quiet`, including full tool parameters
3. Returns the proper hook output format to auto-deny the tool

This provides visibility into what tools agents are attempting to use without showing permission dialogs. The log entry format includes the hook type for clear attribution:
```
[2026-01-10T15:05:06-06:00] [PermissionRequest] Permission denied: Bash (command: curl https://example.com/api/data, description: Execute curl request to fetch data)
```

Full tool parameters are logged to help debug which tools need to be allowed.

**Note**: Folder/location permission prompts (e.g., "allow access to /tmp/") bypass PermissionRequest hooks. These are contextual permissions shown when an allowed tool needs file system access, not tool denials.

### PreToolUse Hook Denials

The PreToolUse hook (`ib hooks agent-path`) enforces path isolation and also logs denials with its hook type:
```
[2026-01-10T15:05:06-06:00] [PreToolUse] Permission denied: Read (file_path: /etc/passwd)
[2026-01-10T15:05:06-06:00] [PreToolUse] Path violation: Read tried to access main repo: /path/to/main/repo/file.txt
```

To review denied permissions for an agent:
```bash
grep "Permission denied\|Path violation" .ittybitty/agents/<id>/agent.log
```

To filter by hook type:
```bash
grep "\[PermissionRequest\]" .ittybitty/agents/<id>/agent.log  # Tool not in allow list
grep "\[PreToolUse\]" .ittybitty/agents/<id>/agent.log         # Path isolation violations
```

## Logging System

Each agent has an `agent.log` at `.ittybitty/agents/<id>/agent.log` with timestamped events (creation, messages, denials, teardown).

```bash
log_agent "$ID" "message"           # logs and prints
log_agent "$ID" "message" --quiet   # logs only
ib log "debug info"                 # agents can self-log
```

When agents are killed/merged, logs are archived to `.ittybitty/archive/<timestamp>-<name>/` with `output.log`, `agent.log`, `meta.json`, and `settings.local.json`.

## Process and Session Management

### Tmux Session Naming

Session format: `ittybitty-<repo-id>-<agent-id>`. Each repo gets a unique ID in `.ittybitty/repo-id` to isolate agents across multiple repos.

### Process Hierarchy

```
tmux session (ittybitty-<repo-id>-<agent-id>)
  └── bash shell (pane_pid)
        └── claude process (claude_pid)
```

### Process Management

`kill_agent_process` finds Claude via tmux pane PID (preferred) or falls back to `claude_pid` in `meta.json`.

### Agent State Detection

The `get_state` function reads recent tmux output to determine state. See the Agent States table in the `<ittybitty>` block for state meanings.

**Detection priority order** (see `get_state` function for patterns):
1. Check if Claude hasn't started yet (creating) - no logo or [USER TASK] in output
2. Check last 5 lines for compacting state ("Compacting conversation") - agent is busy summarizing context
3. Check last 5 lines for active execution indicators (esc/ctrl+c to interrupt, ⎿ Running) - these mean something is running RIGHT NOW
4. Check last 15 lines for rate limiting ("rate_limit_error", "usage limit reached")
5. Check last 15 lines for completion ("I HAVE COMPLETED THE GOAL")
6. Check last 15 lines for waiting ("WAITING")
7. Check last 15 lines for other running indicators (ctrl+b ctrl+b, thinking)
8. Unknown if no indicators found

This order ensures that creating agents are properly identified, compacting is detected before generic running indicators (since both have "esc to interrupt"), and active execution indicators in the very recent output override completion phrases.

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

Claude may show a "trust files" permission screen in new worktrees. The `wait_for_claude_start` function detects whether logo or permissions screen appears first, then `auto_accept_workspace_trust` sends Enter only when needed and verifies the logo appears afterward. Key: never send Enter blindly—always detect the screen first.

## Testing

The `ib` script has a unit test suite in `tests/` for testing internal helper functions. These tests are fixture-driven and test pure logic functions in isolation.

### Running Tests

```bash
# Run all test suites
./tests/test-all.sh

# Run a specific test suite
./tests/test-parse-state.sh
./tests/test-format-age.sh
./tests/test-pretooluse.sh

# Test a single fixture directly
ib parse-state tests/fixtures/complete-simple.txt

# Verbose mode (shows which pattern matched)
ib parse-state -v tests/fixtures/complete-with-bullet.txt
```

### Test Structure

```
tests/
├── test-all.sh              # Master runner - executes all test-*.sh scripts
├── test-parse-state.sh      # Tests state detection logic
├── test-format-age.sh       # Tests age formatting (5s, 2h, 1d)
├── test-pretooluse.sh       # Tests path isolation hook logic
├── test-tool-allowed.sh     # Tests tool permission matching
├── test-tool-match.sh       # Tests tool pattern matching
├── test-load-config.sh      # Tests config file parsing
├── test-build-settings.sh   # Tests settings.json generation
├── test-resolve-id.sh       # Tests agent ID resolution
├── test-relationships.sh    # Tests manager/worker relationships
├── test-log-format.sh       # Tests log message formatting
└── fixtures/                # Test input files
    ├── complete-*.txt       # State detection: complete states
    ├── running-*.txt        # State detection: running states
    ├── waiting-*.txt        # State detection: waiting states
    ├── unknown-*.txt        # State detection: unknown states
    ├── format-age/          # Age formatting test cases
    ├── pretooluse/          # Path isolation test cases
    ├── load-config/         # Config parsing test cases
    └── ...
```

### Fixture Naming Convention

Test fixtures encode expected output in the filename:

```
{expected-output}-{description}.txt
{expected-output}-{description}.json
```

Examples:
- `complete-simple.txt` → expects `complete` state
- `running-bash.txt` → expects `running` state
- `allow-read-in-worktree.json` → expects `allow` decision
- `deny-cd-main-repo.json` → expects `deny` decision
- `1h-boundary-60-minutes.txt` → expects `1h` output

The test runner extracts the expected output from the filename prefix (before first hyphen), runs the test command with the fixture file, and compares.

### Test Commands in `ib`

The `ib` script exposes internal functions as `test-*` subcommands for testing:

| Command | Tests | Example |
|---------|-------|---------|
| `ib parse-state FILE` | `get_state` logic | `ib parse-state tests/fixtures/running-bash.txt` |
| `ib test-format-age FILE` | `format_age` function | `ib test-format-age tests/fixtures/format-age/5m-basic.txt` |
| `ib test-pretooluse FILE` | PreToolUse hook logic | `ib test-pretooluse tests/fixtures/pretooluse/allow-cd-in-worktree.json` |
| `ib test-tool-allowed FILE` | Tool permission matching | `ib test-tool-allowed tests/fixtures/tool-allowed/allowed-exact.json` |
| `ib test-tool-match FILE` | Tool pattern matching | `ib test-tool-match tests/fixtures/tool-match/match-wildcard.json` |
| `ib test-load-config FILE` | Config parsing | `ib test-load-config tests/fixtures/load-config/full-config.json` |
| `ib test-build-settings FILE` | Settings generation | `ib test-build-settings --validate tests/fixtures/build-settings/valid-manager.txt` |

### Writing Tests

1. Create fixture file with expected output in filename: `{expected}-{description}.txt`
2. Run `./tests/test-<feature>.sh` to verify
3. For new test suites, follow the existing `tests/test-*.sh` pattern

**Testability principle**: Extract pure helper functions that can read from files. Expose via `cmd_test_<feature>`. Avoid testing interactive UI, tmux operations, or process management directly.

**Note**: Use `ib` (not `./ib`) in worktrees to run the current PATH version.

## Agent Merge Review Checklist

Before merging agent work, check:
- **`set -e` safety**: All `[[ ... ]] && ...` must have `|| true` unless in `if` block
- **Bash 3.2**: No Bash 4.0+ features (see compatibility table above)
- **Tests**: New helpers need `cmd_test_*`, fixtures, and test script
- **No duplication**: Extract repeated code (3+ lines) into helpers
- **Performance**: No subprocess spawning in render hot paths
- **Security**: Proper variable quoting, no command injection

```bash
ib diff <agent-id>                                              # Review changes
git show agent/<id>:ib | grep -n '\[\[.*\]\] &&' | grep -v '|| true'  # Check set -e
```

## Prompt System Architecture

Understanding how prompts flow to different Claude instances is essential for developing ittybitty.

### Three Layers of Prompts

1. **CLAUDE.md (this file)** - Loaded by Claude Code for ALL sessions in this repo
   - Contains project documentation, coding guidelines, architecture info
   - Seen by: Primary Claude, manager agents, worker agents (all Claude instances in this repo)
   - This is standard Claude Code behavior, not ittybitty-specific

2. **The `<ittybitty>` block** - Installed into user repos via `ib watch` setup
   - Canonical source: `get_ittybitty_instructions()` function in the `ib` script
   - Installed to other repos when users run `ib watch` → press 'h' → enable 'ib instructions'
   - Our CLAUDE.md has it too because we use ib to develop ib
   - Seen by: ALL Claude instances (primary, managers, workers) in repos where it's installed
   - Purpose: Teaches Claude how to use `ib` commands and understand agent roles

3. **Custom agent prompts** - Generated by `build_agent_prompt()` for spawned agents
   - Injected IN ADDITION TO CLAUDE.md content when agents start
   - Only seen by the specific agent it's generated for
   - Contains role-specific instructions, constraints, and context

### The `<ittybitty>` Block

The `<ittybitty>` block is what makes Claude aware of ittybitty in any repo:

```
┌─────────────────────────────────────────────────────────────┐
│ get_ittybitty_instructions() in ib script                   │  ← Canonical source
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│ User's repo CLAUDE.md   │     │ ittybitty's CLAUDE.md   │
│ (installed via ib watch)│     │ (we use ib to develop)  │
└─────────────────────────┘     └─────────────────────────┘
```

When updating the `<ittybitty>` block:
1. Edit `get_ittybitty_instructions()` in the `ib` script
2. Users get updates when they reinstall via `ib watch` setup
3. Update our own CLAUDE.md to match (or reinstall it ourselves)

### Custom Agent Prompts (`build_agent_prompt()`)

When `ib new-agent` spawns an agent, it generates a custom prompt with these components:

| Component | Description |
|-----------|-------------|
| `ROLE_MARKER` | `<ittybitty>You are an IttyBitty manager/worker agent.</ittybitty>` - identifies agent type |
| `WORKTREE_INFO` | Branch name (`agent/$ID`) and parent branch it forked from |
| `PATH_ISOLATION` | What paths the agent can/cannot access (worktree, ~/.claude, /tmp vs main repo) |
| `GIT_WORKTREE_CONTEXT` | How worktrees work: local branches, no need for `git fetch`, shared commits |
| `MANAGER_INFO` | Who the agent's manager is (if any) |
| `IB_INSTRUCTIONS` | Role-specific guidance - managers get spawning/merging instructions, workers get communication guidance |
| `COMPLETION_INSTRUCTIONS` | How to signal states: "I HAVE COMPLETED THE GOAL" or "WAITING" |

The prompt is assembled and saved to `$AGENT_DIR/prompt.txt` for debugging.

**Manager-specific content** (in `IB_INSTRUCTIONS`):
- Task sizing strategy (small/medium/large)
- How to spawn and manage sub-agents
- Watchdog notification behavior
- Merge conflict resolution guidelines
- How to ask user questions (`ib ask` for top-level managers)

**Worker-specific content** (in `IB_INSTRUCTIONS`):
- Communication with manager (`ib send`)
- Self-inspection commands (`ib diff`, `ib status`)
- How to report being stuck

### Permissions Configuration

Permissions flow through several layers:

```
┌─────────────────────────────────────────┐
│ .ittybitty.json                         │  ← User configures (optional)
│ permissions.manager.allow/deny          │
│ permissions.worker.allow/deny           │
└─────────────────────────────────────────┘
                    │
                    ▼ build_agent_settings()
┌─────────────────────────────────────────┐
│ Mandatory permissions (always added)    │  ← ib adds automatically
│ + User permissions from .ittybitty.json │
│ = Final merged permissions              │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│ $AGENT_DIR/settings.local.json          │  ← Claude Code reads
│ - permissions.allow/deny                │
│ - hooks (see "Agent Hooks" section)     │
└─────────────────────────────────────────┘
```

Hooks enforce permissions at runtime. See the **"Agent Hooks"** section for details on PreToolUse (path isolation) and PermissionRequest (tool allow/deny) hooks.

**User-configurable permissions** (`.ittybitty.json`):
```json
{
  "permissions": {
    "manager": { "allow": [...], "deny": [...] },
    "worker": { "allow": [...], "deny": [...] }
  }
}
```

**Mandatory permissions** (always added by `build_agent_settings()`):

| Category | Always Allowed |
|----------|---------------|
| **ib commands** | `Bash(ib:*)`, `Bash(./ib:*)` |
| **Git operations** | `Bash(git status:*)`, `Bash(git add:*)`, `Bash(git commit:*)`, `Bash(git diff:*)`, `Bash(git show:*)`, `Bash(git log:*)`, `Bash(git ls-files:*)`, `Bash(git grep:*)`, `Bash(git rm:*)`, `Bash(git merge:*)`, `Bash(git rebase:*)` |
| **Basic shell** | `Bash(pwd:*)`, `Bash(ls:*)`, `Bash(head:*)`, `Bash(tail:*)`, `Bash(cat:*)`, `Bash(grep:*)` |
| **File tools** | `Read`, `Write`, `Edit`, `MultiEdit`, `Glob`, `Grep`, `LS` |
| **Other tools** | `TodoWrite`, `Task`, `TaskOutput`, `KillShell`, `NotebookEdit`, `WebFetch`, `WebSearch`, `AskUserQuestion` |

| Category | Always Denied |
|----------|--------------|
| **Plan mode** | `EnterPlanMode`, `ExitPlanMode` (agents should work directly, not enter planning mode) |

**Why file tools are allowed by default:** Path isolation is enforced at runtime by the PreToolUse hook (see **"Agent Hooks"** section). Agents can only access files in their own worktree.

Key files:
- `.ittybitty.json` - User-editable config in repo root (optional)
- `$AGENT_DIR/settings.local.json` - Generated per-agent, merges mandatory + user permissions
- `$AGENT_DIR/agent.log` - Contains hook denial logs (see **"Agent Hooks"** for log format)

<!-- INSTALLED ITTYBITTY BLOCK: This is the installed copy of the <ittybitty> section.
     The canonical source is in the ib script: get_ittybitty_instructions() function.
     To update: modify get_ittybitty_instructions() in ib, then reinstall via 'ib watch' setup dialog.
     New users installing ib will get the latest version from the ib script. -->

<ittybitty>
## Multi-Agent Orchestration (ittybitty)

`ib` spawns persistent Claude agents in isolated git worktrees. Check your role marker at conversation start.

### Primary Claude

Spawn agents for complex/parallel tasks. Status updates appear automatically via hooks. User can also run `ib watch` for live monitoring.
Always spawn **manager** agents (not `--worker`). Managers assess the task and spawn their own workers if needed.

**Agents start automatically** - each agent has a watchdog that handles initialization, permission prompts, and monitors for issues (rate limits, context compaction). Never send input to "help" an agent start. Just spawn with `ib new-agent` and monitor with `ib look` or `ib list`.

| Command | Description |
|---------|-------------|
| `ib new-agent "goal"` | Spawn agent (returns ID) |
| `ib list` | Show all agents |
| `ib look <id>` | View agent output |
| `ib send <id> "msg"` | Send input to agent |
| `ib status <id>` | Show commits/changes |
| `ib diff <id>` | Review agent's changes |
| `ib merge <id> --force` | Merge and close agent (`--force` skips confirmation) |
| `ib kill <id> --force` | Close without merging (`--force` skips confirmation) |
| `ib resume <id>` | Restart stopped agent |
| `ib questions` | Check agent questions |
| `ib acknowledge <qid>` | Mark question handled |

**Agent questions:** Agents ask via `ib ask`. Check `ib questions` periodically.

### Agent States

| State | Meaning |
|-------|---------|
| `creating` | Starting up |
| `running` | Actively working |
| `compacting` | Summarizing context |
| `waiting` | Idle, may need input |
| `complete` | Signaled done |
| `rate_limited` | Hit API rate limits |
| `stopped` | Session ended |
| `unknown` | State unclear |

</ittybitty>
