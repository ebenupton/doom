
; ============================================================================
; br_project_x — project view-space X to screen X with sub-pixel.
;
;   Inputs (zp):
;     zp_br_t0 = vx (s8, truncated view-space x)
;     zp_br_t1 = vx_frac (u8, fractional part)
;     zp_br_rhi = M8 (recip mantissa), zp_br_rlo = S (recip shift)
;
;   Output:
;     zp_br_resl/h = sx (s16 screen x)
;
;   Python (fp_project_x_subpx):
;     sx = 128 + rns(X88*m9, S+8)  with X88 = vx*256 + frac, m9 = 256+M8.
;
;   Two 8x8 multiplies (was 3 with the 8.8 recip — the third mul carried
;   recip bits below quarter-pixel significance). Exact identity used:
;     floor(X88*m9 / 256) = (frac*M8 >> 8) + frac
;                         + smul(vx, M8) + (vx << 8)
;   (only frac*M8 has bits below 2^8), accumulated as s24 in
;   (t2, t3, vxext) and handed to rns24 — bit-identical to Python's
;   rns(P32, S+8) by floor composition.
;
;   This is the NARROW path — the integer view-x must fit s8. Callers go
;   through br_project_x_auto (defq.s B region), which dispatches here or
;   to br_project_x_wide (lo.s, 3 muls) on the s16 view-x sign extension.
;   Clobbers zp_br_t2/t3, zp_br_vxext, zp_br_a/b, mul workspace.
; ============================================================================
br_project_x:
.scope
; --- b123 := (frac*M8 >> 8) + frac  (u9; both terms vanish when frac=0) ---
   LDA #0
   STA zp_br_t3
   STA zp_br_vxext
; M8 == 0 (m9 = 256 exactly): both products are zero — b123 = frac + vx<<8.
   LDA zp_br_rhi
   BNE px_have_m8
   LDA zp_br_t1
   STA zp_br_t2
   JMP px_p_pos
px_have_m8:
   LDA zp_br_t1
   BNE px_have_frac
   STA zp_br_t2
   BEQ px_no_frac
px_have_frac:
   LDA zp_br_rhi
   STA zp_mul_b
   LDA zp_br_t1
   JSR SC_UMUL8                            ; A = prod_hi (umul8 contract)
   CLC
   ADC zp_br_t1
   STA zp_br_t2
   LDA #0
   ADC #0
   STA zp_br_t3
px_no_frac:

; --- += smul(vx, M8) (s16, sign-extended into vxext) ---
   LDA zp_br_rhi
   STA zp_mul_b
   LDA zp_br_t0
   JSR br_smul_am                          ; a in A (N live), b in zp_mul_b
   LDA zp_br_resl
   CLC
   ADC zp_br_t2
   STA zp_br_t2
   LDA zp_br_resh
   ADC zp_br_t3
   STA zp_br_t3
   BCC px_p_nc                             ; BCC/INC ext bump (carry ~50%)
   INC zp_br_vxext
px_p_nc:
   LDA zp_br_resh
   BPL px_p_pos
   DEC zp_br_vxext
px_p_pos:

; --- += vx << 8 (sign-extended) ---
   LDA zp_br_t0
   CLC
   ADC zp_br_t3
   STA zp_br_t3
   BCC px_i_nc
   INC zp_br_vxext
px_i_nc:
   LDA zp_br_t0
   BPL px_i_pos
   DEC zp_br_vxext
px_i_pos:

; --- sx = 128 + rns(b123, S) (per-vertex vectored shifter) ---
   JSR rns_go
   LDA zp_br_resl
   CLC
   ADC #128
   STA zp_br_resl
   TAY                                     ; REG CONTRACT (2026-07-12): every
                                        ; projection RTSes with Y = res lo,
                                        ; A = res hi (ZP resl/resh still
                                        ; written — regs are the fast lane)
   LDA zp_br_resh
   ADC #0
   STA zp_br_resh
   RTS
.endscope


; ============================================================================
; br_project_y — project height delta to screen Y, through the VWHC memo.
; (Consolidated 2026-07-12: the cache front moved here from the deleted
; ycache.s and the raw body below is INLINED — the miss path FALLS
; THROUGH into it, and the writeback rides the raw tail. One routine,
; one file, no JSR/RTS between front and body.)
;
;   Native entry (br_project_y): h in A (REG CONTRACT — also stored to
;     zp_br_t0 here), zp_br_rhi/rlo = (M8, S) recip.
;   jt/harness entry (br_project_y_paged): pages L2, loads h from
;     zp_br_t0 (the wrapper contract predates the register pass).
;   Output: zp_br_resl/h = sy (s16, pre-biased by Y_BIAS folded into the
;     128 constant); RTSes with Y = sy lo, A = sy hi (REG CONTRACT).
;   Preserves the input set; clobbers X, Y, zp_pyc_idx + raw scratch on
;     a miss. CALLER pages BANK_L2 (y_stage/apv page once per run).
;
; VWHC: direct-mapped, 256 entries, five parallel arrays (equates in
; resolve_crossing.s; flat $D500-$D9FF page-aligned, banked L2 $B500-).
; Probe = h ^ rhi (corpus-searched 2026-07-12: the ~140-key working set
; sits AT the birthday bound — S-boxes and 2-way associativity measured
; no better; only probe COST was free). Key = the COMPLETE input tuple
; (rhi, rlo, h) of a pure function, so entries survive frames/positions
; and a hit is bit-identical to the raw body by construction. RLO
; doubles as the valid flag (live S is never 0). Never cleared: the
; bank/harness images arrive zeroed (the old boot-only vwhc_clear had
; no callers and was GC'd).
; ============================================================================
br_project_y_paged:
   PAGE BANK_L2
   LDA zp_br_t0
br_project_y:
.scope
   STA zp_br_t0                            ; h (tag compare + raw body reads)
   EOR zp_br_rhi
   TAX                                     ; probe idx = h ^ rhi
   LDA VWHC_RLO,X                          ; RLO doubles as the valid flag
   CMP zp_br_rlo
   BNE pyc_miss
   LDA VWHC_RHI,X
   CMP zp_br_rhi
   BNE pyc_miss
   LDA VWHC_H,X
   CMP zp_br_t0
   BNE pyc_miss
   LDY VWHC_LO,X                           ; REG CONTRACT: Y = lo, A = hi
   STY zp_br_resl
   LDA VWHC_HI,X
   STA zp_br_resh
   RTS
pyc_miss:
   STX zp_pyc_idx                          ; slot for the tail writeback;
.endscope                                  ; FALLS THROUGH into the raw body

; ============================================================================
; br_project_y — project height delta to screen Y.
;
;   Inputs (zp):
;     zp_br_t0 = height_delta (s8)
;     zp_br_rhi = M8 (recip mantissa), zp_br_rlo = S (recip shift)
;
;   Output:
;     zp_br_resl/h = sy (s16)
;
;   Python (fp_project_y):
;     sy = HALF_H - rns(h*M8 + (h << 8), S)     [h*m9, m9 = 256+M8]
;
;   ONE signed s8×u8 multiply (was 2 with the 8.8 recip). The s24
;   product P = h*m9 (|P| <= 127*511, s17) goes through rns24 — the
;   shared round-to-nearest shifter, bit-identical to Python's rns.
;   With the near-plane crossing reciprocal (M8=0, S=1) this computes
;   sy = 128 - (h<<7) exactly: the mul degenerates to zero.
;
;   This label is br_project_y_RAW: the uncached projection body.
;   Production callers go through br_project_y (the cache front ABOVE),
;   front keyed on the full (M8, S, h) input tuple; only that front
;   calls _raw.
;
;   NOTE the constant loaded below is 128 = HALF_H (80) + Y_BIAS (48): the
;   screen-space Y bias every consumer used to add per-store is folded into
;   the projection, so results come out PRE-BIASED. Same final values.
;   Clobbers zp_br_t2/t3, zp_br_vxext, zp_br_a/b, mul workspace.
; ============================================================================
br_project_y_raw:
.scope
; --- P24 = h*M8 + (h << 8), s24 in (t2, t3, vxext) ---
; M8 == 0 (m9 = 256 exactly: the near-plane crossing recip and every
; power-of-two depth): the product is zero — skip the mul, P24 = h<<8.
   LDA zp_br_rhi
   BNE py_have_m8
   STA zp_br_t2
   LDA zp_br_t0
   STA zp_br_t3
   LDA #0
   STA zp_br_vxext
   LDA zp_br_t0
   BPL py_go
   DEC zp_br_vxext
py_go:
   JMP py_shift
py_have_m8:
; --- h*M8 inlined (br_smul_s8_u8 body, de-larded): lo lands straight in
; t2 and the hi byte stays in A for the mid add — saves the a/b staging,
; the JSR/RTS, the prod->res copy and both resh reloads (~44 cyc/call).
; Math is bit-identical to br_smul_s8_u8 (same quarter-square idiom).
   LDA zp_br_t0
   BMI pym_neg
; positive h: unsigned quarter-square, result used as-is
   TAX
   SEC
   SBC zp_br_rhi
   BCS pym_pd
   EOR #$FF
   ADC #1
pym_pd:
   TAY                                     ; Y = |h - M8|
   TXA
   CLC
   ADC zp_br_rhi
   TAX                                     ; X = h + M8
   BCS pym_puo
   LDA sqr_lo,X
   SEC
   SBC sqr_lo,Y
   STA zp_br_t2                            ; P24 lo
   LDA sqr_hi,X
   SBC sqr_hi,Y
   JMP pym_join                            ; A = hi(h*M8)
pym_puo:
   LDA sqr2_lo,X                           ; f(x+y) overflowed into the
   SBC sqr_lo,Y                            ; +256 window (carry in = 1)
   STA zp_br_t2
   LDA sqr2_hi,X
   SBC sqr_hi,Y
   JMP pym_join
pym_neg:
; negative h: |h| through the quarter-square, negate during the copy-out
   EOR #$FF
   BUMP                                    ; A = |h|
   TAX
   SEC
   SBC zp_br_rhi
   BCS pym_nd
   EOR #$FF
   ADC #1
pym_nd:
   TAY
   TXA
   CLC
   ADC zp_br_rhi
   TAX
   BCS pym_nuo
   LDA sqr_lo,X
   SEC
   SBC sqr_lo,Y
   STA zp_br_t2                            ; |prod| lo (negated below)
   LDA sqr_hi,X
   SBC sqr_hi,Y
   JMP pym_nneg
pym_nuo:
   LDA sqr2_lo,X
   SBC sqr_lo,Y
   STA zp_br_t2
   LDA sqr2_hi,X
   SBC sqr_hi,Y
pym_nneg:
   TAX                                     ; X = |prod| hi
   SEC
   LDA #0
   SBC zp_br_t2
   STA zp_br_t2                            ; lo = -|prod| lo
   TXA
   EOR #$FF
   ADC #0                                  ; hi = ~|hi| + (lo == 0)
pym_join:
; --- P24 mid: A = hi(h*M8). |h| <= 64 is PACK-ASSERTED (the projection
; bound fence in doom_wireframe.py, 2026-07-12): |h*m9| <= 64*511 < 2^15,
; so P24 fits s16 and the ext byte is PURE SIGN of the mid byte — the
; old carry + two sign-extension terms (the senior-byte bookkeeping)
; cancel by construction and are gone (~12 cycles/raw call). A violating
; map fails the PACK, not the render. ---
   CLC
   ADC zp_br_t0                            ; mid = hi(h*M8) + h
   STA zp_br_t3
   ASL A                                   ; C = sign of t3 (A dead after);
   LDA #0                                  ; branchless sign spread — NOTE
   ADC #$FF                                ; the first cut used LDX #0/BPL
   EOR #$FF                                ; and LDX had already clobbered
   STA zp_br_vxext                         ; the ADC's N flag: ext was
py_shift:                                  ; always 0. C survives LDA/STA.

; --- sy = 128 - rns(P24, S) (per-vertex vectored shifter) ---
   JSR rns_go
   LDA #128
   SEC
   SBC zp_br_resl
   STA zp_br_resl
   TAY                                     ; REG CONTRACT: Y = sy lo, A = sy hi
   LDA #0
   SBC zp_br_resh
   STA zp_br_resh
; --- VWHC writeback (the raw body is only ever entered through the
; cache front's miss path above) ---
   LDX zp_pyc_idx
   LDA zp_br_rhi
   STA VWHC_RHI,X
   LDA zp_br_rlo
   STA VWHC_RLO,X
   LDA zp_br_t0
   STA VWHC_H,X
   TYA
   STA VWHC_LO,X
   LDA zp_br_resh
   STA VWHC_HI,X                           ; (A = hi, Y = lo at RTS)
   RTS
.endscope

; ============================================================================
; RNS VECTORING — round-to-nearest shift dispatch for the projections.
;
; The shift S (zp_br_rlo, ALWAYS in [1,10], never 0 — it doubles as the
; VWHC valid flag) is a per-vertex constant, so the shifter is selected
; ONCE per reciprocal and each projection dispatches with a single JSR:
;
;   rns_go:  JSR'd by br_project_x and br_project_y_raw (both this
;            file). It is ONE instruction — JMP <body> — whose OPERAND is
;            the live shifter (SMC, 2026-07-12): rns_select below and the
;            three INLINED selects in subsector.s's y_stage write
;            rns_go+1/+2 from the rns_vec tables. No ZP vector (the old
;            zp_rns_vec pair $C6/$C7 is freed), and JMP abs is 2 cycles
;            cheaper than the old JMP (zp).
;   INVARIANT: every writer of zp_br_rlo MUST re-select (JSR rns_select
;            or the inlined form) before the next projection, or the
;            dispatch runs a stale shifter. Current writers: br_recip
;            (arith.s), the vcache hit path (seg_xform.s), chain_reuse_v1
;            (lo.s), y_stage (subsector.s).
;
; ALL bodies live in this file, in the LO segment (one CODE region both
; builds; evicted from the stack page 2026-07-12 — page 1 is reserved
; headroom and the banked staging/boot-copy machinery died with it):
; unrolled rns_s6..rns_s10 for the hot shifts, generic rns24 for the
; rare S in [1,5]. Every body computes floor((P + 2^(S-1)) / 2^S) on the
; s24 product in (t2, t3, vxext) and RTSes straight back to the
; projection's caller — pure leaves, bit-exact vs Python's rns().
; ============================================================================
.segment "LO"
.segment "RNSPG"                        ; page-ALIGNED segment (cfg align=$100):
                                        ; guarantees all kernel entries share
                                        ; the JMP operand's high byte
rns_go:
   JMP rns24                               ; operand LO byte = live shifter
                                        ; (SMC by rns_select + the inlined
                                        ; selects; the HI byte is CONSTANT
                                        ; — all six kernel entries share
                                        ; one 256-byte window, asserted
                                        ; below — so a select patches ONE
                                        ; byte, 2026-07-12)

rns_select:
.scope
   LDX zp_br_rlo
   LDA rns_vec_lo-1,X
   STA rns_go+1
   RTS
.endscope
rns_vec_lo:
   .byte <rns24, <rns24, <rns24, <rns24, <rns24
   .byte <rns_s6, <rns_s7, <rns_s8, <rns_s9, <rns_s10
; (rns_vec_hi retired: single-page kernels, constant JMP hi byte)

; --- the six kernels: entries must stay inside the first 256 bytes of
; this aligned segment (bodies may spill past); the fence asserts catch
; any growth that pushes an entry over the edge ---
rns_s8:
.scope
; floor((P + $80) / 256): carry out of the b0 half-add, then drop b0
   LDA zp_br_t2
   CLC
   ADC #$80
   LDA zp_br_t3
   ADC #0
   STA zp_br_resl
   LDA zp_br_vxext
   ADC #0
   STA zp_br_resh
   RTS
.endscope
rns_s9:
.scope
; floor((P + $100) / 512): t3 += 1 (carry into ext), ASR the top pair
   LDA zp_br_t3
   CLC
   ADC #1
   TAX
   LDA zp_br_vxext
   ADC #0
   CMP #$80                                ; C = sign bit → arithmetic ROR
   ROR A
   STA zp_br_resh
   TXA
   ROR A
   STA zp_br_resl
   RTS
.endscope

rns_s6:
.scope
; floor((P + $20) / 64) = ((P + $20) << 2) >> 8
   LDA zp_br_t2
   CLC
   ADC #$20
   STA zp_br_t2
   BCC rc_done_s6                     ; round-carry: BCC/INC wrap chain
   INC zp_br_t3                            ; (carry set ~12%, wrap rarer —
   BNE rc_done_s6                     ; beats the 16-cycle ADC ladder
   INC zp_br_vxext                         ; on every path)
rc_done_s6:
   ASL zp_br_t2
   ROL zp_br_t3
   ROL zp_br_vxext
   ASL zp_br_t2
   LDA zp_br_t3
   ROL A
   STA zp_br_resl
   LDA zp_br_vxext
   ROL A
   STA zp_br_resh
   RTS
.endscope

rns_s7:
.scope
; floor((P + $40) / 128) = ((P + $40) << 1) >> 8
   LDA zp_br_t2
   CLC
   ADC #$40
   STA zp_br_t2
   BCC rc_done_s7                     ; round-carry: BCC/INC wrap chain
   INC zp_br_t3                            ; (carry set ~12%, wrap rarer —
   BNE rc_done_s7                     ; beats the 16-cycle ADC ladder
   INC zp_br_vxext                         ; on every path)
rc_done_s7:
   ASL zp_br_t2
   LDA zp_br_t3
   ROL A
   STA zp_br_resl
   LDA zp_br_vxext
   ROL A
   STA zp_br_resh
   RTS
.endscope

rns_s10:
.scope
; floor((P + $200) / 1024): t3 += 2 (carry into ext), drop b0, ASR twice
   LDA zp_br_t3
   CLC
   ADC #2
   STA zp_br_t3
   LDA zp_br_vxext
   ADC #0
   CMP #$80                                ; C = sign → arithmetic ROR
   ROR A
   ROR zp_br_t3
   CMP #$80
   ROR A
   ROR zp_br_t3
   STA zp_br_resh
   LDA zp_br_t3
   STA zp_br_resl
   RTS
.endscope
; (rns24 follows IN THE SAME LO PAGE — pulled out of the ANG segment
; 2026-07-12 so all six kernel entries share the JMP hi byte; its
; rns_half rounding-constant tables stay in resolve_crossing.s.)
; ============================================================================
rns24:
.scope
   LDX zp_br_rlo
; --- add half = 2^(S-1): lo byte for S<=8, mid byte holds S=9,10 ---
   LDA rns_half_lo-1,X
   CLC
   ADC zp_br_t2
   STA zp_br_t2
   LDA rns_half_mid-1,X
   ADC zp_br_t3
   STA zp_br_t3
   BCC rn_half_nc                          ; BCC/INC ext bump (-2 bytes, ANG is full)
   INC zp_br_vxext
rn_half_nc:
   CPX #8
   BCC rn_small
; --- S >= 8 here means S = 10: rns_fast (the only caller) intercepts
; S = 8 and S = 9 with unrolled bodies. Drop b0, ASR twice. ---
   LDA zp_br_vxext
   CMP #$80                                ; C = sign bit → arithmetic ROR
   ROR zp_br_vxext
   ROR zp_br_t3
   LDA zp_br_vxext
   CMP #$80
   ROR zp_br_vxext
   ROR zp_br_t3
rn_tail_mid:
   LDA zp_br_t3
   STA zp_br_resl
   LDA zp_br_vxext
   STA zp_br_resh
   RTS
rn_small:
   CPX #5
   BCC rn_right
; --- S in [5,7]: shift LEFT (8-S) — 1..3 iterations — then drop b0 ---
   LDA #8
   SEC
   SBC zp_br_rlo
   TAX                                     ; X = 8-S in [1,3]
rn_lloop:
   ASL zp_br_t2
   ROL zp_br_t3
   ROL zp_br_vxext
   DEX
   BNE rn_lloop
   BEQ rn_tail_mid                         ; (always) result = (t3, vxext)
rn_right:
; --- S in [1,4]: ASR the s24 S times — 1..4 iterations. S=1 is the
; near-plane crossing reciprocal, so this path is hot for clipped segs.
rn_rloop:
   LDA zp_br_vxext
   CMP #$80
   ROR zp_br_vxext
   ROR zp_br_t3
   ROR zp_br_t2
   DEX
   BNE rn_rloop
   LDA zp_br_t2
   STA zp_br_resl
   LDA zp_br_t3
   STA zp_br_resh
   RTS
.endscope
.assert >rns_s6 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s7 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s8 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s9 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s10 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"


.if ::BANKED
.segment "MAIN"
.else
.segment "MAIN"
.endif

; ============================================================================
; ROM/RAM base addresses (Python wrapper writes these into ZP at frame start)
; "zp_"-named for history but these live in the $0BEC-$0BF7 absolute page —
; cold, read a few times per seg via indirect-pointer setup. They point at
; the packed WAD arrays built by wad_packed.build_packed (vertices,
; subsector SoA pages, seg headers, VWH heights, seg detail).
; ============================================================================
; ($0BF4/$0BF5 freed 2026-07-10: zp_rom_vwh retired — no 6502 reader)
zp_rom_detail_lo = $0BF6
zp_rom_detail_hi = $0BF7

; BSP traversal state
BSP_STACK = $0A00                       ; 32 entries × 2 bytes = 64-byte stack at $0A00-0A3F

; Side-test result holder

; --- Node-read scratch ---
