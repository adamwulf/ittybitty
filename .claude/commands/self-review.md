## Review Your Changes Before Completing

Before declaring "I HAVE COMPLETED THE GOAL", you must spawn worker agents to review your changes. Do not review your own code yourself — delegate the review to workers.

### Steps

1. Find your own agent ID (check your branch name or run `ib status`).
2. Spawn 2-3 worker agents, each focused on a specific review area from the list below. Tell each worker to run `ib diff <your-agent-id>` to get the diff, and give clear instructions about what to look for.
3. Wait for all workers to complete.
4. Fix any issues they find and commit.
5. Only then declare completion.

### Review Areas to Assign

Distribute these across your workers. Each worker should focus on 2-3 areas:

- **Correctness**: Edge cases, return values, logic errors.
- **Security**: Variable quoting, command injection from untrusted input.
- **Code duplication**: Search for existing helpers that the new code might be reinventing.
- **Tests**: Are new tests needed? Are existing tests affected by the changes?
- **Project-specific rules**: Check CLAUDE.md for coding standards, compatibility requirements, and conventions that apply to this codebase.
