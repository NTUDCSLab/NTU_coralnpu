#!/bin/bash
# =============================================================================
# run_bootloader.sh — boot the CnnAccel firmware on the whole chip the way the
# silicon does, in pure SystemVerilog on VCS.
#
# The reproduced AUTOBOOT sequence in tb_cnn_boot_sv.sv releases the core by
# writing the reset CSR (0x30000) over real TL-UL WITH SECDED integrity — no
# hierarchical reset poke. The firmware runs and prints its verdict over UART1,
# which a device BFM in the TB captures. (Firmware image is staged via the sram
# backdoor for memory init; the boot + verdict paths use real ports.)
#
# Requires: vcs on PATH (source your VCS env) + bazel (for the firmware ELF).
# Run ../build_coralnpu.sh first (it emits 01_RTL/CoralNPUChiselSubsystem.sv).
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../01_RTL"
REPO="$(cd "$HERE/../.." && pwd)"
DPI="$REPO/hdl/verilog"
WORK="$HERE/work"; mkdir -p "$WORK"

command -v vcs >/dev/null || { echo "ERROR: vcs not on PATH — source your VCS env first."; exit 1; }
[ -f "$RTL/CoralNPUChiselSubsystem.sv" ] || { echo "ERROR: run ../build_coralnpu.sh first."; exit 1; }
BAZEL="$(command -v bazel || command -v bazelisk || echo "$HOME/bin/bazel")"

echo "[boot] building CnnAccel UART firmware..."
(cd "$REPO" && "$BAZEL" build //custom_ip/00_TB:cnn_boot_app.elf)
ELF="$(find -L "$REPO/bazel-out" -type f -name cnn_boot_app.elf -path '*custom_ip*' | head -1)"

cd "$WORK"
echo "[boot] compiling chip + autoboot TB + sram_backdoor DPI (VCS)..."
vcs -full64 -sverilog -timescale=1ns/1ps +define+VCS +notimingcheck -q \
  +define+USE_GENERIC +define+TB_SUPPORT +define+ZVE32F_ON +define+VLEN_128 \
  "$RTL/CoralNPUChiselSubsystem.sv" "$HERE/tb_cnn_boot_sv.sv" \
  "$DPI/sram_backdoor.cc" -CFLAGS "-I$DPI" \
  -o simv_boot -l boot_compile.log
echo "[boot] running..."
./simv_boot +binary="$ELF" -l boot_run.log
