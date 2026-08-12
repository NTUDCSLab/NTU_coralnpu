// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy at
//     http://www.apache.org/licenses/LICENSE-2.0
//
// =============================================================================
// tb_cnn_stream_sv.sv - PURE-SYSTEMVERILOG whole-chip DMA-STREAMING testbench.
//
// Same chip + environment as tb_cnn_chip_sv.sv (peripheral ports tied off,
// backdoor-load the firmware, PASS = the core halts), with the input tensors held
// in EXTERNAL DDR.  The firmware (cnn_stream_test.cc) uses the general DMA engine
// to STREAM those tensors out of DDR into on-chip SRAM, then points the CnnAccel
// at the SRAM buffers -- the "feed an accelerator from DRAM with a DMA" pattern:
//
//     DDR (this AXI BFM) --(general DMA 0x40050000)--> SRAM --(CnnAccel)--> result
//
// DDR (ddr_mem, base 0x80000000) is a 256-bit AXI4 slave on the chip's async "ddr"
// clock domain.  Unlike the tie-off TBs, we DRIVE that clock and release its reset
// so the AXI crossing runs, and serve read beats with a small AXI BFM below.
//
// halted|wfi = PASS, fault = FAIL (cnn_stream_test halts only on the correct
// result; the fail path spins -> timeout).
//
// Run (needs the emitted chip .sv + firmware + operands.hex from build_coralnpu.sh):
//   ../build_coralnpu.sh   then   ./run.sh stream
// =============================================================================
`timescale 1ns/1ps

module tb_cnn_stream_sv;
  reg clk = 1'b0;
  reg rst_ni = 1'b0;
  wire halted, fault, wfi;

  always #5 clk = ~clk;   // 100 MHz

  // ============== DDR (AXI4 read) memory BFM — holds the input tensors ==============
  // ddr_mem is a 256-bit AXI4 slave at 0x80000000 on the async "ddr" clock domain.
  // The general DMA reads the operand tensors from here and streams them to SRAM.
  // read_addr_len is hardwired to 0 upstream, so every read is a single 256-bit
  // (32-byte) beat -> this BFM only serves the AR and R channels, one at a time.
  // ../build_coralnpu.sh writes operands.hex: word 0 (0x80000000)=IN, 0x40 (0x80000100)=W.
  wire         ddr_clk = clk;                  // run the DDR domain at the core clock
  reg  [31:0]  ddr_word [0:2047];
  initial $readmemh("../operands.hex", ddr_word);
  wire         dm_ar_valid, dm_r_ready;        // AR.valid / R.ready  (driven by the chip)
  wire [31:0]  dm_ar_addr;
  wire         dm_ar_id;
  reg          dm_r_valid = 1'b0;              // R.valid / R.data    (driven by this BFM)
  reg          dm_r_id;
  reg  [255:0] dm_r_data;
  wire         dm_ar_ready = !dm_r_valid;      // single outstanding: accept AR when R idle
  wire [12:0]  ddr_off = dm_ar_addr[12:0];     // low 8 KB is plenty for the operands
  wire [10:0]  wb      = {ddr_off[12:5], 3'b000};  // 32-byte-line-aligned word base (8 words)
  always @(posedge ddr_clk or negedge rst_ni) begin
    if (!rst_ni) begin
      dm_r_valid <= 1'b0;
    end else if (dm_ar_valid && dm_ar_ready) begin
      dm_r_valid <= 1'b1;
      dm_r_id    <= dm_ar_id;
      dm_r_data  <= {ddr_word[wb+11'd7], ddr_word[wb+11'd6], ddr_word[wb+11'd5], ddr_word[wb+11'd4],
                     ddr_word[wb+11'd3], ddr_word[wb+11'd2], ddr_word[wb+11'd1], ddr_word[wb]};
    end else if (dm_r_valid && dm_r_ready) begin
      dm_r_valid <= 1'b0;
    end
  end

  // ---- the whole chip ----
  CoralNPUChiselSubsystem dut (
    .io_clk_i(clk),
    .io_rst_ni(rst_ni),
    .io_async_ports_hosts_isp_axi_clk_clock(1'b0),
    .io_async_ports_hosts_isp_axi_clk_reset(1'b1),
    .io_async_ports_devices_ddr_clock(ddr_clk),      // DRIVE the DDR domain (was tied 0)
    .io_async_ports_devices_ddr_reset(~rst_ni),      // release it after reset (active-high)
    .io_async_ports_devices_isp_axi_clk_clock(1'b0),
    .io_async_ports_devices_isp_axi_clk_reset(1'b1),
    .io_external_hosts_autoboot_a_ready(),
    .io_external_hosts_autoboot_a_valid(1'b0),
    .io_external_hosts_autoboot_a_bits_opcode('0),
    .io_external_hosts_autoboot_a_bits_param('0),
    .io_external_hosts_autoboot_a_bits_size('0),
    .io_external_hosts_autoboot_a_bits_source('0),
    .io_external_hosts_autoboot_a_bits_address('0),
    .io_external_hosts_autoboot_a_bits_mask('0),
    .io_external_hosts_autoboot_a_bits_data('0),
    .io_external_hosts_autoboot_a_bits_user_rsvd('0),
    .io_external_hosts_autoboot_a_bits_user_instr_type('0),
    .io_external_hosts_autoboot_a_bits_user_cmd_intg('0),
    .io_external_hosts_autoboot_a_bits_user_data_intg('0),
    .io_external_hosts_autoboot_d_ready(1'b1),
    .io_external_hosts_autoboot_d_valid(),
    .io_external_hosts_autoboot_d_bits_opcode(),
    .io_external_hosts_autoboot_d_bits_param(),
    .io_external_hosts_autoboot_d_bits_size(),
    .io_external_hosts_autoboot_d_bits_source(),
    .io_external_hosts_autoboot_d_bits_sink(),
    .io_external_hosts_autoboot_d_bits_data(),
    .io_external_hosts_autoboot_d_bits_user_rsp_intg(),
    .io_external_hosts_autoboot_d_bits_user_data_intg(),
    .io_external_hosts_autoboot_d_bits_error(),
    .io_external_devices_i2c_master_a_ready(1'b1),
    .io_external_devices_i2c_master_a_valid(),
    .io_external_devices_i2c_master_a_bits_opcode(),
    .io_external_devices_i2c_master_a_bits_param(),
    .io_external_devices_i2c_master_a_bits_size(),
    .io_external_devices_i2c_master_a_bits_source(),
    .io_external_devices_i2c_master_a_bits_address(),
    .io_external_devices_i2c_master_a_bits_mask(),
    .io_external_devices_i2c_master_a_bits_data(),
    .io_external_devices_i2c_master_a_bits_user_rsvd(),
    .io_external_devices_i2c_master_a_bits_user_instr_type(),
    .io_external_devices_i2c_master_a_bits_user_cmd_intg(),
    .io_external_devices_i2c_master_a_bits_user_data_intg(),
    .io_external_devices_i2c_master_d_ready(),
    .io_external_devices_i2c_master_d_valid(1'b0),
    .io_external_devices_i2c_master_d_bits_opcode('0),
    .io_external_devices_i2c_master_d_bits_param('0),
    .io_external_devices_i2c_master_d_bits_size('0),
    .io_external_devices_i2c_master_d_bits_source('0),
    .io_external_devices_i2c_master_d_bits_sink('0),
    .io_external_devices_i2c_master_d_bits_data('0),
    .io_external_devices_i2c_master_d_bits_user_rsp_intg('0),
    .io_external_devices_i2c_master_d_bits_user_data_intg('0),
    .io_external_devices_i2c_master_d_bits_error('0),
    .io_external_devices_uart1_a_ready(1'b1),
    .io_external_devices_uart1_a_valid(),
    .io_external_devices_uart1_a_bits_opcode(),
    .io_external_devices_uart1_a_bits_param(),
    .io_external_devices_uart1_a_bits_size(),
    .io_external_devices_uart1_a_bits_source(),
    .io_external_devices_uart1_a_bits_address(),
    .io_external_devices_uart1_a_bits_mask(),
    .io_external_devices_uart1_a_bits_data(),
    .io_external_devices_uart1_a_bits_user_rsvd(),
    .io_external_devices_uart1_a_bits_user_instr_type(),
    .io_external_devices_uart1_a_bits_user_cmd_intg(),
    .io_external_devices_uart1_a_bits_user_data_intg(),
    .io_external_devices_uart1_d_ready(),
    .io_external_devices_uart1_d_valid(1'b0),
    .io_external_devices_uart1_d_bits_opcode('0),
    .io_external_devices_uart1_d_bits_param('0),
    .io_external_devices_uart1_d_bits_size('0),
    .io_external_devices_uart1_d_bits_source('0),
    .io_external_devices_uart1_d_bits_sink('0),
    .io_external_devices_uart1_d_bits_data('0),
    .io_external_devices_uart1_d_bits_user_rsp_intg('0),
    .io_external_devices_uart1_d_bits_user_data_intg('0),
    .io_external_devices_uart1_d_bits_error('0),
    .io_external_devices_clk_table_a_ready(1'b1),
    .io_external_devices_clk_table_a_valid(),
    .io_external_devices_clk_table_a_bits_opcode(),
    .io_external_devices_clk_table_a_bits_param(),
    .io_external_devices_clk_table_a_bits_size(),
    .io_external_devices_clk_table_a_bits_source(),
    .io_external_devices_clk_table_a_bits_address(),
    .io_external_devices_clk_table_a_bits_mask(),
    .io_external_devices_clk_table_a_bits_data(),
    .io_external_devices_clk_table_a_bits_user_rsvd(),
    .io_external_devices_clk_table_a_bits_user_instr_type(),
    .io_external_devices_clk_table_a_bits_user_cmd_intg(),
    .io_external_devices_clk_table_a_bits_user_data_intg(),
    .io_external_devices_clk_table_d_ready(),
    .io_external_devices_clk_table_d_valid(1'b0),
    .io_external_devices_clk_table_d_bits_opcode('0),
    .io_external_devices_clk_table_d_bits_param('0),
    .io_external_devices_clk_table_d_bits_size('0),
    .io_external_devices_clk_table_d_bits_source('0),
    .io_external_devices_clk_table_d_bits_sink('0),
    .io_external_devices_clk_table_d_bits_data('0),
    .io_external_devices_clk_table_d_bits_user_rsp_intg('0),
    .io_external_devices_clk_table_d_bits_user_data_intg('0),
    .io_external_devices_clk_table_d_bits_error('0),
    .io_external_devices_uart0_a_ready(1'b1),
    .io_external_devices_uart0_a_valid(),
    .io_external_devices_uart0_a_bits_opcode(),
    .io_external_devices_uart0_a_bits_param(),
    .io_external_devices_uart0_a_bits_size(),
    .io_external_devices_uart0_a_bits_source(),
    .io_external_devices_uart0_a_bits_address(),
    .io_external_devices_uart0_a_bits_mask(),
    .io_external_devices_uart0_a_bits_data(),
    .io_external_devices_uart0_a_bits_user_rsvd(),
    .io_external_devices_uart0_a_bits_user_instr_type(),
    .io_external_devices_uart0_a_bits_user_cmd_intg(),
    .io_external_devices_uart0_a_bits_user_data_intg(),
    .io_external_devices_uart0_d_ready(),
    .io_external_devices_uart0_d_valid(1'b0),
    .io_external_devices_uart0_d_bits_opcode('0),
    .io_external_devices_uart0_d_bits_param('0),
    .io_external_devices_uart0_d_bits_size('0),
    .io_external_devices_uart0_d_bits_source('0),
    .io_external_devices_uart0_d_bits_sink('0),
    .io_external_devices_uart0_d_bits_data('0),
    .io_external_devices_uart0_d_bits_user_rsp_intg('0),
    .io_external_devices_uart0_d_bits_user_data_intg('0),
    .io_external_devices_uart0_d_bits_error('0),
    // rom device: unused now (tensors live in DDR); tied off.
    .io_external_devices_rom_a_ready(1'b1),
    .io_external_devices_rom_a_valid(),
    .io_external_devices_rom_a_bits_opcode(),
    .io_external_devices_rom_a_bits_param(),
    .io_external_devices_rom_a_bits_size(),
    .io_external_devices_rom_a_bits_source(),
    .io_external_devices_rom_a_bits_address(),
    .io_external_devices_rom_a_bits_mask(),
    .io_external_devices_rom_a_bits_data(),
    .io_external_devices_rom_a_bits_user_rsvd(),
    .io_external_devices_rom_a_bits_user_instr_type(),
    .io_external_devices_rom_a_bits_user_cmd_intg(),
    .io_external_devices_rom_a_bits_user_data_intg(),
    .io_external_devices_rom_d_ready(),
    .io_external_devices_rom_d_valid(1'b0),
    .io_external_devices_rom_d_bits_opcode('0),
    .io_external_devices_rom_d_bits_param('0),
    .io_external_devices_rom_d_bits_size('0),
    .io_external_devices_rom_d_bits_source('0),
    .io_external_devices_rom_d_bits_sink('0),
    .io_external_devices_rom_d_bits_data('0),
    .io_external_devices_rom_d_bits_user_rsp_intg('0),
    .io_external_devices_rom_d_bits_user_data_intg('0),
    .io_external_devices_rom_d_bits_error('0),
    .io_external_ports_ext_intrs('0),
    .io_external_ports_spim_flash_clk_i('0),
    .io_external_ports_spim_flash_miso('0),
    .io_external_ports_spim_flash_mosi(),
    .io_external_ports_spim_flash_csb(),
    .io_external_ports_spim_flash_sclk(),
    .io_external_ports_cnn_irq(),
    .io_external_ports_gpio_i('0),
    .io_external_ports_gpio_en_o(),
    .io_external_ports_gpio_o(),
    .io_external_ports_spim_clk_i('0),
    .io_external_ports_spim_miso('0),
    .io_external_ports_spim_mosi(),
    .io_external_ports_spim_csb(),
    .io_external_ports_spim_sclk(),
    .io_external_ports_spi_miso(),
    .io_external_ports_spi_mosi('0),
    .io_external_ports_spi_csb('0),
    .io_external_ports_spi_clk('0),
    .io_external_ports_dm_rsp_bits_op(),
    .io_external_ports_dm_rsp_bits_data(),
    .io_external_ports_dm_rsp_ready(1'b1),
    .io_external_ports_dm_rsp_valid(),
    .io_external_ports_dm_req_bits_op('0),
    .io_external_ports_dm_req_bits_data('0),
    .io_external_ports_dm_req_bits_address('0),
    .io_external_ports_dm_req_ready(),
    .io_external_ports_dm_req_valid(1'b0),
    .io_external_ports_boot_addr(32'h0),
    .io_external_ports_te('0),
    .io_external_ports_wfi(wfi),
    .io_external_ports_fault(fault),
    .io_external_ports_halted(halted),
    .io_ddr_ctrl_axi_write_addr_ready(1'b1),
    .io_ddr_ctrl_axi_write_addr_valid(),
    .io_ddr_ctrl_axi_write_addr_bits_addr(),
    .io_ddr_ctrl_axi_write_addr_bits_prot(),
    .io_ddr_ctrl_axi_write_addr_bits_id(),
    .io_ddr_ctrl_axi_write_addr_bits_len(),
    .io_ddr_ctrl_axi_write_addr_bits_size(),
    .io_ddr_ctrl_axi_write_addr_bits_burst(),
    .io_ddr_ctrl_axi_write_addr_bits_lock(),
    .io_ddr_ctrl_axi_write_addr_bits_cache(),
    .io_ddr_ctrl_axi_write_addr_bits_qos(),
    .io_ddr_ctrl_axi_write_addr_bits_region(),
    .io_ddr_ctrl_axi_write_data_ready(1'b1),
    .io_ddr_ctrl_axi_write_data_valid(),
    .io_ddr_ctrl_axi_write_data_bits_data(),
    .io_ddr_ctrl_axi_write_data_bits_last(),
    .io_ddr_ctrl_axi_write_data_bits_strb(),
    .io_ddr_ctrl_axi_write_resp_ready(),
    .io_ddr_ctrl_axi_write_resp_valid(1'b0),
    .io_ddr_ctrl_axi_write_resp_bits_id('0),
    .io_ddr_ctrl_axi_write_resp_bits_resp('0),
    .io_ddr_ctrl_axi_read_addr_ready(1'b1),
    .io_ddr_ctrl_axi_read_addr_valid(),
    .io_ddr_ctrl_axi_read_addr_bits_addr(),
    .io_ddr_ctrl_axi_read_addr_bits_prot(),
    .io_ddr_ctrl_axi_read_addr_bits_id(),
    .io_ddr_ctrl_axi_read_addr_bits_len(),
    .io_ddr_ctrl_axi_read_addr_bits_size(),
    .io_ddr_ctrl_axi_read_addr_bits_burst(),
    .io_ddr_ctrl_axi_read_addr_bits_lock(),
    .io_ddr_ctrl_axi_read_addr_bits_cache(),
    .io_ddr_ctrl_axi_read_addr_bits_qos(),
    .io_ddr_ctrl_axi_read_addr_bits_region(),
    .io_ddr_ctrl_axi_read_data_ready(),
    .io_ddr_ctrl_axi_read_data_valid(1'b0),
    .io_ddr_ctrl_axi_read_data_bits_data('0),
    .io_ddr_ctrl_axi_read_data_bits_id('0),
    .io_ddr_ctrl_axi_read_data_bits_resp('0),
    .io_ddr_ctrl_axi_read_data_bits_last('0),
    .io_ddr_mem_axi_write_addr_ready(1'b1),
    .io_ddr_mem_axi_write_addr_valid(),
    .io_ddr_mem_axi_write_addr_bits_addr(),
    .io_ddr_mem_axi_write_addr_bits_prot(),
    .io_ddr_mem_axi_write_addr_bits_id(),
    .io_ddr_mem_axi_write_addr_bits_len(),
    .io_ddr_mem_axi_write_addr_bits_size(),
    .io_ddr_mem_axi_write_addr_bits_burst(),
    .io_ddr_mem_axi_write_addr_bits_lock(),
    .io_ddr_mem_axi_write_addr_bits_cache(),
    .io_ddr_mem_axi_write_addr_bits_qos(),
    .io_ddr_mem_axi_write_addr_bits_region(),
    .io_ddr_mem_axi_write_data_ready(1'b1),
    .io_ddr_mem_axi_write_data_valid(),
    .io_ddr_mem_axi_write_data_bits_data(),
    .io_ddr_mem_axi_write_data_bits_last(),
    .io_ddr_mem_axi_write_data_bits_strb(),
    .io_ddr_mem_axi_write_resp_ready(),
    .io_ddr_mem_axi_write_resp_valid(1'b0),
    .io_ddr_mem_axi_write_resp_bits_id('0),
    .io_ddr_mem_axi_write_resp_bits_resp('0),
    // ===== ddr_mem AXI4 READ channel -> active BFM (holds the input tensors) =====
    .io_ddr_mem_axi_read_addr_ready(dm_ar_ready),
    .io_ddr_mem_axi_read_addr_valid(dm_ar_valid),
    .io_ddr_mem_axi_read_addr_bits_addr(dm_ar_addr),
    .io_ddr_mem_axi_read_addr_bits_prot(),
    .io_ddr_mem_axi_read_addr_bits_id(dm_ar_id),
    .io_ddr_mem_axi_read_addr_bits_len(),
    .io_ddr_mem_axi_read_addr_bits_size(),
    .io_ddr_mem_axi_read_addr_bits_burst(),
    .io_ddr_mem_axi_read_addr_bits_lock(),
    .io_ddr_mem_axi_read_addr_bits_cache(),
    .io_ddr_mem_axi_read_addr_bits_qos(),
    .io_ddr_mem_axi_read_addr_bits_region(),
    .io_ddr_mem_axi_read_data_ready(dm_r_ready),
    .io_ddr_mem_axi_read_data_valid(dm_r_valid),
    .io_ddr_mem_axi_read_data_bits_data(dm_r_data),
    .io_ddr_mem_axi_read_data_bits_id(dm_r_id),
    .io_ddr_mem_axi_read_data_bits_resp(2'b00),
    .io_ddr_mem_axi_read_data_bits_last(1'b1),
    .io_ispyocto_ctrl_a_ready(1'b1),
    .io_ispyocto_ctrl_a_valid(),
    .io_ispyocto_ctrl_a_bits_opcode(),
    .io_ispyocto_ctrl_a_bits_param(),
    .io_ispyocto_ctrl_a_bits_size(),
    .io_ispyocto_ctrl_a_bits_source(),
    .io_ispyocto_ctrl_a_bits_address(),
    .io_ispyocto_ctrl_a_bits_mask(),
    .io_ispyocto_ctrl_a_bits_data(),
    .io_ispyocto_ctrl_a_bits_user_rsvd(),
    .io_ispyocto_ctrl_a_bits_user_instr_type(),
    .io_ispyocto_ctrl_a_bits_user_cmd_intg(),
    .io_ispyocto_ctrl_a_bits_user_data_intg(),
    .io_ispyocto_ctrl_d_ready(),
    .io_ispyocto_ctrl_d_valid(1'b0),
    .io_ispyocto_ctrl_d_bits_opcode('0),
    .io_ispyocto_ctrl_d_bits_param('0),
    .io_ispyocto_ctrl_d_bits_size('0),
    .io_ispyocto_ctrl_d_bits_source('0),
    .io_ispyocto_ctrl_d_bits_sink('0),
    .io_ispyocto_ctrl_d_bits_data('0),
    .io_ispyocto_ctrl_d_bits_user_rsp_intg('0),
    .io_ispyocto_ctrl_d_bits_user_data_intg('0),
    .io_ispyocto_ctrl_d_bits_error('0),
    .io_ispyocto_m1_axi_write_addr_ready(),
    .io_ispyocto_m1_axi_write_addr_valid(1'b0),
    .io_ispyocto_m1_axi_write_addr_bits_addr('0),
    .io_ispyocto_m1_axi_write_addr_bits_prot('0),
    .io_ispyocto_m1_axi_write_addr_bits_id('0),
    .io_ispyocto_m1_axi_write_addr_bits_len('0),
    .io_ispyocto_m1_axi_write_addr_bits_size('0),
    .io_ispyocto_m1_axi_write_addr_bits_burst('0),
    .io_ispyocto_m1_axi_write_addr_bits_lock('0),
    .io_ispyocto_m1_axi_write_addr_bits_cache('0),
    .io_ispyocto_m1_axi_write_addr_bits_qos('0),
    .io_ispyocto_m1_axi_write_addr_bits_region('0),
    .io_ispyocto_m1_axi_write_data_ready(),
    .io_ispyocto_m1_axi_write_data_valid(1'b0),
    .io_ispyocto_m1_axi_write_data_bits_data('0),
    .io_ispyocto_m1_axi_write_data_bits_last('0),
    .io_ispyocto_m1_axi_write_data_bits_strb('0),
    .io_ispyocto_m1_axi_write_resp_ready(1'b1),
    .io_ispyocto_m1_axi_write_resp_valid(),
    .io_ispyocto_m1_axi_write_resp_bits_id(),
    .io_ispyocto_m1_axi_write_resp_bits_resp(),
    .io_ispyocto_m1_axi_read_addr_ready(),
    .io_ispyocto_m1_axi_read_addr_valid(1'b0),
    .io_ispyocto_m1_axi_read_addr_bits_addr('0),
    .io_ispyocto_m1_axi_read_addr_bits_prot('0),
    .io_ispyocto_m1_axi_read_addr_bits_id('0),
    .io_ispyocto_m1_axi_read_addr_bits_len('0),
    .io_ispyocto_m1_axi_read_addr_bits_size('0),
    .io_ispyocto_m1_axi_read_addr_bits_burst('0),
    .io_ispyocto_m1_axi_read_addr_bits_lock('0),
    .io_ispyocto_m1_axi_read_addr_bits_cache('0),
    .io_ispyocto_m1_axi_read_addr_bits_qos('0),
    .io_ispyocto_m1_axi_read_addr_bits_region('0),
    .io_ispyocto_m1_axi_read_data_ready(1'b1),
    .io_ispyocto_m1_axi_read_data_valid(),
    .io_ispyocto_m1_axi_read_data_bits_data(),
    .io_ispyocto_m1_axi_read_data_bits_id(),
    .io_ispyocto_m1_axi_read_data_bits_resp(),
    .io_ispyocto_m1_axi_read_data_bits_last(),
    .io_ispyocto_m2_axi_write_addr_ready(),
    .io_ispyocto_m2_axi_write_addr_valid(1'b0),
    .io_ispyocto_m2_axi_write_addr_bits_addr('0),
    .io_ispyocto_m2_axi_write_addr_bits_prot('0),
    .io_ispyocto_m2_axi_write_addr_bits_id('0),
    .io_ispyocto_m2_axi_write_addr_bits_len('0),
    .io_ispyocto_m2_axi_write_addr_bits_size('0),
    .io_ispyocto_m2_axi_write_addr_bits_burst('0),
    .io_ispyocto_m2_axi_write_addr_bits_lock('0),
    .io_ispyocto_m2_axi_write_addr_bits_cache('0),
    .io_ispyocto_m2_axi_write_addr_bits_qos('0),
    .io_ispyocto_m2_axi_write_addr_bits_region('0),
    .io_ispyocto_m2_axi_write_data_ready(),
    .io_ispyocto_m2_axi_write_data_valid(1'b0),
    .io_ispyocto_m2_axi_write_data_bits_data('0),
    .io_ispyocto_m2_axi_write_data_bits_last('0),
    .io_ispyocto_m2_axi_write_data_bits_strb('0),
    .io_ispyocto_m2_axi_write_resp_ready(1'b1),
    .io_ispyocto_m2_axi_write_resp_valid(),
    .io_ispyocto_m2_axi_write_resp_bits_id(),
    .io_ispyocto_m2_axi_write_resp_bits_resp(),
    .io_ispyocto_m2_axi_read_addr_ready(),
    .io_ispyocto_m2_axi_read_addr_valid(1'b0),
    .io_ispyocto_m2_axi_read_addr_bits_addr('0),
    .io_ispyocto_m2_axi_read_addr_bits_prot('0),
    .io_ispyocto_m2_axi_read_addr_bits_id('0),
    .io_ispyocto_m2_axi_read_addr_bits_len('0),
    .io_ispyocto_m2_axi_read_addr_bits_size('0),
    .io_ispyocto_m2_axi_read_addr_bits_burst('0),
    .io_ispyocto_m2_axi_read_addr_bits_lock('0),
    .io_ispyocto_m2_axi_read_addr_bits_cache('0),
    .io_ispyocto_m2_axi_read_addr_bits_qos('0),
    .io_ispyocto_m2_axi_read_addr_bits_region('0),
    .io_ispyocto_m2_axi_read_data_ready(1'b1),
    .io_ispyocto_m2_axi_read_data_valid(),
    .io_ispyocto_m2_axi_read_data_bits_data(),
    .io_ispyocto_m2_axi_read_data_bits_id(),
    .io_ispyocto_m2_axi_read_data_bits_resp(),
    .io_ispyocto_m2_axi_read_data_bits_last()
  );

  // DPI backdoor ELF loader (address-based, DUT-agnostic; from hdl/verilog/sram_backdoor).
  import "DPI-C" function void sram_load_elf(input string filepath);

  string binary_path;
  integer cycles = 0, limit = 2000000;

  initial begin
    if (!$value$plusargs("binary=%s", binary_path)) begin
      $display("FATAL: pass +binary=<cnn_chip_test.elf>"); $finish;
    end
    rst_ni = 1'b0;          // hold chip in reset
    #100;
    sram_load_elf(binary_path);   // load firmware into on-chip SRAMs
    #20;
    // Release the core: CoreCSR.resetReg comes up 0x3 (core held); clear it, then
    // deassert chip reset -- same trick tests/vcs_sim/top.sv uses on the core.
    dut.rvv_core.coreAxi.csr.resetReg = 32'h0;
    rst_ni = 1'b1;
    $display("== tb_cnn_stream_sv: booted; fw streams ROM->SRAM via DMA, then runs CnnAccel ==");
  end

  // Teaching probe: watch the general DMA stream the tensors in.  It goes busy
  // while copying DDR->SRAM and raises done when the operands are staged; the
  // firmware then points the CnnAccel at them and the chip eventually halts.
  reg dma_busy_seen = 1'b0, dma_done_seen = 1'b0;
  always @(posedge clk) if (rst_ni) begin
    if (dut.dma.status_busy && !dma_busy_seen) begin
      dma_busy_seen <= 1'b1;
      $display("[stream] general DMA busy  @cyc %0d  (streaming tensors DDR -> SRAM)", cycles);
    end
    if (dut.dma.status_done && !dma_done_seen) begin
      dma_done_seen <= 1'b1;
      $display("[stream] general DMA done  @cyc %0d  (operands staged; CnnAccel takes over)", cycles);
    end
  end

  // Completion: halted|wfi = PASS, fault = FAIL, else timeout.
  always @(posedge clk) begin
    cycles <= cycles + 1;
    if (rst_ni && (halted || wfi)) begin
      $display("== PASS: DMA-streamed operands, CnnAccel computed correct result, chip halted (cyc=%0d) ==", cycles); $finish;
    end
    if (rst_ni && fault) begin
      $display("== FAIL: chip raised fault =="); $finish;
    end
    if (cycles >= limit) begin
      $display("== FAIL: timeout after %0d cycles (stream or CNN check failed) ==", limit); $finish;
    end
  end
endmodule
