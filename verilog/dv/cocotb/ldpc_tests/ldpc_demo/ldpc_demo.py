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
LDPC Demo Firmware Test - cocotb Monitor

Runs the demo firmware which exercises:
  1. Clean all-zero codeword decode
  2. Noisy correctable codeword decode (test vector 0)

Monitors GPIO[7:0] for pass (0xAB) / fail (0xFF) via management GPIO.
"""

from caravel_cocotb.caravel_interfaces import test_configure
from caravel_cocotb.caravel_interfaces import report_test
import cocotb

PASS_SIGNATURE = 0xAB
FAIL_SIGNATURE = 0xFF


@cocotb.test()
@report_test
async def ldpc_demo(dut):
    caravelEnv = await test_configure(dut, timeout_cycles=500000)

    cocotb.log.info("[TEST] Starting LDPC demo firmware test")

    await caravelEnv.release_csb()

    # Wait for firmware ready
    cocotb.log.info("[TEST] Waiting for firmware ready (mgmt_gpio=1)...")
    await caravelEnv.wait_mgmt_gpio(1)
    cocotb.log.info("[TEST] Firmware ready, running demo scenarios...")

    # Wait for test complete
    await caravelEnv.wait_mgmt_gpio(0)
    cocotb.log.info("[TEST] Firmware signaled test complete")

    # Read result
    gpio_val = caravelEnv.monitor_gpio(7, 0)

    if not gpio_val.is_resolvable:
        cocotb.log.error(
            f"[TEST] FAIL - GPIO[7:0] is unresolvable: {gpio_val.binstr}"
        )
        assert False, "GPIO[7:0] has X/Z values"

    result = gpio_val.integer
    cocotb.log.info(f"[TEST] GPIO[7:0] = 0x{result:02X}")

    if result == PASS_SIGNATURE:
        cocotb.log.info("[TEST] PASS - Demo firmware all scenarios passed (0xAB)")
    elif result == FAIL_SIGNATURE:
        cocotb.log.error(
            "[TEST] FAIL - Demo firmware reported failure (0xFF)"
        )
        assert False, "Demo firmware reported failure"
    else:
        cocotb.log.error(
            f"[TEST] FAIL - Unexpected GPIO value: 0x{result:02X}"
        )
        assert False, f"Unexpected GPIO result: 0x{result:02X}"
