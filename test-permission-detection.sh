#!/bin/bash
# test-permission-detection.sh
# Test script to verify we can detect the workspace trust dialog

echo "Testing permissions screen detection..."
echo ""

# Spawn a test agent
echo "1. Spawning test agent..."
agent_id=$(ib new-agent "test permissions detection" | tail -1)
echo "   Agent ID: $agent_id"

# Wait briefly to catch the permissions dialog
echo "2. Waiting 1.5 seconds (to catch dialog before auto-accept)..."
sleep 1.5

# Capture output early
echo "3. Capturing tmux output (early capture)..."
session="ittybitty-${agent_id}"
output_early=$(tmux capture-pane -t "$session" -p -S -50 2>/dev/null)

# Wait for auto-accept to process
echo "4. Waiting another 4 seconds (after auto-accept)..."
sleep 4

# Capture again to see post-accept state
echo "5. Capturing tmux output (late capture)..."
output_late=$(tmux capture-pane -t "$session" -p -S -50 2>/dev/null)

# Use early capture for testing
output="$output_early"

# Test detection patterns on early capture
echo "6. Testing detection patterns (EARLY capture at 1.5s):"
echo ""

if echo "$output" | grep -qiE "Enter to confirm"; then
    echo "   ✓ Pattern 'Enter to confirm' detected"
else
    echo "   ✗ Pattern 'Enter to confirm' NOT detected"
fi

if echo "$output" | grep -qiE "trust this workspace"; then
    echo "   ✓ Pattern 'trust this workspace' detected"
else
    echo "   ✗ Pattern 'trust this workspace' NOT detected"
fi

if echo "$output" | grep -qiE "Do you trust"; then
    echo "   ✓ Pattern 'Do you trust' detected"
else
    echo "   ✗ Pattern 'Do you trust' NOT detected"
fi

echo ""
echo "7. Early capture (last 20 lines at 1.5s):"
echo "----------------------------------------"
echo "$output_early" | tail -20
echo "----------------------------------------"
echo ""
echo "8. Late capture (last 20 lines at 5.5s):"
echo "----------------------------------------"
echo "$output_late" | tail -20
echo "----------------------------------------"

# Cleanup
echo ""
echo "9. Cleaning up..."
ib kill "$agent_id" --force

echo ""
echo "Test complete!"
