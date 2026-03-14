// LDPC Decoder Core - Layered Min-Sum with QC structure
//
// Layered scheduling processes one base-matrix row at a time.
// For each row, we:
//   1. LAYER_READ (8 cycles): Read beliefs, subtract old messages → vn_to_cn
//   2. CN_STAGE1 (1 cycle): Sign/mag extract, min-find (registered)
//   3. CN_STAGE2 (1 cycle): Extrinsic output generation
//   4. LAYER_WRITE (8 cycles): Write beliefs + update CN->VN messages
// Total: 18 cycles/layer × 7 layers + 3 (syndrome) = 129 cycles/iteration

module ldpc_decoder_core #(
    parameter N_BASE    = 8,
    parameter M_BASE    = 7,
    parameter Z         = 32,
    parameter N         = N_BASE * Z,
    parameter M         = M_BASE * Z,
    parameter Q         = 6,
    parameter MAX_ITER  = 30,
    parameter DC        = 8,        // check node degree
    parameter DV_MAX    = 7         // max variable node degree
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Control
    input  logic                    start,
    input  logic                    early_term_en,
    input  logic [4:0]              max_iter,

    // Channel LLRs (loaded before start) - packed vector for Yosys compatibility
    input  logic [N*Q-1:0]          llr_in,

    // Status
    output logic                    busy,
    output logic                    converged,
    output logic [4:0]              iter_used,

    // Results
    output logic [Z-1:0]            decoded_bits,   // first Z bits = info bits
    output logic [7:0]              syndrome_weight
);

    // =========================================================================
    // Base matrix H stored as shift values (-1 = no connection)
    // H_BASE[row][col] = cyclic shift amount, or -1 if zero sub-matrix
    // =========================================================================

    // IRA staircase base matrix for rate-1/8 QC-LDPC
    // Column 0 = info (dv=7), Columns 1-7 = parity with lower-triangular staircase
    // This matches model/ldpc_sim.py exactly.
    //
    // Row 0: info(0) + p1(5)
    // Row 1: info(11) + p1(3)  + p2(0)
    // Row 2: info(17) + p2(7)  + p3(0)
    // Row 3: info(23) + p3(13) + p4(0)
    // Row 4: info(29) + p4(19) + p5(0)
    // Row 5: info(3)  + p5(25) + p6(0)
    // Row 6: info(9)  + p6(31) + p7(0)

    logic signed [5:0] H_BASE [M_BASE][N_BASE];

    initial begin
        // Row 0: cols 0,1 connected
        H_BASE[0][0] =  0; H_BASE[0][1] =  5; H_BASE[0][2] = -1;
        H_BASE[0][3] = -1; H_BASE[0][4] = -1; H_BASE[0][5] = -1;
        H_BASE[0][6] = -1; H_BASE[0][7] = -1;
        // Row 1: cols 0,1,2 connected
        H_BASE[1][0] = 11; H_BASE[1][1] =  3; H_BASE[1][2] =  0;
        H_BASE[1][3] = -1; H_BASE[1][4] = -1; H_BASE[1][5] = -1;
        H_BASE[1][6] = -1; H_BASE[1][7] = -1;
        // Row 2: cols 0,2,3 connected
        H_BASE[2][0] = 17; H_BASE[2][1] = -1; H_BASE[2][2] =  7;
        H_BASE[2][3] =  0; H_BASE[2][4] = -1; H_BASE[2][5] = -1;
        H_BASE[2][6] = -1; H_BASE[2][7] = -1;
        // Row 3: cols 0,3,4 connected
        H_BASE[3][0] = 23; H_BASE[3][1] = -1; H_BASE[3][2] = -1;
        H_BASE[3][3] = 13; H_BASE[3][4] =  0; H_BASE[3][5] = -1;
        H_BASE[3][6] = -1; H_BASE[3][7] = -1;
        // Row 4: cols 0,4,5 connected
        H_BASE[4][0] = 29; H_BASE[4][1] = -1; H_BASE[4][2] = -1;
        H_BASE[4][3] = -1; H_BASE[4][4] = 19; H_BASE[4][5] =  0;
        H_BASE[4][6] = -1; H_BASE[4][7] = -1;
        // Row 5: cols 0,5,6 connected
        H_BASE[5][0] =  3; H_BASE[5][1] = -1; H_BASE[5][2] = -1;
        H_BASE[5][3] = -1; H_BASE[5][4] = -1; H_BASE[5][5] = 25;
        H_BASE[5][6] =  0; H_BASE[5][7] = -1;
        // Row 6: cols 0,6,7 connected
        H_BASE[6][0] =  9; H_BASE[6][1] = -1; H_BASE[6][2] = -1;
        H_BASE[6][3] = -1; H_BASE[6][4] = -1; H_BASE[6][5] = -1;
        H_BASE[6][6] = 31; H_BASE[6][7] =  0;
    end

    // =========================================================================
    // Memory: VN beliefs (total posterior LLR per bit)
    // beliefs[j] = channel_llr[j] + sum of all CN->VN messages to j
    // =========================================================================

    logic signed [Q-1:0] beliefs [N];

    // =========================================================================
    // Memory: CN->VN messages for layered update
    // msg_cn2vn[row][col][z] = message from check (row*Z+z) to variable (col*Z+shift(z))
    // Stored as [M_BASE][N_BASE] banks of Z entries each
    // =========================================================================

    logic signed [Q-1:0] msg_cn2vn [M_BASE][N_BASE][Z];

    // =========================================================================
    // Decoder FSM
    // =========================================================================

    typedef enum logic [3:0] {
        IDLE,
        INIT,            // Initialize beliefs from channel LLRs, zero messages
        LAYER_READ,      // Read Z beliefs for each of DC columns in current row
        CN_STAGE1,       // Pipeline stage 1: sign/mag extract, min-find
        CN_STAGE2,       // Pipeline stage 2: extrinsic output generation
        LAYER_WRITE,     // Write beliefs + update CN->VN messages
        SYNDROME_S1,     // Syndrome pipeline stage 1: compute parity bits
        SYNDROME_S2,     // Syndrome pipeline stage 2: popcount parity vector
        SYNDROME_DONE,   // Read registered syndrome result
        DONE
    } state_t;

    state_t state, state_next;

    logic [4:0]  iter_cnt;
    logic [2:0]  row_idx;       // current base matrix row (0..M_BASE-1)
    logic [2:0]  col_idx;       // current column being read/written (0..N_BASE-1)
    logic [4:0]  effective_max_iter;

    // Working registers for current layer
    logic signed [Q-1:0] vn_to_cn [DC][Z];
    logic signed [Q-1:0] cn_to_vn [DC][Z];

    // CN pipeline stage 1 intermediate registers
    logic [DC-1:0]  s1_signs    [Z];
    logic           s1_sign_xor [Z];
    logic [Q-2:0]   s1_min1     [Z];
    logic [Q-2:0]   s1_min2     [Z];
    logic [2:0]     s1_min1_idx [Z];

    // Syndrome pipeline registers
    logic [M_BASE*Z-1:0] parity_vec;  // 224-bit registered parity results
    logic [7:0] syndrome_cnt;
    logic       syndrome_ok;

    // Popcount balanced adder tree intermediates (combinational)
    logic [2:0] pc_l1 [56];  // Level 1: 56 groups of 4 bits → 3-bit counts
    logic [4:0] pc_l2 [14];  // Level 2: 14 groups of 4 → 5-bit counts
    logic [6:0] pc_l3 [4];   // Level 3: 4 groups → 7-bit counts

    assign effective_max_iter = (max_iter == 0) ? MAX_ITER[4:0] : max_iter;
    assign busy = (state != IDLE) && (state != DONE);

    // =========================================================================
    // State machine
    // =========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= state_next;
        end
    end

    always_comb begin
        state_next = state;
        case (state)
            IDLE:        if (start) state_next = INIT;
            INIT:        state_next = LAYER_READ;
            LAYER_READ:  if (col_idx == N_BASE - 1) state_next = CN_STAGE1;
            CN_STAGE1:   state_next = CN_STAGE2;
            CN_STAGE2:   state_next = LAYER_WRITE;
            LAYER_WRITE: begin
                if (col_idx == N_BASE - 1) begin
                    if (row_idx == M_BASE - 1)
                        state_next = SYNDROME_S1;
                    else
                        state_next = LAYER_READ;
                end
            end
            SYNDROME_S1: state_next = SYNDROME_S2;
            SYNDROME_S2: state_next = SYNDROME_DONE;
            SYNDROME_DONE: begin
                if (syndrome_ok && early_term_en)
                    state_next = DONE;
                else if (iter_cnt >= effective_max_iter)
                    state_next = DONE;
                else
                    state_next = LAYER_READ;
            end
            DONE:        if (!start) state_next = IDLE;
            default:     state_next = IDLE;
        endcase
    end

    // =========================================================================
    // Datapath
    // =========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iter_cnt   <= '0;
            row_idx    <= '0;
            col_idx    <= '0;
            converged  <= 1'b0;
            iter_used  <= '0;
            syndrome_weight <= '0;
            syndrome_ok <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    iter_cnt  <= '0;
                    row_idx   <= '0;
                    col_idx   <= '0;
                    // Note: converged, iter_used, syndrome_weight, decoded_bits
                    // are NOT cleared here so the host can read them after decode.
                    // They are cleared in INIT when a new decode starts.
                end

                INIT: begin
                    // Initialize beliefs from channel LLRs
                    // Use blocking assignment for array in loop (Verilator requirement)
                    for (int j = 0; j < N; j++) begin
                        beliefs[j] = $signed(llr_in[j*Q +: Q]);
                    end
                    // Zero all CN->VN messages
                    for (int r = 0; r < M_BASE; r++)
                        for (int c = 0; c < N_BASE; c++)
                            for (int z = 0; z < Z; z++)
                                msg_cn2vn[r][c][z] = {Q{1'b0}};
                    row_idx <= '0;
                    col_idx <= '0;
                    iter_cnt <= '0;
                    converged <= 1'b0;
                    syndrome_ok <= 1'b0;
                end

                LAYER_READ: begin
                    // For column col_idx in current row_idx:
                    // VN->CN = belief - old CN->VN message
                    // (belief already contains the sum of ALL CN->VN messages,
                    //  so subtracting the current row's message gives the extrinsic)
                    // Skip unconnected columns (H_BASE == -1)
                    if (H_BASE[row_idx][col_idx] >= 0) begin
                        for (int z = 0; z < Z; z++) begin
                            int bit_idx;
                            int shifted_z;
                            logic signed [Q-1:0] old_msg;
                            logic signed [Q-1:0] belief_val;

                            shifted_z = (z + H_BASE[row_idx][col_idx]) % Z;
                            bit_idx   = int'(col_idx) * Z + shifted_z;
                            // On first iteration (iter_cnt==0), old messages are zero
                            // since no CN update has run yet. Use 0 directly rather
                            // than reading msg_cn2vn, which may not be reliably zeroed
                            // by the INIT state in all simulation tools.
                            old_msg   = (iter_cnt == 0) ?
                                        {Q{1'b0}} : msg_cn2vn[row_idx][col_idx][z];
                            belief_val = beliefs[bit_idx];

                            vn_to_cn[col_idx][z] <= sat_sub(belief_val, old_msg);
                        end
                    end else begin
                        // Unconnected: set to +MAX so magnitude doesn't affect min-sum
                        for (int z = 0; z < Z; z++)
                            vn_to_cn[col_idx][z] <= {1'b0, {(Q-1){1'b1}}};  // +31
                    end

                    if (col_idx == N_BASE - 1)
                        col_idx <= '0;
                    else
                        col_idx <= col_idx + 1;
                end

                // =============================================================
                // CN Pipeline Stage 1: Extract signs/mags, find min1/min2
                // =============================================================
                CN_STAGE1: begin
                    for (int z = 0; z < Z; z++) begin
                        logic [DC-1:0]  signs_w;
                        logic           sign_xor_w;
                        logic [Q-2:0]   mags_w [DC];
                        logic [Q-2:0]   min1_w, min2_w;
                        int             min1_idx_w;

                        sign_xor_w = 1'b0;
                        for (int i = 0; i < DC; i++) begin
                            logic [Q-1:0] abs_val;
                            signs_w[i] = vn_to_cn[i][z][Q-1];
                            if (vn_to_cn[i][z][Q-1]) begin
                                abs_val = ~vn_to_cn[i][z] + 1'b1;
                                mags_w[i] = (abs_val[Q-1]) ? {(Q-1){1'b1}} : abs_val[Q-2:0];
                            end else begin
                                mags_w[i] = vn_to_cn[i][z][Q-2:0];
                            end
                            sign_xor_w = sign_xor_w ^ signs_w[i];
                        end

                        min1_w = {(Q-1){1'b1}};
                        min2_w = {(Q-1){1'b1}};
                        min1_idx_w = 0;
                        for (int i = 0; i < DC; i++) begin
                            if (mags_w[i] < min1_w) begin
                                min2_w     = min1_w;
                                min1_w     = mags_w[i];
                                min1_idx_w = i;
                            end else if (mags_w[i] < min2_w) begin
                                min2_w = mags_w[i];
                            end
                        end

                        s1_signs[z]    = signs_w;
                        s1_sign_xor[z] = sign_xor_w;
                        s1_min1[z]     = min1_w;
                        s1_min2[z]     = min2_w;
                        s1_min1_idx[z] = min1_idx_w[2:0];
                    end
                end

                // =============================================================
                // CN Pipeline Stage 2: Compute extrinsic outputs + pre-register
                // first LAYER_WRITE shift value
                // =============================================================
                CN_STAGE2: begin
                    for (int z = 0; z < Z; z++) begin
                        for (int j = 0; j < DC; j++) begin
                            logic [Q-2:0] mag_out;
                            logic         sign_out;

                            mag_out  = (j[2:0] == s1_min1_idx[z]) ? s1_min2[z] : s1_min1[z];
                            mag_out  = (mag_out > 5'd1) ? (mag_out - 5'd1) : 5'd0;
                            sign_out = s1_sign_xor[z] ^ s1_signs[z][j];

                            cn_to_vn[j][z] <= sign_out ? (~{1'b0, mag_out} + 1'b1) : {1'b0, mag_out};
                        end
                    end
                    col_idx <= '0;
                end

                // =============================================================
                // LAYER_WRITE: Write beliefs and update CN->VN messages
                // =============================================================
                LAYER_WRITE: begin
                    if (H_BASE[row_idx][col_idx] >= 0) begin
                        for (int z = 0; z < Z; z++) begin
                            int shifted_z;
                            int bit_idx;

                            shifted_z = (z + H_BASE[row_idx][col_idx]) % Z;
                            bit_idx   = int'(col_idx) * Z + shifted_z;

                            beliefs[bit_idx] <= sat_add(vn_to_cn[col_idx][z],
                                                        cn_to_vn[col_idx][z]);
                            msg_cn2vn[row_idx][col_idx][z] <= cn_to_vn[col_idx][z];
                        end
                    end

                    if (col_idx == N_BASE - 1) begin
                        col_idx <= '0;
                        if (row_idx == M_BASE - 1)
                            row_idx <= '0;
                        else
                            row_idx <= row_idx + 1;
                    end else begin
                        col_idx <= col_idx + 1;
                    end
                end

                // Syndrome Pipeline Stage 1: Compute parity bits (register)
                // Each parity is only 2-3 XOR levels deep (~3-4 ns)
                SYNDROME_S1: begin
                    for (int r = 0; r < M_BASE; r++) begin
                        for (int z = 0; z < Z; z++) begin
                            logic parity;
                            parity = 1'b0;
                            for (int c = 0; c < N_BASE; c++) begin
                                if (H_BASE[r][c] >= 0) begin
                                    int shifted_z, bit_idx;
                                    shifted_z = (z + H_BASE[r][c]) % Z;
                                    bit_idx = c * Z + shifted_z;
                                    parity = parity ^ beliefs[bit_idx][Q-1];
                                end
                            end
                            parity_vec[r * Z + z] <= parity;
                        end
                    end
                end

                // Syndrome Pipeline Stage 2: Popcount registered parity vector
                // 224-bit popcount via adder tree (~14 ns)
                SYNDROME_S2: begin
                    // Balanced 4-wide adder tree popcount (no loop-carried dependency)
                    // Level 1: 56 groups of 4 bits → 3-bit counts
                    for (int i = 0; i < 56; i++)
                        pc_l1[i] = {2'b0, parity_vec[4*i]} + {2'b0, parity_vec[4*i+1]} +
                                   {2'b0, parity_vec[4*i+2]} + {2'b0, parity_vec[4*i+3]};

                    // Level 2: 14 groups of 4 three-bit counts → 5-bit counts
                    for (int i = 0; i < 14; i++)
                        pc_l2[i] = {2'b0, pc_l1[4*i]} + {2'b0, pc_l1[4*i+1]} +
                                   {2'b0, pc_l1[4*i+2]} + {2'b0, pc_l1[4*i+3]};

                    // Level 3: 14 → 4 (3 groups of 4 + 1 group of 2) → 7-bit counts
                    pc_l3[0] = {2'b0, pc_l2[0]}  + {2'b0, pc_l2[1]}  + {2'b0, pc_l2[2]}  + {2'b0, pc_l2[3]};
                    pc_l3[1] = {2'b0, pc_l2[4]}  + {2'b0, pc_l2[5]}  + {2'b0, pc_l2[6]}  + {2'b0, pc_l2[7]};
                    pc_l3[2] = {2'b0, pc_l2[8]}  + {2'b0, pc_l2[9]}  + {2'b0, pc_l2[10]} + {2'b0, pc_l2[11]};
                    pc_l3[3] = {2'b0, pc_l2[12]} + {2'b0, pc_l2[13]};

                    // Level 4: final sum → 8-bit count
                    syndrome_cnt = {1'b0, pc_l3[0]} + {1'b0, pc_l3[1]} +
                                   {1'b0, pc_l3[2]} + {1'b0, pc_l3[3]};

                    syndrome_weight <= syndrome_cnt;
                    syndrome_ok <= (syndrome_cnt == 0);

                    iter_cnt <= iter_cnt + 1;
                    iter_used <= iter_cnt + 1;
                end

                SYNDROME_DONE: begin
                    // Check registered syndrome result
                    if (syndrome_ok) converged <= 1'b1;
                end

                DONE: begin
                    // Output decoded info bits (first Z=32 bits, column 0)
                    for (int z = 0; z < Z; z++)
                        decoded_bits[z] <= beliefs[z][Q-1]; // sign bit = hard decision
                end
            endcase
        end
    end

    // =========================================================================
    // Saturating arithmetic (Yosys-compatible)
    // =========================================================================

    function automatic logic signed [Q-1:0] sat_add(
        input logic signed [Q-1:0] a,
        input logic signed [Q-1:0] b
    );
        reg signed [Q:0] sum;
        begin
            sum = {a[Q-1], a} + {b[Q-1], b};
            if (!sum[Q] && sum[Q-1])         // positive overflow
                sat_add = {1'b0, {(Q-1){1'b1}}};
            else if (sum[Q] && !sum[Q-1])    // negative overflow
                sat_add = {1'b1, {(Q-1){1'b0}}};
            else
                sat_add = sum[Q-1:0];
        end
    endfunction

    function automatic logic signed [Q-1:0] sat_sub(
        input logic signed [Q-1:0] a,
        input logic signed [Q-1:0] b
    );
        begin
            sat_sub = sat_add(a, -b);
        end
    endfunction

endmodule
