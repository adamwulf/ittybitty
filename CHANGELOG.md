# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Questions pane in `ib watch` with answer dialog and 'g' key to jump to agent
- Status injection hooks (`ib hooks inject-status`) for automated agent status updates
- `ib pause` command to pause and resume agents with nudge on resume
- Relative time display and dead agent filtering for pending questions
- Agent merge review checklist in CLAUDE.md documentation

### Changed
- Made questions panel full-screen and added to quick jump menu
- Updated `<ittybitty>` block for primary Claude clarity
- Optimized config loading (reduced from 28 jq calls to 2)
- Optimized `json_filter_questions()` to reduce subprocess calls
- Replaced Python with pure bash for JSON output in inject-status
- Refactored hook event reading from stdin instead of CLI param

### Fixed
- Fix `set -e` exit with `&&` conditional assignment patterns
- Fix questions suffix length calculation (18 to 19 chars)
- Fix stop hook spam when usage limit is hit
- Fix panel cycling when no agents are running
- Fix function ordering and test dependency issues
- Fix PostToolUse hook event parameter

### Removed
- Removed STATUS.md-based status injection (replaced with hooks)
- Removed outdated analysis doc and profiling scripts
- Removed unused `_config_get` function

## [0.1.2] - 2026-01-17

### Added
- Tabbed Settings UI in `ib watch` (Project Settings and User Settings tabs)
- Agent count summary to `ib list` and `ib tree` output
- Update notification in `ib watch` header (checks once per hour)
- Cross-platform JSON engine support with jq fallback
- User-level config support (`~/.ittybitty.json`)
- Uncommitted changes check before merge operations
- Tests for user-level config and JSON operations

### Changed
- Swapped tab order: Project Settings before User Settings in setup dialog
- Improved FPS targeting with 3-frame rolling average
- Compact JSON output from jq for consistency
- Unified merge check logic across merge dialog, diff panel, and command

### Fixed
- Fix jq array access for numeric keypaths
- Fix remaining `set -e` safety issues in jq commands
- Fix two bugs in update notification feature
- Clamp minimum render time to 1ms to prevent rolling average reset

## [0.1.1] - 2026-01-16

### Added
- `externalDiffTool` config option for external diff viewers
- Consistent git repo check across all commands

## [0.1.0] - 2026-01-16

### Added
- Initial release of ittybitty multi-agent orchestration tool
- Core commands: `new-agent`, `list`, `send`, `look`, `status`, `diff`, `kill`, `resume`, `merge`
- `ib watch` dashboard with real-time agent monitoring
- `ib tree` for hierarchical agent visualization
- Git worktree isolation for each agent
- Tmux session management for persistent agent processes
- Agent communication via `ib send` with message prefixing
- Manager and worker agent types with different capabilities
- Watchdog monitoring for agent state changes
- Custom prompts support (`.ittybitty/prompts/`)
- User hooks (`post-create-agent`)
- Agent hooks (Stop, PreToolUse, PermissionRequest)
- Path isolation enforcement via PreToolUse hooks
- Permission configuration via `.ittybitty.json`
- `ib config` command for managing settings
- `noFastForward` config option for merge commits
- `autoCompactThreshold` setting for automatic context compaction
- Archive system for completed agent logs
- Session and weekly usage percentage display
- Setup dialog in `ib watch` (press 'h')
- Quick jump menu for navigation between agents
- Send message dialog with 'send to all agents' toggle
- Diff panel with merge readiness indicator
- Feedback dialog for user satisfaction
- Pure bash JSON helpers (removed jq dependency)
- Comprehensive test suite with fixture-driven tests

### Fixed
- State detection order for creating, compacting, and running states
- Scroll jumping during heavy agent output
- Dialog text field rendering flicker
- Tree view alignment for UTF-8 box-drawing characters
- Message delivery when target agent is busy processing
- WAITING detection to avoid matching instructions

[Unreleased]: https://github.com/adamwulf/ittybitty/compare/release/v0.1.2...HEAD
[0.1.2]: https://github.com/adamwulf/ittybitty/compare/release/0.1.1...release/v0.1.2
[0.1.1]: https://github.com/adamwulf/ittybitty/compare/release/0.1.0...release/0.1.1
[0.1.0]: https://github.com/adamwulf/ittybitty/releases/tag/release/0.1.0
