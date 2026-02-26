#!/bin/bash
# Exploratory test: how does parse_state perform on just the last agent message?
#
# Simulates what would happen if we passed last_assistant_message (from the Stop
# hook JSON input) to parse_state instead of the full tmux capture.
#
# For each parse-state fixture:
#   1. Extract the "last agent message" (text after last user prompt, stripped of
#      tmux UI chrome: ⏺ markers, tool calls, spinners, status bar, logo)
#   2. Run parse_state on that extracted text
#   3. Compare against expected state (from filename) and full-tmux state
#
# Output categories:
#   SAME   - message-only gives same result as full-tmux (and matches expected)
#   DIFF   - message-only gives different result than full-tmux
#   EMPTY  - no agent message text could be extracted from fixture

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

SAME=0
DIFF=0
EMPTY=0

# Temp file for passing extracted messages to ib parse-state (which requires a file path)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# Extract the last agent message text from a tmux capture fixture.
# Mimics what last_assistant_message in the Stop hook JSON would contain:
# - Text Claude wrote in its LAST response turn only (resets on each user prompt ❯)
# - No ⏺ markers (those are Claude Code UI decorations, not message content)
# - No tool calls, no tool output, no spinners, no status bar, no logo
#
# Key insight: last_assistant_message is raw text. The ⏺ bullet prefix only
# appears in the terminal rendering, not in the actual message JSON field.
extract_last_message() {
    local content="$1"

    # Step 1: Remove status bar area.
    # The status bar starts at the first ────── separator line.
    # Everything after that first separator is status chrome, not message content.
    local sep="────────────────────────────────────────────────────────────"
    content="${content%%${sep}*}"

    # Step 2: Process line-by-line, collecting only message text.
    # Reset result on each user prompt (❯) so we keep only the LAST turn.
    # Strip ⏺ prefix (UI decoration). Skip tool calls, tool output, spinners, logo.
    local result=""
    local skip_tool_output=false   # true while inside indented tool output block
    local skip_prompt_wrap=false   # true while skipping wrapped user-prompt continuation lines

    while IFS= read -r line; do
        # ── Logo / welcome box lines (╭ │ ╰ box-drawing) ─────────────────────
        if [[ "$line" =~ ^[╭│╰] ]]; then
            continue
        fi

        # ── Thinking / hook spinner lines (✽ ✶ ✢ · ✻ ✳ at line start) ───────
        if [[ "$line" =~ ^[✽✶✢·✻✳] ]]; then
            skip_tool_output=false
            skip_prompt_wrap=false
            continue
        fi

        # ── User prompt line (❯) — reset to start collecting new turn ─────────
        if [[ "$line" == "❯"* ]] || [[ "$line" == "❯" ]]; then
            result=""
            skip_tool_output=false
            skip_prompt_wrap=true   # skip wrapped continuation of this prompt
            continue
        fi

        # ── Blank line — pass through but don't reset flags ───────────────────
        if [[ -z "$line" ]]; then
            if [[ -n "$result" ]]; then
                result="${result}"$'\n'
            fi
            # A blank line ends prompt-wrap skipping (next line is new content)
            skip_prompt_wrap=false
            continue
        fi

        # ── Skip wrapped continuation of a user prompt (indented after ❯) ─────
        if $skip_prompt_wrap && [[ "$line" =~ ^[[:space:]] ]]; then
            continue
        fi
        skip_prompt_wrap=false

        # ── Tool output line (⎿) — skip ───────────────────────────────────────
        if [[ "$line" == *"⎿"* ]]; then
            skip_tool_output=true
            continue
        fi

        # ── ⏺-prefixed line ───────────────────────────────────────────────────
        if [[ "$line" == "⏺"* ]]; then
            local rest="${line#⏺}"
            rest="${rest# }"  # strip one leading space

            # Tool invocation — skip it and following indented output
            if [[ "$rest" =~ ^(Bash|Read|Write|Edit|MultiEdit|Glob|Grep|LS|Search|Update|Task|TodoWrite|NotebookEdit|WebFetch|WebSearch|AskUserQuestion)\( ]]; then
                skip_tool_output=true
                continue
            fi

            skip_tool_output=false

            # Plain text ⏺ line — add stripped content
            if [[ -n "$result" ]]; then
                result="${result}"$'\n'"${rest}"
            else
                result="${rest}"
            fi
            continue
        fi

        # ── Indented line ──────────────────────────────────────────────────────
        if [[ "$line" =~ ^[[:space:]] ]]; then
            # Skip if inside tool output block
            if $skip_tool_output; then
                continue
            fi
            # Otherwise it's continuation of Claude's response — include it
            if [[ -n "$result" ]]; then
                result="${result}"$'\n'"${line}"
            else
                result="${line}"
            fi
            continue
        fi

        # ── Non-indented bare text line ────────────────────────────────────────
        # Clear tool-output flag — a non-indented line ends any tool output region
        skip_tool_output=false
        if [[ -n "$result" ]]; then
            result="${result}"$'\n'"${line}"
        else
            result="${line}"
        fi
    done <<< "$content"

    printf '%s' "$result"
}

# Print header
printf '%-10s %-12s %-12s %s\n' "RESULT" "EXPECTED" "MSG-STATE" "FIXTURE"
printf '%s\n' "$(printf '=%.0s' {1..70})"

for fixture in "$FIXTURE_DIR"/*.txt; do
    filename=$(basename "$fixture")
    # Expected state is the prefix before the first hyphen
    expected="${filename%%-*}"

    # Skip non-parse-state fixtures (e.g., format-age subdirectory files)
    # Only process files that have a known expected state prefix
    case "$expected" in
        complete|running|waiting|unknown|creating|rate_limited|compacting) ;;
        *) continue ;;
    esac

    # Get state from full tmux fixture
    full_state=$(ib parse-state "$fixture" 2>/dev/null)

    # Extract last agent message and get state from that
    fixture_content=$(<"$fixture")
    last_msg=$(extract_last_message "$fixture_content")

    if [[ -z "$last_msg" ]]; then
        msg_state="(empty)"
        printf '%-10s %-12s %-12s %s\n' "EMPTY" "$expected" "$msg_state" "$filename"
        EMPTY=$((EMPTY + 1))
    else
        printf '%s' "$last_msg" > "$TMPFILE"
        msg_state=$(ib parse-state "$TMPFILE" 2>/dev/null) || msg_state="(error)"

        if [[ "$msg_state" == "$full_state" ]]; then
            printf '%-10s %-12s %-12s %s\n' "SAME" "$expected" "$msg_state" "$filename"
            SAME=$((SAME + 1))
        else
            printf '%-10s %-12s %-12s %s\n' "DIFF" "$expected($full_state)" "$msg_state" "$filename"
            DIFF=$((DIFF + 1))
        fi
    fi
done

printf '\n%s\n' "$(printf '=%.0s' {1..70})"
printf 'SAME: %d   DIFF: %d   EMPTY: %d   TOTAL: %d\n' \
    "$SAME" "$DIFF" "$EMPTY" "$((SAME + DIFF + EMPTY))"
