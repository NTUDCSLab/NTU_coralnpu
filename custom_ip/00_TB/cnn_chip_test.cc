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
// cnn_chip_test.cc — WHOLE-CHIP firmware test for the CnnAccel accelerator.
//
// This runs on the Coral RISC-V core (the real CPU inside the SoC) and drives
// the CNN engine exactly the way production firmware would: stage operands in
// shared SRAM, program the engine's MMIO CSRs, kick it, poll for done, and check
// the result. That makes it a true "whole chip on CNN function" test — CPU ->
// crossbar -> CnnAccel -> SRAM -> back to CPU — not a unit test of the engine.
//
// It self-checks and reports through a memory mailbox + the halt convention:
//   * PASS  -> write MAGIC_PASS to the mailbox, then return (core halts cleanly).
//   * FAIL  -> write MAGIC_FAIL to the mailbox, then spin (TB times out).
// The testbench waits for halt and/or reads the mailbox. It is run by
// `test_cnn_chip` in tests/cocotb/tlul/test_subsystem.py, which boots the core
// on the full CoralNPUChiselSubsystem and checks the mailbox.
//
// This same skeleton is how you'd offload a layer to ANY accelerator (e.g. the
// lab's PRESTO engine) from a Coral core: point the CSRs at DRAM/SRAM buffers,
// start, wait, check.
// =============================================================================

#include <cstdint>

// --- CnnAccel MMIO register map (base = its DeviceConfig in CrossbarConfig) ---
static constexpr uintptr_t CNN_BASE = 0x40060000u;
#define CNN(off) (*reinterpret_cast<volatile int32_t *>(CNN_BASE + (off)))
#define CNN_CTRL    CNN(0x00)   // bit0 GO, bit1 IRQ_EN, bit2 CLEAR
#define CNN_STATUS  CNN(0x04)   // bit0 busy, bit1 done, bit2 error
#define CNN_IN_ADDR CNN(0x08)
#define CNN_W_ADDR  CNN(0x0c)
#define CNN_OUT_ADDR CNN(0x10)
#define CNN_LEN     CNN(0x14)
#define CNN_RESULT  CNN(0x18)

#define CTRL_GO     0x1
#define STATUS_DONE 0x2

// --- shared SRAM scratch layout ---
static constexpr uintptr_t SRAM_BASE = 0x20000000u;
static constexpr uintptr_t IN_ADDR  = SRAM_BASE + 0x000;
static constexpr uintptr_t W_ADDR   = SRAM_BASE + 0x100;
static constexpr uintptr_t OUT_ADDR = SRAM_BASE + 0x200;
// Result mailbox the testbench can read back.
static constexpr uintptr_t MBOX     = SRAM_BASE + 0x800;
static constexpr uint32_t MAGIC_PASS = 0x600D600Du;
static constexpr uint32_t MAGIC_FAIL = 0xDEADDEADu;

static constexpr int32_t EXPECTED = -41;   // the dot product below

// Pack 4 signed int8 into a word (lane j at bits [8j+7:8j]).
static inline uint32_t pack4(int8_t a, int8_t b, int8_t c, int8_t d) {
  return (uint8_t)a | ((uint8_t)b << 8) | ((uint8_t)c << 16) | ((uint8_t)d << 24);
}

static inline void fence() { asm volatile("fence" ::: "memory"); }

int main() {
  volatile uint32_t *in_buf  = reinterpret_cast<volatile uint32_t *>(IN_ADDR);
  volatile uint32_t *w_buf   = reinterpret_cast<volatile uint32_t *>(W_ADDR);
  volatile int32_t  *out_buf = reinterpret_cast<volatile int32_t  *>(OUT_ADDR);
  volatile uint32_t *mbox    = reinterpret_cast<volatile uint32_t *>(MBOX);

  // in = [1,-2,3,-4,5,6], w = [-1,2,-3,4,5,-6]; LEN=6 leaves lanes 6,7 unused,
  // so we stuff them with garbage the engine must ignore (tail masking).
  in_buf[0] = pack4(1, -2, 3, -4);
  in_buf[1] = pack4(5, 6, 100, -100);
  w_buf[0]  = pack4(-1, 2, -3, 4);
  w_buf[1]  = pack4(5, -6, 50, -50);

  // Make sure our SRAM writes are visible before the engine DMA-reads them.
  fence();

  CNN_IN_ADDR  = (int32_t)IN_ADDR;
  CNN_W_ADDR   = (int32_t)W_ADDR;
  CNN_OUT_ADDR = (int32_t)OUT_ADDR;
  CNN_LEN      = 6;
  CNN_CTRL     = CTRL_GO;

  while (!(CNN_STATUS & STATUS_DONE)) { /* spin until done */ }

  fence();  // ensure the engine's write-back to OUT_ADDR is visible to us

  int32_t result = CNN_RESULT;
  mbox[1] = (uint32_t)result;

  if (result == EXPECTED && out_buf[0] == EXPECTED) {
    mbox[0] = MAGIC_PASS;
    return 0;                    // clean halt -> "Simulator halted successfully."
  }
  mbox[0] = MAGIC_FAIL;
  for (;;) { asm volatile("nop"); }   // hang -> testbench timeout = FAIL
}
