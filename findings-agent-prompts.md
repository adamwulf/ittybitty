# Agent Prompt Construction Analysis

## Overview

This document analyzes how manager and worker agent prompts are constructed in the `ib` script, specifically in the `cmd_new_agent` function (starting at line 2384).

## Prompt Construction Location

The prompt construction happens in `cmd_new_agent()` at lines 2733-2912 of the `ib` script. The final prompt is assembled from several components and written to `$AGENT_DIR/prompt.txt`.

## Components of Agent Prompts

### 1. Role Marker (lines 2894-2903)

Each agent gets an XML-tagged role identifier:
- **Worker**: `<ittybitty>You are an IttyBitty worker agent.</ittybitty>`
- **Manager**: `<ittybitty>You are an IttyBitty manager agent.</ittybitty>`

### 2. Agent Context Section (`[AGENT CONTEXT]`)

The prompt includes:

#### A. Worktree Information (lines 2739-2810)
- **With worktree**: "You are running as agent {ID} in a git worktree on branch agent/{ID}."
- **Without worktree**: "You are running as agent {ID} in the main repository (no worktree)."

#### B. Manager Information (lines 2734-2737)
- If the agent has a manager: "Your manager agent is: {MANAGER_ID}"
- Empty if top-level agent

#### C. IB Instructions (lines 2812-2891)

**For Manager Agents** (lines 2821-2871):
- Full list of `ib` commands available
- Task sizing strategy (small/medium/large tasks)
- Automatic notification system explanation
- Merge conflict resolution strategies
- For root-level managers: `ib ask` guidance for user questions

**For Worker Agents** (lines 2874-2890):
- Simple communication instructions
- How to use `ib send` to report to manager
- Stuck/blocker protocol

#### D. Completion Instructions (lines 2740-2810)

**For Workers**:
- State management (WAITING vs I HAVE COMPLETED THE GOAL)
- Completion workflow (commit, summarize, signal)

**For Managers**:
- State management
- Full workflow: break down tasks, spawn workers, enter WAITING, review criteria, merge/kill
- PR creation instructions (if configured and `gh` available)

### 3. User Task (`[USER TASK]`)
The original prompt passed to `ib new-agent` is included at the end.

## Final Prompt Structure

```
{ROLE_MARKER}

[AGENT CONTEXT]
{WORKTREE_INFO}
{MANAGER_INFO}
{IB_INSTRUCTIONS}
{COMPLETION_INSTRUCTIONS}

[USER TASK]
{USER_PROMPT}
```

## Additional Context Sources

### 1. Settings File (lines 2661-2680)
Agents get a `settings.local.json` file in their worktree with:
- Permissions (allow/deny lists)
- Hooks (Stop, PreToolUse, PermissionRequest)
- The `__AGENT_ID__` placeholder is replaced with actual agent ID

### 2. CLAUDE.md Inheritance
Agents inherit the project's CLAUDE.md which includes:
- The full `<ittybitty>` section with detailed orchestration documentation
- All project-specific instructions
- `@.ittybitty/STATUS.md` import (for root-level managers)

### 3. Built-in Permissions (lines 730-736)
Default allowed tools include:
- `ib` commands
- Git commands (status, add, commit, diff, show, log, etc.)
- Basic file operations (Read, Write, Edit, Glob, Grep, etc.)
- Task management (TodoWrite)
- Web tools (WebFetch, WebSearch)

## Identified Gaps in Agent Context/Knowledge

### 1. No Explicit Path Boundaries
Agents are NOT explicitly told:
- What paths they CAN access (their worktree)
- What paths they CANNOT access (main repo, other agents' worktrees)
- This is enforced via hooks but not documented in the prompt

**Recommendation**: Add explicit path isolation information to the prompt.

### 2. No Information About Sibling Agents
Agents don't know:
- What other agents exist at their level
- Whether siblings are working on related tasks
- How to avoid duplicate work

**Recommendation**: Consider adding sibling awareness for coordination.

### 3. No Repository Context
Agents are not given:
- What the repository is about (beyond what's in CLAUDE.md)
- What files exist in their worktree
- The current state of the branch they're on

**Recommendation**: Could add brief repo/branch context summary.

### 4. No Model Information
Agents don't know:
- What model they're running on (opus/sonnet/haiku)
- How this affects their capabilities

**Recommendation**: Consider adding model context if relevant to task sizing.

### 5. Limited Error Context
Agents are not told:
- What happens if tools fail
- How to interpret permission denied errors
- What the PreToolUse hook might block

**Recommendation**: Add troubleshooting guidance for common errors.

### 6. No Time/Duration Context
Agents don't know:
- How long they've been running
- When they were created
- Any timeout expectations

**Recommendation**: Could be useful for long-running tasks.

### 7. No Resource Awareness
Agents don't know:
- The maximum agent limit (`CONFIG_MAX_AGENTS`)
- Current agent count in the system
- System load or constraints

**Recommendation**: Managers could benefit from knowing resource constraints.

### 8. Missing `ib diff` in Worker Instructions
Worker agents have `ib send` but don't know about:
- `ib diff` to check their own changes
- `ib status` to see their commits

**Recommendation**: Add self-inspection commands to worker instructions.

### 9. No Explicit Branch Base Information
Agents are not told:
- Which branch they forked from
- If they forked from main vs a manager's branch

**Recommendation**: Could help with merge conflict understanding.

### 10. No Watchdog Details
Agents know they'll be notified but not:
- The 30-second waiting threshold
- How watchdog monitoring works
- What triggers notifications

**Recommendation**: More detail could help agents optimize their WAITING patterns.

## Summary

The prompt construction is well-organized with clear separation between manager and worker roles. The main gaps are:
1. **Path isolation** - enforced but not explained
2. **Sibling awareness** - no visibility into parallel agents
3. **Self-inspection for workers** - missing diff/status commands
4. **Error handling guidance** - agents discover hook blocks by trial

The CLAUDE.md inheritance provides substantial context, but some operational details are implicit rather than explicit.
