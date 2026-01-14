# Findings: CLAUDE.md Review for User-Run Claude Instances

## Overview

This document analyzes what the primary (user-run) Claude instance sees regarding ittybitty multi-agent orchestration via the `<ittybitty>` block in CLAUDE.md.

## Two Versions of ittybitty Documentation

There are **two distinct versions** of the `<ittybitty>` block:

### 1. Installable Template (Short Version)
- **Location**: `ib` script lines 7161-7215 (`get_ittybitty_instructions()` function)
- **Installed via**: `ib setup ib-instructions install`
- **Size**: ~55 lines
- **Focus**: Role identification and behavioral guidelines

### 2. Full Repository Version (Long Version)
- **Location**: `CLAUDE.md` lines 610-753
- **Size**: ~145 lines
- **Focus**: Complete operational documentation with all commands, options, and workflows

## What User-Run Claude Sees

### With Full CLAUDE.md (this repo)
The primary Claude instance sees:

1. **When to Use** - Criteria for spawning ib agents
2. **Automatic Notifications** - Clear warning that user-level Claude does NOT get watchdog notifications
3. **Workflow Steps** (7 steps for primary agent)
4. **All Commands Table** - 13 commands with descriptions
5. **Spawn Options Table** - 9 flags with descriptions
6. **Yolo Mode Section** - Detailed explanation
7. **Agent States** - 5 states with meanings
8. **Key Differences from Task Tool** - Comparison table
9. **User Questions System** - Communication hierarchy and workflow
10. **@.ittybitty/STATUS.md import** - Dynamic status file

### With Installable Template Only
A more minimal view focusing on:

1. **Role Identification** - How to identify as PRIMARY/MANAGER/WORKER
2. **For Manager Agents** - Guidance on subdividing work
3. **For Worker Agents** - Guidance on completing work alone
4. **For Primary Agents** - Key principle of spawning ONE root agent

## How STATUS.md Import Works

### Generation
- Function: `update_claude_status()` at ib:1696
- Output file: `.ittybitty/STATUS.md`
- Called from: Lifecycle events (agent creation, state changes, kill, merge)

### Content Structure
```markdown
<ittybitty-status>
## Current Agents (N active)
[Tree view of agents with: state, age, prompt]

## Pending Questions (N)
[List of questions from agents with IDs and timestamps]
</ittybitty-status>
```

### Installation
- The `@.ittybitty/STATUS.md` line is inserted just before `</ittybitty>`
- Installed via: `ib setup status-import install`
- Claude Code's `@` import directive pulls in the file contents dynamically

## Gaps and Issues Identified

### 1. Inconsistency Between Two Templates
The installable template (short version) and the CLAUDE.md version (long version) have different content:
- **Short version** focuses on role identification and anti-patterns
- **Long version** has comprehensive command reference

**Issue**: Users who install via `ib setup ib-instructions install` get much less documentation than users of this specific repo.

### 2. Missing Setup Documentation for Primary Claude
Neither version clearly explains:
- How to run `ib setup` to install the ittybitty block
- What setup steps are required before first use
- How to check if setup is complete

### 3. Missing Error Handling Guidance
No documentation on:
- What to do when agents get stuck
- How to debug permission denials
- Recovery procedures for crashed agents

### 4. Ambiguous STATUS.md Behavior
The documentation says "See pending questions in STATUS.md (via @import)" but:
- Doesn't explain that STATUS.md is dynamically generated
- Doesn't mention it may not exist if no agents are running
- Doesn't explain how Claude sees the content (via @ import)

### 5. Missing `ib watch` Recommendation Details
While the docs say "suggest they run `ib watch` in another terminal", there's no explanation of:
- What `ib watch` shows
- How to use its interface
- Keyboard shortcuts (h for setup, etc.)

### 6. No Escalation Patterns
The docs mention workers should ask managers, but don't provide:
- Message format recommendations
- When to escalate vs keep working
- How managers should batch questions for users

### 7. Incomplete Command Reference in Short Template
The installable template lacks:
- Command table
- Spawn options
- State definitions
- Yolo mode explanation

## Recommendations

1. **Unify the Templates**: The installable template should include more operational content, or clearly reference where to find the full documentation.

2. **Add Setup Section**: Include a clear "Getting Started" section in the installable template explaining initial setup steps.

3. **Document STATUS.md Lifecycle**: Explain that STATUS.md is dynamically generated and what triggers updates.

4. **Add Troubleshooting Section**: Common issues and how to resolve them.

5. **Expand `ib watch` Documentation**: Since this is the primary way users monitor agents, it deserves more explanation.

## Files Analyzed

- `ib` script: Lines 1420-1710 (STATUS generation), 7155-7350 (setup commands), 7490-7700 (ask/acknowledge)
- `CLAUDE.md`: Lines 610-753 (full ittybitty block)
- `README.md`: Lines 55-64 (role identification)
