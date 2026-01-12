# Testing Strategy: test-* Commands for ib

## Executive Summary

This document proposes adding a suite of `test-*` commands to the `ib` script that enable isolated testing of core functionality without requiring a full agent setup. These commands accept stdin input (following the pattern established by `parse-state`) and are blocked from running inside agent contexts to prevent accidental usage.

---

## Research Findings

### How `parse-state` Works

The existing `parse-state` command (ib:4523-4659) provides an excellent pattern for test commands:

1. **Dual input modes**: Accepts input via stdin OR file argument
2. **Stdin detection**: Uses `[[ -t 0 ]]` to detect if stdin is a terminal (no data piped)
3. **Verbose option**: `-v/--verbose` flag shows which pattern matched
4. **Help text**: `-h/--help` with examples
5. **Clear error messages**: Guides user when no input provided

**Key pattern from `cmd_parse_state()`:**
```bash
if [[ -n "$input_file" ]]; then
    input=$(cat "$input_file")
else
    if [[ -t 0 ]]; then
        echo "Error: no input provided" >&2
        exit 1
    fi
    input=$(cat)
fi
```

### Agent Context Detection

The `is_running_as_agent()` function (ib:134-140) detects agent context by checking if the current working directory contains `/.ittybitty/agents/*/repo`:

```bash
is_running_as_agent() {
    local current_dir=$(pwd)
    if [[ "$current_dir" == *"/.ittybitty/agents/"*"/repo"* ]]; then
        return 0
    fi
    return 1
}
```

This function is already used to block interactive prompts in commands like `kill`, `merge`, and `nuke`. Test commands should follow the same pattern.

### Core Functions That Benefit from Test Commands

Based on analysis of the codebase, these functions would benefit most from exposed test commands:

| Function | Location | Purpose | Testability Value |
|----------|----------|---------|-------------------|
| `parse_state()` | ib:896-977 | State detection from output | **Already exposed** via `parse-state` |
| `log_agent()` | ib:74-91 | Timestamped logging | Medium - simple but foundation for debugging |
| `format_age()` | ib:757-774 | Age calculation from timestamps | High - date math edge cases |
| `tool_matches_pattern()` | ib:524-549 | Tool permission pattern matching | High - complex regex logic |
| `tool_in_allow_list()` | ib:554-576 | Tool permission checking | High - validates permission system |
| `resolve_agent_id()` | ib:651-692 | Partial ID matching | Medium - fuzzy matching edge cases |
| `load_config()` | ib:411-453 | Config file parsing | Medium - JSON parsing edge cases |
| `build_agent_settings()` | ib:580-649 | Settings generation | High - complex JSON construction |
| `get_children()` | ib:147-203 | Parent-child relationships | Medium - tree traversal |
| `get_state()` | ib:982-1018 | Full state detection (tmux-dependent) | Low - requires tmux session |

---

## Proposed Test Commands

### Pattern for All Test Commands

Each test command should:
1. Accept input via stdin or file argument
2. Support `-v/--verbose` and `-h/--help` flags
3. Block execution when running inside an agent context
4. Return clear, parseable output
5. Have corresponding test fixtures when applicable

**Agent blocking pattern:**
```bash
if is_running_as_agent; then
    echo "Error: test-* commands cannot be run inside an agent context" >&2
    exit 1
fi
```

---

### Priority 1: High-Value Pure Functions

#### `test-tool-match` - Test tool permission pattern matching

**Purpose:** Verify that `tool_matches_pattern()` correctly matches tool names against permission patterns.

**Input format (JSON):**
```json
{"tool_name": "Bash", "tool_input": {"command": "git status"}, "pattern": "Bash(git:*)"}
```

**Output:** `match` or `no-match`

**Example usage:**
```bash
echo '{"tool_name": "Bash", "tool_input": {"command": "git status"}, "pattern": "Bash(git:*)"}' | ib test-tool-match
# Output: match

echo '{"tool_name": "Read", "tool_input": {}, "pattern": "Bash(git:*)"}' | ib test-tool-match
# Output: no-match
```

**Verbose output:**
```
match (pattern: Bash(git:*), command: git status, prefix match: git)
```

**Test fixtures needed:**
- Exact tool name matches
- Bash prefix pattern matches (`Bash(ib:*)`)
- No-match cases
- Edge cases (empty command, null input)

---

#### `test-format-age` - Test timestamp age formatting

**Purpose:** Verify that `format_age()` correctly calculates and formats relative ages.

**Input format:** ISO timestamp or Unix epoch, optionally with a reference "now" timestamp

**Output:** Formatted age string (e.g., `5m`, `2h`, `1d`)

**Example usage:**
```bash
# Using current time as reference
echo "2026-01-12T10:00:00-06:00" | ib test-format-age

# Using explicit "now" for deterministic testing
echo "2026-01-12T10:00:00-06:00 2026-01-12T10:05:00-06:00" | ib test-format-age
# Output: 5m

# From file
ib test-format-age tests/fixtures/age-5-minutes.txt
```

**Verbose output:**
```
5m (diff: 300 seconds, from: 2026-01-12T10:00:00-06:00, to: 2026-01-12T10:05:00-06:00)
```

**Test fixtures needed:**
- Seconds (< 60s)
- Minutes (1-59m)
- Hours (1-23h)
- Days (1+d)
- Boundary conditions (exactly 60s, exactly 1h)
- Timezone handling

---

#### `test-tool-allowed` - Test full permission checking

**Purpose:** Verify that `tool_in_allow_list()` correctly checks tools against a settings file.

**Input format (JSON):**
```json
{
  "tool_name": "Bash",
  "tool_input": {"command": "ib list"},
  "settings": {"permissions": {"allow": ["Bash(ib:*)"]}}
}
```

**Output:** `allowed` or `denied`

**Example usage:**
```bash
echo '{"tool_name": "Read", "tool_input": {}, "settings": {"permissions": {"allow": ["Read"]}}}' | ib test-tool-allowed
# Output: allowed
```

**Verbose output:**
```
allowed (matched pattern: Bash(ib:*), tool: Bash, command: ib list)
```

---

### Priority 2: Config and Settings Testing

#### `test-build-settings` - Test agent settings generation

**Purpose:** Verify that `build_agent_settings()` produces correct settings.local.json content.

**Input format:** Agent type (`manager` or `worker`)

**Output:** Generated JSON (or validation result in verbose mode)

**Example usage:**
```bash
echo "manager" | ib test-build-settings
# Output: full JSON

echo "worker" | ib test-build-settings --validate
# Output: valid (all required fields present)
```

**Verbose output:**
- Shows allow/deny lists
- Shows hook configurations
- Validates JSON structure

---

#### `test-load-config` - Test config file parsing

**Purpose:** Verify that `load_config()` correctly parses `.ittybitty.json`.

**Input:** Path to a config file (or JSON via stdin)

**Output:** Parsed configuration values

**Example usage:**
```bash
echo '{"permissions": {"manager": {"allow": ["Read"]}}}' | ib test-load-config
# Output:
# manager_allow: ["Read"]
# manager_deny: []
# worker_allow: []
# worker_deny: []
# create_prs: false
# max_agents: 10
# model:
# fps: 10
```

**Verbose output:** Shows raw JSON values before processing

---

### Priority 3: ID Resolution and Relationships

#### `test-resolve-id` - Test partial agent ID matching

**Purpose:** Verify that `resolve_agent_id()` correctly handles partial matches.

**Input:** Partial ID string and mock agent list

**Note:** This command requires mocking the agent directory structure. Input format:
```json
{
  "partial": "abc",
  "agents": ["abc123", "def456", "abc789"]
}
```

**Output:** Resolved ID, or error for ambiguous/missing matches

**Example usage:**
```bash
echo '{"partial": "def", "agents": ["abc123", "def456"]}' | ib test-resolve-id
# Output: def456

echo '{"partial": "abc", "agents": ["abc123", "abc789"]}' | ib test-resolve-id
# Output: Error: 'abc' matches multiple agents: abc123, abc789
```

---

#### `test-relationships` - Test parent-child relationship detection

**Purpose:** Verify that `get_children()` and tree-building logic works correctly.

**Input (JSON):** Mock agent metadata
```json
{
  "agents": [
    {"id": "manager1", "manager": null},
    {"id": "worker1", "manager": "manager1"},
    {"id": "worker2", "manager": "manager1"}
  ],
  "query": {"manager": "manager1", "filter": "all"}
}
```

**Output:** List of matching agent IDs

---

### Priority 4: Logging System Testing

#### `test-log-format` - Test log message formatting

**Purpose:** Verify that `log_agent()` produces correctly formatted log entries.

**Input:** Message string

**Output:** Formatted log entry (without actually writing to a file)

**Example usage:**
```bash
echo "Agent started successfully" | ib test-log-format
# Output: [2026-01-12 10:30:45] Agent started successfully

echo "Agent started successfully" | ib test-log-format --timestamp "2026-01-12 10:30:45"
# Output: [2026-01-12 10:30:45] Agent started successfully
```

---

### Priority 5: Advanced State Detection

#### `test-creating-state` - Test creating state detection

**Purpose:** Test the `creating` state detection logic from `get_state()` that checks for Claude logo and permissions screen.

**Input:** Mock tmux output that would indicate creating state

**Output:** `creating` or the actual state if not creating

**Note:** This tests the logic that's separate from `parse_state()` - the logic in `get_state()` that checks for Claude logo absence and permission screen presence.

---

## Implementation Plan

### Phase 1: Foundation (test-tool-match, test-format-age)

1. Add `is_running_as_agent` check pattern as reusable helper
2. Implement `test-tool-match` command
3. Create test fixtures for tool matching
4. Implement `test-format-age` command
5. Create test fixtures for age formatting
6. Add to main dispatch case statement
7. Update help text with new commands

### Phase 2: Permissions (test-tool-allowed, test-build-settings)

1. Implement `test-tool-allowed` command
2. Implement `test-build-settings` command
3. Create comprehensive fixtures
4. Add integration with test-parse-state.sh pattern

### Phase 3: Config and Resolution (test-load-config, test-resolve-id)

1. Implement `test-load-config` command
2. Implement `test-resolve-id` command with mock support
3. Create edge case fixtures

### Phase 4: Relationships and Logging (test-relationships, test-log-format)

1. Implement `test-relationships` command
2. Implement `test-log-format` command
3. Complete documentation

### Phase 5: Test Harness Expansion

1. Create `tests/test-all.sh` that runs all test suites
2. Add CI-friendly output format
3. Document test fixture conventions
4. Create fixture generation helpers

---

## Command Summary

| Command | Input | Output | Priority |
|---------|-------|--------|----------|
| `test-tool-match` | JSON (tool_name, tool_input, pattern) | `match`/`no-match` | P1 |
| `test-format-age` | timestamp [now_timestamp] | Formatted age (5m, 2h, etc.) | P1 |
| `test-tool-allowed` | JSON (tool_name, tool_input, settings) | `allowed`/`denied` | P1 |
| `test-build-settings` | `manager`/`worker` | JSON settings | P2 |
| `test-load-config` | JSON or file path | Parsed config values | P2 |
| `test-resolve-id` | JSON (partial, agents list) | Resolved ID or error | P3 |
| `test-relationships` | JSON (agents, query) | Matching agent IDs | P4 |
| `test-log-format` | Message string | Formatted log entry | P4 |

---

## Agent Blocking Implementation

All test commands should include this guard at the start:

```bash
cmd_test_tool_match() {
    # Block test commands from running inside agents
    if is_running_as_agent; then
        echo "Error: test-* commands are for development testing only" >&2
        echo "These commands cannot be run inside an agent worktree" >&2
        exit 1
    fi

    # ... rest of implementation
}
```

This ensures that:
1. Agents cannot accidentally use test commands
2. Test commands don't interfere with production agent behavior
3. Clear error message explains why the command is blocked

---

## Test Fixture Organization

```
tests/
├── fixtures/
│   ├── parse-state/           # Existing: state detection fixtures
│   │   └── *.txt
│   ├── tool-match/            # New: tool pattern matching
│   │   ├── match-exact-tool.json
│   │   ├── match-bash-prefix.json
│   │   └── nomatch-wrong-tool.json
│   ├── format-age/            # New: age formatting
│   │   ├── seconds.txt
│   │   ├── minutes.txt
│   │   └── days.txt
│   └── config/                # New: config parsing
│       ├── minimal.json
│       └── full-config.json
├── test-parse-state.sh        # Existing
├── test-tool-match.sh         # New
├── test-format-age.sh         # New
└── test-all.sh                # New: runs all tests
```

---

## Notes

### Why stdin/file Input Pattern?

1. **Consistency**: Follows established `parse-state` pattern
2. **Composability**: Works with pipes, heredocs, and files
3. **Testability**: Easy to write deterministic tests
4. **Debuggability**: Can replay exact inputs that caused issues

### Why Block Agents?

1. **Prevent confusion**: Test commands aren't meant for production
2. **Prevent wasted cycles**: Agents spending tokens on test commands
3. **Clear boundaries**: Development tools vs. production tools
4. **Safety**: Prevents agents from exploring internal testing infrastructure

### Future Considerations

- **Mock framework**: For testing functions that depend on file system or tmux
- **Performance testing**: Benchmarks for key functions
- **Regression fixtures**: Captured from real bugs for regression prevention
- **Coverage reporting**: Track which code paths are tested
