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
// cnn_stream_test.cc — TEACHING example: STREAM operands to the CnnAccel with the
// general-purpose DMA engine, then run the accelerator.
//
// The sibling test (cnn_chip_test.cc) has the CPU store the operands into SRAM by
// hand.  Real firmware almost never does that: the input tensors live off-chip
// (flash / DRAM), and a DMA engine streams them on-chip while the CPU does other
// work.  This test shows that data path end to end:
//
//     external ROM  --(general DMA, 0x40050000)-->  on-chip SRAM  --(CnnAccel
//     host-port read-master)-->  the engine  --(writes result back to SRAM)
//
// Two distinct "DMAs" appear here, and it is worth pointing juniors at both:
//   1. The general DMA engine (0x40050000): a memory->memory copier you program
//      with a descriptor (src, dst, length).  We use it to STREAM tensors in.
//   2. The CnnAccel's OWN host port: once you write its IN/W_ADDR CSRs and hit GO,
//      the engine streams those operands out of SRAM itself.  You never push data
//      into the engine; you point it at a buffer and it pulls.
//
// So "streaming data to the engine" = fill the engine's source buffer with a DMA,
// then hand the engine the address.  That is the whole pattern.
//
// Reports through the same mailbox + halt convention as cnn_chip_test.cc:
//   PASS -> MAGIC_PASS to the mailbox, then return (core halts cleanly).
//   FAIL -> MAGIC_FAIL to the mailbox, then spin (TB times out).
// =============================================================================

#include <cstdint>

// ---- general DMA engine: a memory->memory copier (see DmaEngine.scala) --------
static constexpr uintptr_t DMA_BASE = 0x40050000u;
#define DMA(off) (*reinterpret_cast<volatile uint32_t *>(DMA_BASE + (off)))
#define DMA_CTRL      DMA(0x00)   // bit0 ENABLE, bit1 START
#define DMA_STATUS    DMA(0x04)   // bit0 busy, bit1 done, bit2 error
#define DMA_DESC_ADDR DMA(0x08)   // address of the descriptor (in SRAM here)
#define DMA_GO        0x3         // ENABLE | START
#define DMA_DONE      0x2         // STATUS.done

// A DMA descriptor is 8 words in memory.  The engine reads it from DMA_DESC_ADDR:
//   [0] src address
//   [1] dst address
//   [2] len_flags = len_bytes[23:0] | width_log2<<24 | src_fixed<<27
//                                    | dst_fixed<<28 | poll_en<<29
//   [3] next-descriptor address (0 = single transfer)
//   [4..7] poll fields (unused here)
// width_log2 = 2 means 4-byte (one word) per beat.

// ---- CnnAccel MMIO register map (identical to cnn_chip_test.cc) ---------------
static constexpr uintptr_t CNN_BASE = 0x40060000u;
#define CNN(off) (*reinterpret_cast<volatile int32_t *>(CNN_BASE + (off)))
#define CNN_CTRL     CNN(0x00)   // bit0 GO, bit1 IRQ_EN, bit2 CLEAR
#define CNN_STATUS   CNN(0x04)   // bit0 busy, bit1 done, bit2 error
#define CNN_IN_ADDR  CNN(0x08)
#define CNN_W_ADDR   CNN(0x0c)
#define CNN_OUT_ADDR CNN(0x10)
#define CNN_LEN      CNN(0x14)
#define CNN_RESULT   CNN(0x18)
#define CNN_GO       0x1
#define CNN_DONE     0x2

// ---- memory map ---------------------------------------------------------------
// External DDR holds the input tensors (weights/activations that live off-chip in
// DRAM on a real system).  The TB's AXI BFM serves these at the ddr_mem base.
static constexpr uintptr_t DDR_IN = 0x80000000u;   // IN tensor: 2 words (int8 x8)
static constexpr uintptr_t DDR_W  = 0x80000100u;   // W  tensor: 2 words (int8 x8)

// On-chip SRAM: DMA staging buffers the engine reads from, plus scratch + mailbox.
static constexpr uintptr_t SRAM     = 0x20000000u;
static constexpr uintptr_t IN_ADDR  = SRAM + 0x000; // engine IN  buffer (DMA dst)
static constexpr uintptr_t W_ADDR   = SRAM + 0x100; // engine W   buffer (DMA dst)
static constexpr uintptr_t OUT_ADDR = SRAM + 0x200; // engine OUT buffer
static constexpr uintptr_t DESC     = SRAM + 0x400; // DMA descriptor scratch
static constexpr uintptr_t MBOX     = SRAM + 0x800; // result mailbox for the TB

static constexpr uint32_t MAGIC_PASS = 0x600D600Du;
static constexpr uint32_t MAGIC_FAIL = 0xDEADDEADu;
static constexpr int32_t  EXPECTED   = -41;         // dot product of the tensors below

static inline void fence() { asm volatile("fence" ::: "memory"); }

// Stream `nbytes` from `src` to `dst` with the general DMA engine, then wait.
// This is the reusable "bring a tile on-chip" helper.
static void dma_stream(uint32_t src, uint32_t dst, uint32_t nbytes) {
  volatile uint32_t *d = reinterpret_cast<volatile uint32_t *>(DESC);
  d[0] = src;
  d[1] = dst;
  d[2] = (nbytes & 0xFFFFFF) | (2u << 24);  // width_log2=2 (4B beats); src/dst increment
  d[3] = 0;                                 // no chained descriptor
  fence();                                  // descriptor must be visible before START

  DMA_DESC_ADDR = DESC;
  DMA_CTRL      = DMA_GO;                    // ENABLE | START -> engine fetches desc + copies
  while (!(DMA_STATUS & DMA_DONE)) { /* poll until this transfer completes */ }
}

int main() {
  volatile int32_t *out_buf = reinterpret_cast<volatile int32_t *>(OUT_ADDR);
  volatile uint32_t *mbox   = reinterpret_cast<volatile uint32_t *>(MBOX);

  // 1) STREAM the operands on-chip: external DDR -> SRAM, via the general DMA.
  //    The engine reads its operands from SRAM, so this is how off-chip (DRAM)
  //    tensors become engine-visible.  in = [1,-2,3,-4,5,6], w = [-1,2,-3,4,5,-6]
  //    (LEN=6; lanes 6,7 hold garbage the engine tail-masks).
  dma_stream(DDR_IN, IN_ADDR, 8);   // 8 bytes = 2 packed words
  dma_stream(DDR_W,  W_ADDR,  8);
  fence();                          // ensure the streamed data is visible to the engine

  // 2) Hand the accelerator the staged buffers and start it.  From here the
  //    CnnAccel's own host port streams IN/W out of SRAM and computes.
  CNN_IN_ADDR  = (int32_t)IN_ADDR;
  CNN_W_ADDR   = (int32_t)W_ADDR;
  CNN_OUT_ADDR = (int32_t)OUT_ADDR;
  CNN_LEN      = 6;
  CNN_CTRL     = CNN_GO;

  while (!(CNN_STATUS & CNN_DONE)) { /* spin until the engine finishes */ }
  fence();                          // engine's write-back to OUT_ADDR now visible

  // 3) Check + report.
  int32_t result = CNN_RESULT;
  mbox[1] = (uint32_t)result;
  if (result == EXPECTED && out_buf[0] == EXPECTED) {
    mbox[0] = MAGIC_PASS;
    return 0;                       // clean halt -> PASS
  }
  mbox[0] = MAGIC_FAIL;
  for (;;) { asm volatile("nop"); } // hang -> TB timeout = FAIL
}
