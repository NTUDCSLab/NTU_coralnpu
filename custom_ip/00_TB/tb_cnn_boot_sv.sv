// Copyright 2026 Google LLC
// Licensed under the Apache License, Version 2.0.
// =============================================================================
// tb_cnn_boot_sv.sv - PURE-SV VCS BOOTLOADER testbench for the CnnAccel chip.
//
// Boots the core the way silicon does: a reproduced AUTOBOOT host writes the reset
// CSR (0x30000) over real TL-UL WITH correct SECDED integrity -- no hierarchical
// reset poke (unlike tb_cnn_chip_sv.sv). The firmware then drives CnnAccel and
// prints its verdict over UART1. The TB models the peripherals the boot path needs:
//   * a mock DRAM   (AXI slave on ddr_mem)   -- so heap/startup DRAM access completes
//   * a clk_table   (returns the clock table) -- so uart_init() doesn't spin
//   * a UART1 BFM   (captures the verdict; passes on "TEST PASSED")
// Firmware is staged via the sram backdoor (memory init only; boot + verdict use
// real ports). The autoboot FSM + SECDED are reproduced from fpga/rtl/autoboot.sv,
// so nothing under fpga/ is modified.  Run: ./run_bootloader.sh
//
// Verified on VCS:
//   CnnAccel RESULT = FFFFFFD7 (-41) ; TEST PASSED
//   == PASS: CnnAccel bootloader test (autoboot -> firmware -> UART) ==
// =============================================================================
`timescale 1ns/1ps
module tb_cnn_boot_sv;
  reg clk = 1'b0, rst_ni = 1'b0;
  wire halted, fault, wfi;
  always #5 clk = ~clk;

  // reproduced autoboot SECDED encoders (from fpga/rtl/autoboot.sv)
  function automatic [6:0] secded_39_32(input [31:0] d);
    secded_39_32[0]=^(d&32'h2606BD25); secded_39_32[1]=^(d&32'hDEBA8050);
    secded_39_32[2]=^(d&32'h413D89AA); secded_39_32[3]=^(d&32'h31234ED1);
    secded_39_32[4]=^(d&32'hC2C1323B); secded_39_32[5]=^(d&32'h2DCC624C);
    secded_39_32[6]=^(d&32'h98505586); secded_39_32=secded_39_32^7'h2A; endfunction
  function automatic [6:0] secded_64_57(input [56:0] d);
    secded_64_57[0]=^(d&57'h0103FFF800007FFF); secded_64_57[1]=^(d&57'h017C1FF801FF801F);
    secded_64_57[2]=^(d&57'h01BDE1F87E0781E1); secded_64_57[3]=^(d&57'h01DEEE3B8E388E22);
    secded_64_57[4]=^(d&57'h01EF76CDB2C93244); secded_64_57[5]=^(d&57'h01F7BB56D5525488);
    secded_64_57[6]=^(d&57'h01FBDDA769A46910); secded_64_57=secded_64_57^7'h2A; endfunction

  reg  [2:0]  ab_state = 3'd0;
  // autoboot outputs are COMBINATIONAL (as in fpga/rtl/autoboot.sv): a_valid is high
  // in the two write states; data = 1 (un-gate) then 0 (release). The FSM only advances
  // state. (Driving a_valid from the sequential block races itself and never asserts.)
  wire        ab_a_valid  = (ab_state == 3'd1) || (ab_state == 3'd3);  // AB_CG or AB_RST
  wire [2:0]  ab_a_opcode = 3'd0;                                       // PutFullData
  wire [31:0] ab_a_addr   = 32'h30000;
  wire [31:0] ab_a_data   = (ab_state == 3'd3) ? 32'h0 : 32'h1;
  wire        ab_a_ready, ab_d_valid;
  wire [6:0]  ab_cmd_intg  = secded_64_57({14'h0, 4'h9, ab_a_addr, ab_a_opcode, 4'hF});
  wire [6:0]  ab_data_intg = secded_39_32(ab_a_data);

  wire         u_a_valid, u_d_ready;
  wire [2:0]   u_a_opcode;
  wire [31:0]  u_a_addr, u_a_data;
  wire [1:0]   u_a_size;
  wire [10-1:0] u_a_source;
  reg          u_a_ready = 1'b1, u_d_valid = 1'b0, u_busy = 1'b0, pass_seen = 1'b0;
  reg  [2:0]   u_d_opcode = 3'd0;
  reg  [1:0]   u_d_size = 2'd0;
  reg  [10-1:0] u_d_source = '0;
  reg  [31:0]  u_d_data = 32'd0;
  reg  [127:0] win = '0;

  // ---- mock DRAM (AXI slave on ddr_mem) signal declarations ----
  wire         dr_awvalid, dr_wvalid, dr_wlast, dr_bready, dr_arvalid, dr_rready;
  wire [31:0]  dr_awaddr, dr_araddr;
  wire [7:0]   dr_awlen, dr_arlen;
  wire         dr_awid, dr_arid;
  wire [255:0] dr_wdata;
  reg          dr_awready=1'b1, dr_wready=1'b1, dr_bvalid=1'b0, dr_arready=1'b1, dr_rvalid=1'b0, dr_rlast=1'b0;
  reg          dr_bid=1'b0, dr_rid=1'b0;
  reg  [1:0]   dr_bresp=2'b0, dr_rresp=2'b0;
  reg  [255:0] dr_rdata=256'b0;
  reg  [255:0] dram [longint];
  reg  [31:0]  dr_wa, dr_ra;
  reg  [8:0]   dr_rbeats=9'd0;

  // ---- clk_table device BFM (returns clock-freq table; without it uart_init hangs) ----
  wire         ck_a_valid, ck_d_ready;
  wire [2:0]   ck_a_opcode;
  wire [31:0]  ck_a_addr, ck_a_data;
  wire [1:0]   ck_a_size;
  wire [9:0]   ck_a_source;
  reg          ck_a_ready=1'b1, ck_d_valid=1'b0, ck_busy=1'b0;
  reg  [2:0]   ck_d_opcode=3'd0;
  reg  [1:0]   ck_d_size=2'd0;
  reg  [9:0]   ck_d_source=10'd0;
  reg  [31:0]  ck_d_data=32'd0;

  CoralNPUChiselSubsystem dut (
    .io_clk_i(clk),
    .io_rst_ni(rst_ni),
    .io_async_ports_hosts_isp_axi_clk_clock(1'b0),
    .io_async_ports_hosts_isp_axi_clk_reset(1'b1),
    .io_async_ports_devices_ddr_clock(1'b0),
    .io_async_ports_devices_ddr_reset(1'b1),
    .io_async_ports_devices_isp_axi_clk_clock(1'b0),
    .io_async_ports_devices_isp_axi_clk_reset(1'b1),
    .io_external_hosts_autoboot_a_ready(ab_a_ready),
    .io_external_hosts_autoboot_a_valid(ab_a_valid),
    .io_external_hosts_autoboot_a_bits_opcode(ab_a_opcode),
    .io_external_hosts_autoboot_a_bits_param(3'h0),
    .io_external_hosts_autoboot_a_bits_size(2'h2),
    .io_external_hosts_autoboot_a_bits_source('0),
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
    .io_external_devices_uart1_a_ready(u_a_ready),
    .io_external_devices_uart1_a_valid(u_a_valid),
    .io_external_devices_uart1_a_bits_opcode(u_a_opcode),
    .io_external_devices_uart1_a_bits_param(),
    .io_external_devices_uart1_a_bits_size(u_a_size),
    .io_external_devices_uart1_a_bits_source(u_a_source),
    .io_external_devices_uart1_a_bits_address(u_a_addr),
    .io_external_devices_uart1_a_bits_mask(),
    .io_external_devices_uart1_a_bits_data(u_a_data),
    .io_external_devices_uart1_a_bits_user_rsvd(),
    .io_external_devices_uart1_a_bits_user_instr_type(),
    .io_external_devices_uart1_a_bits_user_cmd_intg(),
    .io_external_devices_uart1_a_bits_user_data_intg(),
    .io_external_devices_uart1_d_ready(u_d_ready),
    .io_external_devices_uart1_d_valid(u_d_valid),
    .io_external_devices_uart1_d_bits_opcode(u_d_opcode),
    .io_external_devices_uart1_d_bits_param(3'h0),
    .io_external_devices_uart1_d_bits_size(u_d_size),
    .io_external_devices_uart1_d_bits_source(u_d_source),
    .io_external_devices_uart1_d_bits_sink(1'b0),
    .io_external_devices_uart1_d_bits_data(u_d_data),
    .io_external_devices_uart1_d_bits_user_rsp_intg(7'h0),
    .io_external_devices_uart1_d_bits_user_data_intg(7'h0),
    .io_external_devices_uart1_d_bits_error(1'b0),
    .io_external_devices_clk_table_a_ready(ck_a_ready),
    .io_external_devices_clk_table_a_valid(ck_a_valid),
    .io_external_devices_clk_table_a_bits_opcode(ck_a_opcode),
    .io_external_devices_clk_table_a_bits_param(),
    .io_external_devices_clk_table_a_bits_size(ck_a_size),
    .io_external_devices_clk_table_a_bits_source(ck_a_source),
    .io_external_devices_clk_table_a_bits_address(ck_a_addr),
    .io_external_devices_clk_table_a_bits_mask(),
    .io_external_devices_clk_table_a_bits_data(ck_a_data),
    .io_external_devices_clk_table_a_bits_user_rsvd(),
    .io_external_devices_clk_table_a_bits_user_instr_type(),
    .io_external_devices_clk_table_a_bits_user_cmd_intg(),
    .io_external_devices_clk_table_a_bits_user_data_intg(),
    .io_external_devices_clk_table_d_ready(ck_d_ready),
    .io_external_devices_clk_table_d_valid(ck_d_valid),
    .io_external_devices_clk_table_d_bits_opcode(ck_d_opcode),
    .io_external_devices_clk_table_d_bits_param(3'h0),
    .io_external_devices_clk_table_d_bits_size(ck_d_size),
    .io_external_devices_clk_table_d_bits_source(ck_d_source),
    .io_external_devices_clk_table_d_bits_sink(1'b0),
    .io_external_devices_clk_table_d_bits_data(ck_d_data),
    .io_external_devices_clk_table_d_bits_user_rsp_intg(7'h0),
    .io_external_devices_clk_table_d_bits_user_data_intg(7'h0),
    .io_external_devices_clk_table_d_bits_error(1'b0),
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
    .io_ddr_mem_axi_write_addr_ready(dr_awready),
    .io_ddr_mem_axi_write_addr_valid(dr_awvalid),
    .io_ddr_mem_axi_write_addr_bits_addr(dr_awaddr),
    .io_ddr_mem_axi_write_addr_bits_prot(),
    .io_ddr_mem_axi_write_addr_bits_id(dr_awid),
    .io_ddr_mem_axi_write_addr_bits_len(dr_awlen),
    .io_ddr_mem_axi_write_addr_bits_size(),
    .io_ddr_mem_axi_write_addr_bits_burst(),
    .io_ddr_mem_axi_write_addr_bits_lock(),
    .io_ddr_mem_axi_write_addr_bits_cache(),
    .io_ddr_mem_axi_write_addr_bits_qos(),
    .io_ddr_mem_axi_write_addr_bits_region(),
    .io_ddr_mem_axi_write_data_ready(dr_wready),
    .io_ddr_mem_axi_write_data_valid(dr_wvalid),
    .io_ddr_mem_axi_write_data_bits_data(dr_wdata),
    .io_ddr_mem_axi_write_data_bits_last(dr_wlast),
    .io_ddr_mem_axi_write_data_bits_strb(),
    .io_ddr_mem_axi_write_resp_ready(dr_bready),
    .io_ddr_mem_axi_write_resp_valid(dr_bvalid),
    .io_ddr_mem_axi_write_resp_bits_id(dr_bid),
    .io_ddr_mem_axi_write_resp_bits_resp(dr_bresp),
    .io_ddr_mem_axi_read_addr_ready(dr_arready),
    .io_ddr_mem_axi_read_addr_valid(dr_arvalid),
    .io_ddr_mem_axi_read_addr_bits_addr(dr_araddr),
    .io_ddr_mem_axi_read_addr_bits_prot(),
    .io_ddr_mem_axi_read_addr_bits_id(dr_arid),
    .io_ddr_mem_axi_read_addr_bits_len(dr_arlen),
    .io_ddr_mem_axi_read_addr_bits_size(),
    .io_ddr_mem_axi_read_addr_bits_burst(),
    .io_ddr_mem_axi_read_addr_bits_lock(),
    .io_ddr_mem_axi_read_addr_bits_cache(),
    .io_ddr_mem_axi_read_addr_bits_qos(),
    .io_ddr_mem_axi_read_addr_bits_region(),
    .io_ddr_mem_axi_read_data_ready(dr_rready),
    .io_ddr_mem_axi_read_data_valid(dr_rvalid),
    .io_ddr_mem_axi_read_data_bits_data(dr_rdata),
    .io_ddr_mem_axi_read_data_bits_id(dr_rid),
    .io_ddr_mem_axi_read_data_bits_resp(dr_rresp),
    .io_ddr_mem_axi_read_data_bits_last(dr_rlast),
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

  // reproduced autoboot: on reset release, write 0x30000=1 then =0 (real TL-UL+SECDED)
  localparam AB_IDLE=0,AB_CG=1,AB_CG_ACK=2,AB_RST=3,AB_RST_ACK=4,AB_DONE=5;
  always @(posedge clk or negedge rst_ni) begin
    if(!rst_ni) ab_state<=AB_IDLE;
    else case(ab_state)
      AB_IDLE:    ab_state<=AB_CG;
      AB_CG:      if(ab_a_ready) ab_state<=AB_CG_ACK;   // clock-gate write accepted
      AB_CG_ACK:  if(ab_d_valid) ab_state<=AB_RST;      // ...ack'd
      AB_RST:     if(ab_a_ready) ab_state<=AB_RST_ACK;  // reset-release write accepted
      AB_RST_ACK: if(ab_d_valid) ab_state<=AB_DONE;     // ...ack'd -> core running
      AB_DONE:    ;
      default:    ab_state<=AB_IDLE;
    endcase
  end

  // UART1 device BFM: Get(status)->0 (ready); Put(WDATA 0x1c)->capture char.
  // Responses carry rsp_intg=0, which the core accepts (CnnAccel replies the same).
  localparam [11:0] UART_WDATA = 12'h01c;
  always @(posedge clk or negedge rst_ni) begin
    if(!rst_ni) begin u_d_valid<=1'b0; u_busy<=1'b0; win<=128'h0; pass_seen<=1'b0; end
    else begin
      if(u_a_valid && u_a_ready && !u_busy) begin
        u_busy<=1'b1; u_d_source<=u_a_source; u_d_size<=u_a_size;
        if(u_a_opcode==3'd4) begin u_d_opcode<=3'd1; u_d_data<=32'h0; end
        else begin
          u_d_opcode<=3'd0; u_d_data<=32'h0;
          if(u_a_addr[11:0]==UART_WDATA) begin
            $write("%c", u_a_data[7:0]);
            if({win[39:0], u_a_data[7:0]} == 48'h504153534544) pass_seen<=1'b1; // "PASSED"
            win <= (win<<8) | {120'h0, u_a_data[7:0]};
          end
        end
      end
      if(u_busy && !u_d_valid) u_d_valid<=1'b1;
      if(u_d_valid && u_d_ready) begin u_d_valid<=1'b0; u_busy<=1'b0; end
    end
  end

  import "DPI-C" function void sram_load_elf(input string filepath);
  string binary_path; integer cyc = 0; localparam integer LIMIT = 4000000;
  initial begin
    if(!$value$plusargs("binary=%s",binary_path)) begin $display("FATAL: pass +binary=<elf>"); $finish; end
    rst_ni=1'b0; #100; sram_load_elf(binary_path); #20; rst_ni=1'b1;
    $display("== tb_cnn_boot_sv: reset released; autoboot is booting the core ==");
  end
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if(rst_ni && pass_seen) begin $display("\n== PASS: CnnAccel bootloader test (autoboot -> firmware -> UART) =="); $finish; end
    if(rst_ni && fault)     begin $display("\n== FAIL: chip raised fault =="); $finish; end
    if(cyc >= LIMIT)        begin $display("\n== FAIL: timeout (no PASSED seen on UART) =="); $finish; end
  end


  // ================= mock DRAM (AXI slave memory on ddr_mem) =================
  // Lets the core's DRAM accesses (heap / startup) complete so the chip can boot.
  // (signals declared above the instantiation)
  // write: accept AW, store each W beat (incrementing), reply B on last
  always @(posedge clk or negedge rst_ni) begin
    if(!rst_ni) begin dr_bvalid<=1'b0; dr_wa<=32'b0; end
    else begin
      if(dr_awvalid && dr_awready) dr_wa <= dr_awaddr;
      if(dr_wvalid && dr_wready) begin
        dram[dr_wa[31:5]] = dr_wdata; dr_wa <= dr_wa + 32'd32;
        if(dr_wlast) begin dr_bvalid<=1'b1; dr_bid<=1'b0; dr_bresp<=2'b0; end
      end
      if(dr_bvalid && dr_bready) dr_bvalid<=1'b0;
    end
  end
  // read: accept AR, stream R beats from memory (0 if never written), R_last on last
  always @(posedge clk or negedge rst_ni) begin
    if(!rst_ni) begin dr_rvalid<=1'b0; dr_rbeats<=9'd0; dr_arready<=1'b1; end
    else begin
      if(dr_arvalid && dr_arready && dr_rbeats==0) begin
        dr_ra <= dr_araddr; dr_rbeats <= {1'b0,dr_arlen} + 9'd1; dr_arready<=1'b0;
      end
      if(dr_rbeats!=0 && (!dr_rvalid || dr_rready)) begin
        dr_rvalid <= 1'b1;
        dr_rdata  <= dram.exists(dr_ra[31:5]) ? dram[dr_ra[31:5]] : 256'b0;
        dr_rid<=1'b0; dr_rresp<=2'b0; dr_rlast <= (dr_rbeats==9'd1);
        dr_ra <= dr_ra + 32'd32; dr_rbeats <= dr_rbeats - 9'd1;
        if(dr_rbeats==9'd1) dr_arready<=1'b1;
      end else if(dr_rvalid && dr_rready) dr_rvalid<=1'b0;
    end
  end


  // ================= clk_table device BFM =================
  // Reads: offset 0x0 -> magic "CLKT", 0x4 -> main freq (MHz). Writes -> ack.
  always @(posedge clk or negedge rst_ni) begin
    if(!rst_ni) begin ck_d_valid<=1'b0; ck_busy<=1'b0; end
    else begin
      if(ck_a_valid && ck_a_ready && !ck_busy) begin
        ck_busy<=1'b1; ck_d_source<=ck_a_source; ck_d_size<=ck_a_size;
        if(ck_a_opcode==3'd4) begin
          ck_d_opcode<=3'd1;
          case(ck_a_addr[11:0])
            12'h000: ck_d_data<=32'h434C4B54; // "CLKT"
            12'h004: ck_d_data<=32'd100;       // main MHz
            12'h008: ck_d_data<=32'd100;       // isp MHz
            12'h00c: ck_d_data<=32'd100;       // spim MHz
            default: ck_d_data<=32'd100;
          endcase
        end else begin ck_d_opcode<=3'd0; ck_d_data<=32'd0; end
      end
      if(ck_busy && !ck_d_valid) ck_d_valid<=1'b1;
      if(ck_d_valid && ck_d_ready) begin ck_d_valid<=1'b0; ck_busy<=1'b0; end
    end
  end

endmodule
