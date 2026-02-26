// LDPC Decoder Top - Caravel-adapted wrapper
// QC-LDPC Rate 1/8 for Photon-Starved Optical Communication
// Target: Efabless chipIgnite (SkyWater 130nm, Caravel harness)
//
// Adaptations from standalone version:
//   - USE_POWER_PINS ifdef for Caravel power pass-through
//   - 32-bit Wishbone address (lower 8 bits passed to wishbone_interface)
//   - wb_sel_i byte selects accepted but unused (word-aligned access only)

module ldpc_decoder_top #(
    parameter N_BASE    = 8,
    parameter M_BASE    = 7,
    parameter Z         = 32,
    parameter N         = N_BASE * Z,
    parameter K         = Z,
    parameter M         = M_BASE * Z,
    parameter Q         = 6,
    parameter MAX_ITER  = 30,
    parameter DC        = 8,
    parameter DV_MAX    = 7
)(
`ifdef USE_POWER_PINS
    inout vccd1,
    inout vssd1,
`endif
    input  logic        clk,
    input  logic        rst_n,
    input  logic        wb_cyc_i,
    input  logic        wb_stb_i,
    input  logic        wb_we_i,
    input  logic [3:0]  wb_sel_i,      // byte selects (unused, Caravel compat)
    input  logic [31:0] wb_adr_i,      // full 32-bit address from Caravel
    input  logic [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    output logic        wb_ack_o,
    output logic        irq_o
);
    // Internal signals
    logic        ctrl_start;
    logic        ctrl_early_term;
    logic [4:0]  ctrl_max_iter;
    logic        stat_busy;
    logic        stat_converged;
    logic [4:0]  stat_iter_used;
    logic signed [Q-1:0] llr_input [N];
    logic [K-1:0]  decoded_bits;
    logic [7:0]    syndrome_weight;

    wishbone_interface #(.N(N), .K(K), .Q(Q)) u_wb (
        .clk(clk), .rst_n(rst_n),
        .wb_cyc_i(wb_cyc_i), .wb_stb_i(wb_stb_i), .wb_we_i(wb_we_i),
        .wb_adr_i(wb_adr_i[7:0]),  // lower 8 bits only
        .wb_dat_i(wb_dat_i), .wb_dat_o(wb_dat_o), .wb_ack_o(wb_ack_o),
        .ctrl_start(ctrl_start), .ctrl_early_term(ctrl_early_term),
        .ctrl_max_iter(ctrl_max_iter),
        .stat_busy(stat_busy), .stat_converged(stat_converged),
        .stat_iter_used(stat_iter_used),
        .llr_input(llr_input), .decoded_bits(decoded_bits),
        .syndrome_weight(syndrome_weight), .irq_o(irq_o)
    );

    ldpc_decoder_core #(
        .N_BASE(N_BASE), .M_BASE(M_BASE), .Z(Z), .Q(Q),
        .MAX_ITER(MAX_ITER), .DC(DC), .DV_MAX(DV_MAX)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .start(ctrl_start), .early_term_en(ctrl_early_term),
        .max_iter(ctrl_max_iter), .llr_in(llr_input),
        .busy(stat_busy), .converged(stat_converged),
        .iter_used(stat_iter_used), .decoded_bits(decoded_bits),
        .syndrome_weight(syndrome_weight)
    );
endmodule
