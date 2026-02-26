// SPDX-FileCopyrightText: 2024 LDPC Optical Project
// SPDX-License-Identifier: Apache-2.0

// Symlink/copy to the actual demo firmware
// This file just includes the demo firmware from its canonical location
// so that caravel_cocotb can find it in the test directory.

// Note: caravel_cocotb expects the C file in the test directory.
// We keep the actual firmware in firmware/ldpc_demo/ for standalone builds.
// For cocotb, we duplicate the essential parts here.

#include <firmware_apis.h>

// Pull in test vectors (these are in firmware/ldpc_demo/)
// For cocotb, we need the vectors accessible from include path
// The test vector data is embedded directly via test_data definitions

// LDPC register word offsets (byte_addr / 4)
#define LDPC_CTRL       0   // 0x00
#define LDPC_STATUS     1   // 0x04
#define LDPC_LLR_BASE   4   // 0x10
#define LDPC_DECODED    20  // 0x50
#define LDPC_VERSION    21  // 0x54

#define CTRL_START        (1 << 0)
#define CTRL_EARLY_TERM   (1 << 1)
#define CTRL_MAX_ITER(n)  (((n) & 0x1F) << 8)

#define STATUS_BUSY       (1 << 0)
#define STATUS_CONVERGED  (1 << 1)
#define STATUS_ITER_SHIFT 8
#define STATUS_ITER_MASK  (0x1F << STATUS_ITER_SHIFT)

#define EXPECTED_VERSION  0x1D010001
#define PASS_SIGNATURE    0xAB
#define FAIL_SIGNATURE    0xFF

#define ALL_ZERO_LLR_WORD 0x1F7DF7DF
#define LLR_WORD_COUNT    52

// Write LLRs and start decode, return STATUS
static unsigned int run_decode(const unsigned int *llr, int count) {
    for (int i = 0; i < count; i++)
        USER_writeWord(llr[i], LDPC_LLR_BASE + i);
    USER_writeWord(CTRL_START | CTRL_EARLY_TERM | CTRL_MAX_ITER(30), LDPC_CTRL);
    unsigned int st;
    do { st = USER_readWord(LDPC_STATUS); } while (st & STATUS_BUSY);
    return st;
}

void main() {
    int pass = 1;
    unsigned int status, decoded, version;

    // Setup
    ManagmentGpio_outputEnable();
    ManagmentGpio_write(0);
    enableHkSpi(0);

    GPIOs_configureAll(GPIO_MODE_MGMT_STD_OUTPUT);
    GPIOs_loadConfigs();
    GPIOs_writeLow(0x00000000);
    User_enableIF();
    ManagmentGpio_write(1);

    // Check version
    version = USER_readWord(LDPC_VERSION);
    if (version != EXPECTED_VERSION) pass = 0;

    // Scenario 1: clean all-zero codeword
    {
        unsigned int llr[LLR_WORD_COUNT];
        for (int i = 0; i < LLR_WORD_COUNT - 1; i++) llr[i] = ALL_ZERO_LLR_WORD;
        llr[LLR_WORD_COUNT - 1] = 0x0000001F;

        status = run_decode(llr, LLR_WORD_COUNT);
        decoded = USER_readWord(LDPC_DECODED);

        if (!(status & STATUS_CONVERGED)) pass = 0;
        if (decoded != 0x00000000) pass = 0;
    }

    // Scenario 2: noisy decode (vector 0 from test_data.py)
    // Inline test vector 0 LLR words
    {
        static const unsigned int tv0_llr[52] = {
            0x1F7DF81F, 0x20C9F7E0, 0x207CC7DF, 0x1F82081F,
            0x328207E0, 0x20820820, 0x208207CC, 0x1F81F7DF,
            0x1F7F27DF, 0x1F7CC81F, 0x0C81F81F, 0x207E07F2,
            0x1F820820, 0x207DF7CC, 0x1F81F7E0, 0x2082081F,
            0x0C31F81F, 0x2081F7DF, 0x1FCA081F, 0x20820820,
            0x1F7DF7DF, 0x207E07E0, 0x208207CC, 0x1F8207DF,
            0x0C7DF7DF, 0x2030C820, 0x207DF7E0, 0x1F82081F,
            0x203207DF, 0x20832820, 0x2081F820, 0x20820832,
            0x1F82081F, 0x207E081F, 0x207DF820, 0x1F7E0320,
            0x1F7E07E0, 0x1F81F820, 0x20CA07CC, 0x0C81F7E0,
            0x1F820820, 0x1FCA07DF, 0x1F7E080C, 0x208207F2,
            0x207E081F, 0x20820820, 0x207E07DF, 0x2082081F,
            0x1F7E07DF, 0x1F7DF7E0, 0x207DF820, 0x00000020
        };
        status = run_decode(tv0_llr, 52);
        decoded = USER_readWord(LDPC_DECODED);

        if (!(status & STATUS_CONVERGED)) pass = 0;
        if (decoded != 0x3FD74222) pass = 0;
    }

    // Report result
    if (pass) {
        GPIOs_writeLow(PASS_SIGNATURE);
    } else {
        GPIOs_writeLow(FAIL_SIGNATURE);
    }
    ManagmentGpio_write(0);
    while (1);
}
