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
