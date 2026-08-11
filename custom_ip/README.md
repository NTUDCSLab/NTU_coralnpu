# `custom_ip` — standalone custom-IP workspace (Coral NPU)

The `CnnAccel` int8 engine as a self-contained IP: design RTL, SystemVerilog
testbenches, and a VCS run flow. ASIC-style layout so a junior can drop in their
own engine and reuse the exact flow.

## Layout

```
custom_ip/
  build_coralnpu.sh          build Coral NPU -> emit chip SV + firmware (bazel)
  01_RTL/                    design RTL
    CnnAccel.sv              the IP (hand-written SV; also wired into the SoC
                             via the Chisel BlackBox shim)
    CoralNPUChiselSubsystem.sv   GENERATED whole-chip SV (by build_coralnpu.sh)
  00_TB/                     testbenches + VCS run script
    tb_cnn_accel.sv          IP unit testbench
    tb_cnn_chip_sv.sv        whole-chip testbench (CPU boots firmware, drives IP)
    cnn_chip_test.cc         firmware the chip runs to exercise the IP
    run.sh                   VCS runner: ./run.sh [unit|chip|both]
    BUILD                    firmware build target (coralnpu_v2_binary)
```

## Flow

```bash
# 0. one-time: put vcs + bazel on PATH (source your VCS env + conda env)

# 1. generate the whole-chip RTL + firmware (re-run after any RTL change):
./build_coralnpu.sh
#    -> 01_RTL/CoralNPUChiselSubsystem.sv   (154k-line emitted chip)
#    -> 00_TB/cnn_chip_test.elf

# 2. run the testbenches on VCS:
cd 00_TB && ./run.sh          # both; or ./run.sh unit / ./run.sh chip
```

## The two testbenches

- **unit** (`tb_cnn_accel.sv`) — instantiates `CnnAccelImpl` alone with a tiny TL-UL
  CSR master + memory model; checks the signed int8 dot product (result −41).
  Pass → `== PASS: all checks passed ==`. Needs only `01_RTL/CnnAccel.sv` (no bazel).
- **chip** (`tb_cnn_chip_sv.sv`) — instantiates the *whole emitted chip*, backdoor-
  loads the firmware, boots the Coral core (which programs and runs the IP over the
  real crossbar), and waits for halt. Pass → `== PASS: chip halted cleanly ... ==`.

Both are pure SystemVerilog driven by VCS; the whole-chip TB links the
`sram_backdoor` DPI (from `hdl/verilog/`) to load firmware and boots the core by
poking its reset register (`dut.rvv_core.coreAxi.csr.resetReg = 0`).

## Adapting to your own IP

**File-by-file checklist: [`INTEGRATION.md`](INTEGRATION.md).** In short:

1. Replace `01_RTL/CnnAccel.sv` with your engine (keep the Chisel BlackBox shim
   `hdl/chisel/src/bus/CnnAccel.scala` pointing at it — it pulls the SV in via
   `addResource` from `//custom_ip/01_RTL:CnnAccel.sv`).
2. Update `00_TB/tb_cnn_accel.sv` (unit stimulus) and `00_TB/cnn_chip_test.cc`
   (the firmware CSR sequence) for your registers.
3. If your top-level ports change, regenerate `tb_cnn_chip_sv.sv` from the chip's
   port list (its header documents the tie-off rule).

> The IP design lives **only** here (`01_RTL/CnnAccel.sv`); the SoC build references
> it from this location, so there is a single source of truth.
