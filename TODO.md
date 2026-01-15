# TODO

## Bugs

- [x] Agent status showing 'waiting' in tree view when actually running (fixed: `42d754d`)
  - State detection may be incorrectly identifying running agents as waiting
- [x] Tree view has incorrect alignment when managers have workers (fixed: `6e54813`)
  - Root cause: printf counts bytes not display chars for UTF-8 box-drawing characters
  - Fix approach: Manual padding using character count instead of printf field width
- [x] Column alignment broken in `ib watch` - state/age/model columns offset incorrectly (fixed: `6e54813`, `377b3ea`)
  - Columns after agent name (state, age, model, description) don't line up
  - May be related to variable agent name lengths
  - Visible when viewing tree with multiple agents of different name lengths

## Features & Enhancements

### UI/UX Improvements
- [x] Add tree mode with pane cycling (implemented: `3091ed4`)
  - Full-height bot tree pane that takes up entire tree+pane section
  - Cycle through panes without showing left/right panes
  - Tree view would be visible at all times during cycling
- [x] Press / to quick jump to an agent by name (implemented: `c957ae0`)
- [x] Add worker type to new agent dialog (implemented: `3572745`)
- [x] Add session limit tracking to UI (implemented: `37b7e28`, `0f3e8fe`)
- [x] Add GitHub sponsor link into UI (implemented: `28d62c9`)
- [x] Add "are you enjoying ittybitty?" dialog prompt (implemented: `5448e1a`)
- [x] Add "all agents" toggle to send message dialog (implemented: `6c2210b`)
  - When checked, send the same message to all alive agents (running, waiting, complete)
  - When unchecked, send only to the currently selected agent
  - Add keybinding (Tab or 'a') to toggle between modes
  - Update dialog UI to show current mode clearly

### CLI Features
- [x] Add config get/set commands to ib (implemented: `6623bcd`)
  - Allow reading and modifying config values via command line

### Configuration
- [x] Add failsafe for session limit in json config (already implemented: `maxAgents` in .ittybitty.json)
  - Prevent accidental API overuse
- [ ] Add messages to user-controlled Claude installed through CLAUDE.md
  - Better integration with Claude configuration

## Documentation

- [ ] Add tutorial to watch
  - Help new users understand ittybitty workflow

## Project Management

- [ ] Decide on license
  - Choose appropriate open source license

## Security & Permissions

- [x] Prevent non-yolo agents from spawning agents in yolo mode (implemented: `b340fe7`)
  - Added yolo field to meta.json for detection
  - Added security check in cmd_new_agent that blocks yolo escalation

