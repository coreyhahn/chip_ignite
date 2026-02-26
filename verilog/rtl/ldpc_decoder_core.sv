// LDPC Decoder Core - Layered Min-Sum with QC structure
//
// Layered scheduling processes one base-matrix row at a time.
// For each row, we:
//   1. Read VN beliefs for all Z columns connected to this row
//   2. Subtract old CN->VN messages to get VN->CN messages
//   3. Run CN min-sum update
//   4. Add new CN->VN messages back to VN beliefs
//   5. Write updated beliefs back
//
// This converges ~2x faster than flooding and needs only one message memory
// (CN->VN messages for current layer, overwritten each layer).

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

    // Channel LLRs (loaded before start)
    input  logic signed [Q-1:0]     llr_in [N],

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
        INIT,           // Initialize beliefs from channel LLRs, zero messages
        LAYER_READ,     // Read Z beliefs for each of DC columns in current row
        CN_UPDATE,      // Run min-sum CN update on gathered messages
        LAYER_WRITE,    // Write updated beliefs and new CN->VN messages
        SYNDROME,       // Check syndrome after full iteration
        SYNDROME_DONE,  // Read registered syndrome result
        DONE
    } state_t;

    state_t state, state_next;

    logic [4:0]  iter_cnt;
    logic [2:0]  row_idx;       // current base matrix row (0..M_BASE-1)
    logic [2:0]  col_idx;       // current column being read/written (0..N_BASE-1)
    logic [4:0]  effective_max_iter;

    // Working registers for current layer CN update
    logic signed [Q-1:0] vn_to_cn [DC][Z];  // VN->CN messages for current row
    logic signed [Q-1:0] cn_to_vn [DC][Z];  // new CN->VN messages (output of min-sum)

    // Syndrome check
    logic [7:0] syndrome_cnt;
    logic       syndrome_ok;

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
            LAYER_READ:  if (col_idx == N_BASE - 1) state_next = CN_UPDATE;
            CN_UPDATE:   state_next = LAYER_WRITE;
            LAYER_WRITE: begin
                if (col_idx == N_BASE - 1) begin
                    if (row_idx == M_BASE - 1)
                        state_next = SYNDROME;
                    else
                        state_next = LAYER_READ;  // next row
                end
            end
            SYNDROME:    state_next = SYNDROME_DONE;
            SYNDROME_DONE: begin
                if (syndrome_ok && early_term_en)
                    state_next = DONE;
                else if (iter_cnt >= effective_max_iter)
                    state_next = DONE;
                else
                    state_next = LAYER_READ;  // next iteration
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
                    for (int j = 0; j < N; j++) begin
                        beliefs[j] <= llr_in[j];
                    end
                    // Zero all CN->VN messages
                    for (int r = 0; r < M_BASE; r++)
                        for (int c = 0; c < N_BASE; c++)
                            for (int z = 0; z < Z; z++)
                                msg_cn2vn[r][c][z] <= {Q{1'b0}};
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

                CN_UPDATE: begin
                    // Min-sum update for all Z check nodes in current row
                    // Each CN has DC=8 incoming messages (one per column)
                    for (int z = 0; z < Z; z++) begin
                        // Gather DC messages for check node z
                        logic signed [Q-1:0] msgs [DC];
                        for (int d = 0; d < DC; d++)
                            msgs[d] = vn_to_cn[d][z];

                        // Min-sum: find min1, min2, sign product, min1 index
                        cn_min_sum(msgs, cn_to_vn[0][z], cn_to_vn[1][z],
                                   cn_to_vn[2][z], cn_to_vn[3][z],
                                   cn_to_vn[4][z], cn_to_vn[5][z],
                                   cn_to_vn[6][z], cn_to_vn[7][z]);
                    end
                    col_idx <= '0;  // prepare for LAYER_WRITE
                end

                LAYER_WRITE: begin
                    // Write back: update beliefs and store new CN->VN messages
                    // Skip unconnected columns (H_BASE == -1)
                    if (H_BASE[row_idx][col_idx] >= 0) begin
                        for (int z = 0; z < Z; z++) begin
                            int bit_idx;
                            int shifted_z;
                            logic signed [Q-1:0] new_msg;
                            logic signed [Q-1:0] old_extrinsic;

                            shifted_z = (z + H_BASE[row_idx][col_idx]) % Z;
                            bit_idx   = int'(col_idx) * Z + shifted_z;
                            new_msg   = cn_to_vn[col_idx][z];
                            old_extrinsic = vn_to_cn[col_idx][z];

                            // belief = extrinsic (VN->CN) + new CN->VN message
                            beliefs[bit_idx] <= sat_add(old_extrinsic, new_msg);

                            // Store new message for next iteration
                            msg_cn2vn[row_idx][col_idx][z] <= new_msg;
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

                SYNDROME: begin
                    // Check H * c_hat == 0 (compute syndrome weight)
                    // Only include connected columns (H_BASE >= 0)
                    syndrome_cnt = '0;
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
                            if (parity) syndrome_cnt = syndrome_cnt + 1;
                        end
                    end
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
    // Min-sum CN update function
    // =========================================================================

    // Offset min-sum for DC=8 inputs
    // For each output j: sign = XOR of all other signs, magnitude = min of all other magnitudes - offset
    task automatic cn_min_sum(
        input  logic signed [Q-1:0] in [DC],
        output logic signed [Q-1:0] out0, out1, out2, out3,
                                     out4, out5, out6, out7
    );
        logic [DC-1:0] signs;
        logic [Q-2:0]  mags [DC];
        logic          sign_xor;
        logic [Q-2:0]  min1, min2;
        int            min1_idx;
        logic signed [Q-1:0] outs [DC];

        // Extract signs and magnitudes
        // Note: -32 (100000) has magnitude 32 which overflows 5-bit field to 0.
        // Clamp to 31 (max representable magnitude) to avoid corruption.
        sign_xor = 1'b0;
        for (int i = 0; i < DC; i++) begin
            logic [Q-1:0] abs_val;  // wider to detect overflow
            signs[i] = in[i][Q-1];
            if (in[i][Q-1]) begin
                abs_val = ~in[i] + 1'b1;
                // If abs_val overflowed (input was most negative), clamp
                mags[i] = (abs_val[Q-1]) ? {(Q-1){1'b1}} : abs_val[Q-2:0];
            end else begin
                mags[i] = in[i][Q-2:0];
            end
            sign_xor = sign_xor ^ signs[i];
        end

        // Find two smallest magnitudes
        min1 = {(Q-1){1'b1}};
        min2 = {(Q-1){1'b1}};
        min1_idx = 0;
        for (int i = 0; i < DC; i++) begin
            if (mags[i] < min1) begin
                min2     = min1;
                min1     = mags[i];
                min1_idx = i;
            end else if (mags[i] < min2) begin
                min2 = mags[i];
            end
        end

        // Compute extrinsic outputs with offset correction
        for (int j = 0; j < DC; j++) begin
            logic [Q-2:0] mag_out;
            logic          sign_out;

            mag_out  = (j == min1_idx) ? min2 : min1;
            // Offset correction (subtract 1 in integer representation)
            mag_out  = (mag_out > 1) ? (mag_out - 1) : {(Q-1){1'b0}};
            sign_out = sign_xor ^ signs[j];

            outs[j] = sign_out ? (~{1'b0, mag_out} + 1) : {1'b0, mag_out};
        end

        out0 = outs[0]; out1 = outs[1]; out2 = outs[2]; out3 = outs[3];
        out4 = outs[4]; out5 = outs[5]; out6 = outs[6]; out7 = outs[7];
    endtask

    // =========================================================================
    // Saturating arithmetic helpers
    // =========================================================================

    function automatic logic signed [Q-1:0] sat_add(
        logic signed [Q-1:0] a, logic signed [Q-1:0] b
    );
        logic signed [Q:0] sum;
        sum = {a[Q-1], a} + {b[Q-1], b};  // sign-extend and add
        if (sum > $signed({1'b0, {(Q-1){1'b1}}}))
            return {1'b0, {(Q-1){1'b1}}};  // +max
        else if (sum < $signed({1'b1, {(Q-1){1'b0}}}))
            return {1'b1, {(Q-1){1'b0}}};  // -max
        else
            return sum[Q-1:0];
    endfunction

    function automatic logic signed [Q-1:0] sat_sub(
        logic signed [Q-1:0] a, logic signed [Q-1:0] b
    );
        return sat_add(a, -b);
    endfunction

endmodule
