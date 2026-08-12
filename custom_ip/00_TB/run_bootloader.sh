#!/bin/bash
# =============================================================================
# run_bootloader.sh — whole-chip SELF-LOAD on VCS (pure SystemVerilog).
#
# tb_cnn_boot_sv.sv reproduces an fpga-style HARDWARE AUTOBOOT (fpga/rtl/autoboot.sv)
# that, over the real TL-UL bus WITH SECDED integrity, TRIGGERS THE ON-CHIP DMA to
# copy the firmware from external ROM into ITCM, then releases the core:
#
#   0x30000 = 0x1         un-gate core clock, hold in reset
#   0x40050008 = 0x10000000   DMA DESC_ADDR (descriptor lives in external ROM)
#   0x40050000 = 0x3          DMA CTRL = enable|start  -> copies ROM -> ITCM
#   (wait for DMA status_done)
#   0x30000 = 0x0         release reset -> core boots from ITCM(0x0)
#
# The whole chip self-loads from external memory — no CPU boot-stub, no SPI. PASS =
# the core halts cleanly (cnn_chip_test writes MAGIC_PASS and returns only when the
# CnnAccel result is correct; the FAIL path spins forever -> TB timeout).
#
# Requires: vcs on PATH (source your VCS env first) + bazel (for the firmware ELF),
# and the emitted chip .sv from ../build_coralnpu.sh.  The crossbar must map
#   "autoboot" -> Seq("coralnpu_device", "dma")   (CrossbarConfig.scala)
# so the autoboot host can reach the DMA; regenerate the .sv if you changed it.
# =============================================================================
set -euo pipefail

# Strip the Cadence/Verdi libstdc++ (from cvsd.cshrc) that crashes bazel (CXXABI).
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  export LD_LIBRARY_PATH="$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' \
    | grep -ivE 'cadence|innovus|verdi|spyglass' | paste -sd: -)"
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../01_RTL"
REPO="$(cd "$HERE/../.." && pwd)"
DPI="$REPO/hdl/verilog"                 # sram_backdoor.{cc,h} (DPI-backed on-chip SRAMs)
WORK="$HERE/work"; mkdir -p "$WORK"

command -v vcs >/dev/null || { echo "ERROR: vcs not on PATH — source your VCS env first."; exit 1; }
[ -f "$RTL/CoralNPUChiselSubsystem.sv" ] || { echo "ERROR: run ../build_coralnpu.sh first (emits the chip .sv)."; exit 1; }
[ -f "$HERE/cnn_chip_test.elf" ]         || { echo "ERROR: run ../build_coralnpu.sh first (builds cnn_chip_test.elf)."; exit 1; }

# Stage the external ROM image the DMA reads: [ DMA descriptor @ 0x10000000 ][ app @ 0x10001000 ].
echo "[boot] staging external ROM image [DMA descriptor | app] from cnn_chip_test.elf..."
python3 - "$HERE/cnn_chip_test.elf" "$HERE/rom_boot.hex" <<'PY'
import struct, sys
elf, out = sys.argv[1], sys.argv[2]
with open(elf, 'rb') as f: d = f.read()
e_phoff = struct.unpack_from('<I', d, 0x1c)[0]
e_phnum = struct.unpack_from('<H', d, 0x2c)[0]
seg = None
for i in range(e_phnum):                      # find the ITCM LOAD segment (paddr 0x0)
    o = e_phoff + i * 0x20
    p_type, p_off, p_va, p_pa, p_fsz = struct.unpack_from('<IIIII', d, o)
    if p_type == 1 and p_pa == 0 and p_fsz > 0:
        seg = (p_off, p_fsz); break
assert seg, "no ITCM (paddr 0x0) LOAD segment in ELF"
off, fsz = seg
app = d[off:off + fsz]
while len(app) % 4: app += b'\x00'
words = [struct.unpack('<I', app[i:i+4])[0] for i in range(0, len(app), 4)]
APP = 0x400                                    # app @ ROM word 0x400 -> byte 0x1000 -> 0x10001000
rom = [0] * (APP + len(words))
rom[0] = 0x10001000                            # desc.src  = app in ROM
rom[1] = 0x00000000                            # desc.dst  = ITCM 0x0
rom[2] = (len(app) & 0xFFFFFF) | (2 << 24)     # desc.len | width_log2=2 (4B beats)
rom[3] = 0x00000000                            # desc.next = none
for i, w in enumerate(words): rom[APP + i] = w
with open(out, 'w') as g:
    for w in rom: g.write('%08x\n' % w)
print("  app=%d bytes (%d words) -> %s (%d lines)" % (len(app), len(words), out, len(rom)))
PY

cd "$WORK"
echo "[boot] compiling chip + autoboot TB + sram_backdoor DPI (VCS)..."
vcs -full64 -sverilog -timescale=1ns/1ps +define+VCS +notimingcheck -q \
  +define+USE_GENERIC +define+TB_SUPPORT +define+ZVE32F_ON +define+VLEN_128 \
  "$RTL/CoralNPUChiselSubsystem.sv" "$HERE/tb_cnn_boot_sv.sv" \
  "$DPI/sram_backdoor.cc" -CFLAGS "-I$DPI" \
  -o simv_boot -l boot_compile.log
echo "[boot] running self-load (autoboot -> DMA -> ITCM -> core halt)..."
./simv_boot -l boot_run.log
