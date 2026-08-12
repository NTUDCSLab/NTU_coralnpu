#!/bin/bash
# =============================================================================
# run.sh — run the custom-IP testbenches with VCS (pure SystemVerilog sim).
#
#   ./run.sh unit    IP unit testbench          (01_RTL/CnnAccel.sv + tb_cnn_accel.sv)
#   ./run.sh chip    whole-chip testbench       (needs ../build_coralnpu.sh first)
#   ./run.sh         both (default)
#
# Requires: vcs on PATH (source your VCS env first, e.g. `source ~/cvsd.cshrc`).
# The whole-chip test also needs the generated files produced by
# ../build_coralnpu.sh (the chip .sv and the firmware .elf).
# =============================================================================
set -euo pipefail

# Strip the Cadence/Verdi libstdc++ (from cvsd.cshrc) that crashes the bazel
# launcher with a CXXABI error; keep everything else.
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  export LD_LIBRARY_PATH="$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' \
    | grep -ivE 'cadence|innovus|verdi|spyglass' | paste -sd: -)"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../01_RTL"
REPO="$(cd "$HERE/../.." && pwd)"
DPI="$REPO/hdl/verilog"                 # sram_backdoor.{cc,h}
WORK="$HERE/work"; mkdir -p "$WORK"

command -v vcs >/dev/null || { echo "ERROR: vcs not on PATH — source your VCS env first."; exit 1; }

VCS_COMMON="-full64 -sverilog -timescale=1ns/1ps +define+VCS +notimingcheck -q"

run_unit() {
  echo "=================== UNIT IP TESTBENCH ==================="
  cd "$WORK"
  vcs $VCS_COMMON \
    "$RTL/CnnAccel.sv" "$HERE/tb_cnn_accel.sv" \
    -o simv_unit -l unit_compile.log
  ./simv_unit -l unit_run.log
}

run_chip() {
  echo "=================== WHOLE-CHIP TESTBENCH ==================="
  local CHIP="$RTL/CoralNPUChiselSubsystem.sv"
  local ELF="$HERE/cnn_chip_test.elf"
  [ -f "$CHIP" ] || { echo "ERROR: $CHIP missing — run ../build_coralnpu.sh first."; exit 1; }
  [ -f "$ELF" ]  || { echo "ERROR: $ELF missing — run ../build_coralnpu.sh first."; exit 1; }
  cd "$WORK"
  # RVV defines match the SoC build; sram_backdoor.cc is the DPI backdoor loader.
  vcs $VCS_COMMON \
    +define+USE_GENERIC +define+TB_SUPPORT +define+ZVE32F_ON +define+VLEN_128 \
    "$CHIP" "$HERE/tb_cnn_chip_sv.sv" \
    "$DPI/sram_backdoor.cc" -CFLAGS "-I$DPI" \
    -o simv_chip -l chip_compile.log
  ./simv_chip +binary="$ELF" -l chip_run.log
}

run_boot() {
  echo "=================== WHOLE-CHIP SELF-LOAD (AUTOBOOT -> DMA) ==================="
  "$HERE/run_bootloader.sh"
}

case "${1:-both}" in
  unit) run_unit ;;
  chip) run_chip ;;
  boot) run_boot ;;
  both) run_unit; run_chip ;;
  *) echo "usage: $0 [unit|chip|boot|both]"; exit 1 ;;
esac
