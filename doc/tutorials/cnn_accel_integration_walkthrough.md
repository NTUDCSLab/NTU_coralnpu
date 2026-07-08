# Walkthrough: Integrating a CNN/MatMul Engine (`CnnAccel`)

A concrete, reproducible record of integrating one real compute accelerator into the
Coral NPU SoC via **Path A (MMIO + DMA)**. It follows the recipe in
[`integrating_new_ip.md`](integrating_new_ip.md) and ends with a passing simulation.

> **Result:** the engine elaborates into `CoralNPUChiselSubsystem.sv`, is wired into the
> TL-UL crossbar, and a cocotb test drives it end to end —
> `test_cnn_dot_product` produces **`result = 115`** = `[1,2,3,4,5]·[5,6,7,8,9]`, verified
> via both the `RESULT` CSR and the DMA-written value in SRAM. **2/2 tests pass on Verilator.**

---

## 1. What we built

`CnnAccel` is a minimal but genuine CNN/GEMM primitive: a **length-`LEN` integer dot product**
(multiply-accumulate) — the kernel at the heart of convolution and matmul:

```
RESULT = sum_{i=0..LEN-1} IN[i] * W[i]        (uint32 MAC)
```

It is a TileLink-UL **bus device** shaped exactly like `DmaEngine`:

- a **CSR slave** (`tl_device`) the core writes to configure and kick it, and
- a **bus master** (`tl_host`) that DMA-reads the operands and DMA-writes the result.

**CSR map** (base `0x40060000`, the free 4 KB slot between `dma` @ `0x40050000` and
`spi_master_flash` @ `0x40070000`):

| Offset | Reg | Access | Meaning |
|---|---|---|---|
| `0x00` | CTRL | W | bit0 = GO (write 1 to start) |
| `0x04` | STATUS | RO | bit0 busy, bit1 done, bit2 error |
| `0x08` | IN_ADDR | RW | activation base address |
| `0x0c` | W_ADDR | RW | weight base address |
| `0x10` | OUT_ADDR | RW | result base address |
| `0x14` | LEN | RW | element count |
| `0x18` | RESULT | RO | accumulator read-back |

**Control flow:** firmware/host writes IN/W/OUT/LEN, sets `CTRL.GO`; the engine walks a
read-in → read-w → MAC loop (`Get` per operand), then `PutFullData` writes the accumulator to
`OUT_ADDR`, sets `STATUS.done`, and drops `busy`.

---

## 2. Files touched (6)

| # | File | Change |
|---|---|---|
| 1 | `hdl/chisel/src/bus/CnnAccel.scala` | **new** — the engine (copied `DmaEngine` structure) |
| 2 | `hdl/chisel/src/bus/BUILD` | add `CnnAccel.scala` to the `bus` `srcs` |
| 3 | `hdl/chisel/src/soc/CrossbarConfig.scala` | `HostConfig` + `DeviceConfig` + 3 connection edges |
| 4 | `hdl/chisel/src/soc/SoCChiselConfig.scala` | `CnnAccelParameters` + a `ChiselModuleConfig` |
| 5 | `hdl/chisel/src/soc/CoralNPUChiselSubsystem.scala` | the load-bearing `instantiateModule` match arm |
| 6 | `tests/cocotb/tlul/{test_cnn_accel.py,BUILD}` | **new** cocotb test + suite |

No change to the scalar core, decode, or pipeline — that is the whole point of Path A.

---

## 3. Step by step

### Step 1 — the engine module (`hdl/chisel/src/bus/CnnAccel.scala`)

Copied `DmaEngine.scala` and kept its exact skeleton, swapping the descriptor logic for a MAC loop:

- **Same dual-port `io`** (names matter — the auto-wiring loop looks them up by string):
  ```scala
  class CnnAccel(hostParams: Parameters, deviceParams: Parameters) extends Module {
    val hostTlulP   = new TLULParameters(hostParams)
    val deviceTlulP = new TLULParameters(deviceParams)
    val io = IO(new Bundle {
      val tl_host   = new OpenTitanTileLink.Host2Device(hostTlulP)            // bus master
      val tl_device = Flipped(new OpenTitanTileLink.Host2Device(deviceTlulP)) // CSR slave
    })
  ```
- **CSR enum with the `RSVD = 0xfff` sentinel** (keeps the `ChiselEnum` a full 12 bits, else the
  address decode collapses to the largest declared offset — a `DmaEngine` gotcha we inherited):
  ```scala
  object CnnReg extends ChiselEnum {
    val CTRL = Value(0x00.U(12.W)); val STATUS = Value(0x04.U(12.W))
    val IN_ADDR = Value(0x08.U(12.W)); val W_ADDR = Value(0x0c.U(12.W))
    val OUT_ADDR = Value(0x10.U(12.W)); val LEN = Value(0x14.U(12.W))
    val RESULT = Value(0x18.U(12.W)); val RSVD = Value(0xfff.U(12.W))
  }
  ```
- **The compute FSM** (`sIdle → sReadInReq/Resp → sReadWReq/Resp → …loop… → sWriteReq/Resp → sDone`)
  reuses `DmaEngine`'s host request/response pattern verbatim; only the datapath differs:
  ```scala
  when(state === sReadWResp && host_d_fire) {
    val w_word = extractWord(host_d_internal.bits.data, cur_w)
    acc    := (acc + in_word * w_word)(31, 0)   // multiply-accumulate
    idx    := idx + 1.U
    cur_in := cur_in + 4.U
    cur_w  := cur_w + 4.U
  }
  ```
- **Reused wholesale from `DmaEngine`:** `sizeMask`, the byte-offset `extractWord` shift, the host A
  channel builder (`opcode`/`size`/`mask`/`user.instr_type := MuBi4.False`), the four `Queue`s, and
  the device CSR read-mux / `AccessAck`/`AccessAckData` response with an `error` bit for unknown
  addresses and RO writes.

### Step 2 — register the module (`hdl/chisel/src/bus/BUILD`)

```python
chisel_library(
    name = "bus",
    srcs = [
        "Clint.scala",
        "CnnAccel.scala",   # <-- added
        "DmaEngine.scala",
        ...
```

### Step 3 — fabric map (`hdl/chisel/src/soc/CrossbarConfig.scala`)

Three edits (mirroring `dma`):

```scala
// (a) host — the engine masters the bus:
HostConfig("cnn_accel", width = 128),                            // in baseHosts, after "dma"

// (b) device — CSR slave at a fresh, non-overlapping range:
DeviceConfig("cnn_accel", Seq(AddressRange(0x40060000, 0x1000))), // in devices, after "dma"

// (c) connections — THREE edges:
"coralnpu_core" -> Seq(..., "dma", "cnn_accel", ...),   // CPU may program its CSRs
"cnn_accel"     -> Seq("sram", "coralnpu_device", "ddr_mem"), // engine may master these
// and grant the cocotb driver host too:
"test_host_32"  -> Seq(..., "dma", "cnn_accel", ...),
```

> **Why the `test_host_32` edge matters:** the cocotb integration test drives from the
> `test_host_32` port. Without granting it `cnn_accel`, the test's CSR writes are routed nowhere and
> error out. (Only present under `enableTestHarness`.)

The `CrossbarConfigValidator` confirmed no address overlap.

### Step 4 — instance list (`hdl/chisel/src/soc/SoCChiselConfig.scala`)

```scala
// params case class (must extend the sealed ModuleParameters trait):
case class CnnAccelParameters(hostDataBits: Int, deviceDataBits: Int) extends ModuleParameters

// instance in the `modules` Seq (copied from the `dma` block):
ChiselModuleConfig(
  name = "cnn_accel",
  moduleClass = "bus.CnnAccel",                         // documentation only
  params = CnnAccelParameters(hostDataBits = 128, deviceDataBits = 32),
  hostConnections   = Map("io.tl_host"   -> "cnn_accel"),
  deviceConnections = Map("io.tl_device" -> "cnn_accel"),
  externalPorts = Seq.empty)
```

### Step 5 — the load-bearing match arm (`hdl/chisel/src/soc/CoralNPUChiselSubsystem.scala`)

Instances are built by a **pattern-match on the params type**, not reflection — `moduleClass` above
is only documentation. Omit this arm and elaboration dies with `scala.MatchError`.

```scala
case p: CnnAccelParameters =>
  val host_p = new Parameters
  host_p.lsuDataBits = p.hostDataBits
  val device_p = new Parameters
  device_p.lsuDataBits = p.deviceDataBits
  device_p.axi2IdBits  = 10
  Module(new bus.CnnAccel(host_p, device_p))
```

Everything else — clock/reset (implicit, via the surrounding `withClockAndReset`), and the
`io.tl_host`/`io.tl_device` connections to the crossbar — is auto-wired by the generic loops from
the config maps. No per-module wiring.

### Step 6 — the test (`tests/cocotb/tlul/{test_cnn_accel.py,BUILD}`)

A cocotb suite mirroring `dma_integration_cocotb`, driving from `test_host_32`:

```python
# preload operands into SRAM, program CSRs, kick, poll, verify
for i, v in enumerate(in_vals):  await tl_write(host_if, in_addr + i*4, v)
for i, v in enumerate(w_vals):   await tl_write(host_if, w_addr  + i*4, v)
await tl_write(host_if, CNN_IN_ADDR, in_addr);  await tl_write(host_if, CNN_W_ADDR, w_addr)
await tl_write(host_if, CNN_OUT_ADDR, out_addr); await tl_write(host_if, CNN_LEN, n)
await tl_write(host_if, CNN_CTRL, 0x1)                       # GO
status = await poll_done(host_if)
assert await tl_read(host_if, CNN_RESULT) == expected        # CSR readback
assert await tl_read(host_if, out_addr)  == expected         # DMA-written to memory
```

---

## 4. Build, elaborate & test — the actual commands

All run in the VCS + conda environment (see the top-level [`README.md`](../../README.md)); Verilator
needs no license.

```bash
# (a) validate the crossbar config — compiles the config, checks address overlap
bazel run //hdl/chisel/src/soc:validate_crossbar_config
#   -> "Validation successful: No address range collisions found."
#   -> cnn_accel appears as host + device + connections

# (b) elaborate the whole SoC (Chisel -> firtool -> SystemVerilog) with the engine wired in
bazel build //hdl/chisel/src/soc:coralnpu_chisel_subsystem_cc_library_emit_verilog
#   -> Build completed successfully; CoralNPUChiselSubsystem.sv emitted
#   -> `module CnnAccel` defined once, instantiated as `cnn_accel` (562 wired signals)

# (c) build the Verilator testharness + run the cocotb tests
bazel test \
  //tests/cocotb/tlul:cnn_accel_integration_cocotb_test_cnn_csr_access \
  //tests/cocotb/tlul:cnn_accel_integration_cocotb_test_cnn_dot_product
#   -> test_cnn_csr_access   PASS
#   -> test_cnn_dot_product  PASS   (result = 115)
#   -> Executed 2 out of 2 tests: 2 tests pass.
```

(There is also a `vcs_*` variant of each test target for the licensed VCS flow.)

---

## 5. Gotchas hit (and how they showed up)

- **The `instantiateModule` match arm is mandatory.** It is a `sealed trait` match, so a missing arm
  is only a compile *warning*, then a runtime `scala.MatchError` at elaboration. Add it.
- **IO port names are looked up by string** (`io.tl_host`, `io.tl_device`). Renaming the bundle
  fields breaks the auto-wiring with a `NoSuchElementException`. Keep them.
- **Grant `test_host_32`**, or the cocotb driver can't reach the new CSRs (routes to nothing → error).
- **Keep the `RSVD = 0xfff` enum sentinel** or CSR address decode silently narrows.
- **Two connection edges, not one:** `coralnpu_core -> cnn_accel` (program it) *and*
  `cnn_accel -> {sram, ...}` (let it master memory). Missing either yields a dead master or an
  unreachable device.
- **Locating build artifacts:** `bazel-out` is a symlink, so `find -L bazel-out -name '*.sv'`
  (or the explicit `bazel-out/<cfg>/bin/...` path) — plain `find` won't descend it.

---

## 6. Where to take it next

This engine is a scalar-output dot product — deliberately simple to keep the first integration
correct and verifiable. Real CNN/GEMM extensions, all *inside `CnnAccel.scala`* with **no further SoC
changes** (the bus interface is done):

- **Tiling / output vectors:** loop the MAC over output channels, `PutFullData` a burst of results.
- **int8 × int8 → int32** with signed arithmetic and per-channel bias/requant.
- **Wider datapath:** issue larger `Get`s (`size` > 2) to stream multiple elements per beat and add a
  small MAC array (the host port is already 128-bit).
- **Interrupt on done:** add an `ExternalPort` for an IRQ line and wire it to the PLIC (see the
  CLINT/PLIC block in the subsystem) instead of polling `STATUS`.

For the general recipe and the other two integration paths (custom RVV instruction; in-core
functional unit), see [`integrating_new_ip.md`](integrating_new_ip.md).
