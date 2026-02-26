// SPDX-FileCopyrightText: 2024 LDPC Optical Project

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at

//      http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// SPDX-License-Identifier: Apache-2.0

/*
 * LDPC Basic Decode Test Firmware
 *
 * Runs on PicoRV32 inside Caravel. Exercises the LDPC decoder via Wishbone:
 *   1. Checks VERSION register
 *   2. Writes all-zero-codeword LLRs (all +31)
 *   3. Starts decode with early termination
 *   4. Polls until done
 *   5. Checks convergence, syndrome weight, and decoded bits
 *   6. Signals pass (0xAB) or fail (0xFF) on GPIO[7:0]
 */

#include <firmware_apis.h>

// LDPC register word offsets (byte_addr / 4)
#define LDPC_CTRL       0   // 0x00
#define LDPC_STATUS     1   // 0x04
#define LDPC_LLR_BASE   4   // 0x10
#define LDPC_DECODED    20  // 0x50
#define LDPC_VERSION    21  // 0x54

#define LLR_WORD_COUNT  52  // 260 LLRs / 5 per word, rounded up

// CTRL register fields
#define CTRL_START        (1 << 0)
#define CTRL_EARLY_TERM   (1 << 1)
#define CTRL_MAX_ITER(n)  (((n) & 0x1F) << 8)

// STATUS register fields
#define STATUS_BUSY       (1 << 0)
#define STATUS_CONVERGED  (1 << 1)
#define STATUS_ITER_MASK  (0x1F << 8)
#define STATUS_SYN_MASK   (0xFF << 16)

// Expected values
#define EXPECTED_VERSION  0x1D010001
#define PASS_SIGNATURE    0xAB
#define FAIL_SIGNATURE    0xFF

// All-zero codeword: every LLR = +31 (6'b011111 = 0x1F)
// Pack 5x 0x1F per word:
//   (0x1F << 0) | (0x1F << 6) | (0x1F << 12) | (0x1F << 18) | (0x1F << 24)
//   = 0x1F | 0x7C0 | 0x1F000 | 0x7C0000 | 0x1F000000
//   = 0x1F7DF7DF
#define ALL_ZERO_LLR_WORD 0x1F7DF7DF

void main(){
    unsigned int status;
    unsigned int decoded;
    unsigned int version;
    int pass = 1;

    // --- Setup management GPIO for synchronization ---
    ManagmentGpio_outputEnable();
    ManagmentGpio_write(0);
    enableHkSpi(0);

    // Configure all GPIOs as management standard output (driven by firmware)
    GPIOs_configureAll(GPIO_MODE_MGMT_STD_OUTPUT);
    GPIOs_loadConfigs();

    // Clear GPIO output
    GPIOs_writeLow(0x00000000);

    // Enable Wishbone interface to user project
    User_enableIF();

    // Signal firmware ready
    ManagmentGpio_write(1);

    // --- Step 1: Read and verify VERSION register ---
    version = USER_readWord(LDPC_VERSION);
    if (version != EXPECTED_VERSION) {
        pass = 0;
    }

    // --- Step 2: Write all-zero-codeword LLRs ---
    // All 256 LLRs = +31 (strong confidence in bit=0)
    // Last word (index 51) has only 1 LLR, upper bits zero
    for (int i = 0; i < LLR_WORD_COUNT - 1; i++) {
        USER_writeWord(ALL_ZERO_LLR_WORD, LDPC_LLR_BASE + i);
    }
    // Last word: only LLR[255] = +31, remaining slots zero
    // bits[5:0] = 0x1F, bits[29:6] = 0
    USER_writeWord(0x0000001F, LDPC_LLR_BASE + LLR_WORD_COUNT - 1);

    // --- Step 3: Start decode ---
    // start=1, early_term_en=1, max_iter=30
    USER_writeWord(CTRL_START | CTRL_EARLY_TERM | CTRL_MAX_ITER(30), LDPC_CTRL);

    // --- Step 4: Poll STATUS until not busy ---
    do {
        status = USER_readWord(LDPC_STATUS);
    } while (status & STATUS_BUSY);

    // --- Step 5: Check results ---
    // Check converged (bit 1)
    if (!(status & STATUS_CONVERGED)) {
        pass = 0;
    }

    // Check syndrome weight = 0 (bits [23:16])
    if ((status & STATUS_SYN_MASK) != 0) {
        pass = 0;
    }

    // Read decoded info bits (should be all zero for all-zero codeword)
    decoded = USER_readWord(LDPC_DECODED);
    if (decoded != 0x00000000) {
        pass = 0;
    }

    // --- Step 6: Signal result via GPIO[7:0] ---
    if (pass) {
        GPIOs_writeLow(PASS_SIGNATURE);  // 0xAB = pass
    } else {
        GPIOs_writeLow(FAIL_SIGNATURE);  // 0xFF = fail
    }

    // Signal test complete via management GPIO
    ManagmentGpio_write(0);

    return;
}
