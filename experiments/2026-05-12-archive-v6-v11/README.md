# Archived: v6–v11 Wrapper LVS-Fix Experiments (May 7–11, 2026)

These files are from a failed series of attempts to eliminate the 208 cosmetic LVS pin-match errors on `user_project_wrapper`. **None succeeded.** They are archived here for reference; do not re-introduce them into the build.

## Why this is archived (not deleted)

Future sessions may be tempted to re-try this approach. These files document exactly what was tried and exactly what failed, so we don't repeat the exercise. See also:
- `../../../docs/hardening-results.md` — "Wrapper Hardening Attempts (May 7-11, 2026)" section
- `~/.claude/projects/-home-cah-r2d2-code-fpga-claude-project-ldpc-optical/memory/wrapper-lvs-cosmetic.md`

## Contents

### `verilog_rtl/manual_tieoffs.vh`
206 explicit `sky130_fd_sc_hd__conb_1` instantiations, one per wrapper output pin (`io_out[37:0]`, `io_oeb[37:0]`, `la_data_out[127:0]`, `user_irq[2:1]`). Was `\`include`-ed from `verilog/rtl/user_project_wrapper.v` during the v8 attempt.

**Why it failed:** Magic's SPICE-extraction step resolves each `conb_1` output back to the global VPWR / VGND net, collapsing all 206 distinct logical nets into 2 shared power nets at the extracted layout level. The wrapper's output ports lose their individual labels in extraction, producing the same 208 pin-match errors as the bulk `assign la_data_out = 128'b0` tieoff it was meant to replace.

### `openlane_wrapper/manual_placements.json`
Hand-coded `MANUAL_GLOBAL_PLACEMENTS` for the 206 tieoff cells, distributing them along the wrapper's edges adjacent to their target pins. Used by the v8 attempt with the wrapper config's `mprj` location shifted from `[60, 15]` → `[60, 200]` to make room.

**Why it didn't help:** Placement doesn't change Magic's extraction behavior. The cells were placed where requested but their outputs still merged into the global power/ground nets.

### `mag/user_project_wrapper.mag`
121 MB uncompressed Magic layout from the v8 run (May 8 03:17). Replaces `mag/user_project_wrapper.mag.gz` which contains the v5-era wrapper layout.

### `spef/multicorner/user_project_wrapper.{max,min,nom}.spef`
Wrapper-level SPEFs from the v8 run (May 8 03:17), ~15 MB each. The v5-era wrapper SPEFs that should ship with the submission have different blob hashes and would need to be restored from gitea commit `32b469d` if needed for `cf verify`.

### `user_project_wrapper.gds`
Uncompressed wrapper GDS from the v8 run (May 8 03:17), 436 MB. Originally written to `gds/user_project_wrapper.gds`, which conflicted with HEAD's `gds/user_project_wrapper.gds.gz` and broke `cf precheck` with `Both compressed and uncompressed GDS exist. Keep only one.` The committed `.gz` (commit `8cc8414`, May 7 PDN swap) is the canonical wrapper GDS for the submission. This uncompressed v8 copy is preserved here for reference only and not tracked in git.

## Per-run summary

| Run | Date | Strategy | Outcome |
|-----|------|----------|---------|
| v6 | May 7 | First post-PDN-swap retry; same wrapper RTL as v5 | Flow completed; KLayout crashed in final manufacturability step; same 208 LVS errors |
| v7 | May 7 | Retry of v6 | Aborted mid-routing on `[DRT-0349]` LEF58_ENCLOSURE warnings |
| **v8** | May 8 | `manual_tieoffs.vh` + `manual_placements.json` + mprj at `[60, 200]` | Flow completed; STA failed on `min_ss_100C_1v60` + `nom_tt_025C_1v80`; **same 208 LVS errors** |
| v9 | May 9 | Same as v8 + `ERROR_ON_TR_DRC=false` to push through routing | 1780 routing DRC errors (deferred) |
| v10 | May 11 | Variant placement tweaks | 1362 routing DRC errors (deferred) |
| v11 | May 11 | One more attempt | Interrupted at step 01 (yosys-jsonheader) |

## What to do instead

The May 12, 2026 pivot: stop trying to fix LVS through wrapper hardening. Document the 208 errors as cosmetic in `chip_ignite/docs/LVS_WAIVER.md`, verify HEAD's signoff with `cf precheck` + `cf verify`, then `cf push` to ChipFoundry SFTP before the May 13 deadline.

If a future shuttle requires clean LVS, the only viable approach is to drive the 206 unused wrapper outputs from inside `ldpc_decoder_top` as dummy zero ports — this forces distinct extracted macro pins. Cost: full macro re-harden with the risk of Yosys non-determinism breaking Run 6's golden timing. Don't attempt this under deadline pressure.
