#!/bin/bash
RUN_DIR="ldpc_decoder_top/runs/run6_reuse_bp"
echo "=== Run 6 Reuse BP (balanced_popcount synth, hold 0.4/0.2) ==="
STAGES=$(find "$RUN_DIR" -maxdepth 1 -type d | grep -c '/[0-9]')
LATEST=$(ls -td "$RUN_DIR"/[0-9]* 2>/dev/null | head -1)
echo "Stages completed: $STAGES / 78"
echo "Latest stage: $LATEST"
echo ""
if [ -s "$RUN_DIR/error.log" ]; then
    echo "ERROR:"
    cat "$RUN_DIR/error.log"
elif docker ps --format '{{.Status}}' 2>/dev/null | grep -q Up; then
    echo "(Still running...)"
    docker ps --format '{{.Status}}' 2>/dev/null
else
    echo "(Docker stopped - run may be complete or failed)"
    if [ -f "$RUN_DIR/state_out.json" ]; then echo "SUCCESS - state_out.json exists"; fi
fi
