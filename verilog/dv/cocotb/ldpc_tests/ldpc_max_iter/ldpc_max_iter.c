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
 * LDPC Max Iteration Test Firmware
 *
 * Runs on PicoRV32 inside Caravel. Exercises the LDPC decoder with an
 * uncorrectable codeword to verify it hits max iterations:
 *   1. Writes uncorrectable noisy LLRs (test vector 11)
 *   2. Starts decode with early termination, max_iter=30
 *   3. Checks converged=0 (not converged), iterations_used=30 (hit max)
 *   4. Signals pass (0xAB) or fail (0xFF) on GPIO[7:0]
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

// Test vector 11: uncorrectable codeword (too many errors)
// Expected: converged=False, iterations=30, syndrome_weight=67
static const unsigned int uncorrectable_llr_words[LLR_WORD_COUNT] = {
    0x0C30C80C, 0x0C30C30C, 0x2730C820, 0x0C80C30C, 0x0C32730C, 0x0C30C9E7, 0x0CE8C33A, 0x0C9CC320,
    0x2032030C, 0x0C32030C, 0x0C30C9E0, 0x209CC320, 0x0C9E730C, 0x0C33A9CC, 0x3A80C30C, 0x0C30C80C,
    0x279CC320, 0x0CEA080C, 0x0C30C9CC, 0x279E0320, 0x2730C30C, 0x0CE8C30C, 0x0C80C9CC, 0x0C9CC30C,
    0x3AE8CEA0, 0x20E8C320, 0x0C33A80C, 0x0CEBA33A, 0x0C30C9CC, 0x27EA0E8C, 0x0C30CEBA, 0x0CE8C30C,
    0x0CEA7EA7, 0x0C30C30C, 0x0C83A327, 0x0CEBA30C, 0x0C83AEA0, 0x2033A80C, 0x0C80C30C, 0x0C30C30C,
    0x0C82730C, 0x3A30C33A, 0x3A820E8C, 0x0C30C320, 0x0C30C9E7, 0x279CC320, 0x2080C30C, 0x27320327,
    0x3A32083A, 0x0C33A80C, 0x0C9CC30C, 0x0000000C
};

void main(){
    unsigned int status;
    unsigned int version;
    unsigned int iter_used;
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

    // --- Step 2: Write uncorrectable noisy LLRs ---
    for (int i = 0; i < LLR_WORD_COUNT; i++) {
        USER_writeWord(uncorrectable_llr_words[i], LDPC_LLR_BASE + i);
    }

    // --- Step 3: Start decode ---
    // start=1, early_term_en=1, max_iter=30
    USER_writeWord(CTRL_START | CTRL_EARLY_TERM | CTRL_MAX_ITER(30), LDPC_CTRL);

    // --- Step 4: Poll STATUS until not busy ---
    do {
        status = USER_readWord(LDPC_STATUS);
    } while (status & STATUS_BUSY);

    // --- Step 5: Check results ---
    // Should NOT have converged
    if (status & STATUS_CONVERGED) {
        pass = 0;  // Unexpectedly converged
    }

    // Should have used all 30 iterations
    iter_used = (status & STATUS_ITER_MASK) >> 8;
    if (iter_used != 30) {
        pass = 0;  // Did not hit max iterations
    }

    // Syndrome weight should be non-zero (not converged)
    if ((status & STATUS_SYN_MASK) == 0) {
        pass = 0;  // Syndrome weight unexpectedly zero
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
