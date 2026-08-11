// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// =============================================================================
// cnn_boot_test.cc — BOOTLOADER / gate-portable whole-chip CNN test.
//
// Same CnnAccel exercise as cnn_chip_test.cc, but it reports its verdict over the
// **UART** instead of a backdoor SRAM mailbox. That makes it independent of how it
// is loaded/booted: it works when the ELF arrives over the real spi2tlul port, or
// when the chip's own ROM bootloader copies it in from SPI flash. Nothing here
// reaches into RTL internals, so it survives synthesis / gate-level sim.
//
// The chip-sim harness (coralnpu_v2_sim_test) passes the test on a UART line
// matching "PASS"/"TEST PASSED" and fails on "FAIL"/"ERROR".
// =============================================================================

#include <cstdint>
#include "fpga/sw/uart.h"

// --- CnnAccel MMIO register map (base = its DeviceConfig in CrossbarConfig) ---
static constexpr uintptr_t CNN_BASE = 0x40060000u;
#define CNN(off) (*reinterpret_cast<volatile int32_t *>(CNN_BASE + (off)))
#define CNN_CTRL     CNN(0x00)   // bit0 GO
#define CNN_STATUS   CNN(0x04)   // bit1 done
#define CNN_IN_ADDR  CNN(0x08)
#define CNN_W_ADDR   CNN(0x0c)
#define CNN_OUT_ADDR CNN(0x10)
#define CNN_LEN      CNN(0x14)
#define CNN_RESULT   CNN(0x18)
#define CTRL_GO      0x1
#define STATUS_DONE  0x2

static constexpr uintptr_t SRAM_BASE = 0x20000000u;
static constexpr uintptr_t IN_ADDR  = SRAM_BASE + 0x000;
static constexpr uintptr_t W_ADDR   = SRAM_BASE + 0x100;
static constexpr uintptr_t OUT_ADDR = SRAM_BASE + 0x200;
static constexpr int32_t EXPECTED = -41;

static inline uint32_t pack4(int8_t a, int8_t b, int8_t c, int8_t d) {
  return (uint8_t)a | ((uint8_t)b << 8) | ((uint8_t)c << 16) | ((uint8_t)d << 24);
}
static inline void fence() { asm volatile("fence" ::: "memory"); }

int main() {
  uart_init();
  uart_puts("CnnAccel boot test: staging operands + programming engine...\n");

  volatile uint32_t *in_buf = reinterpret_cast<volatile uint32_t *>(IN_ADDR);
  volatile uint32_t *w_buf  = reinterpret_cast<volatile uint32_t *>(W_ADDR);
  volatile int32_t  *out    = reinterpret_cast<volatile int32_t  *>(OUT_ADDR);

  // in = [1,-2,3,-4,5,6], w = [-1,2,-3,4,5,-6]; LEN=6 -> lanes 6,7 are garbage
  // the engine must ignore (tail masking). Expected dot product = -41.
  in_buf[0] = pack4(1, -2, 3, -4);
  in_buf[1] = pack4(5, 6, 100, -100);
  w_buf[0]  = pack4(-1, 2, -3, 4);
  w_buf[1]  = pack4(5, -6, 50, -50);
  fence();  // operands visible before the engine DMA-reads them

  CNN_IN_ADDR  = (int32_t)IN_ADDR;
  CNN_W_ADDR   = (int32_t)W_ADDR;
  CNN_OUT_ADDR = (int32_t)OUT_ADDR;
  CNN_LEN      = 6;
  CNN_CTRL     = CTRL_GO;

  while (!(CNN_STATUS & STATUS_DONE)) { /* poll */ }
  fence();  // engine's write-back visible to us

  int32_t result = CNN_RESULT;
  uart_puts("CnnAccel RESULT = ");
  uart_puthex32((uint32_t)result);
  uart_putc('\n');

  if (result == EXPECTED && out[0] == EXPECTED) {
    uart_puts("TEST PASSED: CnnAccel dot product == -41\n");
  } else {
    uart_puts("TEST FAILED: CnnAccel result mismatch\n");
  }
  return 0;
}
