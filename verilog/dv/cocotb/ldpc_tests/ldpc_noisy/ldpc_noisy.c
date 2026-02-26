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
 * LDPC Noisy Decode Test Firmware
 *
 * Runs on PicoRV32 inside Caravel. Exercises the LDPC decoder with a noisy
 * but correctable codeword:
 *   1. Writes noisy LLRs (test vector 0 from gen_firmware_vectors.py)
 *   2. Starts decode with early termination, max_iter=30
 *   3. Checks converged=1, syndrome_weight=0, decoded matches expected
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

// Test vector 0: noisy but correctable codeword
// Expected decoded word: 0x3FD74222
#define EXPECTED_DECODED  0x3FD74222

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

    // --- Step 2: Write noisy LLRs ---
    for (int i = 0; i < LLR_WORD_COUNT; i++) {
        USER_writeWord(noisy_llr_words[i], LDPC_LLR_BASE + i);
    }

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

    // Read decoded info bits
    decoded = USER_readWord(LDPC_DECODED);
    if (decoded != EXPECTED_DECODED) {
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
