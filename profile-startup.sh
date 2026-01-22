#!/bin/bash
# Profile ib watch startup components
# Measures time for each initialization step

set -e

echo "=== ib watch Startup Profiling ==="
echo ""

# Helper to time a command
time_cmd() {
    local label="$1"
    shift
    local start=$(python3 -c "import time; print(int(time.time() * 1000))")
    "$@" >/dev/null 2>&1 || true
    local end=$(python3 -c "import time; print(int(time.time() * 1000))")
    local elapsed=$((end - start))
    printf "  %-40s %5d ms\n" "$label:" "$elapsed"
    echo "$elapsed"
}

TOTAL_START=$(python3 -c "import time; print(int(time.time() * 1000))")

echo "1. Dependency Checks"
time_cmd "command -v git" command -v git
time_cmd "command -v tmux" command -v tmux
time_cmd "command -v claude" command -v claude
echo ""

echo "2. Git Operations (init_paths)"
time_cmd "git rev-parse --git-dir" git rev-parse --git-dir
time_cmd "git rev-parse --git-common-dir" git rev-parse --git-common-dir
time_cmd "git rev-parse --show-toplevel" git rev-parse --show-toplevel
echo ""

echo "3. Repo ID Check"
if [[ -f ".ittybitty/repo-id" ]]; then
    time_cmd "cat .ittybitty/repo-id" cat .ittybitty/repo-id
else
    time_cmd "openssl rand -hex 4" openssl rand -hex 4
fi
echo ""

echo "4. Agent Access Checks (enforce_command_access)"
time_cmd "tmux display-message (if in tmux)" tmux display-message -p '#{session_name}'
echo ""

echo "5. Directory Checks"
time_cmd "mkdir -p .ittybitty (if needed)" mkdir -p .ittybitty
echo ""

echo "6. JSON Engine Detection"
if command -v jq >/dev/null 2>&1; then
    echo "  Using: jq (fast)"
    time_cmd "jq --version" jq --version
else
    echo "  Using: osascript (slow)"
    time_cmd "osascript -l JavaScript" osascript -l JavaScript -e "1+1"
fi
echo ""

echo "7. Config Loading (load_config) - Simulated"
# Each config key requires json_has + json_get calls
CONFIG_FILE=".ittybitty.json"
USER_CONFIG="$HOME/.ittybitty.json"

echo "  Checking config files..."
[[ -f "$CONFIG_FILE" ]] && echo "    Project config: exists" || echo "    Project config: not found"
[[ -f "$USER_CONFIG" ]] && echo "    User config: exists" || echo "    User config: not found"

if command -v jq >/dev/null 2>&1; then
    if [[ -f "$CONFIG_FILE" ]]; then
        time_cmd "jq query (project config)" jq -r '.fps // empty' "$CONFIG_FILE"
    fi
    if [[ -f "$USER_CONFIG" ]]; then
        time_cmd "jq query (user config)" jq -r '.fps // empty' "$USER_CONFIG"
    fi
else
    # osascript JSON parsing is slower
    if [[ -f "$CONFIG_FILE" ]]; then
        JSON=$(cat "$CONFIG_FILE")
        B64=$(echo -n "$JSON" | base64)
        time_cmd "osascript JSON parse" osascript -l JavaScript -e "
            ObjC.import('Foundation');
            var decoded = $.NSString.alloc.initWithDataEncoding(
                $.NSData.alloc.initWithBase64EncodedStringOptions('$B64', 0),
                $.NSUTF8StringEncoding
            ).js;
            JSON.parse(decoded).fps || '';
        "
    fi
fi
echo "  Note: load_config makes ~14 config lookups"
echo ""

echo "8. Agent Metadata Validation (validate_agent_metadata)"
AGENTS_DIR=".ittybitty/agents"
if [[ -d "$AGENTS_DIR" ]]; then
    AGENT_COUNT=$(ls -d "$AGENTS_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')
    echo "  Active agents: $AGENT_COUNT"
    if [[ $AGENT_COUNT -gt 0 ]]; then
        # Time reading one meta.json with json_get
        FIRST_AGENT=$(ls -d "$AGENTS_DIR"/*/ 2>/dev/null | head -1)
        if [[ -n "$FIRST_AGENT" && -f "$FIRST_AGENT/meta.json" ]]; then
            if command -v jq >/dev/null 2>&1; then
                time_cmd "jq query meta.json (x$AGENT_COUNT)" jq -r '.created_epoch // empty' "$FIRST_AGENT/meta.json"
            fi
        fi
    fi
else
    echo "  No agents directory"
fi
echo ""

echo "9. Setup Checks (watch_check_all_setup)"
SETTINGS_FILE=".claude/settings.local.json"
echo "  a) Hooks status check:"
if [[ -f "$SETTINGS_FILE" ]]; then
    if command -v jq >/dev/null 2>&1; then
        time_cmd "jq hooks check" jq -r '.hooks.PreToolUse // []' "$SETTINGS_FILE"
    fi
else
    echo "    No settings file (skip)"
fi

echo "  b) CLAUDE.md ittybitty check:"
if [[ -f "CLAUDE.md" ]]; then
    time_cmd "grep CLAUDE.md (x2)" bash -c "grep -q '^<ittybitty>$' CLAUDE.md && grep -q '^</ittybitty>$' CLAUDE.md"
else
    echo "    No CLAUDE.md (skip)"
fi

echo "  c) .gitignore check:"
if [[ -f ".gitignore" ]]; then
    time_cmd "grep .gitignore" grep -q '\.ittybitty' .gitignore
else
    echo "    No .gitignore (skip)"
fi
echo ""

echo "10. Usage API Fetch (watch_refresh_usage)"
echo "  a) Keychain access:"
time_cmd "security find-generic-password" security find-generic-password -s "Claude Code-credentials" -w
echo "  b) API call (not executed - would add network latency)"
echo "  c) Timestamp parsing (perl):"
time_cmd "perl Time::Piece" perl -MTime::Piece -e 'print time'
echo ""

TOTAL_END=$(python3 -c "import time; print(int(time.time() * 1000))")
TOTAL_TIME=$((TOTAL_END - TOTAL_START))
echo "==================================="
printf "TOTAL PROFILING TIME: %d ms\n" "$TOTAL_TIME"
echo ""
echo "Note: This profiles individual operations, not the actual 'ib watch' startup."
echo "Actual startup may differ due to caching and order of operations."
