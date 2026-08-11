# Integrating a new IP into Coral NPU — one-page checklist

For a memory-mapped **MMIO + DMA** accelerator (the `CnnAccel` pattern). Copy the
CnnAccel code in each file; full detail in
[`../doc/tutorials/cnn_accel_integration_walkthrough.md`](../doc/tutorials/cnn_accel_integration_walkthrough.md).

Pick a name `<ip>` (e.g. `cnn_accel`) and an MMIO base (e.g. `0x40060000`, 4 KB).

---

### ☐ 1. IP RTL — `custom_ip/01_RTL/<IP>.sv`
Your engine. Expose two TL-UL ports (`tl_device` = CSR slave, `tl_host` = DMA
master) and any interrupt. Ignoring bus integrity keeps the SV simple.

### ☐ 2. Chisel BlackBox shim — `hdl/chisel/src/bus/<IP>.scala`
- `class <IP>Impl … extends BlackBox with HasBlackBoxResource` — mirror the SV
  ports **exactly** (explicit `clock`/`reset`, no `io_` prefix); `addResource("<IP>.sv")`.
- `class <IP> … extends Module` — a thin shim exposing `io.tl_host` / `io.tl_device` /
  `io.irq`, wired to the BlackBox. (The SoC generator wires the shim, not the BlackBox.)

### ☐ 2b. Bus BUILD — `hdl/chisel/src/bus/BUILD`
Add `<IP>.scala` to `srcs`, and on that library:
```python
resource_strip_prefix = "custom_ip/01_RTL",
resources = ["//custom_ip/01_RTL:<IP>.sv"],
```
Add `exports_files(["<IP>.sv"])` in `custom_ip/01_RTL/BUILD`.

### ☐ 3. Crossbar map — `hdl/chisel/src/soc/CrossbarConfig.scala`
- `devices += DeviceConfig("<ip>", Seq(AddressRange(0x40060000, 0x1000)))`
- if it DMAs: `hosts += HostConfig("<ip>", width = 128)`
- **`connections`** (the allow-list — easy to forget → bus error if missing):
  - grant the CPU **and** the test host: add `"<ip>"` to `coralnpu_core` and `test_host_32`.
  - if it's a host: `"<ip>" -> Seq("sram", "ddr_mem", …)` (what it may reach).

### ☐ 4. Instance config — `hdl/chisel/src/soc/SoCChiselConfig.scala`
- a `case class <IP>Parameters(...) extends ModuleParameters`
- a `ChiselModuleConfig` entry for it, exposing the IRQ:
  ```scala
  externalPorts = Seq(ExternalPort("<ip>_irq", Bool, Out, "io.irq"))
  ```

### ☐ 5. The load-bearing match arm — `hdl/chisel/src/soc/CoralNPUChiselSubsystem.scala`
Add to `instantiateModule`:
```scala
case p: <IP>Parameters => // instantiate new <IP>(...) and wire tl_host/tl_device/irq
```
⚠️ **Miss this and elaboration dies with `scala.MatchError`.**

### ☐ 6. Testbenches — `custom_ip/00_TB/`
- `tb_<ip>.sv` — unit TB (copy `tb_cnn_accel.sv`).
- `cnn_chip_test.cc` — firmware CSR sequence for the whole-chip TB; register it in
  `custom_ip/00_TB/BUILD` (`coralnpu_v2_binary`).
- regenerate `tb_cnn_chip_sv.sv` only if the chip's top-level ports changed.

---

### Build & test
```bash
cd custom_ip && ./build_coralnpu.sh   # emit chip SV + firmware (also proves 1–5 elaborate)
cd 00_TB && ./run.sh                    # unit + whole-chip on VCS
```

### The two that bite
1. **Step 3 `connections`** — no grant ⇒ the CPU/test-host routes to nothing ⇒ TL error.
2. **Step 5 match arm** — no arm ⇒ `scala.MatchError` at elaboration.
