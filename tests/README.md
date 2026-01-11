# ittybitty Test Suite

This directory contains test cases for `ib` agents. Each test file describes:
- A prompt to give an agent
- Expected behavior/outcome
- Success criteria

## Test Format

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

## Running Tests

To run a test:

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
| 001  | Plan mode exit bug | 🔴 FAILING |
