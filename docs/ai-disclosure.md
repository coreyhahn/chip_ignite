# AI Disclosure

This project was developed with assistance from Claude (Anthropic), an AI coding assistant.

## How AI Was Used

- **RTL design and debugging**: AI assisted with SystemVerilog implementation of the LDPC decoder core, Wishbone interface, and Caravel integration wrapper. AI-driven verification found and fixed 7 RTL bugs through standalone and vector-driven testbenches.
- **Behavioral modeling**: Python simulation model (density evolution, BER analysis, test vector generation) co-developed with AI assistance.
- **Build system and tooling**: OpenLane configuration, SDC timing constraints, and Makefile setup guided by AI.
- **Documentation**: Architecture docs, project reports, and contest submission materials drafted with AI assistance.
- **Design space exploration**: Code rate comparison, base matrix optimization, SC-LDPC analysis performed with AI-guided Python scripts.

## Human Contributions

All architectural decisions, algorithm selection (layered offset min-sum, QC-LDPC rate 1/8, IRA staircase structure), target application (photon-starved optical communication), and final design review were made by the human designer. The AI served as a coding assistant, technical reference, and verification tool.

## Transparency

Full conversation transcripts with the AI assistant are available upon request. Key AI-assisted files include:
- `verilog/rtl/*.sv` — RTL implementation
- `../model/*.py` — Python behavioral model (in parent ldpc_optical repo)
- `openlane/*/config.json` — Synthesis configuration
- `docs/` — Documentation

## Tool

- **AI Model**: Claude (Anthropic) via Claude Code CLI
- **Usage Period**: February 2026
