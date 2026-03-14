#!/bin/bash
# Export hardened macro views from a successful run to chip_ignite locations
# Usage: ./export_views.sh <run_name>
# Example: ./export_views.sh antenna_iterative

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHIP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_NAME="${1:?Usage: $0 <run_name>}"
RUN_DIR="$SCRIPT_DIR/runs/$RUN_NAME"

if [ ! -d "$RUN_DIR" ]; then
    echo "ERROR: Run directory not found: $RUN_DIR"
    exit 1
fi

echo "=== Exporting views from run: $RUN_NAME ==="
echo "Run dir: $RUN_DIR"
echo "Chip dir: $CHIP_DIR"
echo ""

# Find artifacts by stage name pattern
find_artifact() {
    local pattern="$1"
    local file="$2"
    local result
    result=$(find "$RUN_DIR" -path "*$pattern*/$file" -type f 2>/dev/null | head -1)
    if [ -z "$result" ]; then
        echo "WARNING: Not found: *$pattern*/$file"
        return 1
    fi
    echo "$result"
}

# GDS
echo "--- GDS ---"
GDS=$(find_artifact "magic-streamout" "ldpc_decoder_top.gds")
if [ -n "$GDS" ]; then
    cp -v "$GDS" "$CHIP_DIR/gds/"
fi

# LEF
echo "--- LEF ---"
LEF=$(find_artifact "magic-writelef" "ldpc_decoder_top.lef")
if [ -n "$LEF" ]; then
    cp -v "$LEF" "$CHIP_DIR/lef/"
fi

# Gate-level netlist
echo "--- GL Netlist ---"
GL=$(find_artifact "openroad-fillinsertion" "ldpc_decoder_top.pnl.v")
if [ -n "$GL" ]; then
    cp -v "$GL" "$CHIP_DIR/verilog/gl/ldpc_decoder_top.v"
fi

# SPEF (3 corners)
echo "--- SPEF ---"
mkdir -p "$CHIP_DIR/spef/multicorner"
for corner in min nom max; do
    SPEF=$(find "$RUN_DIR" -path "*openroad-rcx*/${corner}*/*.spef" -type f 2>/dev/null | head -1)
    if [ -n "$SPEF" ]; then
        cp -v "$SPEF" "$CHIP_DIR/spef/multicorner/ldpc_decoder_top.${corner}.spef"
    else
        echo "WARNING: SPEF not found for corner: $corner"
    fi
done

# LIB
echo "--- LIB ---"
LIB=$(find "$RUN_DIR" -path "*openroad-stapostpnr*/nom_tt_025C_1v80/*.lib" -type f 2>/dev/null | head -1)
if [ -n "$LIB" ]; then
    cp -v "$LIB" "$CHIP_DIR/lib/ldpc_decoder_top.lib"
else
    echo "WARNING: LIB not found"
fi

# DEF
echo "--- DEF ---"
DEF=$(find_artifact "openroad-detailedrouting" "ldpc_decoder_top.def")
if [ -n "$DEF" ]; then
    cp -v "$DEF" "$CHIP_DIR/def/ldpc_decoder_top.def"
else
    echo "WARNING: DEF not found"
fi

echo ""
echo "=== Export complete ==="
echo "Verify with: ls -la $CHIP_DIR/{gds,lef,def,lib,spef/multicorner,verilog/gl}/ldpc_decoder_top*"
