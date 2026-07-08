# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Integration test for the CnnAccel MMIO + DMA compute accelerator.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from coralnpu_test_utils.TileLinkULInterface import (
    TileLinkULInterface,
    create_a_channel_req,
)

# --- CnnAccel register map (base from CrossbarConfig) ---
CNN_BASE = 0x40060000
CNN_CTRL = CNN_BASE + 0x00      # bit0 = GO
CNN_STATUS = CNN_BASE + 0x04    # bit0 busy, bit1 done, bit2 error
CNN_IN_ADDR = CNN_BASE + 0x08
CNN_W_ADDR = CNN_BASE + 0x0C
CNN_OUT_ADDR = CNN_BASE + 0x10
CNN_LEN = CNN_BASE + 0x14
CNN_RESULT = CNN_BASE + 0x18

SRAM_BASE = 0x20000000
MASK32 = 0xFFFFFFFF


async def setup_dut(dut, host_if):
    clock = Clock(dut.io_clk_i, 10, "ns")
    cocotb.start_soon(clock.start())
    test_clock = Clock(dut.io_async_ports_hosts_test_clock, 20, "ns")
    cocotb.start_soon(test_clock.start())

    dut.io_rst_ni.value = 0
    dut.io_async_ports_hosts_test_reset.value = 1
    dut.io_external_ports_gpio_i.value = 0
    await ClockCycles(dut.io_clk_i, 5)
    dut.io_rst_ni.value = 1
    dut.io_async_ports_hosts_test_reset.value = 0
    await ClockCycles(dut.io_clk_i, 100)


async def tl_write(host_if, addr, data, source=0x10):
    txn = create_a_channel_req(
        address=addr, data=data & MASK32, mask=0xF, width=host_if.width, source=source
    )
    await host_if.host_put(txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0, f"TL write error at 0x{addr:08X}"


async def tl_read(host_if, addr, source=0x10):
    txn = create_a_channel_req(
        address=addr, width=host_if.width, is_read=True, size=2, source=source
    )
    await host_if.host_put(txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0, f"TL read error at 0x{addr:08X}"
    return int(resp["data"]) & MASK32


async def poll_done(host_if, timeout_cycles=20000):
    for _ in range(timeout_cycles):
        status = await tl_read(host_if, CNN_STATUS)
        if status & 0x2:  # done
            return status
        await ClockCycles(host_if.clock, 1)
    raise TimeoutError("CnnAccel did not complete within timeout")


def make_host(dut):
    return TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32,
    )


@cocotb.test()
async def test_cnn_csr_access(dut):
    """CSR read/write + reset sanity."""
    host_if = make_host(dut)
    await host_if.init()
    await setup_dut(dut, host_if)

    # STATUS should be 0 after reset (not busy, not done).
    status = await tl_read(host_if, CNN_STATUS)
    assert status == 0, f"STATUS should be 0 after reset, got 0x{status:08X}"

    # Config registers are read/write.
    for reg, val in [
        (CNN_IN_ADDR, 0x20001000),
        (CNN_W_ADDR, 0x20002000),
        (CNN_OUT_ADDR, 0x20003000),
        (CNN_LEN, 0x00000007),
    ]:
        await tl_write(host_if, reg, val)
        got = await tl_read(host_if, reg)
        assert got == val, f"reg 0x{reg:08X}: wrote 0x{val:08X}, read 0x{got:08X}"

    dut._log.info("CnnAccel CSR access PASSED")


@cocotb.test()
async def test_cnn_dot_product(dut):
    """Full MMIO + DMA dot product: RESULT = sum(IN[i] * W[i])."""
    host_if = make_host(dut)
    await host_if.init()
    await setup_dut(dut, host_if)

    in_addr = SRAM_BASE + 0x0000
    w_addr = SRAM_BASE + 0x0100
    out_addr = SRAM_BASE + 0x0200

    in_vals = [1, 2, 3, 4, 5]
    w_vals = [5, 6, 7, 8, 9]
    n = len(in_vals)
    expected = sum(a * b for a, b in zip(in_vals, w_vals)) & MASK32  # 5+12+21+32+45 = 115

    # Preload operands into SRAM.
    for i, v in enumerate(in_vals):
        await tl_write(host_if, in_addr + i * 4, v)
    for i, v in enumerate(w_vals):
        await tl_write(host_if, w_addr + i * 4, v)

    # Program the accelerator.
    await tl_write(host_if, CNN_IN_ADDR, in_addr)
    await tl_write(host_if, CNN_W_ADDR, w_addr)
    await tl_write(host_if, CNN_OUT_ADDR, out_addr)
    await tl_write(host_if, CNN_LEN, n)

    # Kick and wait.
    await tl_write(host_if, CNN_CTRL, 0x1)  # GO
    status = await poll_done(host_if, timeout_cycles=20000)
    assert not (status & 0x4), f"CnnAccel error: 0x{status:08X}"

    # RESULT register readback.
    result = await tl_read(host_if, CNN_RESULT)
    assert result == expected, f"RESULT: expected {expected}, got {result}"

    # Result also DMA-written to OUT_ADDR in memory.
    mem = await tl_read(host_if, out_addr)
    assert mem == expected, f"OUT memory: expected {expected}, got {mem}"

    dut._log.info(f"CnnAccel dot product PASSED: result = {result}")
