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
import coralnpu.Parameters

/**
 * CnnAccel — "Option A" integration: all logic is hand-written SystemVerilog in
 * hdl/verilog/CnnAccel.sv (module `CnnAccelImpl`). The Chisel here is only glue:
 *
 *  - `CnnAccelImpl` is a thin `BlackBox` mirroring the SV module's ports. A
 *    BlackBox's io fields become TOP-LEVEL SV ports (no `io_` prefix), and it has
 *    no implicit clock/reset, so `clock`/`reset` are explicit ports.
 *  - `CnnAccel` is a thin `Module` shim presenting the normal `io` bundle that the
 *    subsystem's dynamic wiring loop expects (`io.tl_host` / `io.tl_device` / `io.irq`,
 *    implicit clock/reset). It just pipes those to the BlackBox. This is the same
 *    shim pattern the RVV backend uses, and it keeps the SoC config unchanged.
 *
 * No behaviour lives in Chisel — see CnnAccel.sv.
 */

/** BlackBox around the pure-SystemVerilog implementation (module `CnnAccelImpl`). */
class CnnAccelImpl(hostParams: Parameters, deviceParams: Parameters)
    extends BlackBox with HasBlackBoxResource {
  val hostTlulP   = new TLULParameters(hostParams)
  val deviceTlulP = new TLULParameters(deviceParams)

  val io = IO(new Bundle {
    val clock     = Input(Clock())
    val reset     = Input(AsyncReset())
    val tl_host   = new OpenTitanTileLink.Host2Device(hostTlulP)
    val tl_device = Flipped(new OpenTitanTileLink.Host2Device(deviceTlulP))
    val irq       = Output(Bool())
  })

  addResource("CnnAccel.sv")
}

/** Thin Chisel shim: the normal Module the SoC generator wires up. */
class CnnAccel(hostParams: Parameters, deviceParams: Parameters) extends Module {
  val hostTlulP   = new TLULParameters(hostParams)
  val deviceTlulP = new TLULParameters(deviceParams)

  val io = IO(new Bundle {
    val tl_host   = new OpenTitanTileLink.Host2Device(hostTlulP)
    val tl_device = Flipped(new OpenTitanTileLink.Host2Device(deviceTlulP))
    val irq       = Output(Bool())
  })

  val impl = Module(new CnnAccelImpl(hostParams, deviceParams))
  impl.io.clock := clock
  impl.io.reset := reset.asAsyncReset
  io.tl_host        <> impl.io.tl_host
  impl.io.tl_device <> io.tl_device
  io.irq := impl.io.irq
}
