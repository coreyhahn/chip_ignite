// SPDX-FileCopyrightText: 2024 LDPC Optical Project
// SPDX-License-Identifier: Apache-2.0

/*
 * LDPC Decoder Demo Firmware
 *
 * Runs on PicoRV32 inside Caravel. Demonstrates the LDPC decoder by running
 * three scenarios and reporting results via UART and GPIO:
 *
 *   Scenario 1: Clean all-zero codeword (should decode in 1 iteration)
 *   Scenario 2: Noisy but correctable codeword (test vector 0)
 *   Scenario 3: Stress test - all 20 test vectors back to back
 *
 * UART output format (115200 baud, 8N1):
 *   LDPC Decoder Demo v1.0
 *   VERSION: 1D010001
 *   --- Scenario 1: Clean decode ---
 *   LLR: all +31 (zero codeword)
 *   STATUS: 00001E02 DECODED: 00000000
 *   PASS: converged in 1 iter, syndrome=0
 *   --- Scenario 2: Noisy decode ---
 *   ...
 *
 * GPIO[7:0] final status:
 *   0xAB = all scenarios passed
 *   0xFF = at least one scenario failed
 */

#include <firmware_apis.h>
#include "test_vectors.h"

// LDPC register word offsets (byte_addr / 4)
#define LDPC_CTRL       0   // 0x00
#define LDPC_STATUS     1   // 0x04
#define LDPC_LLR_BASE   4   // 0x10
#define LDPC_DECODED    20  // 0x50
#define LDPC_VERSION    21  // 0x54

// CTRL register fields
#define CTRL_START        (1 << 0)
#define CTRL_EARLY_TERM   (1 << 1)
#define CTRL_MAX_ITER(n)  (((n) & 0x1F) << 8)

// STATUS register fields
#define STATUS_BUSY       (1 << 0)
#define STATUS_CONVERGED  (1 << 1)
#define STATUS_ITER_SHIFT 8
#define STATUS_ITER_MASK  (0x1F << STATUS_ITER_SHIFT)
#define STATUS_SYN_SHIFT  16
#define STATUS_SYN_MASK   (0xFF << STATUS_SYN_SHIFT)

#define EXPECTED_VERSION  0x1D010001
#define PASS_SIGNATURE    0xAB
#define FAIL_SIGNATURE    0xFF

// All-zero codeword LLR word (5x +31)
#define ALL_ZERO_LLR_WORD 0x1F7DF7DF

// Simple hex print (8 chars, uppercase)
static void print_hex(unsigned int val) {
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 28; i >= 0; i -= 4) {
        UART_sendChar(hex[(val >> i) & 0xF]);
    }
}

static void print_dec(unsigned int val) {
    if (val == 0) {
        UART_sendChar('0');
        return;
    }
    char buf[10];
    int n = 0;
    while (val > 0) {
        buf[n++] = '0' + (val % 10);
        val /= 10;
    }
    for (int i = n - 1; i >= 0; i--) {
        UART_sendChar(buf[i]);
    }
}

static void println(const char *s) {
    while (*s) UART_sendChar(*s++);
    UART_sendChar('\r');
    UART_sendChar('\n');
}

static void print_str(const char *s) {
    while (*s) UART_sendChar(*s++);
}

// Write LLR words to decoder and start decode
static unsigned int run_decode(const unsigned int *llr_words, int count) {
    // Write LLRs
    for (int i = 0; i < count; i++) {
        USER_writeWord(llr_words[i], LDPC_LLR_BASE + i);
    }

    // Start: early_term=1, max_iter=30, start=1
    USER_writeWord(CTRL_START | CTRL_EARLY_TERM | CTRL_MAX_ITER(30), LDPC_CTRL);

    // Poll until not busy
    unsigned int status;
    do {
        status = USER_readWord(LDPC_STATUS);
    } while (status & STATUS_BUSY);

    return status;
}

void main() {
    int total_pass = 1;
    int scenario_pass;
    unsigned int status, decoded, version;

    // --- Hardware setup ---
    ManagmentGpio_outputEnable();
    ManagmentGpio_write(0);
    enableHkSpi(0);

    // GPIO[7:0] as management output, GPIO[5:6] for UART
    GPIOs_configure(5, GPIO_MODE_MGMT_STD_OUTPUT);  // UART TX
    GPIOs_configure(6, GPIO_MODE_MGMT_STD_INPUT_NOPULL);  // UART RX
    for (int i = 0; i < 8; i++) {
        if (i != 5 && i != 6)
            GPIOs_configure(i, GPIO_MODE_MGMT_STD_OUTPUT);
    }
    GPIOs_loadConfigs();
    GPIOs_writeLow(0x00000000);

    // Enable UART (115200 baud) and Wishbone
    UART_enableTX(1);
    User_enableIF();

    // Signal ready
    ManagmentGpio_write(1);

    // --- Banner ---
    println("LDPC Decoder Demo v1.0");
    println("Rate 1/8, n=256, k=32, Z=32");
    println("Offset min-sum, layered scheduling");
    println("");

    // --- Version check ---
    version = USER_readWord(LDPC_VERSION);
    print_str("VERSION: ");
    print_hex(version);
    println("");
    if (version != EXPECTED_VERSION) {
        println("ERROR: unexpected version");
        total_pass = 0;
    }

    // ============================================================
    // Scenario 1: Clean all-zero codeword
    // ============================================================
    println("--- Scenario 1: Clean decode ---");
    println("Input: all-zero codeword, LLR=+31");

    // Build LLR words on stack (all +31)
    unsigned int clean_llr[LLR_WORDS_PER_VECTOR];
    for (int i = 0; i < LLR_WORDS_PER_VECTOR - 1; i++) {
        clean_llr[i] = ALL_ZERO_LLR_WORD;
    }
    clean_llr[LLR_WORDS_PER_VECTOR - 1] = 0x0000001F;  // last word: 1 LLR

    status = run_decode(clean_llr, LLR_WORDS_PER_VECTOR);
    decoded = USER_readWord(LDPC_DECODED);

    print_str("STATUS: ");
    print_hex(status);
    print_str(" DECODED: ");
    print_hex(decoded);
    println("");

    scenario_pass = 1;
    if (!(status & STATUS_CONVERGED)) {
        println("FAIL: did not converge");
        scenario_pass = 0;
    }
    if ((status & STATUS_SYN_MASK) != 0) {
        println("FAIL: nonzero syndrome");
        scenario_pass = 0;
    }
    if (decoded != 0x00000000) {
        println("FAIL: wrong decoded bits");
        scenario_pass = 0;
    }
    if (scenario_pass) {
        unsigned int iters = (status & STATUS_ITER_MASK) >> STATUS_ITER_SHIFT;
        print_str("PASS: converged in ");
        print_dec(iters);
        println(" iterations");
    } else {
        total_pass = 0;
    }
    println("");

    // ============================================================
    // Scenario 2: Noisy but correctable codeword (vector 0)
    // ============================================================
    println("--- Scenario 2: Noisy decode ---");
    print_str("Expected decoded: ");
    print_hex(tv0_decoded);
    println("");

    status = run_decode(tv0_llr, LLR_WORDS_PER_VECTOR);
    decoded = USER_readWord(LDPC_DECODED);

    print_str("STATUS: ");
    print_hex(status);
    print_str(" DECODED: ");
    print_hex(decoded);
    println("");

    scenario_pass = 1;
    if (!(status & STATUS_CONVERGED)) {
        println("FAIL: did not converge");
        scenario_pass = 0;
    }
    if (decoded != tv0_decoded) {
        println("FAIL: decoded mismatch");
        scenario_pass = 0;
    }
    if (scenario_pass) {
        unsigned int iters = (status & STATUS_ITER_MASK) >> STATUS_ITER_SHIFT;
        print_str("PASS: corrected in ");
        print_dec(iters);
        println(" iterations");
    } else {
        total_pass = 0;
    }
    println("");

    // ============================================================
    // Scenario 3: Stress test - all 20 vectors
    // ============================================================
    println("--- Scenario 3: Stress test (20 vectors) ---");

    // Pointers to all test vector LLR arrays
    const unsigned int * const tv_llr[NUM_TEST_VECTORS] = {
        tv0_llr, tv1_llr, tv2_llr, tv3_llr, tv4_llr,
        tv5_llr, tv6_llr, tv7_llr, tv8_llr, tv9_llr,
        tv10_llr, tv11_llr, tv12_llr, tv13_llr, tv14_llr,
        tv15_llr, tv16_llr, tv17_llr, tv18_llr, tv19_llr
    };
    const unsigned int tv_decoded[NUM_TEST_VECTORS] = {
        tv0_decoded, tv1_decoded, tv2_decoded, tv3_decoded, tv4_decoded,
        tv5_decoded, tv6_decoded, tv7_decoded, tv8_decoded, tv9_decoded,
        tv10_decoded, tv11_decoded, tv12_decoded, tv13_decoded, tv14_decoded,
        tv15_decoded, tv16_decoded, tv17_decoded, tv18_decoded, tv19_decoded
    };
    const int tv_converged[NUM_TEST_VECTORS] = {
        tv0_converged, tv1_converged, tv2_converged, tv3_converged, tv4_converged,
        tv5_converged, tv6_converged, tv7_converged, tv8_converged, tv9_converged,
        tv10_converged, tv11_converged, tv12_converged, tv13_converged, tv14_converged,
        tv15_converged, tv16_converged, tv17_converged, tv18_converged, tv19_converged
    };

    int pass_count = 0;
    int fail_count = 0;

    for (int v = 0; v < NUM_TEST_VECTORS; v++) {
        status = run_decode(tv_llr[v], LLR_WORDS_PER_VECTOR);
        decoded = USER_readWord(LDPC_DECODED);

        unsigned int iters = (status & STATUS_ITER_MASK) >> STATUS_ITER_SHIFT;
        int converged = (status & STATUS_CONVERGED) ? 1 : 0;

        print_str("V");
        print_dec(v);
        print_str(": ");

        // For converged vectors, check decoded matches expected
        if (tv_converged[v]) {
            if (converged && decoded == tv_decoded[v]) {
                print_str("PASS ");
                print_dec(iters);
                println(" iters");
                pass_count++;
            } else {
                print_str("FAIL got=");
                print_hex(decoded);
                print_str(" exp=");
                print_hex(tv_decoded[v]);
                println("");
                fail_count++;
                total_pass = 0;
            }
        } else {
            // Unconverged vector: just check it didn't falsely converge
            // (or if it did converge with correct result, that's also OK)
            if (!converged) {
                print_str("OK uncorrectable ");
                print_dec(iters);
                println(" iters");
                pass_count++;
            } else if (decoded == tv_decoded[v]) {
                print_str("OK converged ");
                print_dec(iters);
                println(" iters");
                pass_count++;
            } else {
                print_str("FAIL false-converge got=");
                print_hex(decoded);
                println("");
                fail_count++;
                total_pass = 0;
            }
        }
    }

    print_str("Results: ");
    print_dec(pass_count);
    print_str("/");
    print_dec(pass_count + fail_count);
    println(" passed");
    println("");

    // ============================================================
    // Final result
    // ============================================================
    if (total_pass) {
        println("=== ALL SCENARIOS PASSED ===");
        GPIOs_writeLow(PASS_SIGNATURE);
    } else {
        println("=== SOME SCENARIOS FAILED ===");
        GPIOs_writeLow(FAIL_SIGNATURE);
    }

    // Signal test complete
    ManagmentGpio_write(0);

    // Halt
    while (1);
}
