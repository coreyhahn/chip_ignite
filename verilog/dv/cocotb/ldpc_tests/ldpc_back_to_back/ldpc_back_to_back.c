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
 * LDPC Back-to-Back Decode Test Firmware
 *
 * Runs on PicoRV32 inside Caravel. Exercises the LDPC decoder with two
 * sequential decodes to verify no state leakage between runs:
 *   1. First decode: all-zero codeword (LLRs=+31), check decoded=0
 *   2. Second decode: noisy correctable codeword (test vector 0),
 *      check decoded matches expected
 *   3. Signals pass (0xAB) only if BOTH decodes are correct
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
//   = 0x1F7DF7DF
#define ALL_ZERO_LLR_WORD 0x1F7DF7DF

// Test vector 0: noisy but correctable codeword
// Expected decoded word: 0x3FD74222
#define EXPECTED_DECODED_VEC0  0x3FD74222

static const unsigned int noisy_llr_words[LLR_WORD_COUNT] = {
    0x1F7DF81F, 0x20C9F7E0, 0x207CC7DF, 0x1F82081F, 0x328207E0, 0x20820820, 0x208207CC, 0x1F81F7DF,
    0x1F7F27DF, 0x1F7CC81F, 0x0C81F81F, 0x207E07F2, 0x1F820820, 0x207DF7CC, 0x1F81F7E0, 0x2082081F,
    0x0C31F81F, 0x2081F7DF, 0x1FCA081F, 0x20820820, 0x1F7DF7DF, 0x207E07E0, 0x208207CC, 0x1F8207DF,
    0x0C7DF7DF, 0x2030C820, 0x207DF7E0, 0x1F82081F, 0x203207DF, 0x20832820, 0x2081F820, 0x20820832,
    0x1F82081F, 0x207E081F, 0x207DF820, 0x1F7E0320, 0x1F7E07E0, 0x1F81F820, 0x20CA07CC, 0x0C81F7E0,
    0x1F820820, 0x1FCA07DF, 0x1F7E080C, 0x208207F2, 0x207E081F, 0x20820820, 0x207E07DF, 0x2082081F,
    0x1F7E07DF, 0x1F7DF7E0, 0x207DF820, 0x00000020
};

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

    // ===== DECODE 1: All-zero codeword =====

    // Write all-zero LLRs (+31 confidence in bit=0)
    for (int i = 0; i < LLR_WORD_COUNT - 1; i++) {
        USER_writeWord(ALL_ZERO_LLR_WORD, LDPC_LLR_BASE + i);
    }
    // Last word: only LLR[255] = +31, remaining slots zero
    USER_writeWord(0x0000001F, LDPC_LLR_BASE + LLR_WORD_COUNT - 1);

    // Start decode: start=1, early_term_en=1, max_iter=30
    USER_writeWord(CTRL_START | CTRL_EARLY_TERM | CTRL_MAX_ITER(30), LDPC_CTRL);

    // Poll until done
    do {
        status = USER_readWord(LDPC_STATUS);
    } while (status & STATUS_BUSY);

    // Check converged
    if (!(status & STATUS_CONVERGED)) {
        pass = 0;
    }

    // Check syndrome weight = 0
    if ((status & STATUS_SYN_MASK) != 0) {
        pass = 0;
    }

    // Check decoded = 0 (all-zero codeword)
    decoded = USER_readWord(LDPC_DECODED);
    if (decoded != 0x00000000) {
        pass = 0;
    }

    // ===== DECODE 2: Noisy correctable codeword =====

    // Write noisy LLRs
    for (int i = 0; i < LLR_WORD_COUNT; i++) {
        USER_writeWord(noisy_llr_words[i], LDPC_LLR_BASE + i);
    }

    // Start decode: start=1, early_term_en=1, max_iter=30
    USER_writeWord(CTRL_START | CTRL_EARLY_TERM | CTRL_MAX_ITER(30), LDPC_CTRL);

    // Poll until done
    do {
        status = USER_readWord(LDPC_STATUS);
    } while (status & STATUS_BUSY);

    // Check converged
    if (!(status & STATUS_CONVERGED)) {
        pass = 0;
    }

    // Check syndrome weight = 0
    if ((status & STATUS_SYN_MASK) != 0) {
        pass = 0;
    }

    // Check decoded matches expected
    decoded = USER_readWord(LDPC_DECODED);
    if (decoded != EXPECTED_DECODED_VEC0) {
        pass = 0;
    }

    // --- Signal result via GPIO[7:0] ---
    if (pass) {
        GPIOs_writeLow(PASS_SIGNATURE);  // 0xAB = pass (both decodes correct)
    } else {
        GPIOs_writeLow(FAIL_SIGNATURE);  // 0xFF = fail
    }

    // Signal test complete via management GPIO
    ManagmentGpio_write(0);

    return;
}
