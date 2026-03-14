#!/bin/bash
# SPDX-FileCopyrightText: 2026 Corey Hahn
# SPDX-License-Identifier: Apache-2.0
# Run all 5 LDPC cocotb tests in gate-level simulation mode
# Usage: ./run_gls_tests.sh [rtl|gl]
# Default: gl (gate-level)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SIM_MODE="${1:-gl}"
CF=~/anaconda3/bin/cf

echo "=== LDPC GLS Test Suite ==="
echo "Simulation mode: $SIM_MODE"
echo "Working directory: $SCRIPT_DIR"
echo "Started: $(date)"
echo ""

# Activate cocotb venv if needed
if [ -d "$SCRIPT_DIR/venv-cocotb" ]; then
    export VIRTUAL_ENV="$SCRIPT_DIR/venv-cocotb"
    export PATH="$SCRIPT_DIR/venv-cocotb/bin:$PATH"
fi

TESTS=(ldpc_basic ldpc_noisy ldpc_max_iter ldpc_back_to_back ldpc_demo)
PASS=0
FAIL=0

for test in "${TESTS[@]}"; do
    echo "--- Running: $test ($SIM_MODE) ---"
    START=$(date +%s)
    if $CF verify "$test" --sim "$SIM_MODE" --project-root "$SCRIPT_DIR" 2>&1 | tee "/tmp/gls_${test}.log"; then
        END=$(date +%s)
        echo "PASS: $test ($(( END - START ))s)"
        PASS=$((PASS + 1))
    else
        END=$(date +%s)
        echo "FAIL: $test ($(( END - START ))s)"
        FAIL=$((FAIL + 1))
    fi
    echo ""
done

echo "=== Results ==="
echo "Passed: $PASS / ${#TESTS[@]}"
echo "Failed: $FAIL / ${#TESTS[@]}"
echo "Finished: $(date)"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed test logs:"
    for test in "${TESTS[@]}"; do
        if grep -q "FAIL\|Error\|error" "/tmp/gls_${test}.log" 2>/dev/null; then
            echo "  /tmp/gls_${test}.log"
        fi
    done
    exit 1
fi
