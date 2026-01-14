# Prompt System Review: Synthesis and Recommendations

## Executive Summary

This review analyzed ittybitty's prompt system across three areas:
1. **Agent prompt construction** (manager/worker prompts in `cmd_new_agent`)
2. **CLAUDE.md ittybitty block** (what user-run Claude sees)
3. **STATUS.md and user-questions.json** (agent-to-user question flow)

The review identified several gaps that lead to the observed problems:
- Agents don't understand git worktrees (try `git fetch origin; git merge origin/main` instead of just `git merge main`)
- Agents try to cd into main repo or other worktrees (blocked by hooks, but shouldn't try)
- Merge conflicts get resolved blindly (taking own changes, losing work)
- User questions from agents aren't noticed mid-conversation

---

## Key Findings

### 1. Path Isolation is Enforced but Not Explained

**Current state**: Hooks block agents from accessing main repo or other worktrees, but agents aren't told this upfront.

**Impact**: Agents waste tokens trying paths that get blocked, and don't understand why.

**Evidence from review-status-questions worker**: It tried to search `~/Developer/bash/ittybitty` and got blocked with "Access denied: work in your worktree, not the main repo".

### 2. Git Worktree Model Not Documented

**Current state**: Agents are told they're "in a git worktree on branch agent/X" but not what that means operationally.

**Missing context**:
- Worktrees share the same git repo - no need for `git fetch origin`
- They can `git merge main` directly (main branch is local)
- Their branch was forked from their manager's branch (or main if top-level)
- Other agents' branches are also visible as local branches

### 3. Merge Conflict Guidance is Missing

**Current state**: Managers are told about merge conflicts in strategy terms ("resolve yourself" or "spawn a worker") but not HOW to resolve them properly.

**The bug**: An agent resolved conflicts by taking its own changes blindly, losing work from other agents that was already merged to main.

**Missing guidance**:
- Both sides of a conflict contain valuable work
- Must understand what each side contributes before resolving
- When unclear, ASK before arbitrarily choosing one side
- Never blindly accept `--ours` or `--theirs`

### 4. User Question Visibility is Fundamentally Limited

**Current state**: Questions are stored in `user-questions.json`, rendered to `STATUS.md`, and imported into CLAUDE.md via `@.ittybitty/STATUS.md`.

**The problem**: The @import is read when Claude Code starts, not continuously. Questions asked after conversation starts are invisible until:
- User starts a new conversation
- User explicitly asks Claude to check `ib questions`
- User runs `ib watch` in another terminal

**This is a fundamental limitation of the current architecture.**

---

## Specific Prompt Changes

### Change 1: Add Path Isolation Section to Agent Prompts

**Location**: Agent context section in `cmd_new_agent()` (after worktree info)

**Proposed addition for all agents**:

```
PATH ISOLATION:
You are isolated to your worktree at: {WORKTREE_PATH}
- You CAN access: Your worktree, ~/.claude, /tmp, and general system paths
- You CANNOT access: The main repo at {MAIN_REPO}, other agents' worktrees
- If you get "Access denied" or "Path violation" errors, you're trying to access a forbidden path
- Do NOT try to cd into the main repo - work only in your worktree
```

### Change 2: Add Git Worktree Understanding Section

**Location**: Agent context section (after path isolation)

**Proposed addition for all agents**:

```
GIT WORKTREE CONTEXT:
You are in a git worktree, which shares the same repository as the main checkout.
- Your branch: agent/{ID}
- Forked from: {PARENT_BRANCH} (your manager's branch, or main if top-level)
- All branches are LOCAL - no need for 'git fetch origin'
- To merge latest main: 'git merge main' (not 'git fetch origin; git merge origin/main')
- Other agents' branches are visible as local branches (agent/*)
- Your worktree is a separate checkout, but commits are shared across all worktrees
```

### Change 3: Add Merge Conflict Resolution Guidelines

**Location**: Manager completion instructions (where merge conflicts are mentioned)

**Proposed addition for managers**:

```
MERGE CONFLICT RESOLUTION:
When 'ib merge' fails due to conflicts:

1. UNDERSTAND BOTH SIDES FIRST:
   - 'git diff --name-only --diff-filter=U' to see conflicted files
   - Each conflict has two sides: YOUR changes and MAIN's changes
   - BOTH sides represent real work that should be preserved

2. DO NOT blindly resolve conflicts:
   - NEVER use 'git checkout --ours .' or 'git checkout --theirs .'
   - NEVER accept one side without understanding the other
   - NEVER delete code you don't understand

3. For each conflict:
   - Read both versions carefully
   - Understand what each change was trying to accomplish
   - Merge the INTENT of both changes, not just the code
   - If unclear, ASK your manager (or user via 'ib ask' if top-level)

4. After resolving:
   - 'git add <resolved-files>'
   - 'git commit' (the merge commit)
   - Then cleanup: 'git worktree remove <path> --force && git branch -D agent/<id>'
```

### Change 4: Add Worker Self-Inspection Commands

**Location**: Worker instructions (currently only mentions `ib send`)

**Proposed addition for workers**:

```
SELF-INSPECTION:
Before completing, verify your work:
  ib diff         Check your changes vs base branch
  ib status       See your commits
```

### Change 5: Enhance User Question Awareness in Primary Claude Docs

**Location**: CLAUDE.md `<ittybitty>` block, workflow section

**Proposed addition**:

```
AGENT QUESTIONS - IMPORTANT:
Questions from agents are stored in STATUS.md, which is imported at conversation start.
If you spawn agents and continue working, you will NOT automatically see new questions.

To stay aware of agent questions:
- Periodically run 'ib questions' to check for pending questions
- The user can run 'ib watch' in another terminal for real-time monitoring
- If an agent seems stuck, check 'ib questions' - it may be waiting for your answer

When you see pending questions:
1. 'ib acknowledge <question-id>' to mark as being handled
2. 'ib send <agent-id> "your answer"' to respond
```

### Change 6: Add Branch Base Info to Prompt

**Location**: Agent context worktree info

**Current**: "You are running as agent {ID} in a git worktree on branch agent/{ID}."

**Proposed**: "You are running as agent {ID} in a git worktree on branch agent/{ID}, forked from {PARENT_BRANCH}."

This helps agents understand their merge base.

---

## Implementation Priority

### High Priority (Addresses reported bugs directly)

1. **Merge Conflict Resolution Guidelines** - Directly addresses the "blindly taking own changes" bug
2. **Git Worktree Understanding** - Fixes the unnecessary `git fetch origin` pattern
3. **Path Isolation Section** - Reduces wasted tokens and agent confusion

### Medium Priority (Improves overall effectiveness)

4. **Worker Self-Inspection Commands** - Helps workers verify their own work
5. **Branch Base Info** - Helps agents understand merge context

### Lower Priority (User-side improvements)

6. **User Question Awareness** - Helps but is fundamentally limited by @import architecture

---

## Files to Modify

1. **`ib` script** - `cmd_new_agent()` function where prompts are constructed (lines ~2733-2912)
   - Add path isolation section
   - Add git worktree context
   - Add merge conflict guidelines (managers)
   - Add self-inspection commands (workers)
   - Add branch base info

2. **`CLAUDE.md`** - The `<ittybitty>` block (lines ~610-753)
   - Add user question awareness reminder

3. **Installable template** - `get_ittybitty_instructions()` function (lines ~7161-7215)
   - Mirror the user question awareness reminder

---

## Summary

The core issues stem from agents operating with incomplete mental models:
- They don't know their path boundaries until they hit them
- They don't understand git worktrees as shared repositories
- They have no guidance on proper merge conflict resolution
- Users don't realize questions arrive invisibly

The proposed prompt changes provide explicit context for each of these areas, trading a small amount of prompt tokens for significantly improved agent behavior.
