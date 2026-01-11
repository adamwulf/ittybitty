# TODO

## Bugs

- [ ] Agent status showing 'waiting' in tree view when actually running
  - State detection may be incorrectly identifying running agents as waiting
- [ ] Tree view has incorrect alignment when managers have workers
  - Indentation or spacing is off in hierarchical display

## Features & Enhancements

### UI/UX Improvements
- [ ] Add tree mode with pane cycling
  - Full-height bot tree pane that takes up entire tree+pane section
  - Cycle through panes without showing left/right panes
  - Tree view would be visible at all times during cycling
- [ ] Press / to quick jump to an agent by name
- [ ] Add worker type to new agent dialog
- [ ] Add session limit tracking to UI
- [ ] Add GitHub sponsor link into UI
- [ ] Add "are you enjoying ittybitty?" dialog prompt

### CLI Features
- [ ] Add config get/set commands to ib
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

