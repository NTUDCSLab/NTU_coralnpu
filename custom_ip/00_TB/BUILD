# Copyright 2026 Google LLC
# Licensed under the Apache License, Version 2.0.
#
# The whole-chip testbench (tb_cnn_chip_sv.sv) runs firmware on the Coral core.
# cnn_chip_test.cc is that firmware; it needs the Coral RISC-V toolchain, so it is
# built with bazel (coralnpu_v2_binary) into cnn_chip_test.elf. ../build_coralnpu.sh
# builds this and copies the ELF next to the testbench for the pure-VCS run.sh.

load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")

package(default_visibility = ["//visibility:public"])

coralnpu_v2_binary(
    name = "cnn_chip_test",
    srcs = ["cnn_chip_test.cc"],
)

# The CNN firmware for the whole-chip BOOTLOADER test: it drives CnnAccel and
# prints its verdict over UART, so it is independent of how it's loaded/booted.
# Built as a plain binary (the coralnpu_v2_sim_test *runner* pulls an FTDI/libftdi1
# dep that doesn't build here; the ROM-bootloader flow below avoids it). Its ELF is
# packed into a SPI-flash image and booted by the chip's own ROM bootloader.
coralnpu_v2_binary(
    name = "cnn_boot_app",
    srcs = ["cnn_boot_test.cc"],
    deps = ["//fpga:uart"],
)
