# LDPC Decoder for Photon-Starved Optical Communication

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

## Overview

A soft-input LDPC decoder ASIC targeting the ChipFoundry chipIgnite shuttle (SkyWater 130nm, Caravel harness). The design targets photon-starved free-space optical communication links such as deep-space optical downlinks, underwater optical modems, and quantum key distribution post-processing. By accepting soft log-likelihood ratio (LLR) inputs rather than hard bit decisions, the decoder preserves 2-3 dB of coding gain that would otherwise be lost at extremely low photon counts. The entire decoder fits in approximately 1.5 mm^2 of the Caravel user area with no multipliers -- only adders, comparators, and shift registers.

## Application

The target channel is a photon-counting optical link using Geiger-mode avalanche photodiode (GMAPD) detectors, such as the BAE Systems single-photon detector array. At photon-starved signal levels (0.5-5 photons per slot), the receiver produces soft detection statistics governed by Poisson counting noise. Channel LLRs are computed from these statistics by the Caravel PicoRV32 management core and written to the decoder via Wishbone. The rate-1/8 LDPC code provides extreme redundancy (32 information bits encoded into 256 coded bits), enabling reliable communication well below 1 photon per bit -- approaching the theoretical limits of optical communication.

## Architecture

```
Caravel SoC (Sky130, chipIgnite)
+=================================================+
|  PicoRV32 (Management Core)                     |
|      |                                          |
|      | Wishbone B4 bus                          |
|      v                                          |
|  ldpc_decoder_top (~1.5 mm^2)                   |
|    +-- wishbone_interface (register map)         |
|    +-- ldpc_decoder_core (layered min-sum)       |
|    |     +-- llr_ram (256 x 6-bit)               |
|    |     +-- msg_ram (edges x 6-bit)             |
|    |     +-- vn_update_array [Z=32]              |
|    |     +-- cn_update_array [Z=32]              |
|    |     +-- barrel_shifter_z32                  |
|    |     +-- iteration_controller                |
|    |     +-- syndrome_checker                    |
|    +-- hard_decision_out (32 decoded bits)        |
|                                                  |
|  Data flow: LLRs in -> layered decode -> 32 bits |
+=================================================+
```

The decoder uses layered (row-serial) scheduling of the offset min-sum algorithm. Each layer processes one row of the 7x8 QC-LDPC base matrix, updating variable-node beliefs immediately rather than waiting for a full flooding iteration. This roughly halves the iteration count needed for convergence. A barrel shifter handles the quasi-cyclic shift operations at the Z=32 lifting factor.

The design uses a single clock domain (`wb_clk_i` from Caravel) and contains no multipliers or lookup tables -- all arithmetic is add/compare/select. This makes it well suited for area-constrained ASIC implementation on Sky130.

## Code Parameters

| Parameter | Value |
|-----------|-------|
| Code type | QC-LDPC (quasi-cyclic) |
| Rate | 1/8 (k=32, n=256) |
| Base matrix | 7x8 IRA staircase |
| Lifting factor Z | 32 |
| Quantization | 6-bit signed LLR |
| Algorithm | Offset min-sum (beta ~ 0.5) |
| Scheduling | Layered (row-serial) |
| Max iterations | 30 (with early termination) |
| Convergence | ~2x faster than flooding schedule |

## Performance

| Metric | Value |
|--------|-------|
| Target clock | 50-75 MHz (Sky130) |
| Cycles per codeword | ~630 (30 iterations x 21 cycles/iter) |
| Codeword latency | 8.4-12.6 us |
| Decoded throughput | ~2.5-3.8 Mbps |
| Estimated area | ~1.5 mm^2 (of 10.3 mm^2 user area) |
| Power | TBD (post-synthesis) |
| Coding gain vs hard | +2-3 dB at BER 10^-5 |

## Register Map

All registers are accessed via Wishbone B4 at word-aligned addresses relative to the decoder base address.

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | CTRL | R/W | [0]=start, [1]=early_term_en, [12:8]=max_iter |
| 0x04 | STATUS | R | [0]=busy, [1]=converged, [12:8]=iter_used, [23:16]=syndrome_wt |
| 0x10-0xDC | LLR_IN | W | 52 words: 5 LLRs packed per 32-bit word (6 bits each) |
| 0x50 | DECODED | R | 32 decoded information bits |
| 0x54 | VERSION | R | 0x1D010001 (LDPC v1.0, rev 1) |

**Typical usage from PicoRV32 firmware:**
1. Write 256 quantized LLRs to LLR_IN (52 Wishbone writes)
2. Write CTRL to start decode (max_iter=30, early_term=1)
3. Poll STATUS until busy=0
4. Read DECODED bits and syndrome weight

## Verification Status

| Layer | Status | Details |
|-------|--------|---------|
| Standalone Verilator | PASS (2/2) | VERSION register read, clean codeword decode |
| Vector-driven Verilator | PASS (20/20) | Bit-exact match vs Python behavioral model |
| cocotb Caravel integration | In progress | Wishbone access, functional decode tests |
| Gate-level simulation | Pending | Post-synthesis netlist, requires OpenLane hardening |
| Static timing analysis | Pending | Target: 50 MHz (20 ns), stretch goal 75 MHz |

The Python behavioral model (`model/ldpc_sim.py`) generates test vectors at multiple SNR points covering the Poisson channel at lambda_s = 0.5, 1.0, 2.0, and 5.0 photons per slot. All 20 vector-driven tests produce bit-exact agreement between RTL and the Python reference.

## Directory Structure

```
chip_ignite/
  verilog/
    rtl/                  RTL sources (decoder + Caravel wrapper)
      ldpc_decoder_top.sv     Top-level with Wishbone interface
      ldpc_decoder_core.sv    Layered min-sum decode engine
      wishbone_interface.sv   Register map and bus logic
      user_project_wrapper.v  Caravel integration wrapper
    dv/
      cocotb/ldpc_tests/  cocotb testbenches for Caravel sim
    gl/                   Gate-level netlists (post-hardening)
    includes/             File lists for simulation
  openlane/
    ldpc_decoder_top/     OpenLane config, SDC, pin ordering
    user_project_wrapper/ Wrapper hardening config
  firmware/
    ldpc_demo/            PicoRV32 bare-metal demo firmware
  docs/                   Sphinx documentation, AI disclosure
  gds/                    GDSII output (post-hardening)
  lef/                    LEF macro definitions
  sdc/                    Timing constraints
```

The parent directory (`ldpc_optical/`) contains additional resources:
- `rtl/` -- standalone RTL (pre-integration)
- `tb/` -- Verilator testbenches with vector-driven tests
- `model/` -- Python behavioral model and test vector generation
- `data/` -- H-matrix definitions and simulation results
- `docs/` -- Design documentation and project report

## Building and Running

### Standalone RTL verification (Verilator)

```bash
# Basic functional tests (VERSION read + clean decode)
cd ../tb && make sim

# 20-vector cross-check against Python behavioral model
cd ../tb && make sim_vectors
```

### Caravel flow (requires ChipFoundry CLI)

```bash
# One-time setup
cf init
cf setup

# Harden the decoder macro
cf harden ldpc_decoder_top

# Integrate into Caravel wrapper
cf harden user_project_wrapper

# Configure GPIO pins
cf gpio-config

# Run cocotb verification (RTL)
cf verify ldpc_basic

# Run gate-level simulation
cf verify ldpc_basic --sim gl

# Shuttle compliance precheck
cf precheck
```

### Python behavioral model

```bash
cd ../model
python3 ldpc_sim.py
```

## Roadmap

**Current (Approach A -- Minimal Viable Submission):**
Wishbone-attached decoder verified in simulation. PicoRV32 firmware injects test LLRs, decodes, and reports results over UART. No external optical hardware required for the demo.

**Future (Approach B -- Full Optical Frontend):**
Populated PCBA with SiPM or GMAPD detector, transimpedance amplifier (AD8015), and fast comparator. External RP2040 MCU computes real-time LLRs from photon counts. Bench-scale free-space optical link demo (1-5 m).

**Future (Approach C -- Silicon Return):**
After chipIgnite silicon returns (Oct/Nov 2026): build full reference board, demonstrate free-space optical link with BAE Systems GMAPD detector, and characterize real-silicon BER performance against simulation predictions. Target applications include CubeSat optical downlinks and underwater optical modems.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full text.

## AI Disclosure

Portions of this project were developed with AI assistance. See [docs/ai-disclosure.md](docs/ai-disclosure.md) for details.
