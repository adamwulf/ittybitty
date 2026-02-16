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

- **`set -e` safety**: `[[ ]] && ...` must have `|| true` unless in `if` blocks. Check `grep`, `read -t`, `(( ))` patterns.
- **Bash 3.2 compatibility**: No `${var,,}`, `declare -A`, `readarray`, `&>>`, `|&`, negative array indices.
- **Cross-platform**: `date`, `sed -i`, `grep -P`, `base64` differ between macOS and Linux.
- **Code duplication**: Search for existing helpers (`json_get`, `read_meta_field`, `format_age`, `log_agent`, `tool_matches_pattern`, etc.) that the new code might be reinventing.
- **jq/osascript consistency**: Both JSON engine paths must produce identical output.
- **Security**: Variable quoting, command injection from untrusted input.
- **Correctness**: Edge cases, return values, logic errors.
- **Tests**: New helpers need `cmd_test_*` + fixtures + test script. Existing `.expected` files updated if output changed.
