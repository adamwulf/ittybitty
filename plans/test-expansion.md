# Test Expansion Proposal: parse-state Test Suite

## Executive Summary

This proposal recommends expanding the `parse-state` test suite with 23 new test fixtures to improve coverage of edge cases, boundary conditions, and realistic tmux output scenarios.

---

## Current Test Coverage Analysis

### Existing Fixtures (26 total)

| State | Count | Fixtures |
|-------|-------|----------|
| **complete** | 4 | `complete-bullet-completion.txt`, `complete-simple.txt`, `complete-with-bullet-near-end.txt`, `complete-with-bullet.txt` |
| **running** | 14 | Various tool invocations, bash, explicit running, thinking, tmux passthrough, complete-in-history-but-active, old-complete-outside-window |
| **waiting** | 4 | `waiting-just-waiting.txt`, `waiting-standalone.txt`, `waiting-with-bullet.txt`, `waiting-with-whitespace.txt` |
| **unknown** | 4 | `unknown-bullet-plain-text.txt`, `unknown-empty.txt`, `unknown-idle.txt` |

### State Detection Logic Summary (from `parse_state()` at ib:790)

**Priority Order:**
1. **Strong running** (line 811): Regex for `esc to interrupt`, `ctrl+c to interrupt`, `ctrl+b ctrl+b`, `⎿  Running`, `thinking)`
2. **Complete** (line 822): `I HAVE COMPLETED THE GOAL` in last 15 lines
3. **Waiting** (line 830): `WAITING` as standalone word in last 15 lines
4. **Weak running** (line 841): `⏺` followed by tool name + `(`
5. **Unknown**: No indicators found

**Key Parameters:**
- `capture_tmux` fetches 20 lines by default (line 859)
- Completion/waiting detection uses last 15 lines (line 818)
- Empty input returns `unknown` (line 799-802)

---

## Coverage Gaps Identified

### Gap 1: Boundary Conditions for 15-line Window

The current tests don't verify the exact boundary behavior when completion/waiting phrases appear at specific line positions.

**Missing tests:**
- Completion phrase at exactly line 15 (should detect)
- Completion phrase at exactly line 16 (should NOT detect, outside window)
- Completion phrase at line 14 with trailing blank lines
- Waiting at boundary positions

### Gap 2: Running Indicator Variations

**Missing tests:**
- `ctrl+c to interrupt` variant (only `esc to interrupt` tested)
- Partial matches that should NOT trigger (e.g., text discussing "esc to interrupt")
- Multiple running indicators in same output
- Strong running indicator appearing after completion phrase (priority test)

### Gap 3: Realistic Multi-line Output Length

Most fixtures are very short (1-10 lines). Real tmux output is typically longer.

**Missing tests:**
- Full 20-line realistic outputs
- Outputs longer than 20 lines where state indicators are at specific positions
- Mixed content with noise before state indicators

### Gap 4: Tool Detection Edge Cases

**Missing tests:**
- All Claude tools are listed but not all tested: `WebFetch`, `WebSearch`, `NotebookEdit`, `LSP`, `AskUserQuestion` missing
- Tool name appearing in text without `⏺` prefix (should NOT detect)
- Nested tool patterns or partial matches

### Gap 5: Combined State Indicators

**Missing tests:**
- Output containing both completion phrase AND running indicator (running should win)
- Output containing both waiting AND running indicator (running should win)
- Output containing both completion AND waiting (completion should win)
- All three indicators present

### Gap 6: Special Character Handling

**Missing tests:**
- ANSI escape codes in output (should be stripped before matching)
- Unicode characters around state keywords
- Very long lines that might cause regex issues

---

## Proposed New Test Fixtures

### Priority 1: Boundary Condition Tests (Critical)

#### 1.1 `complete-at-line-15.txt`
Tests exact boundary of 15-line detection window.
```
Line 1: Some earlier output
Line 2: Agent is working
Line 3: ...
Line 4: ...
Line 5: ...
Line 6: ...
Line 7: ...
Line 8: ...
Line 9: ...
Line 10: ...
Line 11: ...
Line 12: ...
Line 13: ...
Line 14: ...
Line 15: I HAVE COMPLETED THE GOAL
```

#### 1.2 `unknown-complete-at-line-16.txt`
Completion phrase outside 15-line window should NOT be detected.
```
Line 1: I HAVE COMPLETED THE GOAL
Line 2: But then more work came in...
Line 3: ...
Line 4: ...
Line 5: ...
Line 6: ...
Line 7: ...
Line 8: ...
Line 9: ...
Line 10: ...
Line 11: ...
Line 12: ...
Line 13: ...
Line 14: ...
Line 15: ...
Line 16: Just waiting for input now.
```
Expected: `unknown` (completion is at line 1, outside last 15 lines)

#### 1.3 `waiting-at-line-15.txt`
```
Line 1: Earlier context
Line 2: ...
Line 3: ...
Line 4: ...
Line 5: ...
Line 6: ...
Line 7: ...
Line 8: ...
Line 9: ...
Line 10: ...
Line 11: ...
Line 12: ...
Line 13: ...
Line 14: ...
Line 15: WAITING
```

#### 1.4 `unknown-waiting-at-line-16.txt`
```
Line 1: WAITING
Line 2: But then I got new instructions
Line 3: ...
Line 4: ...
Line 5: ...
Line 6: ...
Line 7: ...
Line 8: ...
Line 9: ...
Line 10: ...
Line 11: ...
Line 12: ...
Line 13: ...
Line 14: ...
Line 15: ...
Line 16: Processing the request now
```
Expected: `unknown`

### Priority 2: Running Indicator Completeness

#### 2.1 `running-ctrl-c-interrupt.txt`
Tests the `ctrl+c to interrupt` variant.
```
Processing files...

⏺ Bash(npm run build)
  ⎿  Running (ctrl+c to interrupt)
```

#### 2.2 `running-thinking-explicit.txt`
Tests the `thinking)` indicator with context.
```
Analyzing the problem carefully...

Claude is thinking)

Let me consider all the options...
```

#### 2.3 `running-overrides-complete.txt`
Tests that strong running indicator takes priority over completion phrase.
```
Previously I said I HAVE COMPLETED THE GOAL

But then new work arrived and now I'm processing:

⏺ Bash(git status)
  ⎿  Running (esc to interrupt)
```

#### 2.4 `running-overrides-waiting.txt`
Tests that running takes priority over waiting.
```
I was WAITING for input

But now I received new instructions:

⏺ Read(/path/to/file)
  ⎿  Running (esc to interrupt)
```

### Priority 3: Tool Coverage Expansion

#### 3.1 `running-bullet-webfetch-tool.txt`
```
⏺ WebFetch(https://example.com)
```

#### 3.2 `running-bullet-websearch-tool.txt`
```
⏺ WebSearch(query here)
```

#### 3.3 `running-bullet-notebookedit-tool.txt`
```
⏺ NotebookEdit(/path/to/notebook.ipynb)
```

#### 3.4 `running-bullet-lsp-tool.txt`
```
⏺ LSP(goToDefinition)
```

#### 3.5 `running-bullet-askuserquestion-tool.txt`
```
⏺ AskUserQuestion({"question": "test"})
```

### Priority 4: Negative Tests (Should NOT Match)

#### 4.1 `unknown-discuss-interrupt.txt`
Text discussing the interrupt command without being in active execution.
```
When you see "esc to interrupt" in Claude's output, it means
a tool is currently executing. You can press Escape to stop it.

The agent is now idle and waiting for instructions.
```
Expected: `unknown` (the phrase appears in instructional text, not as active indicator)

**Note:** This test may currently FAIL because the regex does not distinguish context. This documents expected vs actual behavior and could drive a future enhancement.

#### 4.2 `unknown-tool-in-text.txt`
Tool name in text without `⏺` prefix.
```
I used the Bash(npm test) command earlier to run tests.
Now I'm reviewing the results and thinking about next steps.
```
Expected: `unknown`

#### 4.3 `unknown-partial-completion.txt`
Partial completion phrase that shouldn't match.
```
The goal is to HAVE COMPLETED THE implementation by tomorrow.
I will work on this task now.
```
Expected: `unknown`

### Priority 5: Realistic Long Output Tests

#### 5.1 `complete-20-lines-realistic.txt`
Full 20-line realistic output with completion at end.
```
⏺ Bash(git status)
  ⎿ On branch agent/feature
    Changes to be committed:
      modified: src/main.ts
      modified: src/utils.ts

⏺ Bash(git commit -m "Add feature")
  ⎿ [agent/feature abc1234] Add feature
    2 files changed, 45 insertions(+)

All changes have been committed successfully.

I have implemented the requested feature:
- Added the new utility function
- Updated main to use it
- All tests pass

I HAVE COMPLETED THE GOAL
```

#### 5.2 `running-20-lines-with-history.txt`
20 lines with historical completion phrase but currently running.
```
Earlier output:
I HAVE COMPLETED THE GOAL
---
But then new instructions came in:
Please also add documentation.
---
Starting documentation task...

⏺ Read(README.md)
  ⎿  1→# Project Title
     2→
     3→This is a project...
     ...truncated...

⏺ Write(docs/api.md)
  ⎿  Running (esc to interrupt)
```

### Priority 6: Multiple Indicator Tests

#### 6.1 `running-multiple-indicators.txt`
Multiple running indicators present.
```
⏺ Bash(npm test)
  ⎿  Running (esc to interrupt)

ctrl+b ctrl+b

Still executing tests...

Claude is thinking)
```

#### 6.2 `complete-with-past-waiting.txt`
Completion after previous waiting state.
```
I spawned sub-agents and entered WAITING mode.

Later, all agents completed:
- worker-1: merged
- worker-2: merged

I HAVE COMPLETED THE GOAL
```
Expected: `complete` (completion comes after waiting)

### Priority 7: Edge Cases

#### 7.1 `unknown-waiting-embedded-in-sentence.txt`
Test that WAITING must be standalone.
```
The agent will be WAITING for input after this message completes.
Currently processing the request.
```
Expected: `unknown` (WAITING is not standalone)

**Note:** This tests the regex `(^|$'\n')[[:space:]]*WAITING[[:space:]]*($|$'\n')` which requires WAITING on its own line.

#### 7.2 `unknown-complete-lowercase.txt`
Test case sensitivity of completion phrase.
```
The goal was completed successfully.

I have completed the goal (lowercase intentional)

But I did not say the magic phrase.
```
Expected: `unknown` (lowercase doesn't match)

#### 7.3 `unknown-only-whitespace.txt`
Only whitespace, no content.
```




```
Expected: `unknown`

---

## Implementation Priority Order

1. **P1 - Boundary Tests** (1.1-1.4): These verify the core 15-line window logic
2. **P2 - Running Priority** (2.1-2.4): Ensure running indicators properly override other states
3. **P3 - Tool Coverage** (3.1-3.5): Complete coverage of all tool names
4. **P4 - Negative Tests** (4.1-4.3): Prevent false positives
5. **P5 - Realistic Tests** (5.1-5.2): Match real-world output patterns
6. **P6 - Multiple Indicators** (6.1-6.2): Test priority ordering
7. **P7 - Edge Cases** (7.1-7.3): Handle unusual inputs

---

## Test Fixture Naming Convention

The existing convention is `{expected-state}-{description}.txt`. The test harness extracts the expected state from the prefix before the first hyphen.

All proposed fixtures follow this convention.

---

## Summary

| Category | New Fixtures | Coverage Impact |
|----------|--------------|-----------------|
| Boundary conditions | 4 | Critical - verifies 15-line window |
| Running indicators | 4 | High - tests priority + completeness |
| Tool coverage | 5 | Medium - fills obvious gaps |
| Negative tests | 3 | High - prevents false positives |
| Realistic outputs | 2 | Medium - matches production patterns |
| Multiple indicators | 2 | Medium - tests priority ordering |
| Edge cases | 3 | Low - defensive coverage |
| **Total** | **23** | |

This brings total fixture count from 26 to 49, significantly improving test coverage for the state detection logic.

---

## Notes on Potential Test Failures

Some proposed negative tests (4.1 `unknown-discuss-interrupt.txt`) may fail with current implementation because the regex matches the phrase anywhere in output, not just in execution context. These tests would document the current behavior and could inform future enhancements to make detection more context-aware.
