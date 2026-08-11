#!/bin/bash
# =============================================================================
# build_coralnpu.sh — build the Coral NPU and stage everything the testbenches
# need, using bazel (Chisel -> firtool for the RTL, RISC-V toolchain for the fw).
#
#   Produces:
#     01_RTL/CoralNPUChiselSubsystem.sv   the whole-chip SystemVerilog (generated)
#     00_TB/cnn_chip_test.elf             the firmware the chip runs (generated)
#
# After this, run the sims with pure VCS via 00_TB/run.sh (no bazel needed there).
#
# Requires: bazel (bazelisk) + your conda env on PATH.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"     # custom_ip/ lives at the repo root
cd "$REPO"

echo "[build_coralnpu] emitting whole-chip RTL (Chisel -> firtool)..."
bazel build //hdl/chisel/src/soc:CoralNPUChiselSubsystem.sv
CHIP_SV="$(find -L "$REPO/bazel-bin/hdl/chisel/src/soc" -name CoralNPUChiselSubsystem.sv | head -1)"
cp -f "$CHIP_SV" "$HERE/01_RTL/CoralNPUChiselSubsystem.sv"
echo "[build_coralnpu]   -> 01_RTL/CoralNPUChiselSubsystem.sv ($(wc -l < "$HERE/01_RTL/CoralNPUChiselSubsystem.sv") lines)"

echo "[build_coralnpu] building firmware (RISC-V)..."
bazel build //custom_ip/00_TB:cnn_chip_test.elf
ELF="$(find -L "$REPO/bazel-out" -type f -name cnn_chip_test.elf -path '*custom_ip/00_TB*' | head -1)"
cp -f "$ELF" "$HERE/00_TB/cnn_chip_test.elf"
echo "[build_coralnpu]   -> 00_TB/cnn_chip_test.elf"

echo "[build_coralnpu] done. Now: cd 00_TB && ./run.sh"
