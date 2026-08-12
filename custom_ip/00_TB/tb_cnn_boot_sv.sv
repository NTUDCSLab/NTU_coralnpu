// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy at
//     http://www.apache.org/licenses/LICENSE-2.0
//
// =============================================================================
// tb_cnn_boot_sv.sv - PURE-SYSTEMVERILOG whole-chip SELF-LOAD testbench (VCS).
//
// Same chip and environment as tb_cnn_chip_sv.sv (all peripheral ports tied off,
// PASS = the core halts), but instead of DPI-backdoor-loading the firmware we let
// a HARDWARE AUTOBOOT load it over the real TL-UL bus, like fpga/rtl/autoboot.sv.
//
// The fpga autoboot only un-gates + releases the core (2 CSR writes).  This one
// additionally TRIGGERS THE ON-CHIP DMA to copy the app from external ROM into
// ITCM before releasing the core -- the whole chip self-loads from external
// memory, no CPU boot-stub firmware and no SPI:
//
//   phase 0  write CoreCSR  0x00030000 = 0x1   un-gate core clock, hold in reset
//   phase 1  write DMA      0x40050008 = 0x10000000   DESC_ADDR (descriptor in ROM)
//   phase 2  write DMA      0x40050000 = 0x3          CTRL = enable|start  (ROM->ITCM)
//   phase 3  wait for the DMA to finish (status_done)
//   phase 4  write CoreCSR  0x00030000 = 0x0   release reset -> core boots ITCM(0x0)
//
// Requires the crossbar to let the "autoboot" host reach the DMA:
//   CrossbarConfig.scala:  "autoboot" -> Seq("coralnpu_device", "dma")
// Regenerate the chip .sv (../build_coralnpu.sh) after changing it.
//
// The app (cnn_chip_test, ITCM-only) halts via ebreak on success, so the pass
// convention is identical to tb_cnn_chip_sv.sv: halted|wfi = PASS, fault = FAIL.
// =============================================================================
`timescale 1ns/1ps

module tb_cnn_boot_sv;
  reg clk = 1'b0;
  reg rst_ni = 1'b0;
  wire halted, fault, wfi;

  always #5 clk = ~clk;   // 100 MHz

  // ================= reproduced autoboot (from fpga/rtl/autoboot.sv) =================
  // SECDED integrity encoders, identical to the fpga autoboot (a_user.instr_type is
  // MuBi4False = 4'h9; cmd = {rsvd14, instr_type4, addr32, opcode3, mask4}).
  function automatic [6:0] secded_39_32(input [31:0] d);
    secded_39_32[0]=^(d&32'h2606BD25); secded_39_32[1]=^(d&32'hDEBA8050);
    secded_39_32[2]=^(d&32'h413D89AA); secded_39_32[3]=^(d&32'h31234ED1);
    secded_39_32[4]=^(d&32'hC2C1323B); secded_39_32[5]=^(d&32'h2DCC624C);
    secded_39_32[6]=^(d&32'h98505586); secded_39_32=secded_39_32^7'h2A;
  endfunction
  function automatic [6:0] secded_64_57(input [56:0] d);
    secded_64_57[0]=^(d&57'h0103FFF800007FFF); secded_64_57[1]=^(d&57'h017C1FF801FF801F);
    secded_64_57[2]=^(d&57'h01BDE1F87E0781E1); secded_64_57[3]=^(d&57'h01DEEE3B8E388E22);
    secded_64_57[4]=^(d&57'h01EF76CDB2C93244); secded_64_57[5]=^(d&57'h01F7BB56D5525488);
    secded_64_57[6]=^(d&57'h01FBDDA769A46910); secded_64_57=secded_64_57^7'h2A;
  endfunction

  // Autoboot FSM.  Each bus phase drives the A-channel until a_ready, then awaits
  // the D-channel ack; the wait phase blocks on the DMA finishing.
  localparam [2:0] AB_UNGATE=3'd0, AB_DESC=3'd1, AB_START=3'd2,
                   AB_WAIT=3'd3,  AB_RELEASE=3'd4, AB_DONE=3'd5;
  reg  [2:0]  ab_phase = AB_UNGATE;
  reg         ab_sub   = 1'b0;      // 0 = drive A, 1 = await D
  reg  [31:0] ab_wait  = 32'd0;     // safety counter for the DMA wait
  wire        ab_a_ready, ab_d_valid;
  wire [31:0] ab_d_data;

  // DMA completion, observed from the engine.  (A silicon autoboot would poll
  // DMA_STATUS over the bus; here the core is held so we watch status_done.)
  wire        dma_done = dut.dma.status_done;

  wire        ab_busy    = (ab_phase != AB_WAIT) && (ab_phase != AB_DONE);
  wire        ab_a_valid = ab_busy && (ab_sub == 1'b0);
  wire [2:0]  ab_a_opcode = 3'd0;                    // PutFullData
  wire [31:0] ab_a_addr =
      (ab_phase==AB_UNGATE)  ? 32'h00030000 :        // CoreCSR reset register
      (ab_phase==AB_DESC)    ? 32'h40050008 :        // DMA DESC_ADDR
      (ab_phase==AB_START)   ? 32'h40050000 :        // DMA CTRL
      (ab_phase==AB_RELEASE) ? 32'h00030000 : 32'h00030000;
  wire [31:0] ab_a_data =
      (ab_phase==AB_UNGATE)  ? 32'h00000001 :        // un-gate clock, hold reset
      (ab_phase==AB_DESC)    ? 32'h10000000 :        // descriptor @ ROM base
      (ab_phase==AB_START)   ? 32'h00000003 :        // CTRL = enable|start
      (ab_phase==AB_RELEASE) ? 32'h00000000 : 32'h00000000;  // release reset
  wire [6:0]  ab_cmd_intg  = secded_64_57({14'h0, 4'h9, ab_a_addr, ab_a_opcode, 4'hF});
  wire [6:0]  ab_data_intg = secded_39_32(ab_a_data);

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      ab_phase <= AB_UNGATE; ab_sub <= 1'b0; ab_wait <= 32'd0;
    end else begin
      case (ab_phase)
        AB_WAIT: begin
          ab_wait <= ab_wait + 32'd1;
          if (dma_done || ab_wait > 32'd500000) ab_phase <= AB_RELEASE;
        end
        AB_DONE: ;
        default: begin                                 // a bus-write phase
          if (ab_sub == 1'b0) begin
            if (ab_a_ready) ab_sub <= 1'b1;
          end else if (ab_d_valid) begin
            ab_sub <= 1'b0;
            case (ab_phase)
              AB_UNGATE:  ab_phase <= AB_DESC;
              AB_DESC:    ab_phase <= AB_START;
              AB_START:   ab_phase <= AB_WAIT;
              AB_RELEASE: ab_phase <= AB_DONE;
              default:    ;
            endcase
          end
        end
      endcase
    end
  end

  // ================= ROM device BFM =================
  // Holds [DMA descriptor @ 0x10000000][app @ 0x10001000].  The core is held during
  // the copy, so the ROM sees only the DMA's single read stream -- a simple
  // single-outstanding responder suffices (no cross-stream throttle, no deadlock).
  reg  [31:0] rom_mem [0:8191];
  initial $readmemh("../rom_boot.hex", rom_mem);
  wire        r_a_valid, r_d_ready;
  wire [2:0]  r_a_opcode;
  wire [1:0]  r_a_size;
  wire [9:0]  r_a_source;
  wire [31:0] r_a_addr;
  reg         r_d_valid = 1'b0;
  reg  [2:0]  r_d_opcode;
  reg  [1:0]  r_d_size;
  reg  [9:0]  r_d_source;
  reg  [31:0] r_d_data;
  wire        r_a_ready = !r_d_valid;                    // accept when not holding a resp
  wire [6:0]  r_d_data_intg = secded_39_32(r_d_data);
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_d_valid <= 1'b0;
    end else if (r_a_valid && r_a_ready) begin
      r_d_valid  <= 1'b1;
      r_d_data   <= rom_mem[(r_a_addr & 32'h00007FFF) >> 2];
      r_d_opcode <= (r_a_opcode == 3'd4) ? 3'd1 : 3'd0;  // AccessAckData / AccessAck
      r_d_size   <= r_a_size;
      r_d_source <= r_a_source;
    end else if (r_d_valid && r_d_ready) begin
      r_d_valid <= 1'b0;
    end
  end

  // ---- the whole chip ----
  CoralNPUChiselSubsystem dut (
    .io_clk_i(clk),
    .io_rst_ni(rst_ni),
    .io_async_ports_hosts_isp_axi_clk_clock(1'b0),
    .io_async_ports_hosts_isp_axi_clk_reset(1'b1),
    .io_async_ports_devices_ddr_clock(1'b0),
    .io_async_ports_devices_ddr_reset(1'b1),
    .io_async_ports_devices_isp_axi_clk_clock(1'b0),
    .io_async_ports_devices_isp_axi_clk_reset(1'b1),
    // ===== External Host: autoboot (ACTIVE) =====
    .io_external_hosts_autoboot_a_ready(ab_a_ready),
    .io_external_hosts_autoboot_a_valid(ab_a_valid),
    .io_external_hosts_autoboot_a_bits_opcode(ab_a_opcode),
    .io_external_hosts_autoboot_a_bits_param(3'h0),
    .io_external_hosts_autoboot_a_bits_size(2'h2),
    .io_external_hosts_autoboot_a_bits_source(6'h0),
    .io_external_hosts_autoboot_a_bits_address(ab_a_addr),
    .io_external_hosts_autoboot_a_bits_mask(4'hF),
    .io_external_hosts_autoboot_a_bits_data(ab_a_data),
    .io_external_hosts_autoboot_a_bits_user_rsvd('0),
    .io_external_hosts_autoboot_a_bits_user_instr_type(4'h9),
    .io_external_hosts_autoboot_a_bits_user_cmd_intg(ab_cmd_intg),
    .io_external_hosts_autoboot_a_bits_user_data_intg(ab_data_intg),
    .io_external_hosts_autoboot_d_ready(1'b1),
    .io_external_hosts_autoboot_d_valid(ab_d_valid),
    .io_external_hosts_autoboot_d_bits_opcode(),
    .io_external_hosts_autoboot_d_bits_param(),
    .io_external_hosts_autoboot_d_bits_size(),
    .io_external_hosts_autoboot_d_bits_source(),
    .io_external_hosts_autoboot_d_bits_sink(),
    .io_external_hosts_autoboot_d_bits_data(ab_d_data),
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
    // ===== External Device: rom (ACTIVE BFM) =====
    .io_external_devices_rom_a_ready(r_a_ready),
    .io_external_devices_rom_a_valid(r_a_valid),
    .io_external_devices_rom_a_bits_opcode(r_a_opcode),
    .io_external_devices_rom_a_bits_param(),
    .io_external_devices_rom_a_bits_size(r_a_size),
    .io_external_devices_rom_a_bits_source(r_a_source),
    .io_external_devices_rom_a_bits_address(r_a_addr),
    .io_external_devices_rom_a_bits_mask(),
    .io_external_devices_rom_a_bits_data(),
    .io_external_devices_rom_a_bits_user_rsvd(),
    .io_external_devices_rom_a_bits_user_instr_type(),
    .io_external_devices_rom_a_bits_user_cmd_intg(),
    .io_external_devices_rom_a_bits_user_data_intg(),
    .io_external_devices_rom_d_ready(r_d_ready),
    .io_external_devices_rom_d_valid(r_d_valid),
    .io_external_devices_rom_d_bits_opcode(r_d_opcode),
    .io_external_devices_rom_d_bits_param('0),
    .io_external_devices_rom_d_bits_size(r_d_size),
    .io_external_devices_rom_d_bits_source(r_d_source),
    .io_external_devices_rom_d_bits_sink('0),
    .io_external_devices_rom_d_bits_data(r_d_data),
    .io_external_devices_rom_d_bits_user_rsp_intg('0),
    .io_external_devices_rom_d_bits_user_data_intg(r_d_data_intg),
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
    .io_ddr_mem_axi_read_addr_ready(1'b1),
    .io_ddr_mem_axi_read_addr_valid(),
    .io_ddr_mem_axi_read_addr_bits_addr(),
    .io_ddr_mem_axi_read_addr_bits_prot(),
    .io_ddr_mem_axi_read_addr_bits_id(),
    .io_ddr_mem_axi_read_addr_bits_len(),
    .io_ddr_mem_axi_read_addr_bits_size(),
    .io_ddr_mem_axi_read_addr_bits_burst(),
    .io_ddr_mem_axi_read_addr_bits_lock(),
    .io_ddr_mem_axi_read_addr_bits_cache(),
    .io_ddr_mem_axi_read_addr_bits_qos(),
    .io_ddr_mem_axi_read_addr_bits_region(),
    .io_ddr_mem_axi_read_data_ready(),
    .io_ddr_mem_axi_read_data_valid(1'b0),
    .io_ddr_mem_axi_read_data_bits_data('0),
    .io_ddr_mem_axi_read_data_bits_id('0),
    .io_ddr_mem_axi_read_data_bits_resp('0),
    .io_ddr_mem_axi_read_data_bits_last('0),
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

  // ---- boot + completion ----
  integer cyc = 0, limit = 3000000;
  initial begin
    rst_ni = 1'b0;                     // hold chip in reset; CoreCSR comes up 0x3 (core held)
    #100;
    rst_ni = 1'b1;                     // release chip reset -> autoboot FSM takes over
    $display("== tb_cnn_boot_sv: reset released; autoboot -> DMA (ROM->ITCM) -> core ==");
  end

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cyc % 50000 == 0)
      $display("[DBG cyc=%0d] ab_phase=%0d sub=%b dma_busy=%b dma_done=%b | core halted=%b fault=%b wfi=%b",
               cyc, ab_phase, ab_sub, dut.dma.status_busy, dma_done, halted, fault, wfi);
    if (rst_ni && (halted || wfi)) begin
      $display("== PASS: autoboot->DMA self-load complete, chip halted cleanly (cyc=%0d) ==", cyc);
      $finish;
    end
    if (rst_ni && fault) begin
      $display("== FAIL: chip raised fault (cyc=%0d) ==", cyc);
      $finish;
    end
    if (cyc >= limit) begin
      $display("== FAIL: timeout after %0d cycles (self-load or CNN check failed) ==", limit);
      $finish;
    end
  end
endmodule
