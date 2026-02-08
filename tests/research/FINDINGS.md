# State Parser Research Findings

## Context

Analyzed 287 archived agent tmux sessions from muse-ios to find cases where
`parse_state()` misclassifies agent state, particularly "waiting" when "running".

## Key Finding: Step 1 regex doesn't match modern Claude spinner format

The `very_recent` check (last 5 lines) on line ~4320 of `ib`:

```bash
if [[ "$very_recent" =~ \(esc\ to\ interrupt\)|\(ctrl\+c\ to\ interrupt\)|⎿\ \ Running ]]; then
```

This regex requires:
1. Lowercase `esc` — but modern Claude shows `Esc` (capital)
2. Closing `)` immediately after "interrupt" — but modern format has extra content

**Old format** (Jan 2026 early): `✻ Meandering… (ctrl+c to interrupt)` — matches regex
**New format** (Jan 2026 late+): `· Fluttering… (Esc to interrupt · 31s · thought for 1s)` — does NOT match

This means step 1 (checking last 5 lines for active execution) is effectively broken
for modern Claude versions.

## Why it matters: WAITING + running spinner race condition

The `parse_state` priority order is:
1. Compacting (last 5 lines)
2. Active running — `(esc to interrupt)` in last 5 lines ← BROKEN for new format
3. Rate limited (last 15 lines)
4. Complete — `I HAVE COMPLETED THE GOAL` (last 15 lines)
5. Waiting — standalone `WAITING` (last 15 lines)
6. Weak running — thinking spinners (last 15 lines) ← catches new format, but AFTER waiting check
7. Tool invocation (last 15 lines)
8. Unknown

**The bug scenario:**
1. Agent says `WAITING` (standalone line)
2. Manager/watchdog sends input
3. Agent starts thinking — spinner appears: `✻ Frosting… (Esc to interrupt · 1m · thought for 1s)`
4. State detection runs:
   - Step 2: Spinner is in last 5 lines but regex doesn't match new format → miss
   - Step 5: `WAITING` found in last 15 lines → returns "waiting" ← WRONG!
   - Step 6: Would have caught the spinner, but never reached

## Found: Running agent classified as "unknown" (agent-a5ca596f)

The archive `unknown-20260205-002420-agent-a5ca596f.log` shows:
- Active spinner: `✶ Vibing… (Esc to interrupt · 1h 12m 4s · thought for 1s)`
- But queued messages pushed the spinner to line ~16 from bottom
- Last 15 lines don't include the spinner → classified as "unknown"
- Should be "running"

## Archive Samples

In `archive-samples/`:
- `waiting-*` — agents correctly classified as waiting (21 agents total in archive data)
- `unknown-*` — agents classified as unknown (some should be running)
- `running-*` — agents correctly classified as running (for comparison)
- `complete-watchdog-*` — agents with watchdog prompt containing "WAITING" in instructions
  (correctly classified as complete because "I HAVE COMPLETED THE GOAL" takes priority)

## Suggested Test Fixtures to Create

1. **running-after-waiting.txt** — Agent said WAITING, then got input, now has modern
   format spinner in last 5 lines. Should be "running" but current parser says "waiting"

2. **running-spinner-pushed-out.txt** — Active spinner exists but is pushed beyond
   the 15-line window by queued messages. Should be "running" but returns "unknown"

3. **running-new-esc-format.txt** — Spinner with `(Esc to interrupt · time)` format
   in last 5 lines. Should be "running" via step 1 but regex doesn't match.

4. **running-ctrl-c-with-stats.txt** — Spinner with `(ctrl+c to interrupt · time · tokens)`
   in last 5 lines. Extra content prevents step 1 match.

## Spinner Format Variants Found in Archives

```
✻ Meandering… (ctrl+c to interrupt)                                    # old, matches step 1
· Hashing… (ctrl+c to interrupt · 1m 6s · ↓ 1.4k tokens)              # transition, NO match
· Fluttering… (Esc to interrupt · 31s · thought for 1s)                # new, NO match
✢ Deliberating… (Esc to interrupt · running stop hook · 37s            # new with hook, NO match
· Deciphering… (Esc to interrupt · thinking)                           # new short, NO match
✽ Improvising… (Esc to interrupt · 7m 0s · thinking)                   # new with thinking, NO match
✶ Vibing… (Esc to interrupt · 1h 12m 4s · thought for 1s)             # new, NO match
✻ Flambéing… (34m 30s · ↑ 5.4k tokens · thought for 10s)             # no interrupt marker at all
✢ Cultivating… (2m 19s · ↓ 5.0k tokens · thought for 5s)             # no interrupt marker at all
```

Note: Some spinners don't even have "interrupt" text — just timing info. These are caught by
the spinner-at-line-start check (step 6) but only in the 15-line window.
