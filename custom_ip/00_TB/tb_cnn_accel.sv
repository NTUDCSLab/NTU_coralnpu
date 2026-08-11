// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// =============================================================================
// tb_cnn_accel.sv — a STANDALONE, pure-SystemVerilog unit testbench for CnnAccel.
//
// This tests the accelerator in isolation (no SoC, no Python, no cocotb). It is
// possible to keep it this simple ONLY because CnnAccelImpl ignores TL-UL bus
// integrity (SECDED) — so the TB never has to compute ECC bits. Two BFMs:
//   * a CSR master that drives the `tl_device` slave port (we act as the CPU), and
//   * a 1 KB memory model that services the `tl_device`... no — the `tl_host`
//     master port, serving the engine's operand reads and result write.
//
// Use this as the fast inner loop while bringing up your datapath. For the
// SoC-level integration test (CPU -> crossbar -> your IP over real TL-UL with
// integrity), use the cocotb AccelHarness instead — see doc/tutorials/testing_your_ip.md.
//
// Run it:
//   ./run.sh unit
//   # or directly:  vcs -full64 -sverilog ../01_RTL/CnnAccel.sv tb_cnn_accel.sv -o simv && ./simv
//   # (iverilog also works: iverilog -g2012 -o tb ../01_RTL/CnnAccel.sv tb_cnn_accel.sv && ./tb)
// =============================================================================

`timescale 1ns/1ps

module tb_cnn_accel;

  // ---- CSR map (offsets) ----
  localparam [11:0] R_CTRL=12'h000, R_STATUS=12'h004, R_IN=12'h008,
                    R_W=12'h00c, R_OUT=12'h010, R_LEN=12'h014, R_RESULT=12'h018;
  localparam [2:0] OP_PUT_FULL=3'd0, OP_GET=3'd4, OP_ACK=3'd0, OP_ACK_DATA=3'd1;

  // Buffer base addresses in our fake memory (keep them 16-byte aligned).
  localparam [31:0] IN_ADDR=32'h0000_0000, W_ADDR=32'h0000_0100, OUT_ADDR=32'h0000_0200;

  reg clock = 1'b0;
  reg reset = 1'b1;
  always #5 clock = ~clock;   // 100 MHz

  // ------------------------------------------------------------------ DUT nets
  // tl_device (CSR slave): TB drives A, reads D.
  reg          d_a_valid;
  reg  [2:0]   d_a_opcode;
  reg  [1:0]   d_a_size;
  reg  [9:0]   d_a_source;
  reg  [31:0]  d_a_address;
  reg  [3:0]   d_a_mask;
  reg  [31:0]  d_a_data;
  wire         d_a_ready;
  wire         d_d_valid;
  wire [2:0]   d_d_opcode;
  wire [31:0]  d_d_data;
  wire         d_d_error;

  // tl_host (bus master): DUT drives A, TB memory model drives D.
  wire         h_a_valid;
  wire [2:0]   h_a_opcode;
  wire [3:0]   h_a_size;
  wire [31:0]  h_a_address;
  wire [15:0]  h_a_mask;
  wire [127:0] h_a_data;
  reg          h_a_ready;
  reg          h_d_valid;
  reg  [2:0]   h_d_opcode;
  reg  [127:0] h_d_data;
  wire         h_d_ready;

  wire         irq;

  // ------------------------------------------------------------ memory model
  reg [31:0] mem [0:1023];               // word-addressed: mem[byte_addr>>2]
  reg        h_pending;
  reg [2:0]  h_op_q;
  reg [29:0] h_word_q;                    // captured word index of the request
  wire [29:0] h_base = {h_word_q[29:2], 2'b00};  // 16-byte-aligned word group

  assign h_a_ready = ~h_pending;

  // plain `always` (not always_ff): `mem` is a TB array also preloaded by the
  // initial block, which VCS's always_ff single-driver rule would reject.
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      h_pending <= 1'b0; h_d_valid <= 1'b0; h_d_opcode <= OP_ACK; h_d_data <= 128'b0;
    end else begin
      // Accept a request (single outstanding, matching the DUT).
      if (h_a_valid && h_a_ready) begin
        h_pending <= 1'b1;
        h_op_q    <= h_a_opcode;
        h_word_q  <= h_a_address[31:2];
        if (h_a_opcode == OP_PUT_FULL)   // commit the result write immediately
          mem[h_a_address[31:2]] <= h_a_data >> {h_a_address[3:0], 3'b000};
      end
      // Drive the response one cycle later.
      if (h_pending && !h_d_valid) begin
        h_d_valid  <= 1'b1;
        h_d_opcode <= (h_op_q == OP_GET) ? OP_ACK_DATA : OP_ACK;
        // Return the full 16-byte line; the engine shifts out the word it wants.
        h_d_data   <= {mem[h_base+3], mem[h_base+2], mem[h_base+1], mem[h_base+0]};
      end
      if (h_d_valid && h_d_ready) begin  // response accepted
        h_d_valid <= 1'b0;
        h_pending <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------- DUT
  CnnAccelImpl dut (
    .clock(clock), .reset(reset),
    // host A
    .tl_host_a_ready(h_a_ready), .tl_host_a_valid(h_a_valid),
    .tl_host_a_bits_opcode(h_a_opcode), .tl_host_a_bits_param(),
    .tl_host_a_bits_size(h_a_size), .tl_host_a_bits_source(),
    .tl_host_a_bits_address(h_a_address), .tl_host_a_bits_mask(h_a_mask),
    .tl_host_a_bits_data(h_a_data), .tl_host_a_bits_user_rsvd(),
    .tl_host_a_bits_user_instr_type(), .tl_host_a_bits_user_cmd_intg(),
    .tl_host_a_bits_user_data_intg(),
    // host D
    .tl_host_d_ready(h_d_ready), .tl_host_d_valid(h_d_valid),
    .tl_host_d_bits_opcode(h_d_opcode), .tl_host_d_bits_param(3'b0),
    .tl_host_d_bits_size(4'd2), .tl_host_d_bits_source(6'b0),
    .tl_host_d_bits_sink(1'b0), .tl_host_d_bits_data(h_d_data),
    .tl_host_d_bits_user_rsp_intg(7'b0), .tl_host_d_bits_user_data_intg(7'b0),
    .tl_host_d_bits_error(1'b0),
    // device A
    .tl_device_a_ready(d_a_ready), .tl_device_a_valid(d_a_valid),
    .tl_device_a_bits_opcode(d_a_opcode), .tl_device_a_bits_param(3'b0),
    .tl_device_a_bits_size(d_a_size), .tl_device_a_bits_source(d_a_source),
    .tl_device_a_bits_address(d_a_address), .tl_device_a_bits_mask(d_a_mask),
    .tl_device_a_bits_data(d_a_data), .tl_device_a_bits_user_rsvd(5'b0),
    .tl_device_a_bits_user_instr_type(4'b0), .tl_device_a_bits_user_cmd_intg(7'b0),
    .tl_device_a_bits_user_data_intg(7'b0),
    // device D
    .tl_device_d_ready(1'b1), .tl_device_d_valid(d_d_valid),
    .tl_device_d_bits_opcode(d_d_opcode), .tl_device_d_bits_param(),
    .tl_device_d_bits_size(), .tl_device_d_bits_source(), .tl_device_d_bits_sink(),
    .tl_device_d_bits_data(d_d_data), .tl_device_d_bits_user_rsp_intg(),
    .tl_device_d_bits_user_data_intg(), .tl_device_d_bits_error(d_d_error),
    .irq(irq)
  );

  // -------------------------------------------------------------- CSR tasks
  // Write a 32-bit config register.
  task automatic csr_write(input [11:0] off, input [31:0] data);
    begin
      @(posedge clock);
      d_a_valid <= 1'b1; d_a_opcode <= OP_PUT_FULL; d_a_size <= 2'd2;
      d_a_source <= 10'd1; d_a_address <= {20'b0, off}; d_a_mask <= 4'hf;
      d_a_data <= data;
      @(posedge clock);
      while (!d_a_ready) @(posedge clock);   // wait until accepted
      d_a_valid <= 1'b0;
      while (!d_d_valid) @(posedge clock);   // wait for the AccessAck
      @(posedge clock);
    end
  endtask

  // Read a 32-bit register into `data`.
  task automatic csr_read(input [11:0] off, output [31:0] data);
    begin
      @(posedge clock);
      d_a_valid <= 1'b1; d_a_opcode <= OP_GET; d_a_size <= 2'd2;
      d_a_source <= 10'd2; d_a_address <= {20'b0, off}; d_a_mask <= 4'h0;
      d_a_data <= 32'b0;
      @(posedge clock);
      while (!d_a_ready) @(posedge clock);
      d_a_valid <= 1'b0;
      while (!d_d_valid) @(posedge clock);
      data = d_d_data;                       // AccessAckData payload
      @(posedge clock);
    end
  endtask

  // Pack 4 signed int8 into a word (lane j at bits [8j+7:8j]).
  function [31:0] pack4(input signed [7:0] a, b, c, d);
    pack4 = {d, c, b, a};
  endfunction

  // ------------------------------------------------------------------ test
  integer errors = 0;
  integer i;
  reg [31:0] rdata, status;
  localparam signed [31:0] EXPECTED = -41;   // sum of the dot product below

  task automatic check(input [255:0] name, input signed [31:0] got, exp);
    begin
      if (got !== exp) begin
        errors = errors + 1;
        $display("  [FAIL] %0s: got %0d (0x%08h), expected %0d (0x%08h)",
                 name, got, got, exp, exp);
      end else begin
        $display("  [ ok ] %0s = %0d (0x%08h)", name, got, got);
      end
    end
  endtask

  initial begin
    // init
    d_a_valid = 0; d_a_opcode = 0; d_a_size = 0; d_a_source = 0;
    d_a_address = 0; d_a_mask = 0; d_a_data = 0;
    for (i = 0; i < 1024; i = i + 1) mem[i] = 32'b0;

    // reset
    reset = 1'b1;
    repeat (5) @(posedge clock);
    reset = 1'b0;
    @(posedge clock);

    $display("== tb_cnn_accel ==");

    // --- Test 1: CSR round-trip (proves the slave path works) ---
    csr_read(R_STATUS, status);
    check("status after reset", status, 32'd0);
    csr_write(R_IN, 32'h2000_1000);
    csr_read(R_IN, rdata);
    check("IN_ADDR readback", rdata, 32'h2000_1000);

    // --- Test 2: int8 dot product, LEN=6 (tail-masking path) ---
    // in = [1,-2,3,-4,5,6], w = [-1,2,-3,4,5,-6]; lanes 6,7 hold garbage.
    mem[IN_ADDR>>2]     = pack4(1, -2, 3, -4);
    mem[(IN_ADDR>>2)+1] = pack4(5, 6, 100, -100);   // 100,-100 must be ignored
    mem[W_ADDR>>2]      = pack4(-1, 2, -3, 4);
    mem[(W_ADDR>>2)+1]  = pack4(5, -6, 50, -50);     // 50,-50 must be ignored

    csr_write(R_IN,  IN_ADDR);
    csr_write(R_W,   W_ADDR);
    csr_write(R_OUT, OUT_ADDR);
    csr_write(R_LEN, 32'd6);
    csr_write(R_CTRL, 32'h3);       // GO | IRQ_EN

    // wait for done (STATUS bit1), with a timeout
    status = 0;
    for (i = 0; i < 1000 && !(status & 32'h2); i = i + 1) csr_read(R_STATUS, status);
    if (!(status & 32'h2)) begin
      errors = errors + 1; $display("  [FAIL] engine never asserted done");
    end

    csr_read(R_RESULT, rdata);
    check("RESULT csr",     $signed(rdata),           EXPECTED);
    check("OUT in memory",  $signed(mem[OUT_ADDR>>2]), EXPECTED);
    check("irq asserted",   irq,                       1'b1);

    // --- Test 3: W1C clear -> done & irq drop ---
    csr_write(R_CTRL, 32'h6);       // CLEAR | IRQ_EN
    csr_read(R_STATUS, status);
    check("done cleared", (status & 32'h2) >> 1, 1'b0);
    check("irq deasserted", irq, 1'b0);

    // --- verdict ---
    if (errors == 0) $display("== PASS: all checks passed ==");
    else             $display("== FAIL: %0d check(s) failed ==", errors);
    $finish;
  end

  // global watchdog
  initial begin
    #100000;
    $display("== FAIL: global timeout ==");
    $finish;
  end

endmodule
