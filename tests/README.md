# ittybitty Test Suite

This directory contains test cases for `ib` agents and unit tests for core functionality.

## Unit Tests

### parse-state

Tests for the state detection logic (`ib parse-state` command).

```bash
# Run all parse-state tests
bash tests/test-parse-state.sh

# Test a single fixture
ib parse-state tests/fixtures/complete-with-bullet.txt

# Verbose mode - shows which pattern matched
ib parse-state -v tests/fixtures/complete-with-bullet.txt

# Pipe input
echo "I HAVE COMPLETED THE GOAL" | ib parse-state
```

#### Fixtures

Test fixtures in `tests/fixtures/` represent real tmux output patterns:

| Fixture | Expected State | Description |
|---------|----------------|-------------|
| complete-simple.txt | complete | Basic completion phrase |
| complete-with-bullet.txt | complete | Completion with ⏺ marker (bug fix test) |
| waiting-standalone.txt | waiting | WAITING on its own line |
| waiting-with-bullet.txt | waiting | WAITING with ⏺ marker |
| running-tool.txt | running | Tool with "esc to interrupt" |
| running-bash.txt | running | Bash with "ctrl+c to interrupt" |
| running-thinking.txt | running | Model thinking indicator |
| unknown-idle.txt | unknown | No state indicators |

## Agent Integration Tests

Each test file (`test-NNN.md`) contains:

```markdown
# Test NNN: Description

## Prompt
The exact prompt to give the agent.

## Agent Type
- manager / worker

## Expected Behavior
What the agent should do.

## Expected Outcome
- success / failure
- Expected final state (waiting, complete, etc.)
- Any specific outputs or files created

## Success Criteria
How to verify the test passed.

## Notes
Any additional context or known issues.
```

### Running Agent Tests

```bash
# Spawn agent with test prompt
ib new-agent --name test-NNN "$(cat tests/test-NNN.md | grep -A 100 '^## Prompt' | tail -n +2 | head -n 1)"

# Monitor with watch
ib watch

# Verify outcome matches expected
ib status test-NNN
```

## Test Status

| Test | Description | Status |
|------|-------------|--------|
| parse-state | State detection unit tests | 🟢 PASSING |
| 001  | Plan mode exit bug | 🔴 FAILING |
| 002  | Path isolation hook | 🟡 PENDING (requires merge) |
