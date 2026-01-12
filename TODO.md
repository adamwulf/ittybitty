# TODO

## Bugs

- [x] Agent status showing 'waiting' in tree view when actually running (fixed: `42d754d`)
  - State detection may be incorrectly identifying running agents as waiting
- [ ] Tree view has incorrect alignment when managers have workers
  - Indentation or spacing is off in hierarchical display

## Features & Enhancements

### UI/UX Improvements
- [x] Add tree mode with pane cycling (implemented: `3091ed4`)
  - Full-height bot tree pane that takes up entire tree+pane section
  - Cycle through panes without showing left/right panes
  - Tree view would be visible at all times during cycling
- [x] Press / to quick jump to an agent by name (implemented: `c957ae0`)
- [x] Add worker type to new agent dialog (implemented: `3572745`)
- [ ] Add session limit tracking to UI
- [ ] Add GitHub sponsor link into UI
- [ ] Add "are you enjoying ittybitty?" dialog prompt

### CLI Features
- [x] Add config get/set commands to ib (implemented: `6623bcd`)
  - Allow reading and modifying config values via command line

### Configuration
- [ ] Add failsafe for session limit in json config
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

- [ ] Prevent non-yolo agents from spawning agents in yolo mode
  - Need to verify if this protection exists currently
  - Non-yolo agents should not be able to escalate permissions by spawning yolo children

