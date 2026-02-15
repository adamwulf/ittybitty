# Test Fixtures TODO

Rebuild these parse-state test fixtures with real Claude Code tmux captures.
Each entry describes the edge case the synthetic fixture was testing.

## Complete State

- **complete-simple** - Basic completion: agent says "I HAVE COMPLETED THE GOAL" with no surrounding UI chrome
- **complete-at-line-15** - Boundary test: completion phrase exactly at line 15 (edge of the 15-line window)
- **complete-bullet-completion** - Completion phrase on a `⏺` bullet line: `⏺ I HAVE COMPLETED THE GOAL`

## Running State

- **running-bash** - Basic `⏺ Bash(...)` tool with `(ctrl+c to interrupt)`
- **running-thinking** - "Claude is thinking)" pattern (note: synthetic used wrong format)
- **running-explicit** - `⎿  Running` marker without tool context
- **running-tool** - `⏺ Read(...)` tool with `(esc to interrupt)`
- **running-tmux-passthrough** - `ctrl+b ctrl+b` tmux passthrough indicator
- **running-ctrl-c-interrupt** - `(ctrl+c to interrupt)` during Bash execution
- **running-complete-in-history-but-active** - "I HAVE COMPLETED THE GOAL" in history but active `(esc to interrupt)` in last 5 lines
- **running-old-complete-outside-window** - Completion phrase pushed beyond 15-line window by subsequent output
- **running-multiple-indicators** - Multiple running indicators present simultaneously
- **running-overrides-complete** - Active execution indicator overrides prior completion phrase
- **running-overrides-waiting** - Active execution indicator overrides prior WAITING
- **running-thinking-explicit** - "thinking)" pattern in output
- **running-thinking-spinner-active** - Thinking spinner `✻` at start of line with no other context

## Unknown State

- **unknown-empty** - Completely empty input
- **unknown-only-whitespace** - Input with only whitespace/blank lines
- **unknown-idle** - Agent prose with no state indicators at all
- **unknown-tool-in-text** - Tool name mentioned in prose (e.g., "I used the Bash(npm test) command") should NOT trigger running
- **unknown-discuss-interrupt** - Discussion of "esc to interrupt" in prose should NOT trigger running
- **unknown-partial-completion** - Partial match like "HAVE COMPLETED THE" (not the full phrase)
- **unknown-complete-lowercase** - Lowercase "i have completed the goal" should NOT trigger complete
- **unknown-mentions-rate-limit** - Discussion of rate limiting in prose should NOT trigger rate_limited
- **unknown-complete-at-line-16** - Completion phrase at line 16 (just outside 15-line window)
- **unknown-waiting-at-line-16** - WAITING at line 16 (just outside 15-line window)
- **unknown-waiting-embedded-in-sentence** - "WAITING" embedded in a sentence, not standalone
- **unknown-cogitated-completion-time** - `✻ Cogitated for 4m 4s` thinking timer (not active thinking)
- **unknown-pondered-completion-time** - `✻ Pondered for 2m 15s` thinking timer
- **unknown-mused-completion-time** - `✶ Mused for 10m 30s` thinking timer
- **unknown-brewed-completion-time** - `✻ Brewed for 6m 20s` thinking timer
- **unknown-with-bullet-waiting** - WAITING on a `⏺` bullet line (not standalone)

## Waiting State

- **waiting-just-waiting** - Bare "WAITING" with no context
- **waiting-standalone** - WAITING on its own line after brief prose
- **waiting-with-whitespace** - "  WAITING" with leading whitespace
- **waiting-at-line-15** - WAITING exactly at line 15 boundary

## Rate Limited State

- **rate_limited-simple-usage-limit** - "Claude usage limit reached" one-liner
- **rate_limited-hit-your-limit** - "You've hit your limit" pattern
- **rate_limited-upgrade-prompt** - "/upgrade to increase your usage limit" one-liner

## Compacting State

- **compacting-simple** - Basic `✽ Compacting conversation…` with no context
- **compacting-with-context-info** - Compacting with preceding prose

## How to Capture Real Fixtures

Use `ib watch` debug captures or the new Stop hook debug captures in `$AGENT_DIR/debug/`.
Alternatively, manually capture from a running agent:

```bash
# Capture last 20 lines from an agent's tmux session
tmux capture-pane -t "$(ib list --raw | head -1 | cut -f1)" -p -S -20 -E - > tests/fixtures/new-fixture.txt
```

Trim to ~15-20 lines to match what `parse_state` receives from `get_state`.
