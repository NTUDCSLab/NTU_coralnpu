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
// CnnAccel — a CNN/MatMul (signed int8 dot-product) accelerator, written in pure
// SystemVerilog and integrated into the Coral NPU SoC via a thin Chisel BlackBox
// (see hdl/chisel/src/bus/CnnAccel.scala). This is the "Option A" flavour of the
// integration: all logic lives here in SV; the Chisel side is only a port list.
//
// Port names/widths match the flattening of the BlackBox io bundle exactly:
//   { clock, reset, tl_host: Host2Device, tl_device: Flipped(Host2Device), irq }
// (BlackBox ports drop the `io_` prefix; `reset` is active-high async, = !rst_ni).
//
// Behaviour is identical to the Chisel reference:
//   RESULT = sum_{i<LEN} (int8)IN[i] * (int8)W[i]   (int32, 4 packed lanes/word)
//   CSR: CTRL[GO,IRQ_EN,CLEAR] / STATUS[busy,done,error] / IN/W/OUT_ADDR / LEN / RESULT
//   irq = done && IRQ_EN

module CnnAccelImpl(
  input          clock,
  input          reset,   // active-high async

  // ---- host (bus master) ----
  input          tl_host_a_ready,
  output         tl_host_a_valid,
  output [2:0]   tl_host_a_bits_opcode,
  output [2:0]   tl_host_a_bits_param,
  output [3:0]   tl_host_a_bits_size,
  output [5:0]   tl_host_a_bits_source,
  output [31:0]  tl_host_a_bits_address,
  output [15:0]  tl_host_a_bits_mask,
  output [127:0] tl_host_a_bits_data,
  output [4:0]   tl_host_a_bits_user_rsvd,
  output [3:0]   tl_host_a_bits_user_instr_type,
  output [6:0]   tl_host_a_bits_user_cmd_intg,
  output [6:0]   tl_host_a_bits_user_data_intg,
  output         tl_host_d_ready,
  input          tl_host_d_valid,
  input  [2:0]   tl_host_d_bits_opcode,
  input  [2:0]   tl_host_d_bits_param,
  input  [3:0]   tl_host_d_bits_size,
  input  [5:0]   tl_host_d_bits_source,
  input          tl_host_d_bits_sink,
  input  [127:0] tl_host_d_bits_data,
  input  [6:0]   tl_host_d_bits_user_rsp_intg,
  input  [6:0]   tl_host_d_bits_user_data_intg,
  input          tl_host_d_bits_error,

  // ---- device (CSR slave) ----
  output         tl_device_a_ready,
  input          tl_device_a_valid,
  input  [2:0]   tl_device_a_bits_opcode,
  input  [2:0]   tl_device_a_bits_param,
  input  [1:0]   tl_device_a_bits_size,
  input  [9:0]   tl_device_a_bits_source,
  input  [31:0]  tl_device_a_bits_address,
  input  [3:0]   tl_device_a_bits_mask,
  input  [31:0]  tl_device_a_bits_data,
  input  [4:0]   tl_device_a_bits_user_rsvd,
  input  [3:0]   tl_device_a_bits_user_instr_type,
  input  [6:0]   tl_device_a_bits_user_cmd_intg,
  input  [6:0]   tl_device_a_bits_user_data_intg,
  input          tl_device_d_ready,
  output         tl_device_d_valid,
  output [2:0]   tl_device_d_bits_opcode,
  output [2:0]   tl_device_d_bits_param,
  output [1:0]   tl_device_d_bits_size,
  output [9:0]   tl_device_d_bits_source,
  output         tl_device_d_bits_sink,
  output [31:0]  tl_device_d_bits_data,
  output [6:0]   tl_device_d_bits_user_rsp_intg,
  output [6:0]   tl_device_d_bits_user_data_intg,
  output         tl_device_d_bits_error,

  output         irq
);

  // TL opcodes
  localparam [2:0] OP_PUT_FULL = 3'd0;
  localparam [2:0] OP_PUT_PART = 3'd1;
  localparam [2:0] OP_GET      = 3'd4;
  localparam [2:0] OP_ACK      = 3'd0;
  localparam [2:0] OP_ACK_DATA = 3'd1;
  localparam [3:0] MUBI4_FALSE = 4'h9;

  // CSR offsets
  localparam [11:0] R_CTRL = 12'h000, R_STATUS = 12'h004, R_IN = 12'h008,
                    R_W = 12'h00c, R_OUT = 12'h010, R_LEN = 12'h014, R_RESULT = 12'h018;

  // FSM
  localparam [2:0] S_IDLE=3'd0, S_RIN_REQ=3'd1, S_RIN_RSP=3'd2, S_RW_REQ=3'd3,
                   S_RW_RSP=3'd4, S_WR_REQ=3'd5, S_WR_RSP=3'd6, S_DONE=3'd7;

  reg  [2:0]  state;
  reg  [31:0] in_addr, w_addr, out_addr, cur_in, cur_w, in_word;
  reg  [23:0] len_reg, word_idx;
  reg signed [31:0] acc;
  reg         go, irq_en, busy, done;

  // Registered device response (1-deep), mirrors the Chisel dev_d_reg.
  reg         dresp_valid;
  reg  [2:0]  dresp_opcode;
  reg  [31:0] dresp_data;
  reg  [1:0]  dresp_size;
  reg  [9:0]  dresp_source;
  reg         dresp_error;

  // ---- device request decode ----
  wire [11:0] dev_off      = tl_device_a_bits_address[11:0];
  wire        dev_is_write = (tl_device_a_bits_opcode == OP_PUT_FULL) ||
                             (tl_device_a_bits_opcode == OP_PUT_PART);
  wire        dev_a_fire   = tl_device_a_valid & tl_device_a_ready;
  wire        dev_wr       = dev_a_fire & dev_is_write;
  wire        dev_ro       = (dev_off == R_STATUS) || (dev_off == R_RESULT);
  wire        dev_known    = (dev_off == R_CTRL) || (dev_off == R_STATUS) ||
                             (dev_off == R_IN)   || (dev_off == R_W)      ||
                             (dev_off == R_OUT)  || (dev_off == R_LEN)    ||
                             (dev_off == R_RESULT);
  wire        dev_d_fire   = tl_device_d_valid & tl_device_d_ready;

  assign tl_device_a_ready = ~dresp_valid;

  // read mux (captured at request time)
  reg [31:0] dev_rdata;
  always @(*) begin
    case (dev_off)
      R_CTRL:   dev_rdata = {30'b0, irq_en, 1'b0};
      R_STATUS: dev_rdata = {29'b0, 1'b0, done, busy};
      R_IN:     dev_rdata = in_addr;
      R_W:      dev_rdata = w_addr;
      R_OUT:    dev_rdata = out_addr;
      R_LEN:    dev_rdata = {8'b0, len_reg};
      R_RESULT: dev_rdata = acc;
      default:  dev_rdata = 32'b0;
    endcase
  end

  // ---- host handshakes ----
  wire        host_a_fire = tl_host_a_valid & tl_host_a_ready;
  wire        host_d_fire = tl_host_d_valid & tl_host_d_ready;
  wire        start       = (state == S_IDLE) & go;
  wire [23:0] num_words   = (len_reg + 24'd3) >> 2;
  wire        last        = (word_idx + 24'd1) == num_words;
  wire [23:0] rem         = len_reg - (word_idx << 2);

  // operand extraction from the wide host beat
  wire [127:0] ishift = tl_host_d_bits_data >> {cur_in[3:0], 3'b0};
  wire [127:0] wshift = tl_host_d_bits_data >> {cur_w[3:0], 3'b0};
  wire [31:0]  w_word = wshift[31:0];

  // 4-lane signed int8 MAC with tail masking
  wire signed [15:0] p0 = (24'd0 < rem) ? $signed(in_word[7:0])   * $signed(w_word[7:0])   : 16'sd0;
  wire signed [15:0] p1 = (24'd1 < rem) ? $signed(in_word[15:8])  * $signed(w_word[15:8])  : 16'sd0;
  wire signed [15:0] p2 = (24'd2 < rem) ? $signed(in_word[23:16]) * $signed(w_word[23:16]) : 16'sd0;
  wire signed [15:0] p3 = (24'd3 < rem) ? $signed(in_word[31:24]) * $signed(w_word[31:24]) : 16'sd0;
  wire signed [31:0] dot4 = p0 + p1 + p2 + p3;

  // ---- host A outputs ----
  wire [31:0] sel_addr = (state == S_RIN_REQ) ? cur_in :
                         (state == S_RW_REQ)  ? cur_w  : out_addr;
  wire [3:0]  off = sel_addr[3:0];

  assign tl_host_a_valid              = (state == S_RIN_REQ) | (state == S_RW_REQ) | (state == S_WR_REQ);
  assign tl_host_a_bits_opcode        = (state == S_WR_REQ) ? OP_PUT_FULL : OP_GET;
  assign tl_host_a_bits_param         = 3'd0;
  assign tl_host_a_bits_size          = 4'd2;   // 4 bytes
  assign tl_host_a_bits_source        = 6'd0;
  assign tl_host_a_bits_address       = sel_addr;
  assign tl_host_a_bits_mask          = 16'h000f << off;
  assign tl_host_a_bits_data          = {96'b0, acc} << {off, 3'b0};
  assign tl_host_a_bits_user_rsvd     = 5'd0;
  assign tl_host_a_bits_user_instr_type = MUBI4_FALSE;
  assign tl_host_a_bits_user_cmd_intg  = 7'd0;
  assign tl_host_a_bits_user_data_intg = 7'd0;
  assign tl_host_d_ready = (state == S_RIN_RSP) | (state == S_RW_RSP) | (state == S_WR_RSP);

  // ---- device D outputs ----
  assign tl_device_d_valid              = dresp_valid;
  assign tl_device_d_bits_opcode        = dresp_opcode;
  assign tl_device_d_bits_param         = 3'd0;
  assign tl_device_d_bits_size          = dresp_size;
  assign tl_device_d_bits_source        = dresp_source;
  assign tl_device_d_bits_sink          = 1'b0;
  assign tl_device_d_bits_data          = dresp_data;
  assign tl_device_d_bits_user_rsp_intg  = 7'd0;
  assign tl_device_d_bits_user_data_intg = 7'd0;
  assign tl_device_d_bits_error         = dresp_error;

  assign irq = done & irq_en;

  // ---- sequential ----
  always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
      state <= S_IDLE;
      in_addr <= 32'b0; w_addr <= 32'b0; out_addr <= 32'b0;
      cur_in <= 32'b0; cur_w <= 32'b0; in_word <= 32'b0;
      len_reg <= 24'b0; word_idx <= 24'b0; acc <= 32'sd0;
      go <= 1'b0; irq_en <= 1'b0; busy <= 1'b0; done <= 1'b0;
      dresp_valid <= 1'b0; dresp_opcode <= 3'b0; dresp_data <= 32'b0;
      dresp_size <= 2'b0; dresp_source <= 10'b0; dresp_error <= 1'b0;
    end else begin
      // ---- FSM: state + datapath ----
      case (state)
        S_IDLE: if (start) begin
          word_idx <= 24'b0; acc <= 32'sd0; cur_in <= in_addr; cur_w <= w_addr;
          state <= (len_reg == 24'b0) ? S_WR_REQ : S_RIN_REQ;
        end
        S_RIN_REQ: if (host_a_fire) state <= S_RIN_RSP;
        S_RIN_RSP: if (host_d_fire) begin in_word <= ishift[31:0]; state <= S_RW_REQ; end
        S_RW_REQ:  if (host_a_fire) state <= S_RW_RSP;
        S_RW_RSP:  if (host_d_fire) begin
          acc      <= acc + dot4;
          word_idx <= word_idx + 24'd1;
          cur_in   <= cur_in + 32'd4;
          cur_w    <= cur_w + 32'd4;
          state    <= last ? S_WR_REQ : S_RIN_REQ;
        end
        S_WR_REQ:  if (host_a_fire) state <= S_WR_RSP;
        S_WR_RSP:  if (host_d_fire) state <= S_DONE;
        S_DONE:    state <= S_IDLE;
        default:   state <= S_IDLE;
      endcase

      // ---- go: start clears (priority), CTRL.GO write sets ----
      if (start)                                     go <= 1'b0;
      else if (dev_wr && dev_off == R_CTRL && tl_device_a_bits_data[0]) go <= 1'b1;

      // ---- busy / done ----
      if (start)                                     begin busy <= 1'b1; done <= 1'b0; end
      else if (state == S_DONE)                      begin busy <= 1'b0; done <= 1'b1; end
      else if (dev_wr && dev_off == R_CTRL && tl_device_a_bits_data[2]) done <= 1'b0;

      // ---- config registers + irq_en ----
      if (dev_wr) begin
        case (dev_off)
          R_CTRL: irq_en   <= tl_device_a_bits_data[1];
          R_IN:   in_addr  <= tl_device_a_bits_data;
          R_W:    w_addr   <= tl_device_a_bits_data;
          R_OUT:  out_addr <= tl_device_a_bits_data;
          R_LEN:  len_reg  <= tl_device_a_bits_data[23:0];
          default: ;
        endcase
      end

      // ---- device response register (1-deep) ----
      if (dev_a_fire) begin
        dresp_valid  <= 1'b1;
        dresp_opcode <= dev_is_write ? OP_ACK : OP_ACK_DATA;
        dresp_source <= tl_device_a_bits_source;
        dresp_size   <= tl_device_a_bits_size;
        dresp_error  <= (~dev_known) | (dev_is_write & dev_ro);
        dresp_data   <= dev_is_write ? dresp_data : dev_rdata;
      end else if (dev_d_fire) begin
        dresp_valid <= 1'b0;
      end
    end
  end
endmodule
