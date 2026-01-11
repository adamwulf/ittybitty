# TODO

## Bugs

- [ ] Agent status showing 'waiting' in tree view when actually running
  - State detection may be incorrectly identifying running agents as waiting
- [ ] Tree view has incorrect alignment when managers have workers
  - Indentation or spacing is off in hierarchical display

## Security & Permissions

- [ ] Prevent non-yolo agents from spawning agents in yolo mode
  - Need to verify if this protection exists currently
  - Non-yolo agents should not be able to escalate permissions by spawning yolo children

