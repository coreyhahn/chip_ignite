# SPDX-FileCopyrightText: 2024 LDPC Optical Project

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#      http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# SPDX-License-Identifier: Apache-2.0

"""
LDPC Max Iteration Test - cocotb Monitor

Tests the LDPC decoder with an uncorrectable codeword. Firmware:
  1. Verifies the VERSION register
  2. Loads uncorrectable noisy LLRs (test vector 11)
  3. Runs a decode with early termination, max_iter=30
  4. Checks converged=0, iterations_used=30, syndrome_weight>0
  5. Signals pass (0xAB) or fail (0xFF) on GPIO[7:0]

The cocotb monitor waits for the management GPIO to signal firmware ready,
then waits for the management GPIO to drop (test complete), and reads
GPIO[7:0] for the pass/fail result.
"""

from caravel_cocotb.caravel_interfaces import test_configure
from caravel_cocotb.caravel_interfaces import report_test
import cocotb

PASS_SIGNATURE = 0xAB
FAIL_SIGNATURE = 0xFF


@cocotb.test()
@report_test
async def ldpc_max_iter(dut):
    caravelEnv = await test_configure(dut, timeout_cycles=300000)

    cocotb.log.info("[TEST] Starting LDPC max iteration test")

    # Release CSB to allow GPIO to function
    await caravelEnv.release_csb()

    # Wait for firmware to signal ready (mgmt_gpio = 1)
    cocotb.log.info("[TEST] Waiting for firmware ready (mgmt_gpio=1)...")
    await caravelEnv.wait_mgmt_gpio(1)
    cocotb.log.info("[TEST] Firmware ready, decode in progress...")

    # Wait for firmware to signal test complete (mgmt_gpio = 0)
    await caravelEnv.wait_mgmt_gpio(0)
    cocotb.log.info("[TEST] Firmware signaled test complete")

    # Read GPIO[7:0] for pass/fail result
    gpio_val = caravelEnv.monitor_gpio(7, 0)

    if not gpio_val.is_resolvable:
        cocotb.log.error(
            f"[TEST] FAIL - GPIO[7:0] is unresolvable: {gpio_val.binstr}"
        )
        assert False, "GPIO[7:0] has X/Z values"

    result = gpio_val.integer
    cocotb.log.info(f"[TEST] GPIO[7:0] = 0x{result:02X}")

    if result == PASS_SIGNATURE:
        cocotb.log.info(
            "[TEST] PASS - Firmware confirmed max iteration behavior (0xAB)"
        )
    elif result == FAIL_SIGNATURE:
        cocotb.log.error(
            "[TEST] FAIL - Firmware reported max iteration test failure (0xFF)"
        )
        assert False, "Firmware reported LDPC max iteration test failure"
    else:
        cocotb.log.error(
            f"[TEST] FAIL - Unexpected GPIO value: 0x{result:02X}"
        )
        assert False, f"Unexpected GPIO result: 0x{result:02X}"
