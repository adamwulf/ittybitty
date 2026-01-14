# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ittybitty (`ib`) is a minimal multi-agent orchestration tool for Claude Code. It uses tmux sessions and git worktrees to spawn and manage multiple Claude agents in parallel. The entire tool is a single bash script (`ib`, ~2000 lines).

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
| `&>` redirection | `cmd &> file` | `cmd > file 2>&1` |
| `|&` pipe stderr | `cmd |& cmd2` | `cmd 2>&1 | cmd2` |
| Negative array indices | `${arr[-1]}` | `${arr[${#arr[@]}-1]}` |
| `coproc` | `coproc NAME { cmd; }` | Named pipes or temp files |

When adding new code, always test on the system bash (`/bin/bash --version`) to ensure compatibility.

## Bash Script Behavior (`set -e`)

The `ib` script uses `set -e` (exit on error), which means **any command returning non-zero will terminate the entire script**. This is a common source of subtle bugs.

### Common Pitfalls

| Command | Problem | Solution |
|---------|---------|----------|
| `grep "pattern" file` | Returns 1 if no matches | `grep "pattern" file \|\| true` or use in conditional |
| `(( count++ ))` | Returns 1 when count was 0 | `(( count++ )) \|\| true` or `count=$((count + 1))` |
| `[[ "$var" == "x" ]]` | Returns 1 if false | Only use in `if` statements, not standalone |
| `local var=$(cmd)` | Exit status is from `local`, not `cmd` | Declare first: `local var; var=$(cmd)` |
| `read -t 0.1 key` | Returns 1 on timeout | `read -t 0.1 key \|\| true` |

### Safe Patterns

```bash
# BAD: grep failure exits script
matches=$(grep "pattern" file)

# GOOD: handle no-match case
matches=$(grep "pattern" file || true)

# GOOD: use in conditional
if grep -q "pattern" file; then
    # found
fi

# BAD: arithmetic can fail
(( index++ ))

# GOOD: safe increment
(( index++ )) || true
# or
index=$((index + 1))

# BAD: standalone test
[[ -n "$var" ]]

# GOOD: test in conditional
if [[ -n "$var" ]]; then
    # var is set
fi
```

### Debugging `set -e` Issues

If the script exits unexpectedly:
1. Add `set -x` temporarily to see which command failed
2. Look for commands that might return non-zero in success cases
3. Check recent changes to interactive input handling (read, grep in loops)

## Configuration

`.ittybitty.json` configures permissions and behavior for spawned agents:
- `permissions.manager.allow/deny` - tools for manager agents
- `permissions.worker.allow/deny` - tools for worker agents
- `allowAgentQuestions` - allow root managers to ask user questions via `ib ask` (default: true)
- `Bash(ib:*)` and `Bash(./ib:*)` are always added automatically

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

Each agent has an `agent.log` file at `.ittybitty/agents/<id>/agent.log` that captures timestamped events.

### How Logging Works

The `log_agent` helper function (ib:62) both writes to the log file AND echoes to stdout:
```bash
log_agent "$ID" "message"           # logs and prints
log_agent "$ID" "message" --quiet   # logs only, no stdout
```

### What Gets Logged

| Event | Command | Logged Message |
|-------|---------|----------------|
| Agent creation | `new-agent` | "Agent created (manager: X, prompt: Y)" |
| Message received | `send` | "Received message from X: Y" (recipient's log) |
| Message sent | `send` | "Sent message to X: Y" (sender's log) |
| Tool denied (not in allow list) | PermissionRequest hook | "[PermissionRequest] Permission denied: TOOL_NAME" |
| Tool denied (path isolation) | PreToolUse hook | "[PreToolUse] Permission denied: TOOL_NAME" |
| Path violation | PreToolUse hook | "[PreToolUse] Path violation: TOOL_NAME tried to access..." |
| Kill initiated | `kill` | "Agent killed" |
| Process terminated | `kill/merge` | "Terminated Claude process" |
| Session killed | `kill/merge` | "Killed tmux session" |
| Branch deleted | `kill/merge` | "Deleted branch agent/X" |
| Merge completed | `merge` | "Agent merged into BRANCH (N commits)" |
| Agent resumed | `resume` | "Agent resumed" |

### Archive Structure

When agents are killed/merged/nuked, logs are archived to `.ittybitty/archive/`:
```
.ittybitty/archive/
  20260110-011339-agent-name/
    output.log           # Full tmux scrollback
    agent.log            # Timestamped event log
    meta.json            # Agent config (prompt, model, session_id, manager, etc.)
    settings.local.json  # Permissions and hooks configuration
```

The teardown order ensures complete logs:
1. Log all teardown events (kill, session stop, branch delete)
2. Archive (captures complete log)
3. Remove agent directory

### Using `ib log` for Debugging

Agents can write to their own log during execution:
```bash
ib log "Starting task analysis"
ib log "Found 5 files to process"
ib log --quiet "Silent debug info"  # no stdout
```

### Debugging with tmux Output

For deep debugging, you can capture tmux output to the agent log:
```bash
# Capture current visible pane
tmux capture-pane -t "$SESSION" -p >> "$AGENT_DIR/agent.log"

# Capture full scrollback history
tmux capture-pane -t "$SESSION" -p -S - >> "$AGENT_DIR/agent.log"
```

## Process and Session Management

### Tmux Session Naming and Multi-Repo Isolation

Each repository gets a unique repo ID stored in `.ittybitty/repo-id` (auto-generated on first use). This ID is included in tmux session names to prevent collisions when running `ib` in multiple repositories simultaneously.

**Session naming format:** `ittybitty-<repo-id>-<agent-id>`

Example: `ittybitty-a1b2c3d4-agent-e5f6g7h8`

This ensures:
- Each repo's agents are isolated in the tmux namespace
- Orphan detection only targets sessions belonging to the same repo
- Worktree agents automatically use the main repo's ID (via `get_root_repo()`)

The repo ID is gitignored (inside `.ittybitty/`) so each clone gets its own unique ID.

**Migration note**: Agents created before this change used the format `ittybitty-<agent-id>`. After upgrading, these old sessions will appear as orphaned tmux sessions (not recognized by `ib list`). Clean them up manually with `tmux kill-session -t <session-name>` or `tmux kill-server` if no other tmux sessions are in use.

### Process Hierarchy

```
tmux session (ittybitty-<repo-id>-<agent-id>)
  └── bash shell (pane_pid)
        └── claude process (claude_pid)
```

### Finding Process IDs

The `kill_agent_process` function uses two strategies:

1. **Dynamic lookup (preferred)**: Find Claude via tmux pane PID
   ```bash
   PANE_PID=$(tmux list-panes -t "$SESSION" -F '#{pane_pid}')
   CLAUDE_PID=$(pgrep -P "$PANE_PID" -f "claude")
   ```

2. **Fallback**: Read from `meta.json` (set at startup via start.sh)
   ```bash
   PID=$(jq -r '.claude_pid' "$AGENT_DIR/meta.json")
   ```

### Agent State Detection

The `get_state` function (ib:867) reads recent tmux output to determine state:

| State | Detection Method |
|-------|------------------|
| `stopped` | tmux session doesn't exist |
| `creating` | Session exists but Claude hasn't started yet (no logo, may show permissions screen) |
| `running` | Last 5 lines contain active indicators ("esc to interrupt", "⎿  Running") OR last 15 lines contain "ctrl+b ctrl+b", "thinking)" |
| `complete` | Last 15 lines contain "I HAVE COMPLETED THE GOAL" |
| `waiting` | Last 15 lines contain standalone "WAITING" |
| `unknown` | Session exists but no clear indicators |

**Priority order**:
1. Check if Claude hasn't started yet (creating) - no logo or [USER TASK] in output
2. Check last 5 lines for active execution indicators (esc/ctrl+c to interrupt, ⎿ Running) - these mean something is running RIGHT NOW
3. Check last 15 lines for completion ("I HAVE COMPLETED THE GOAL")
4. Check last 15 lines for waiting ("WAITING")
5. Check last 15 lines for other running indicators (ctrl+b ctrl+b, thinking)
6. Unknown if no indicators found

This order ensures that creating agents are properly identified, active execution indicators in the very recent output override completion phrases, while completion phrases take priority over running indicators that may appear in descriptive text or historical output.

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

### The Permission Screen Problem

When Claude starts in a new worktree, it may show a "Do you trust the files in this folder?" permission screen. If we send Enter too early or when not needed, it can:
- Trigger tab-completion if Claude has already started
- Send an unintended command to Claude's input

### Detection Strategy

The `wait_for_claude_start` function (ib:471) waits for EITHER:
1. **Logo** ("Claude Code v") - Claude started, no permissions needed
2. **Permissions screen** ("Enter to confirm" + "trust") - needs acceptance

This is stored in `CLAUDE_STARTED_WITH` global variable.

### Handling Flow

```
wait_for_claude_start()
  ├── Logo detected first → Done (no Enter needed)
  └── Permissions detected → send Enter → wait_for_claude_logo()
```

The `auto_accept_workspace_trust` function (ib:525):
1. Waits for Claude to start (logo OR permissions)
2. If logo appeared first → return immediately
3. If permissions screen → send Enter, wait 4s, verify logo appears
4. Retry up to 5 times if permissions persist

### Key Lessons Learned

1. **Wait before sending Enter**: Always detect what screen is showing first
2. **Check for logo after permissions**: Verify Claude actually started after accepting
3. **Use delays between retries**: 4 second delay allows Claude to process
4. **Don't send Enter blindly**: Only send when permissions screen is confirmed

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

### Writing New Tests

1. **Create a fixture file** with the expected output encoded in the filename:
   ```bash
   # For a new running state test
   echo "⏺ Bash(npm test)
     ⎿  Running (ctrl+c to interrupt)" > tests/fixtures/running-npm-test.txt
   ```

2. **Run the test** to verify:
   ```bash
   ./tests/test-parse-state.sh
   # Should show: PASS [running] npm test
   ```

3. **For new test suites**, create `tests/test-<feature>.sh` following the existing pattern:
   - Set `FIXTURES_DIR` to the appropriate subdirectory
   - Loop through fixture files, extract expected value from filename
   - Call `ib test-<feature>` and compare output

### Writing Testable Code

When adding new features to `ib`, structure code for testability:

**DO: Extract logic into pure helper functions**
```bash
# Pure function - easy to test
format_age() {
    local seconds="$1"
    if (( seconds < 60 )); then echo "${seconds}s"
    elif (( seconds < 3600 )); then echo "$((seconds / 60))m"
    elif (( seconds < 86400 )); then echo "$((seconds / 3600))h"
    else echo "$((seconds / 86400))d"
    fi
}

# Expose for testing
cmd_test_format_age() {
    local input=$(cat "$1")
    format_age "$input"
}
```

**DON'T: Embed logic in interactive code**
```bash
# Hard to test - mixes UI with logic
show_agent_status() {
    local state=$(get_state "$ID")
    # If state detection logic were inline here,
    # you'd need a running tmux session to test it
    tput setaf 2  # colors
    echo "State: $state"
}
```

**Pattern: File-based testing for complex logic**
```bash
# Logic function reads from file or stdin
parse_tmux_output() {
    local content
    if [[ -n "$1" && -f "$1" ]]; then
        content=$(cat "$1")
    else
        content=$(cat)
    fi
    # ... detection logic ...
    echo "$detected_state"
}

# Called with fixture file for testing
ib parse-state tests/fixtures/running-bash.txt

# Called with actual tmux output in production
tmux capture-pane -t "$SESSION" -p | ib parse-state
```

### What TO Test

Test these types of functions:

| Category | Examples | Why Testable |
|----------|----------|--------------|
| **State parsing** | `get_state`, `parse_tmux_output` | Pure text processing, no side effects |
| **Formatting** | `format_age`, `format_log_entry` | Deterministic input → output |
| **Permission logic** | `is_tool_allowed`, `check_path_isolation` | Security-critical, well-defined rules |
| **Config parsing** | `load_config`, `build_settings` | Complex transformations from JSON |
| **ID resolution** | `resolve_agent_id` | Matching/disambiguation logic |
| **Relationship logic** | `get_children`, `get_manager` | Graph traversal from JSON data |

### What NOT TO Test

Skip testing these:

| Category | Examples | Why Not Tested |
|----------|----------|----------------|
| **Interactive UI** | `ib watch`, `show_dialog` | Requires terminal, visual inspection |
| **tmux operations** | `send_keys`, `capture_pane` | External process, integration test |
| **Process management** | `kill_agent_process`, `spawn_agent` | Side effects on system |
| **Git operations** | `git checkout`, `git merge` | External tool, would need mock repo |
| **Real agent behavior** | Agent completing tasks | Requires Claude, non-deterministic |

For these, use manual testing:
```bash
# Test basic spawn
ib new-agent --name test "echo hello and exit"

# Test communication
ib send test "hello"
ib look test

# Cleanup
ib kill test --force
```

### Adding Test Coverage for New Features

When implementing a new feature:

1. **Identify the testable logic** - What pure functions can be extracted?
2. **Create the `test-*` command** - Add `cmd_test_<feature>` that wraps the logic
3. **Create fixtures** - Add test cases to `tests/fixtures/`
4. **Create the test script** - Add `tests/test-<feature>.sh`
5. **Run tests** - Verify with `./tests/test-all.sh`

Example for adding a new "duration parsing" feature:
```bash
# 1. Add the pure function to ib
parse_duration() {
    local input="$1"
    # Convert "5m", "2h", "1d" to seconds
    ...
}

cmd_test_parse_duration() {
    local input=$(cat "$1")
    parse_duration "$input"
}

# 2. Add fixtures
echo "5m" > tests/fixtures/parse-duration/300-5-minutes.txt
echo "2h" > tests/fixtures/parse-duration/7200-2-hours.txt

# 3. Create test script
# tests/test-parse-duration.sh (follow existing pattern)

# 4. Run all tests
./tests/test-all.sh
```

**Note**: Always use `ib` (not `./ib`) to ensure you run the current version from PATH. This is especially important in worktrees where `./ib` would run a stale checkout.

## Key Implementation Details

- **State detection**: See "Process and Session Management" section above for detailed `get_state` behavior
- **Logging**: All commands log to `agent.log`; see "Logging System" section
- **Permission handling**: See "Claude Startup and Permission Screen" section for startup flow
- **Session persistence**: Each agent gets a UUID (`session_id` in meta.json) enabling `claude --resume`
- **Exit handler** (`exit-check.sh`): Prompts for uncommitted changes when agent session ends
- **Send timing**: Message and Enter key sent separately with 0.1s delay to handle busy agents
- **Orphan cleanup**: `scan_and_kill_orphans` runs after kill/merge to clean up stray Claude processes

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
│ - permissions.allow: [...]              │
│ - permissions.deny: [...]               │
│ - hooks: Stop, PreToolUse, PermRequest  │
└─────────────────────────────────────────┘
                    │
                    ▼ Hooks enforce at runtime
┌─────────────────────────────────────────┐
│ PreToolUse hook (ib hooks agent-path)   │  ← Path isolation
│ - Blocks access to main repo            │
│ - Blocks access to other agent worktrees│
│ - Logs violations to agent.log          │
├─────────────────────────────────────────┤
│ PermissionRequest hook                  │  ← Tool allow/deny
│ - Auto-denies tools not in allow list   │
│ - Logs denied requests to agent.log     │
└─────────────────────────────────────────┘
```

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
| **Git operations** | `Bash(git status:*)`, `Bash(git add:*)`, `Bash(git commit:*)`, `Bash(git diff:*)`, `Bash(git show:*)`, `Bash(git log:*)`, `Bash(git ls-files:*)`, `Bash(git grep:*)`, `Bash(git rm:*)` |
| **Basic shell** | `Bash(pwd:*)`, `Bash(ls:*)`, `Bash(head:*)`, `Bash(tail:*)`, `Bash(cat:*)`, `Bash(grep:*)` |
| **File tools** | `Read`, `Write`, `Edit`, `MultiEdit`, `Glob`, `Grep`, `LS` |
| **Other tools** | `TodoWrite`, `Task`, `NotebookEdit`, `WebFetch`, `WebSearch`, `AskUserQuestion` |

| Category | Always Denied |
|----------|--------------|
| **Plan mode** | `EnterPlanMode`, `ExitPlanMode` (agents should work directly, not enter planning mode) |

**Why file tools are allowed by default:** The PreToolUse hook enforces path isolation at runtime. Agents can only access files in their own worktree - attempts to access the main repo or other agents' files are blocked regardless of tool permissions.

Key files:
- `.ittybitty.json` - User-editable config in repo root (optional)
- `$AGENT_DIR/settings.local.json` - Generated per-agent, merges mandatory + user permissions
- `$AGENT_DIR/agent.log` - Contains `[PreToolUse]` and `[PermissionRequest]` denial logs

<!-- INSTALLED ITTYBITTY BLOCK: This is the installed copy of the <ittybitty> section.
     The canonical source is in the ib script: get_ittybitty_instructions() function.
     To update: modify get_ittybitty_instructions() in ib, then reinstall via 'ib watch' setup dialog.
     New users installing ib will get the latest version from the ib script. -->
<ittybitty>
## Multi-Agent Orchestration (ittybitty)

`ib` spawns persistent Claude agents in isolated git worktrees. Check your role marker at conversation start:

| Marker | Role | Action |
|--------|------|--------|
| `<ittybitty>You are an IttyBitty manager agent.</ittybitty>` | Manager | See [AGENT CONTEXT] above |
| `<ittybitty>You are an IttyBitty worker agent.</ittybitty>` | Worker | See [AGENT CONTEXT] above |
| No marker | Primary Claude | Read below |

### Primary Claude

Spawn agents for complex/parallel tasks. **No auto-notifications** - tell user to run `ib watch`.

| Command | Description |
|---------|-------------|
| `ib new-agent "goal"` | Spawn agent (returns ID) |
| `ib look <id>` | View agent output |
| `ib send <id> "msg"` | Send input to agent |
| `ib diff <id>` | Review agent's changes |
| `ib merge <id> --force` | Merge and close agent |
| `ib kill <id> --force` | Close without merging |
| `ib questions` | Check agent questions |
| `ib acknowledge <qid>` | Mark question handled |

**Agent questions:** Agents ask via `ib ask`. Check `ib questions` periodically (STATUS.md import doesn't update mid-conversation).

### Agent States

| State | Meaning |
|-------|---------|
| `creating` | Starting up |
| `running` | Actively working |
| `waiting` | Idle, may need input |
| `complete` | Signaled done |
| `stopped` | Session ended |

@.ittybitty/STATUS.md

</ittybitty>
