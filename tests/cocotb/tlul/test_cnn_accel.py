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
# Integration test for the CnnAccel int8 MMIO + DMA compute accelerator.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from coralnpu_test_utils.TileLinkULInterface import (
    TileLinkULInterface,
    create_a_channel_req,
)

# --- CnnAccel register map (base from CrossbarConfig) ---
CNN_BASE = 0x40060000
CNN_CTRL = CNN_BASE + 0x00      # bit0 GO, bit1 IRQ_EN, bit2 CLEAR
CNN_STATUS = CNN_BASE + 0x04    # bit0 busy, bit1 done, bit2 error
CNN_IN_ADDR = CNN_BASE + 0x08
CNN_W_ADDR = CNN_BASE + 0x0C
CNN_OUT_ADDR = CNN_BASE + 0x10
CNN_LEN = CNN_BASE + 0x14
CNN_RESULT = CNN_BASE + 0x18

CTRL_GO = 0x1
CTRL_IRQ_EN = 0x2
CTRL_CLEAR = 0x4

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


def pack4(vals):
    """Pack up to 4 signed int8 into a 32-bit word (lane j at bits [8j+7:8j])."""
    word = 0
    for j, v in enumerate(vals):
        word |= (v & 0xFF) << (8 * j)
    return word


def make_host(dut):
    return TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32,
    )


def irq_value(dut):
    return int(dut.io_external_ports_cnn_irq.value)


@cocotb.test()
async def test_cnn_csr_access(dut):
    """CSR read/write + reset sanity."""
    host_if = make_host(dut)
    await host_if.init()
    await setup_dut(dut, host_if)

    status = await tl_read(host_if, CNN_STATUS)
    assert status == 0, f"STATUS should be 0 after reset, got 0x{status:08X}"
    assert irq_value(dut) == 0, "irq should be low after reset"

    for reg, val in [
        (CNN_IN_ADDR, 0x20001000),
        (CNN_W_ADDR, 0x20002000),
        (CNN_OUT_ADDR, 0x20003000),
        (CNN_LEN, 0x00000010),
    ]:
        await tl_write(host_if, reg, val)
        got = await tl_read(host_if, reg)
        assert got == val, f"reg 0x{reg:08X}: wrote 0x{val:08X}, read 0x{got:08X}"

    # IRQ_EN is read-back-able in CTRL bit1.
    await tl_write(host_if, CNN_CTRL, CTRL_IRQ_EN)
    ctrl = await tl_read(host_if, CNN_CTRL)
    assert ctrl & CTRL_IRQ_EN, f"IRQ_EN not set: 0x{ctrl:08X}"

    dut._log.info("CnnAccel CSR access PASSED")


@cocotb.test()
async def test_cnn_int8_dot_product(dut):
    """int8 MMIO + DMA dot product with signed values, tail masking, and IRQ."""
    host_if = make_host(dut)
    await host_if.init()
    await setup_dut(dut, host_if)

    in_addr = SRAM_BASE + 0x0000
    w_addr = SRAM_BASE + 0x0100
    out_addr = SRAM_BASE + 0x0200

    # LEN = 6 int8 elements (not a multiple of 4 -> exercises tail-lane masking).
    in8 = [1, -2, 3, -4, 5, 6]
    w8 = [-1, 2, -3, 4, 5, -6]
    n = len(in8)
    expected = sum(a * b for a, b in zip(in8, w8)) & MASK32  # -41 -> 0xFFFFFFD7

    # Pad to a whole word with GARBAGE in the masked lanes; the engine must ignore them.
    in_padded = in8 + [100, -100]  # lanes 6,7 are past LEN
    w_padded = w8 + [50, -50]
    for word in range(2):
        await tl_write(host_if, in_addr + word * 4, pack4(in_padded[word * 4 : word * 4 + 4]))
        await tl_write(host_if, w_addr + word * 4, pack4(w_padded[word * 4 : word * 4 + 4]))

    await tl_write(host_if, CNN_IN_ADDR, in_addr)
    await tl_write(host_if, CNN_W_ADDR, w_addr)
    await tl_write(host_if, CNN_OUT_ADDR, out_addr)
    await tl_write(host_if, CNN_LEN, n)

    # Kick with interrupt enabled.
    await tl_write(host_if, CNN_CTRL, CTRL_GO | CTRL_IRQ_EN)
    status = await poll_done(host_if, timeout_cycles=20000)
    assert not (status & 0x4), f"CnnAccel error: 0x{status:08X}"

    result = await tl_read(host_if, CNN_RESULT)
    assert result == expected, f"RESULT: expected 0x{expected:08X}, got 0x{result:08X}"
    mem = await tl_read(host_if, out_addr)
    assert mem == expected, f"OUT memory: expected 0x{expected:08X}, got 0x{mem:08X}"

    # Interrupt should be asserted on done (IRQ_EN set).
    assert irq_value(dut) == 1, "irq should be asserted after done with IRQ_EN"

    # W1C clear: clear done (keep IRQ_EN) -> irq deasserts, done bit clears.
    await tl_write(host_if, CNN_CTRL, CTRL_CLEAR | CTRL_IRQ_EN)
    await ClockCycles(host_if.clock, 2)
    status = await tl_read(host_if, CNN_STATUS)
    assert not (status & 0x2), f"done should be cleared, STATUS=0x{status:08X}"
    assert irq_value(dut) == 0, "irq should deassert after clear"

    dut._log.info(f"CnnAccel int8 dot product PASSED: result = {result:#010x} ({expected - (1<<32)})")
