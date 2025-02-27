/*=======================================================================================*/
/*  RISCV Sail Model                                                                     */
/*                                                                                       */
/*  This Sail RISC-V architecture model, comprising all files and                        */
/*  directories except for the snapshots of the Lem and Sail libraries                   */
/*  in the prover_snapshots directory (which include copies of their                     */
/*  licences), is subject to the BSD two-clause licence below.                           */
/*                                                                                       */
/*  Copyright (c) 2017-2023                                                              */
/*    Prashanth Mundkur                                                                  */
/*    Rishiyur S. Nikhil and Bluespec, Inc.                                              */
/*    Jon French                                                                         */
/*    Brian Campbell                                                                     */
/*    Robert Norton-Wright                                                               */
/*    Alasdair Armstrong                                                                 */
/*    Thomas Bauereiss                                                                   */
/*    Shaked Flur                                                                        */
/*    Christopher Pulte                                                                  */
/*    Peter Sewell                                                                       */
/*    Alexander Richardson                                                               */
/*    Hesham Almatary                                                                    */
/*    Jessica Clarke                                                                     */
/*    Microsoft, for contributions by Robert Norton-Wright and Nathaniel Wesley Filardo  */
/*    Peter Rugg                                                                         */
/*    Aril Computer Corp., for contributions by Scott Johnson                            */
/*    Philipp Tomsich                                                                    */
/*    VRULL GmbH, for contributions by its employees                                     */
/*                                                                                       */
/*  All rights reserved.                                                                 */
/*                                                                                       */
/*  This software was developed by the above within the Rigorous                         */
/*  Engineering of Mainstream Systems (REMS) project, partly funded by                   */
/*  EPSRC grant EP/K008528/1, at the Universities of Cambridge and                       */
/*  Edinburgh.                                                                           */
/*                                                                                       */
/*  This software was developed by SRI International and the University of               */
/*  Cambridge Computer Laboratory (Department of Computer Science and                    */
/*  Technology) under DARPA/AFRL contract FA8650-18-C-7809 ("CIFV"), and                 */
/*  under DARPA contract HR0011-18-C-0016 ("ECATS") as part of the DARPA                 */
/*  SSITH research programme.                                                            */
/*                                                                                       */
/*  This project has received funding from the European Research Council                 */
/*  (ERC) under the European Union’s Horizon 2020 research and innovation                */
/*  programme (grant agreement 789108, ELVER).                                           */
/*                                                                                       */
/*                                                                                       */
/*  Redistribution and use in source and binary forms, with or without                   */
/*  modification, are permitted provided that the following conditions                   */
/*  are met:                                                                             */
/*  1. Redistributions of source code must retain the above copyright                    */
/*     notice, this list of conditions and the following disclaimer.                     */
/*  2. Redistributions in binary form must reproduce the above copyright                 */
/*     notice, this list of conditions and the following disclaimer in                   */
/*     the documentation and/or other materials provided with the                        */
/*     distribution.                                                                     */
/*                                                                                       */
/*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''                   */
/*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED                    */
/*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A                      */
/*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR                  */
/*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,                         */
/*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT                     */
/*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF                     */
/*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND                  */
/*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,                   */
/*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT                   */
/*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF                   */
/*  SUCH DAMAGE.                                                                         */
/*=======================================================================================*/

/* RV64 Supervisor-mode address translation and page-table walks. */

/* Define the architectural satp and its legalizer. */

register satp : xlenbits

function legalize_satp(a : Architecture, o : xlenbits, v : xlenbits) -> xlenbits =
  legalize_satp64(a, o, v)

/* Define valid source addresses for translation */

function isValidSv39Addr(vAddr : xlenbits) -> bool = {
  vAddr[63 .. 39] == (if   vAddr[38] == bitone
                      then ones()
                      else zeros())
}

function isValidSv48Addr(vAddr : xlenbits) -> bool = {
  vAddr[63 .. 48] == (if   vAddr[47] == bitone
                      then ones()
                      else zeros())
}

/* Compute the address translation mode. */

val translationMode : (Privilege) -> SATPMode
function translationMode(priv) = {
  if priv == Machine then Sbare
  else {
    let arch = architecture(get_mstatus_SXL(mstatus));
    match arch {
      Some(RV64) => {
        let mbits : satp_mode = Mk_Satp64(satp).Mode();
        match satp64Mode_of_bits(RV64, mbits) {
          Some(m) => m,
          None()  => internal_error(__FILE__, __LINE__, "invalid RV64 translation mode in satp")
        }
      },
      Some(RV32) => {
        let s = Mk_Satp32(satp[31..0]);
        if s.Mode() == 0b0 then Sbare else Sv32
      },
      _    => internal_error(__FILE__, __LINE__, "unsupported address translation arch")
    }
  }
}

/* Top-level address translation dispatcher */

val translateAddr_priv : (xlenbits, AccessType(ext_access_type), Privilege) -> TR_Result(xlenbits, ExceptionType)
function translateAddr_priv(vAddr, ac, effPriv) = {
  let mxr    : bool   = mstatus.MXR() == 0b1;
  let do_sum : bool   = mstatus.SUM() == 0b1;
  let mode : SATPMode = translationMode(effPriv);

  let asid = curAsid64(satp);
  let ptb  = curPTB64(satp);

  /* PTW extensions: initialize the PTW extension state. */
  let ext_ptw : ext_ptw = init_ext_ptw;

  match mode {
    Sbare => TR_Address(vAddr, ext_ptw),
    Sv39  => { if   isValidSv39Addr(vAddr)
               then match translate39(asid, ptb, vAddr[38 .. 0], ac, effPriv, mxr, do_sum, SV39_LEVELS - 1, ext_ptw) {
                      TR_Address(pa, ext_ptw) => TR_Address(zero_extend(pa), ext_ptw),
                      TR_Failure(f, ext_ptw)  => TR_Failure(translationException(ac, f), ext_ptw)
                    }
               else TR_Failure(translationException(ac, PTW_Invalid_Addr()), ext_ptw)
             },
    Sv48  => { if   isValidSv48Addr(vAddr)
               then match translate48(asid, ptb, vAddr[47 .. 0], ac, effPriv, mxr, do_sum, SV48_LEVELS - 1, ext_ptw) {
                      TR_Address(pa, ext_ptw) => TR_Address(zero_extend(pa), ext_ptw),
                      TR_Failure(f, ext_ptw)  => TR_Failure(translationException(ac, f), ext_ptw)
                    }
               else TR_Failure(translationException(ac, PTW_Invalid_Addr()), ext_ptw)
             },
    _     => internal_error(__FILE__, __LINE__, "unsupported address translation scheme")
  }
}

val translateAddr : (xlenbits, AccessType(ext_access_type)) -> TR_Result(xlenbits, ExceptionType)
function translateAddr(vAddr, ac) =
  translateAddr_priv(vAddr, ac, effectivePrivilege(ac, mstatus, cur_privilege))

val flush_TLB : (option(xlenbits), option(xlenbits)) -> unit
function flush_TLB(asid_xlen, addr_xlen) -> unit = {
  /* Flush both Sv39 and Sv48 TLBs. */
  let (addr39, addr48) : (option(vaddr39), option(vaddr48)) =
    match addr_xlen {
      None()  => (None(), None()),
      Some(a) => (Some(a[38 .. 0]), Some(a[47 .. 0]))
    };
  let asid : option(asid64) =
    match asid_xlen {
      None()  => None(),
      Some(a) => Some(a[15 .. 0])
  };
  flush_TLB39(asid, addr39);
  flush_TLB48(asid, addr48)
}

function init_vmem() -> unit = {
  init_vmem_sv39();
  init_vmem_sv48()
}
