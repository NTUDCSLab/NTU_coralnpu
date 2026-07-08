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

package bus

import chisel3._
import chisel3.util._
import common.{MakeValid, MakeInvalid, MuBi4}
import coralnpu.Parameters

/**
 * CnnAccel — a minimal CNN/MatMul compute accelerator, integrated as a
 * TileLink-UL bus device (Path A: MMIO + DMA).
 *
 * It computes a length-`LEN` integer dot product (the fundamental conv / GEMM
 * primitive):
 *
 *     RESULT = sum_{i=0..LEN-1} IN[i] * W[i]        (uint32 MAC, truncated)
 *
 * Control is via a memory-mapped CSR block (the `tl_device` slave); the engine
 * streams the IN/W operands and writes the result over its own bus-master port
 * (`tl_host`). Structure intentionally mirrors `DmaEngine.scala` so the same
 * host A/D request pattern and device CSR read/write pattern are reused.
 *
 * CSR map (32-bit registers, base set in CrossbarConfig, default 0x40060000):
 *   0x00 CTRL     [w]  bit0 = GO (write 1 to start)
 *   0x04 STATUS   [ro] bit0 = busy, bit1 = done, bit2 = error
 *   0x08 IN_ADDR  [rw] activation base address in memory
 *   0x0c W_ADDR   [rw] weight base address in memory
 *   0x10 OUT_ADDR [rw] result base address in memory
 *   0x14 LEN      [rw] number of int32 elements
 *   0x18 RESULT   [ro] accumulator read-back
 */
class CnnAccel(hostParams: Parameters, deviceParams: Parameters) extends Module {
  val hostTlulP   = new TLULParameters(hostParams)
  val deviceTlulP = new TLULParameters(deviceParams)

  val io = IO(new Bundle {
    val tl_host   = new OpenTitanTileLink.Host2Device(hostTlulP)            // bus master
    val tl_device = Flipped(new OpenTitanTileLink.Host2Device(deviceTlulP)) // CSR slave
  })

  // --- Internal queued channels (mirror DmaEngine) ---
  val host_a_internal = Wire(Decoupled(new OpenTitanTileLink.A_Channel(hostTlulP)))
  val host_d_internal = Wire(Flipped(Decoupled(new OpenTitanTileLink.D_Channel(hostTlulP))))
  val dev_a_internal  = Wire(Flipped(Decoupled(new OpenTitanTileLink.A_Channel(deviceTlulP))))
  val dev_d_internal  = Wire(Decoupled(new OpenTitanTileLink.D_Channel(deviceTlulP)))

  // --- CSR register map ---
  object CnnReg extends ChiselEnum {
    val CTRL     = Value(0x00.U(12.W))
    val STATUS   = Value(0x04.U(12.W))
    val IN_ADDR  = Value(0x08.U(12.W))
    val W_ADDR   = Value(0x0c.U(12.W))
    val OUT_ADDR = Value(0x10.U(12.W))
    val LEN      = Value(0x14.U(12.W))
    val RESULT   = Value(0x18.U(12.W))
    // Force full 12-bit enum width (see DmaEngine note).
    val RSVD     = Value(0xfff.U(12.W))
  }
  import CnnReg._

  // --- FSM ---
  object State extends ChiselEnum {
    val sIdle, sReadInReq, sReadInResp, sReadWReq, sReadWResp, sWriteReq, sWriteResp, sDone = Value
  }
  import State._

  class CnnDevD extends Bundle {
    val opcode = UInt(3.W)
    val data   = UInt(32.W)
    val size   = UInt(deviceTlulP.z.W)
    val source = UInt(deviceTlulP.o.W)
    val error  = Bool()
  }

  val state = RegInit(sIdle)

  // Config registers (device-writable)
  val in_addr  = RegInit(0.U(32.W))
  val w_addr   = RegInit(0.U(32.W))
  val out_addr = RegInit(0.U(32.W))
  val len_reg  = RegInit(0.U(24.W))

  // Status / compute state
  val go      = RegInit(false.B)
  val busy    = RegInit(false.B)
  val done    = RegInit(false.B)
  val idx     = RegInit(0.U(24.W))
  val acc     = RegInit(0.U(32.W))
  val in_word = RegInit(0.U(32.W))
  val cur_in  = RegInit(0.U(32.W))
  val cur_w   = RegInit(0.U(32.W))

  val dev_d_reg = RegInit(MakeInvalid(new CnnDevD))

  // --- Device port CSR decode ---
  val dev_addr_offset                    = dev_a_internal.bits.address(11, 0)
  val (dev_addr_reg, dev_addr_reg_valid) = CnnReg.safe(dev_addr_offset)
  val dev_is_known_addr                  = dev_addr_reg_valid && (dev_addr_reg =/= RSVD)
  val (dev_a_opcode, dev_a_opcode_valid) = TLULOpcodesA.safe(dev_a_internal.bits.opcode)
  val dev_is_write =
    dev_a_opcode_valid && dev_a_opcode.isOneOf(TLULOpcodesA.PutFullData, TLULOpcodesA.PutPartialData)
  val dev_wr = dev_a_internal.fire && dev_is_write

  // --- Host helpers ---
  val host_a_fire = host_a_internal.fire
  val host_d_fire = host_d_internal.fire
  val start       = (state === sIdle) && go
  val last        = (idx + 1.U) === len_reg

  // Byte-offset word extract from a wide host beat (mirror DmaEngine data_buf logic).
  val offBits = log2Ceil(hostTlulP.w)
  def extractWord(beat: UInt, addr: UInt): UInt =
    (beat >> (addr(offBits - 1, 0) << 3))(31, 0)

  // Mask for a given size (log2 bytes), as in DmaEngine.
  def sizeMask(size: UInt): UInt = {
    val maxBytes = hostTlulP.w
    MuxLookup(size, ((1 << maxBytes) - 1).U)(
      (0 until log2Ceil(maxBytes) + 1).map(i => i.U -> ((1 << (1 << i)) - 1).U)
    )
  }

  // --- FSM next state ---
  state := MuxCase(
    state,
    Seq(
      (state === sIdle && start)                -> Mux(len_reg === 0.U, sWriteReq, sReadInReq),
      (state === sReadInReq && host_a_fire)     -> sReadInResp,
      (state === sReadInResp && host_d_fire)    -> sReadWReq,
      (state === sReadWReq && host_a_fire)      -> sReadWResp,
      (state === sReadWResp && host_d_fire)     -> Mux(last, sWriteReq, sReadInReq),
      (state === sWriteReq && host_a_fire)      -> sWriteResp,
      (state === sWriteResp && host_d_fire)     -> sDone,
      (state === sDone)                         -> sIdle
    )
  )

  // --- go / busy / done ---
  val ctrl_go_wr = dev_wr && (dev_addr_reg === CTRL) && dev_a_internal.bits.data(0)
  when(start)           { go := false.B }
    .elsewhen(ctrl_go_wr) { go := true.B }

  when(start)              { busy := true.B; done := false.B }
    .elsewhen(state === sDone) { busy := false.B; done := true.B }

  // --- config registers ---
  when(dev_wr && dev_addr_reg === IN_ADDR)  { in_addr  := dev_a_internal.bits.data }
  when(dev_wr && dev_addr_reg === W_ADDR)   { w_addr   := dev_a_internal.bits.data }
  when(dev_wr && dev_addr_reg === OUT_ADDR) { out_addr := dev_a_internal.bits.data }
  when(dev_wr && dev_addr_reg === LEN)      { len_reg  := dev_a_internal.bits.data }

  // --- compute datapath ---
  when(start) {
    idx    := 0.U
    acc    := 0.U
    cur_in := in_addr
    cur_w  := w_addr
  }
  when(state === sReadInResp && host_d_fire) {
    in_word := extractWord(host_d_internal.bits.data, cur_in)
  }
  when(state === sReadWResp && host_d_fire) {
    val w_word = extractWord(host_d_internal.bits.data, cur_w)
    acc    := (acc + in_word * w_word)(31, 0)
    idx    := idx + 1.U
    cur_in := cur_in + 4.U
    cur_w  := cur_w + 4.U
  }

  // --- host A channel ---
  host_a_internal.valid := state.isOneOf(sReadInReq, sReadWReq, sWriteReq)
  val sel_addr = MuxLookup(state.asUInt, 0.U)(
    Seq(
      sReadInReq.asUInt -> cur_in,
      sReadWReq.asUInt  -> cur_w,
      sWriteReq.asUInt  -> out_addr
    )
  )
  val off = sel_addr(offBits - 1, 0)
  val host_a_bits = Wire(new OpenTitanTileLink.A_Channel(hostTlulP))
  host_a_bits.opcode  := Mux(state === sWriteReq, TLULOpcodesA.PutFullData.asUInt, TLULOpcodesA.Get.asUInt)
  host_a_bits.param   := 0.U
  host_a_bits.size    := 2.U // 4 bytes
  host_a_bits.source  := 0.U
  host_a_bits.address := sel_addr
  host_a_bits.mask    := sizeMask(2.U) << off
  host_a_bits.data    := acc << (off << 3)
  host_a_bits.user            := 0.U.asTypeOf(host_a_bits.user)
  host_a_bits.user.instr_type := MuBi4.False.asUInt
  host_a_internal.bits := host_a_bits

  io.tl_host.a <> Queue(host_a_internal, 1)
  host_d_internal <> Queue(io.tl_host.d, 1)
  host_d_internal.ready := state.isOneOf(sReadInResp, sReadWResp, sWriteResp)

  // --- device CSR response ---
  val is_ro_reg      = dev_addr_reg.isOneOf(STATUS, RESULT)
  val status_reg_val = Cat(0.U(29.W), 0.U(1.W), done, busy) // [0]=busy [1]=done [2]=error(0)

  dev_d_reg := Mux(
    dev_a_internal.fire, {
      val b = Wire(new CnnDevD)
      b.source := dev_a_internal.bits.source
      b.size   := dev_a_internal.bits.size
      b.opcode := Mux(dev_is_write, TLULOpcodesD.AccessAck.asUInt, TLULOpcodesD.AccessAckData.asUInt)
      b.error  := !dev_is_known_addr || (dev_is_write && is_ro_reg)
      b.data := Mux(
        !dev_is_write,
        MuxLookup(dev_addr_reg, 0.U)(
          Seq(
            CTRL     -> Cat(0.U(31.W), go),
            STATUS   -> status_reg_val,
            IN_ADDR  -> in_addr,
            W_ADDR   -> w_addr,
            OUT_ADDR -> out_addr,
            LEN      -> Cat(0.U(8.W), len_reg),
            RESULT   -> acc
          )
        ),
        dev_d_reg.bits.data
      )
      MakeValid(b)
    },
    Mux(io.tl_device.d.fire, MakeInvalid(new CnnDevD), dev_d_reg)
  )

  // Device A / D queues
  dev_a_internal <> Queue(io.tl_device.a, 1)
  dev_a_internal.ready := !dev_d_reg.valid

  dev_d_internal.valid       := dev_d_reg.valid
  dev_d_internal.bits.opcode := dev_d_reg.bits.opcode
  dev_d_internal.bits.data   := dev_d_reg.bits.data
  dev_d_internal.bits.size   := dev_d_reg.bits.size
  dev_d_internal.bits.source := dev_d_reg.bits.source
  dev_d_internal.bits.error  := dev_d_reg.bits.error
  dev_d_internal.bits.sink   := 0.U
  dev_d_internal.bits.param  := 0.U
  dev_d_internal.bits.user   := 0.U.asTypeOf(dev_d_internal.bits.user)

  io.tl_device.d <> Queue(dev_d_internal, 1)
}
