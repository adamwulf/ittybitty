#!/bin/bash
# Profile the actual config loading sequence

set -e

echo "=== Config Loading Profile ==="
echo ""

# Time a single subprocess call
time_ms() {
    local start=$(python3 -c "import time; print(int(time.time() * 1000))")
    "$@" >/dev/null 2>&1 || true
    local end=$(python3 -c "import time; print(int(time.time() * 1000))")
    echo $((end - start))
}

PROJECT_FILE=".ittybitty.json"
USER_FILE="$HOME/.ittybitty.json"

echo "Config files:"
[[ -f "$PROJECT_FILE" ]] && echo "  Project: $PROJECT_FILE (exists)" || echo "  Project: $PROJECT_FILE (not found)"
[[ -f "$USER_FILE" ]] && echo "  User: $USER_FILE (exists)" || echo "  User: $USER_FILE (not found)"
echo ""

# Simulate _config_get behavior for each key
# Each call does: json_has on project, if not found json_has on user, then json_get
CONFIG_KEYS=(
    "permissions.manager.allow"
    "permissions.manager.deny"
    "permissions.worker.allow"
    "permissions.worker.deny"
    "createPullRequests"
    "maxAgents"
    "model"
    "fps"
    "allowAgentQuestions"
    "externalDiffTool"
    "autoCompactThreshold"
    "noFastForward"
    "hooks.injectStatus"
    "hooks.statusVisible"
)

echo "Timing individual jq calls:"
CALL_COUNT=0
TOTAL_TIME=0

# Convert keypath to jq path
keypath_to_jq() {
    local keypath="$1"
    echo ".${keypath//./\".\"}"
}

for key in "${CONFIG_KEYS[@]}"; do
    jq_path=$(keypath_to_jq "$key")

    # json_has equivalent (check if key exists)
    if [[ -f "$PROJECT_FILE" ]]; then
        t=$(time_ms jq -e "$jq_path" "$PROJECT_FILE")
        ((CALL_COUNT++)) || true
        ((TOTAL_TIME += t)) || true
    fi

    if [[ -f "$USER_FILE" ]]; then
        t=$(time_ms jq -e "$jq_path" "$USER_FILE")
        ((CALL_COUNT++)) || true
        ((TOTAL_TIME += t)) || true
    fi
done

echo "  jq calls made: $CALL_COUNT"
echo "  Total jq time: ${TOTAL_TIME} ms"
echo "  Avg per call: $((TOTAL_TIME / CALL_COUNT)) ms"
echo ""

echo "=== Optimized Approach (read file once) ==="
START=$(python3 -c "import time; print(int(time.time() * 1000))")

# Read both config files once
PROJECT_JSON=""
USER_JSON=""
[[ -f "$PROJECT_FILE" ]] && PROJECT_JSON=$(<"$PROJECT_FILE")
[[ -f "$USER_FILE" ]] && USER_JSON=$(<"$USER_FILE")

# Parse all values in one jq call (if project config exists)
if [[ -n "$PROJECT_JSON" ]]; then
    ALL_VALUES=$(echo "$PROJECT_JSON" | jq -r '
        {
            "permissions.manager.allow": (.permissions.manager.allow // "[]"),
            "permissions.manager.deny": (.permissions.manager.deny // "[]"),
            "permissions.worker.allow": (.permissions.worker.allow // "[]"),
            "permissions.worker.deny": (.permissions.worker.deny // "[]"),
            "createPullRequests": (.createPullRequests // "false"),
            "maxAgents": (.maxAgents // "10"),
            "model": (.model // ""),
            "fps": (.fps // "10"),
            "allowAgentQuestions": (.allowAgentQuestions // "true"),
            "externalDiffTool": (.externalDiffTool // ""),
            "autoCompactThreshold": (.autoCompactThreshold // ""),
            "noFastForward": (.noFastForward // "false"),
            "hooks.injectStatus": (.hooks.injectStatus // "true"),
            "hooks.statusVisible": (.hooks.statusVisible // "true")
        } | to_entries[] | "\(.key)=\(.value)"
    ' 2>/dev/null) || true
fi

END=$(python3 -c "import time; print(int(time.time() * 1000))")
OPTIMIZED_TIME=$((END - START))

echo "  Single jq call time: ${OPTIMIZED_TIME} ms"
echo "  Speedup: $(echo "scale=1; $TOTAL_TIME / $OPTIMIZED_TIME" | bc)x faster"
echo ""

echo "=== Summary ==="
echo "Current approach: ~${TOTAL_TIME} ms for config loading"
echo "Optimized approach: ~${OPTIMIZED_TIME} ms for config loading"
echo "Potential savings: $((TOTAL_TIME - OPTIMIZED_TIME)) ms"
