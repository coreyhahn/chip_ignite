// Wishbone B4 slave interface for LDPC decoder
// Compatible with Caravel SoC Wishbone interconnect
//
// Register map (byte-addressed):
//   0x00 CTRL     R/W  [0]=start (auto-clear), [1]=early_term_en, [12:8]=max_iter
//   0x04 STATUS   R    [0]=busy, [1]=converged, [12:8]=iterations_used, [23:16]=syndrome_wt
//   0x10-0x4F LLR  W   Channel LLRs packed 5x6-bit per 32-bit word (52 words for 256 LLRs)
//   0x50 DECODED  R    32 decoded info bits
//   0x54 VERSION  R    Version/ID register

module wishbone_interface #(
    parameter N = 256,
    parameter K = 32,
    parameter Q = 6
)(
    input  logic        clk,
    input  logic        rst_n,

    // Wishbone slave
    input  logic        wb_cyc_i,
    input  logic        wb_stb_i,
    input  logic        wb_we_i,
    input  logic [7:0]  wb_adr_i,
    input  logic [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    output logic        wb_ack_o,

    // To/from decoder core
    output logic                    ctrl_start,
    output logic                    ctrl_early_term,
    output logic [4:0]              ctrl_max_iter,
    input  logic                    stat_busy,
    input  logic                    stat_converged,
    input  logic [4:0]              stat_iter_used,
    output logic [N*Q-1:0]          llr_input,     // packed LLR vector
    input  logic [K-1:0]            decoded_bits,
    input  logic [7:0]              syndrome_weight,

    // Interrupt
    output logic                    irq_o
);

    localparam VERSION_ID = 32'h1D01_0001;  // LDPC v0.1 build 1

    // Wishbone handshake: ack on valid cycle
    logic wb_valid;
    assign wb_valid = wb_cyc_i && wb_stb_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wb_ack_o <= 1'b0;
        else
            wb_ack_o <= wb_valid && !wb_ack_o;  // single-cycle ack
    end

    // =========================================================================
    // Control register
    // =========================================================================

    logic start_pending;
    logic early_term_reg;
    logic [4:0] max_iter_reg;

    // Start is a pulse: set on write, cleared after one cycle
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_pending  <= 1'b0;
            early_term_reg <= 1'b1;   // early termination on by default
            max_iter_reg   <= 5'd0;   // 0 = use MAX_ITER default
        end else begin
            if (ctrl_start)
                start_pending <= 1'b0;

            if (wb_valid && wb_we_i && !wb_ack_o && wb_adr_i == 8'h00) begin
                start_pending  <= wb_dat_i[0];
                early_term_reg <= wb_dat_i[1];
                max_iter_reg   <= wb_dat_i[12:8];
            end
        end
    end

    assign ctrl_start     = start_pending && !stat_busy;
    assign ctrl_early_term = early_term_reg;
    assign ctrl_max_iter   = max_iter_reg;

    // =========================================================================
    // LLR input: pack 5 LLRs per 32-bit word
    // Word at offset 0x10 + 4*i contains LLRs [5*i] through [5*i+4]
    // Bits [5:0] = LLR[5*i], [11:6] = LLR[5*i+1], ... [29:24] = LLR[5*i+4]
    // 52 words cover 260 LLRs (256 used, 4 padding)
    // =========================================================================

    always_ff @(posedge clk) begin
        if (wb_valid && wb_we_i && !wb_ack_o) begin
            if (wb_adr_i >= 8'h10 && wb_adr_i < 8'hE0) begin
                int word_idx;
                word_idx = (wb_adr_i - 8'h10) >> 2;
                for (int p = 0; p < 5; p++) begin
                    int llr_idx;
                    llr_idx = word_idx * 5 + p;
                    if (llr_idx < N)
                        llr_input[llr_idx*Q +: Q] <= wb_dat_i[p*Q +: Q];
                end
            end
        end
    end

    // =========================================================================
    // Read mux
    // =========================================================================

    always_comb begin
        wb_dat_o = 32'h0;
        case (wb_adr_i)
            8'h00: wb_dat_o = {19'b0, max_iter_reg, 6'b0, early_term_reg, start_pending};
            8'h04: wb_dat_o = {8'b0, syndrome_weight, 3'b0, stat_iter_used, 6'b0, stat_converged, stat_busy};
            8'h50: wb_dat_o = decoded_bits;
            8'h54: wb_dat_o = VERSION_ID;
            default: wb_dat_o = 32'h0;
        endcase
    end

    // =========================================================================
    // Interrupt: assert when decode completes (busy falls)
    // =========================================================================

    logic busy_d1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_d1 <= 1'b0;
            irq_o   <= 1'b0;
        end else begin
            busy_d1 <= stat_busy;
            // Pulse IRQ on falling edge of busy
            irq_o <= busy_d1 && !stat_busy;
        end
    end

endmodule
