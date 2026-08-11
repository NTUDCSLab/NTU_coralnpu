# `CnnAccel` — the sample CNN engine

A deliberately small accelerator that computes **one signed int8 dot product**:

```
RESULT = Σ  (int8) IN[i] × (int8) W[i]        for i = 0 … LEN-1     (accumulated in int32)
```

That single operation is the atom of both convolution and matmul: a conv output
pixel is the dot product of a filter with an input patch, and a matmul element is
the dot product of a row and a column. So `CnnAccel` is the **MAC (multiply-
accumulate) kernel at the heart of a CNN**, exposed as a memory-mapped device —
just enough to show the *whole integration + test path* end to end without the
complexity of a real tiled array. (What it is **not**: see "Scope" below.)

## How it plugs in

It's a bus device on the SoC crossbar at **`0x40060000`** with two TileLink-UL
ports and an interrupt:

```
              ┌─────────────────────── CnnAccel ───────────────────────┐
  CPU  ──CSR──▶ tl_device (slave)   config + start + result             │
              │                                                          │
  SRAM ◀─DMA──▶ tl_host  (master)   reads IN[]/W[], writes RESULT        │
              │                                                          │
              │ 4-lane signed int8 multiply-accumulate  ────────────────┼──▶ irq
              └──────────────────────────────────────────────────────────┘
```

- **`tl_device`** — the CSR slave; the CPU writes config and reads status/result.
- **`tl_host`**  — a DMA master; the engine fetches operands from and writes the
  result back to shared SRAM itself (the CPU only hands it pointers).
- **`irq`** — asserted when done (if enabled), for interrupt-driven firmware.

## Register map (offsets from `0x40060000`)

| Off  | Name       | R/W | Meaning |
|------|------------|-----|---------|
| 0x00 | `CTRL`     | W   | bit0 **GO** (start), bit1 **IRQ_EN**, bit2 **CLEAR** (W1C: clear done/irq) |
| 0x04 | `STATUS`   | R   | bit0 **busy**, bit1 **done** (bit2 reserved, reads 0) |
| 0x08 | `IN_ADDR`  | R/W | byte address of the input vector in SRAM |
| 0x0C | `W_ADDR`   | R/W | byte address of the weight vector in SRAM |
| 0x10 | `OUT_ADDR` | R/W | byte address to write the int32 result |
| 0x14 | `LEN`      | R/W | number of int8 elements to accumulate |
| 0x18 | `RESULT`   | R   | the int32 dot product (also DMA'd to `OUT_ADDR`) |

## Data layout

Operands are **4 signed int8 packed per 32-bit word**, lane `j` in bits `[8j+7:8j]`
(little-endian lanes):

```
word = { W[i+3], W[i+2], W[i+1], W[i+0] }   // one 32-bit word = 4 int8
```

`LEN` need **not** be a multiple of 4: on the last word the engine **masks the tail
lanes** (elements past `LEN` are treated as 0), so garbage in the unused lanes is
ignored. The buses are 128-bit; the engine issues 4-byte accesses and shifts the
addressed word out of the wide beat, so keep buffers word-aligned.

## How it runs (the FSM)

```
IDLE ──GO──▶ RIN_REQ ▶ RIN_RSP ─┐         (read 4 input int8)
                                │
             RW_REQ  ▶ RW_RSP ──┤ acc += Σ lane_in·lane_w   (4-lane int8 MAC)
                ▲               │ i += 4
                └── more words ─┘
                                │ last word
             WR_REQ ▶ WR_RSP ▶ DONE ▶ IDLE   (DMA the int32 result to OUT_ADDR)
```

Per iteration it DMA-reads one input word and one weight word, does a 4-lane signed
multiply and adds the four products into the int32 accumulator, then advances by 4
elements. After `ceil(LEN/4)` words it writes the accumulator to `OUT_ADDR`, sets
`done` (and `irq` if `IRQ_EN`), and returns to idle.

## Driving it from firmware

The whole sequence (see [`../00_TB/cnn_chip_test.cc`](../00_TB/cnn_chip_test.cc)):

```c
// 1. stage operands in SRAM   2. point the engine at them   3. GO   4. wait   5. read
in_buf[0] = pack4(1,-2,3,-4);  in_buf[1] = pack4(5,6, …);     // + weights
fence();                                                       // visible before DMA
CNN_IN_ADDR = IN; CNN_W_ADDR = W; CNN_OUT_ADDR = OUT; CNN_LEN = 6;
CNN_CTRL = GO;
while (!(CNN_STATUS & DONE)) {}
int32_t r = CNN_RESULT;          // e.g. [1,-2,3,-4,5,6]·[-1,2,-3,4,5,-6] = -41
```

## Scope — what this sample is and isn't

- **Is:** a complete, synthesizable, self-checking MAC engine that exercises the
  full path — CSR control, DMA operand fetch, tail-masked int8 MAC, result write-
  back, and interrupt — so it's a faithful template for integrating and testing a
  *real* accelerator.
- **Isn't:** a production CNN engine. It does a single 1-D dot product with a
  4-wide MAC — no 2-D conv windows, no weight/activation tiling, no output-channel
  parallelism, no quantization/requant, no MAC array. A real engine (e.g. the lab's
  PRESTO) keeps this same CSR+DMA+irq shell but replaces the datapath with a large
  tiled MAC array. That shell is exactly what you reuse.

RTL: [`CnnAccel.sv`](CnnAccel.sv) · integration: [`../INTEGRATION.md`](../INTEGRATION.md).
