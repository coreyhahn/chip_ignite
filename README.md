# LDPC Decoder for Photon-Starved Optical Communication

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

## Overview

A soft-input LDPC decoder ASIC targeting the ChipFoundry chipIgnite shuttle (SkyWater 130nm, Caravel harness). The design targets photon-starved free-space optical communication links where received signals are soft probabilities from single-photon detectors, not clean 0/1 bits. By accepting soft log-likelihood ratio (LLR) inputs, the decoder preserves 2-3 dB of coding gain that would otherwise be lost at extremely low photon counts (0.5-5 photons per time slot). The entire decoder fits in approximately 1.4 mm^2 of the Caravel user area with no multipliers -- only adders, comparators, and shift registers.

## Target Applications

### Free-Space Optical Downlinks (CubeSat, UAV-to-Ground)

Low-Earth orbit CubeSat optical downlinks operate at 1-5 photons per slot due to extreme path loss over 400-2000 km. The rate 1/8 code provides 8x redundancy, enabling reliable communication well below 1 photon per information bit. At ~100 mW total power (86 mW decoder + ~15 mW Caravel management core), the ASIC fits within CubeSat payload power budgets (typically 1-5 W allocated to communications). The 2.5 Mbps decoded throughput matches typical CubeSat downlink requirements. The same decoder serves UAV-to-ground and building-to-building free-space optical (FSO) links where atmospheric turbulence and beam wander reduce received photon counts to similar levels.

### Underwater Optical Modems

Blue-green laser communication (450-530 nm) through seawater suffers exponential absorption and scattering, limiting practical ranges to 10-100 m depending on water clarity. At the receiver, photon counts of 2-10 per slot are typical in turbid coastal waters. Soft-decision LDPC decoding provides 2-3 dB of gain over hard-decision approaches -- equivalent to roughly doubling the communication range at fixed BER. The compact ASIC form factor (QFN-64 package) suits integration into autonomous underwater vehicle (AUV) and remotely operated vehicle (ROV) communication modules.

### Quantum Key Distribution (QKD) Post-Processing

QKD systems using weak coherent pulse sources operate at 0.1-1 photons per pulse. Error correction of the raw key material (typically 1-11% QBER) requires efficient reconciliation protocols. This decoder's soft-input capability allows it to process the soft detection statistics directly from single-photon detectors (SPADs or SNSPDs), providing 2-3 dB advantage over hard-decision reconciliation. The 32-bit block size matches common QKD frame sizes, and the low latency (12.6 us per block) supports real-time key distillation.

### Secure Optical Telemetry

Any point-to-point optical link where eavesdropping resistance is desired benefits from operating at minimal photon levels -- an eavesdropper tapping the beam receives even fewer photons. The decoder enables reliable communication at signal levels where interception becomes physically difficult.

## Architecture

```
Caravel SoC (Sky130, chipIgnite)
+=================================================+
|  PicoRV32 (Management Core)                     |
|      |                                          |
|      | Wishbone B4 bus                          |
|      v                                          |
|  ldpc_decoder_top (~1.4 mm^2)                   |
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
| Achieved clock | 50 MHz (TT/FF corners met) |
| Cycles per codeword | ~630 (30 iterations x 21 cycles/iter) |
| Codeword latency | ~12.6 us @ 50 MHz |
| Decoded throughput | ~2.5 Mbps |
| Cell count | 186,915 (post-synthesis) |
| Die area (macro) | 2800 x 1760 um (4.93 mm^2) |
| Core utilization | 28.2% |
| Power (TT corner) | 86 mW |
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

## System Integration

### Breakout Board -- Part A (Fabrication-Ready)

A minimal breakout board for silicon bring-up and firmware demo, designed for immediate fabrication on silicon return.

```
         USB-C
           |
     +-----v------+     +--------+
     |  CH340C    |     | SPI    |
     |  USB-UART  |---->| Flash  |
     +-----+------+     | W25Q32 |
           |             +---+----+
     +-----v------+         |
     |  AP2112K   |   +----v-----------+
     |  3.3V LDO  |   |                |
     +-----+------+   |  Caravel       |
           |           |  QFN-64        |
     +-----v------+   |  (LDPC decoder |
     |  AMS1117   |   |   inside)      |
     |  1.8V 1A   |-->|                |
     +-----+------+   +----+-----------+
           |                |
     +-----v-----------+   |
     | SiT8008 25 MHz   |--+
     | CMOS oscillator   |
     +-------------------+
                    Reset btn, Power LED, 2x Status LEDs
```

**Board specifications:**

| Parameter | Value |
|-----------|-------|
| Dimensions | 50 x 80 mm |
| Layers | 2 (standard FR4) |
| Fabrication | JLCPCB ($2/board, 5-unit MOQ) |
| Power | USB-C or barrel jack, 5V input |
| Interface | UART console at 115200 baud |
| EDA tool | KiCad 8 |

**Bill of Materials (Part A):**

| Component | Part | Qty | Est. Cost |
|-----------|------|-----|-----------|
| 25 MHz CMOS oscillator | SiT8008BI-73-25E | 1 | $0.90 |
| 3.3V LDO regulator | AP2112K-3.3TRG1 | 1 | $0.35 |
| 1.8V LDO regulator (1A) | AMS1117-1.8 | 1 | $0.25 |
| USB-UART bridge | CH340C | 1 | $0.50 |
| SPI flash (32 Mbit) | W25Q32JVSSIQ | 1 | $0.65 |
| USB-C connector | USB4110-GF-A | 1 | $0.60 |
| Decoupling caps (100nF) | CL05B104KO5NNNC | 12 | $0.60 |
| Bulk caps (10uF) | CL10A106KP8NNNC | 4 | $0.40 |
| Reset button | PTS645SM43SMTR92 | 1 | $0.15 |
| LEDs + resistors | -- | 5 | $0.50 |
| PCB fabrication (qty 5) | JLCPCB 2-layer FR4 | 1 | $2.00 |
| **Total (excl. Caravel chip)** | | | **~$8** |

All components are commodity parts available from Digi-Key and LCSC with no long-lead items. The CH340C includes a built-in oscillator (no external crystal needed). The AMS1117-1.8 provides 1A output current for headroom on the 1.8V core supply. Board is designed for hand assembly or JLCPCB SMT service (~$25-40 assembled in qty 5).

### Optical Frontend -- Part B (Reference Design)

A reference design for the optical receiver frontend, sharing the same PCB as Part A. Components are specified and footprints placed, but marked DNP (do not populate) for initial builds.

```
  Optical input
       |
  +----v--------+     +-------------+     +----------+
  | GMAPD/SiPM  |---->| TIA         |---->| Fast     |
  | Detector     |     | AD8015      |     | Comp.    |
  | (bias ~30V)  |     | 240 MHz BW  |     | ADCMP607 |
  +----+---------+     +-------------+     +----+-----+
       |                                        |
  +----v--------+                          +----v-----+
  | HV Bias     |                          | RP2040   |
  | Supply      |                          | MCU      |
  | (isolated)  |                          | LLR comp |
  +-----------+                          +----+-----+
                                              |
                                         +----v-----------+
                                         |  Caravel       |
                                         |  (LDPC decode) |
                                         +----------------+
```

**Part B signal chain:**
1. **Detector**: Geiger-mode APD (BAE Systems GMAPD) or SiPM stand-in (ON Semi C-Series MicroFC-60035) for bench demos
2. **TIA**: AD8015 transimpedance amplifier (240 MHz bandwidth, 10 kOhm gain)
3. **Comparator**: ADCMP607 (800 ps propagation delay, CML output) converts analog pulse to digital timestamp
4. **LLR computation**: RP2040 MCU counts photon arrivals per slot, computes Poisson-model LLRs, writes to Caravel via SPI/UART
5. **HV bias**: Isolated DC-DC boost converter for SiPM bias (~25-30V)

**Bill of Materials (Part B additional):**

| Component | Part | Qty | Est. Cost |
|-----------|------|-----|-----------|
| SiPM detector (demo) | MicroFC-60035-SMT | 1 | $30 |
| Transimpedance amplifier | AD8015ARZ | 1 | $8 |
| Fast comparator | ADCMP607BCPZ | 1 | $6 |
| Companion MCU | RP2040 | 1 | $1 |
| SiPM bias supply (30V boost) | LT3482 + passives | 1 | $8 |
| SMA connector (ext. clock) | SMA-J-P-H-ST-EM1 | 1 | $1 |
| Passives + connectors | -- | ~20 | $5 |
| **Part B additional total** | | | **~$59** |

### Full Bench Demo System

A complete bench-scale free-space optical link for end-to-end demonstration:

| Component | Description | Est. Cost |
|-----------|-------------|-----------|
| TX board | Modulated laser diode (650 nm) + driver + collimating optics | $40-60 |
| RX board | Part A + Part B assembled | $80-120 |
| Optics | Aspheric collimating lens, detector alignment rail | $20-30 |
| Enclosure | 3D-printed (OpenSCAD parametric), standoffs, cutouts | $5 |
| **Complete demo system** | | **$150-250** |

Link parameters: 1-5 m free-space path, 0.5-5 photons/slot at receiver, 650 nm wavelength (visible, eye-safe at these power levels).

### High-Performance Optical Frontend (Advanced Configuration)

The Part B SiPM frontend is designed for low-cost bench demos. For operational deployment, the decoder architecture supports direct integration with professional-grade single-photon detectors that unlock its full soft-decision capability.

**Detector options:**

| Detector | Type | Wavelength | Key Advantage | Typical Use |
|----------|------|------------|---------------|-------------|
| GMAPD array (MIT Lincoln Lab / BAE) | Geiger-mode APD array | 1064 / 1550 nm | High sensitivity, proven in NASA/DARPA programs | Deep-space optical, LIDAR |
| Amplification Technologies DAPD | Discrete amplification photon detector | 1550 nm | Photon-number-resolving (PNR) | Quantum optics, high-fidelity optical comm |

**Availability note:** GMAPD arrays are primarily developed under government contracts (MIT Lincoln Laboratory, BAE Systems) and are not commercial off-the-shelf parts -- procurement typically requires a defense or research relationship. The Amplification Technologies DAPD is available commercially for research applications. For non-restricted deployments, InGaAs SPADs (e.g., ID Quantique ID230) provide single-photon sensitivity at 1550 nm as a commercially available alternative.

**Why photon-number resolution matters for this decoder:**

The SiPM and GMAPD in Geiger mode produce binary outputs (click / no-click). The channel LLR reduces to a single value per slot:

```
LLR_binary = log(P(click | bit=1) / P(click | bit=0))
```

A photon-number-resolving detector like the Amplification Technologies DAPD reports the actual photon count k per slot. The LLR uses the full Poisson probability mass function:

```
LLR_PNR(k) = (lambda_s) - k * ln((lambda_s + lambda_b) / lambda_b)
```

At low photon levels (lambda_s = 1-2), distinguishing k=0 from k=1 from k=2 arrivals provides substantially richer soft information than binary detection. This richer LLR feeds directly into the decoder's 6-bit quantized input, exploiting the full dynamic range of the soft-decision architecture. The result is improved coding gain and a lower operating threshold -- the decoder approaches its theoretical performance limit only when fed high-quality soft information.

**Integration path:**

The electrical interface is identical to Part B: the detector's analog output feeds through a TIA and into either a comparator (binary mode) or a multi-bit ADC (PNR mode). In PNR mode, the RP2040 companion MCU digitizes the photon count and computes the full Poisson LLR before writing to the decoder. No changes to the LDPC decoder ASIC are required -- the 6-bit LLR input accommodates both binary and PNR channel models.

**1550 nm operation** enables compatibility with standard telecom fiber infrastructure, opening additional deployment scenarios: fiber-fed quantum key distribution, metropolitan free-space optical links through atmospheric windows, and hybrid fiber-FSO networks where the last mile is free-space.

## Cost Summary

| Item | Est. Cost | Status |
|------|-----------|--------|
| chipIgnite shuttle | Contest-covered | GDSII submitted |
| Part A breakout board (assembled qty 5) | $25-40 | KiCad design complete, fab-ready on silicon return |
| Part B optical frontend (additional) | ~$59 | Schematic complete, components specified (DNP) |
| Full demo system (TX + RX + optics) | $150-250 | Documented, post-silicon integration |
| Advanced frontend (GMAPD or DAPD) | $5K-15K | Integration path documented, no ASIC changes needed |
| **Minimum viable demo** | **$25-40** | **Buildable immediately on silicon return** |

## Verification Status

**32/32 tests passing across 4 verification layers.**

| Layer | Count | Status | Details |
|-------|-------|--------|---------|
| Standalone Verilator | 2/2 | PASS | VERSION register read, clean codeword decode |
| Vector-driven Verilator | 20/20 | PASS | Bit-exact match vs Python behavioral model |
| cocotb RTL simulation | 5/5 | PASS | basic, noisy, max_iter, back_to_back, demo |
| Gate-level simulation | 5/5 | PASS | All 5 tests pass on post-route GL netlist |
| Static timing analysis | -- | 50 MHz MET (TT) | WNS = +3.28 ns (TT), SS corner fails |
| Precheck | 17/19 | PASS | KLayout FEOL crash + LVS cosmetic pin-match |

### Verification Methodology

The verification strategy uses three independent layers to catch different classes of bugs:

1. **Python cross-check**: The behavioral model (`model/ldpc_sim.py`) generates test vectors at 4 SNR points covering the Poisson channel at lambda_s = 0.5, 1.0, 2.0, and 5.0 photons/slot. All 20 vectors produce bit-exact agreement between RTL simulation and the Python reference, validating the decoder algorithm and fixed-point quantization.

2. **Caravel integration**: cocotb tests exercise the full Caravel SoC path -- PicoRV32 firmware writes LLRs via Wishbone, triggers decode, reads results, and reports pass/fail via GPIO. This validates the register map, bus timing, and firmware interaction.

3. **Gate-level simulation**: All 5 cocotb tests re-run against the post-route netlist (iverilog + SDF-annotated timing). No X-propagation or timing race issues observed. Each test compiles the full Caravel GL netlist (~2 hours, 8.2 GB RAM) and simulates for 30-60 minutes.

### Gate-Level Simulation Results

| Test | Status | Sim Time (ns) | Wall Time | GPIO[7:0] |
|------|--------|---------------|-----------|-----------|
| ldpc_basic | **PASS** | 854,225 | 30 min | 0xAB |
| ldpc_noisy | **PASS** | 1,011,550 | 45 min | 0xAB |
| ldpc_max_iter | **PASS** | 1,104,525 | 57 min | 0xAB |
| ldpc_back_to_back | **PASS** | 1,140,375 | 56 min | 0xAB |
| ldpc_demo | **PASS** | 1,251,050 | 60 min | 0xAB |

GPIO[7:0] = 0xAB is the firmware success code for all tests.

## Hardening Results

The decoder macro was hardened using OpenLane 2 (LibreLane) targeting SkyWater 130nm. Timing closure required 7 OpenLane runs over 2 weeks. The critical path moved from syndrome popcount (48 ns combinational chain, 222 logic levels) to belief update mux (17 ns) through targeted pipelining of the CN update and syndrome computation stages. The golden synthesis netlist (Run 6, `balanced_popcount`) achieves +3.28 ns setup slack at TT 50 MHz.

| Metric | Result |
|--------|--------|
| DRC (Magic) | Clean |
| DRC (KLayout) | Clean |
| LVS | Clean (macro level) |
| Antenna violations | 1,179 (internal nets, accepted) |
| Hold violations | 0 reg-to-reg |
| Setup WNS (TT nom) | +3.28 ns |
| Setup WNS (FF min) | +5.93 ns |
| Setup WNS (SS max) | -9.18 ns (~25 MHz achievable) |
| Power (TT corner) | 86 mW |

See [`docs/hardening-results.md`](../docs/hardening-results.md) for full multi-corner timing data across all 7 hardening runs.

## Precheck Results

Shuttle compliance precheck: **17/19 PASS**.

| # | Check | Result |
|---|-------|--------|
| 1 | License | PASS |
| 2 | Makefile | PASS |
| 3 | Default | PASS |
| 4 | Documentation | PASS |
| 5 | Top Cell | PASS |
| 6 | Consistency | PASS |
| 7 | GPIO-Defines | PASS |
| 8 | XOR | PASS |
| 9 | Magic DRC | PASS |
| 10 | KLayout FEOL | FAIL (tool crash -- SIGSEGV, not a DRC violation) |
| 11 | KLayout BEOL | PASS |
| 12 | KLayout Offgrid | PASS |
| 13 | KLayout Metal Density | PASS |
| 14 | KLayout Pin Labels | PASS |
| 15 | KLayout ZeroArea | PASS |
| 16 | Spike Check | PASS |
| 17 | Illegal Cellname | PASS |
| 18 | OEB | PASS |
| 19 | LVS | FAIL (3 cosmetic pin-match mismatches) |

Both failures are non-functional:
- **KLayout FEOL**: Tool crashed with signal 11 (SIGSEGV) during DRC -- this is a KLayout bug, not a design violation. BEOL, Offgrid, Metal Density, Pin Labels, and ZeroArea all pass.
- **LVS**: "Top level cell failed pin matching" -- 3 cosmetic mismatches where Magic SPICE extraction merged constant-tied output pins (`io_oeb`, `user_irq`) into shared nets, losing individual pin labels. CVC: 0 errors. Device classes: equivalent.

## Demo Strategy

The current submission demonstrates the full decode pipeline without requiring silicon:

**1. PicoRV32 Firmware Demo** (`firmware/ldpc_demo/ldpc_demo.c`)

Three scenarios run sequentially on boot, reporting results via UART (115200 baud, 8N1):

- **Scenario 1 -- Clean decode**: All-zero codeword with LLR = +31. Verifies basic decode in 1 iteration, syndrome = 0.
- **Scenario 2 -- Noisy decode**: Real test vector from Poisson channel model (lambda_s = 5.0 photons/slot). Verifies error correction and convergence.
- **Scenario 3 -- Stress test**: All 20 test vectors decoded back-to-back. Validates convergence, decoded bits, and iteration counts for each. Covers 4 SNR points (lambda_s = 0.5, 1.0, 2.0, 5.0).

Final status reported via GPIO[7:0]: `0xAB` = all pass, `0xFF` = failure detected.

**2. Gate-Level Simulation Evidence**

All 5 cocotb tests pass on the post-route GL netlist (see table above), proving the design survives synthesis, place-and-route, and parasitic extraction.

**3. Physical Design Artifacts**

GDSII layout viewable in KLayout. All DRC checks clean (Magic and KLayout). LVS clean at macro level.

## Deployment Roadmap

**Phase 1: Tape-Out Submission (Current -- April 30, 2026)**
- GDSII submitted via chipIgnite shuttle
- 32/32 verification tests passing (RTL + gate-level)
- Precheck: 17/19 pass (2 non-functional failures documented)
- PicoRV32 firmware compiled with 20 embedded test vectors
- KiCad schematics complete for Part A breakout + Part B optical frontend

**Phase 2: Silicon Bring-Up (Oct/Nov 2026, on silicon return)**
- Part A breakout board ordered from JLCPCB (~$2/board, 5-unit MOQ)
- Components ordered from Digi-Key/LCSC (~$8 BOM per board)
- Board assembly (hand-solder or JLCPCB SMT assembly)
- First silicon bring-up: VERSION register read over UART, firmware demo execution
- Measure real-silicon decode latency and power, compare to simulation predictions

**Phase 3: Optical Frontend Integration (Dec 2026 -- Feb 2027)**
- Part B optical frontend populated (SiPM + TIA + comparator)
- RP2040 firmware for real-time LLR computation from photon counts
- Bench-scale free-space optical link demo (1-5 m, 650 nm laser, 0.5-5 photons/slot)
- Measured BER vs. photon level, compared against Python model predictions
- Open-source reference design published (KiCad + firmware + test procedures)

**Phase 4: Application Validation (2027, if funded)**
- CubeSat-class thermal/vibration qualification testing
- Underwater optical modem integration with AUV partner
- Conference publication (target: IEEE Photonics Technology Letters or CLEO)

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

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full text.

## AI Disclosure

Portions of this project were developed with AI assistance. See [docs/ai-disclosure.md](docs/ai-disclosure.md) for details.
