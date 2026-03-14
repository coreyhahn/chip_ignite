#!/bin/bash
# Monitor antenna_iterative run progress
RUN_DIR="ldpc_decoder_top/runs/antenna_iterative"

cd "$(dirname "$0")/.." || exit 1

if [ ! -d "$RUN_DIR" ]; then
    echo "Run directory not found: $RUN_DIR"
    echo "Has the run been launched?"
    exit 1
fi

# Count completed stages
STAGES=$(ls -d "$RUN_DIR"/[0-9]* 2>/dev/null | wc -l)
echo "=== antenna_iterative: $STAGES stages completed ==="

# Show latest stage
LATEST=$(ls -d "$RUN_DIR"/[0-9]* 2>/dev/null | sort -V | tail -1)
if [ -n "$LATEST" ]; then
    echo "Latest: $(basename "$LATEST")"
    echo "Time:   $(stat -c '%y' "$LATEST" 2>/dev/null | cut -d. -f1)"
fi

# Check for errors in latest log
if [ -n "$LATEST" ]; then
    LOG=$(find "$LATEST" -name "*.log" -type f 2>/dev/null | head -1)
    if [ -n "$LOG" ]; then
        ERRORS=$(grep -c -i "error\|GRT-0118\|failed" "$LOG" 2>/dev/null || echo 0)
        echo "Errors in latest log: $ERRORS"
        if [ "$ERRORS" -gt 0 ]; then
            echo "--- Error lines ---"
            grep -i "error\|GRT-0118\|failed" "$LOG" | tail -5
        fi
    fi
fi

# Check for state_out.json (indicates completion)
if [ -f "$RUN_DIR/state_out.json" ]; then
    echo "=== RUN COMPLETE ==="
fi

# Check Docker status
echo ""
echo "Docker containers:"
docker ps --filter "ancestor=ghcr.io/efabless/openlane2" --format "{{.Status}}" 2>/dev/null || echo "Cannot query Docker"
