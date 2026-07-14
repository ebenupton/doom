
; ============================================================================
; br_project_x — project view-space X to screen X with sub-pixel.
;   THE single X projector (2026-07-12: the old narrow/wide/_auto trio
;   rolled up — narrow and wide each had exactly one caller, _auto, which
;   staged v_x* into t0/t1 and post-staged resext; all of that is gone).
;
;   Inputs (zp):
;     zp_v_x_x:zp_v_x_h = s16 integer view-x, zp_v_x_l = u8 fraction
;     zp_br_r_m8 = M8 (recip mantissa), zp_br_r_s = S (recip shift)
;
;   Output:
;     zp_br_res_l/h = sx (s16 screen x); Y = sx lo, A = sx hi (REG
;     CONTRACT). (resext is NOT an output — no consumer, 2026-07-13.)
;
;   Python (fp_project_x):
;     sx = 128 + rns(X88*m9, S+8)  with X88 = vx*256 + frac, m9 = 256+M8.
;
;   Dispatch: when the integer part fits s8 (xext == sign extension of
;   xint, tested as xext + sign-carry == 0) fall through to the NARROW
;   body — two 8x8 multiplies, exact identity
;     floor(X88*m9 / 256) = (frac*M8 >> 8) + frac
;                         + smul(vx, M8) + (vx << 8)
;   (only frac*M8 has bits below 2^8), accumulated as s24 in
;   (t2, resl, resh) and handed to rns24 — bit-identical to Python's
;   rns(P32, S+8) by floor composition. An s16 view-x is SHRUNK first:
;   X88 >>= 1 with S-- until the integer part fits s8 (px_shrink below;
;   err <= |vx|/(256*vy) px, ~0.008px measured max). Wide-vx segs must
;   still be projected — their mark_solid/draws count.
;   Clobbers zp_br_t2, zp_br_a/b, mul workspace.
; ============================================================================
.scope
px_shrink:
; s16 view-x (cold; INLINED above the entry 2026-07-13 so the hot
; dispatch below falls straight through and this block is in BNE
; range). Halve the 8.8 X88, dropping the exponent per step, until the
; integer part fits s8 — err <= |vx|/(256*vy) px (corpus max 0.008px).
; The NET SHIFT (S minus shifts taken) is tracked in X as an index
; into rns_vec_all, bias +3: X = net+3 in [1,13]. net >= -2 is a DOMAIN
; PRECONDITION, not a runtime clamp (map diagonal 672 wu -> k <= 3;
; S >= 1 — a violating input indexes garbage; the harness respects the
; domain). zp_br_r_s is written ONLY
; on the rns24 arm (net in [1,4], the one kernel that reads it; unseen
; in corpus): every other arm patches rns_go_op straight from the ONE
; ordered table and TAIL-CALLS the narrow body — no S restore, no
; re-select, no register reload. A stale rns_go_op between projections
; is fine BY the rlo-writer invariant: every dispatcher selects before
; its dispatch. Net<1 = the no-round kernels rns_s0/sm1/sm2 ('right
; magnitude on the shrink's truncation grid', per Eben).
   LDX zp_br_r_s
   INX
   INX
   INX                                     ; X = net+3 (starts at S+3)
ps_loop:
   DEX
ps_shift:
   LDA zp_v_x_x
   CMP #$80                                ; arithmetic >>1 of the s24 X88
   ROR zp_v_x_x
   ROR zp_v_x_h
   ROR zp_v_x_l
   LDA zp_v_x_h
   ASL A
   LDA zp_v_x_x
   ADC #0
   BNE ps_loop
; --- dispatch the net shift and tail-call the narrow body ---
   CPX #8
   BCS ps_patch                            ; net >= 5: rlo-free kernels
   CPX #4
   BCS ps_rns24                            ; net in [1,4]: rns24 reads rlo
ps_patch:                                   ; (net <= 0 falls in here too)
   LDA rns_vec_all-1,X
   STA rns_go_op
   JMP px_narrow                           ; tail-call: narrow's RTS + REG
                                        ; contract return to the caller
ps_rns24:
   LDA zp_br_r_s                           ; the ONE arm that must write
   STA zp_px_s_save                        ; rlo: save the TRUE S first
   TXA
   SEC
   SBC #3                                  ; unbias: rlo = net
   STA zp_br_r_s
   JSR rns_select
   JSR px_narrow
   LDA zp_px_s_save                        ; restore + re-select (rlo-
   STA zp_br_r_s                           ; writer invariant); select
   JSR rns_select                          ; clobbers A/X -> re-establish
   LDY zp_br_res_l                          ; the REG CONTRACT from the ZP
   LDA zp_br_res_h                          ; results
   RTS
::br_project_x:
   LDA zp_v_x_h
   ASL A                                   ; C = sign bit of xint
   LDA zp_v_x_x
   ADC #0                                  ; 0 iff xext == sign extension
   BNE px_shrink                           ; cold (in range: block above);
px_narrow:                                  ; hot path FALLS THROUGH
; --- b123 := (frac*M8 >> 8) + frac  (u9; both terms vanish when frac=0) ---
   LDA #0
   STA zp_br_res_l
   STA zp_br_res_h
; M8 == 0 (m9 = 256 exactly): both products are zero — b123 = frac + vx<<8.
   LDA zp_br_r_m8
   BNE px_have_m8
   LDA zp_v_x_l
   STA zp_br_t2
   JMP px_p_pos
px_have_m8:
   LDA zp_v_x_l
   BNE px_have_frac
   STA zp_br_t2
   BEQ px_no_frac
px_have_frac:
; frac*M8, HI BYTE ONLY — quarter-square INLINED (2026-07-12: the JSR'd
; core stored a 16-bit product whose lo byte this caller never reads;
; the lo-table subtract survives only as a CMP for its borrow into the
; hi subtract). A = frac on entry.
   TAX
   SEC
   SBC zp_br_r_m8
   BCS pxf_pd
   EOR #$FF
   ADC #1
pxf_pd:
   TAY                                     ; Y = |frac - M8|
   TXA
   CLC
   ADC zp_br_r_m8
   TAX                                     ; X = frac + M8
   BCS pxf_uo
   LDA sqr_l,X
   CMP sqr_l,Y                            ; C = lo borrow (hi-only: no store)
   LDA sqr_h,X
   SBC sqr_h,Y
   JMP pxf_have
pxf_uo:
   LDA sqr2_l,X
   CMP sqr_l,Y
   LDA sqr2_h,X
   SBC sqr_h,Y
pxf_have:
   CLC
   ADC zp_v_x_l
   STA zp_br_t2
   BCC px_no_frac
   INC zp_br_res_l                            ; t3 pre-zeroed at entry
px_no_frac:

; --- += smul(vx, M8), SIGN FUSED INTO THE ACCUMULATE (inlined
; 2026-07-12): positive vx ADDS the unsigned product, negative vx
; SUBTRACTS it (arm below the tail) — the signed product never
; materialises, so the old two-fixup ext dance (carry bump + product-
; sign correction) is one carry/borrow bump per arm. ---
   LDA zp_v_x_h
   BMI pxm_neg
   TAX
   SEC
   SBC zp_br_r_m8
   BCS pxm_pd
   EOR #$FF
   ADC #1
pxm_pd:
   TAY                                     ; Y = ||vx| - M8|
   TXA
   CLC
   ADC zp_br_r_m8
   TAX                                     ; X = |vx| + M8
   BCS pxm_puo
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_br_a                             ; prod lo (scratch)
   LDA sqr_h,X
   SBC sqr_h,Y
   JMP pxm_pacc
pxm_puo:
   LDA sqr2_l,X
   SBC sqr_l,Y                            ; C set on this arm
   STA zp_br_a
   LDA sqr2_h,X
   SBC sqr_h,Y
pxm_pacc:
   TAX                                     ; X = prod hi
   LDA zp_br_a
   CLC
   ADC zp_br_t2
   STA zp_br_t2
   TXA
   ADC zp_br_res_l
   STA zp_br_res_l
   BCC px_p_pos                            ; ext += carry (unsigned product:
   INC zp_br_res_h                         ; no sign fixup exists)
px_p_pos:

; --- += vx << 8 (sign-extended) ---
; Sign tested FIRST on the single load; the negative arm lives after
; the RTS (its +1/-1 high-byte fixups mostly cancel via the add carry).
   LDA zp_v_x_h
   BMI px_vx_n
   CLC
   ADC zp_br_res_l
   STA zp_br_res_l
   BCC px_i_pos
   INC zp_br_res_h
px_i_pos:

; --- sx = 128 + rns(b123, S) (per-vertex vectored shifter) ---
   JSR rns_go
   LDA zp_br_res_l
   CLC
   ADC #128
   STA zp_br_res_l
   TAY                                     ; REG CONTRACT (2026-07-12): every
                                        ; projection RTSes with Y = res lo,
                                        ; A = res hi (ZP resl/resh still
                                        ; written — regs are the fast lane)
   LDA zp_br_res_h
   ADC #0
   STA zp_br_res_h
   RTS                                     ; (resext staging deleted
                                        ; 2026-07-13: NO consumer reads it
                                        ; after a projection — the bbox-
                                        ; classification story was legacy;
                                        ; sx_hi in the records serves it)
px_vx_n:
; negative vx_h: lo add's carry (+1) and the $FF sign-extend (-1)
; cancel; only the no-carry case decrements the high byte.
   CLC
   ADC zp_br_res_l
   STA zp_br_res_l
   BCS px_vxn_j
   DEC zp_br_res_h
px_vxn_j:
   JMP px_i_pos

pxm_neg:
; negative vx: b123 -= |vx|*M8 (unsigned product, subtractive accumulate)
   EOR #$FF
   BUMP                                    ; A = |vx|
   TAX
   SEC
   SBC zp_br_r_m8
   BCS pxm_nd
   EOR #$FF
   ADC #1
pxm_nd:
   TAY
   TXA
   CLC
   ADC zp_br_r_m8
   TAX
   BCS pxm_nuo
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_br_a                             ; prod lo
   LDA sqr_h,X
   SBC sqr_h,Y
   JMP pxm_nacc
pxm_nuo:
   LDA sqr2_l,X
   SBC sqr_l,Y
   STA zp_br_a
   LDA sqr2_h,X
   SBC sqr_h,Y
pxm_nacc:
   STA zp_mul_b                            ; prod hi (scratch — the mul that
                                        ; owned this byte is inlined now)
   SEC
   LDA zp_br_t2
   SBC zp_br_a
   STA zp_br_t2
   LDA zp_br_res_l
   SBC zp_mul_b
   STA zp_br_res_l
   BCS pxm_njoin                           ; ext -= borrow
   DEC zp_br_res_h
pxm_njoin:
   JMP px_p_pos

.endscope



; ============================================================================
; br_project_y — project height delta to screen Y, through the VWHC memo.
; (Consolidated 2026-07-12: the cache front moved here from the deleted
; ycache.s and the raw body below is INLINED — the miss path FALLS
; THROUGH into it, and the writeback rides the raw tail. One routine,
; one file, no JSR/RTS between front and body.)
;
;   Native entry (br_project_y): h in A (REG CONTRACT — also stored to
;     zp_br_t0 here), zp_br_r_m8/rlo = (M8, S) recip.
;   jt/harness entry (br_project_y_paged): pages L2, loads h from
;     zp_br_t0 (the wrapper contract predates the register pass).
;   Output: zp_br_res_l/h = sy (s16, pre-biased by Y_BIAS folded into the
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
   EOR zp_br_r_m8
   TAX                                     ; probe idx = h ^ rhi
   LDA VWHC_R_S,X                          ; RLO doubles as the valid flag
   CMP zp_br_r_s
   BNE pyc_miss
   LDA VWHC_R_M8,X
   CMP zp_br_r_m8
   BNE pyc_miss
   LDA VWHC_KEY,X
   CMP zp_br_t0
   BNE pyc_miss
   LDY VWHC_L,X                           ; REG CONTRACT: Y = lo, A = hi
   STY zp_br_res_l
   LDA VWHC_H,X
   STA zp_br_res_h
   RTS
pyc_miss:
   STX zp_pyc_idx                          ; slot for the tail writeback;
.endscope                                  ; FALLS THROUGH into the raw body

; ============================================================================
; br_project_y — project height delta to screen Y.
;
;   Inputs (zp):
;     zp_br_t0 = height_delta (s8)
;     zp_br_r_m8 = M8 (recip mantissa), zp_br_r_s = S (recip shift)
;
;   Output:
;     zp_br_res_l/h = sy (s16)
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
;   Clobbers zp_br_t2, zp_br_a/b, mul workspace.
; ============================================================================
; (label deleted 2026-07-12: NO ENTRY EXISTS — the body is reached only
; by falling through the cache front's miss path above, which set
; zp_pyc_idx for the tail's VWHC writeback. A direct JSR here would
; store the result into a stale cache slot: the label was a loaded gun.)
.scope
; --- P24 = h*M8 + (h << 8), s24 in (t2, resl, resh) ---
; M8 == 0 (m9 = 256 exactly: the near-plane crossing recip and every
; power-of-two depth): the product is zero — skip the mul, P24 = h<<8.
   LDA zp_br_r_m8
   BNE py_have_m8
   STA zp_br_t2                            ; A == 0 here (BNE fell through)
   STA zp_br_res_h
   LDA zp_br_t0                            ; N flag survives the STA below
   STA zp_br_res_l
   BPL py_go
   DEC zp_br_res_h
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
   SBC zp_br_r_m8
   BCS pym_pd
   EOR #$FF
   ADC #1
pym_pd:
   TAY                                     ; Y = |h - M8|
   TXA
   CLC
   ADC zp_br_r_m8
   TAX                                     ; X = h + M8
   BCS pym_puo
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_br_t2                            ; P24 lo
   LDA sqr_h,X
   SBC sqr_h,Y
   JMP pym_join                            ; A = hi(h*M8)
pym_puo:
   LDA sqr2_l,X                           ; f(x+y) overflowed into the
   SBC sqr_l,Y                            ; +256 window (carry in = 1)
   STA zp_br_t2
   LDA sqr2_h,X
   SBC sqr_h,Y
   JMP pym_join
pym_neg:
; negative h: |h| through the quarter-square, negate during the copy-out
   EOR #$FF
   BUMP                                    ; A = |h|
   TAX
   SEC
   SBC zp_br_r_m8
   BCS pym_nd
   EOR #$FF
   ADC #1
pym_nd:
   TAY
   TXA
   CLC
   ADC zp_br_r_m8
   TAX
   BCS pym_nuo
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_br_t2                            ; |prod| lo (negated below)
   LDA sqr_h,X
   SBC sqr_h,Y
   JMP pym_nneg
pym_nuo:
   LDA sqr2_l,X
   SBC sqr_l,Y
   STA zp_br_t2
   LDA sqr2_h,X
   SBC sqr_h,Y
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
   STA zp_br_res_l
   ASL A                                   ; C = sign of t3 (A dead after);
   LDA #0                                  ; branchless sign spread — NOTE
   ADC #$FF                                ; the first cut used LDX #0/BPL
   EOR #$FF                                ; and LDX had already clobbered
   STA zp_br_res_h                         ; the ADC's N flag: ext was
py_shift:                                  ; always 0. C survives LDA/STA.

; --- sy = 128 - rns(P24, S) (per-vertex vectored shifter) ---
   JSR rns_go
   LDA #128
   SEC
   SBC zp_br_res_l
   STA zp_br_res_l
   TAY                                     ; REG CONTRACT: Y = sy lo, A = sy hi
   LDA #0
   SBC zp_br_res_h
   STA zp_br_res_h
; --- VWHC writeback (the raw body is only ever entered through the
; cache front's miss path above) ---
   LDX zp_pyc_idx
   LDA zp_br_r_m8
   STA VWHC_R_M8,X
   LDA zp_br_r_s
   STA VWHC_R_S,X
   LDA zp_br_t0
   STA VWHC_KEY,X
   TYA
   STA VWHC_L,X
   LDA zp_br_res_h
   STA VWHC_H,X                           ; (A = hi, Y = lo at RTS)
   RTS
.endscope

; ============================================================================
; RNS VECTORING — round-to-nearest shift dispatch for the projections.
;
; The shift S (zp_br_r_s, ALWAYS in [1,10], never 0 — it doubles as the
; VWHC valid flag) is a per-vertex constant, so the shifter is selected
; ONCE per reciprocal and each projection dispatches with a single JSR:
;
;   rns_go:  JSR'd by br_project_x and br_project_y's raw body (both this
;            file). It is ONE instruction — JMP <body> — whose OPERAND is
;            the live shifter (SMC, 2026-07-12): rns_select below and the
;            three INLINED selects in subsector.s's y_stage write
;            rns_go+1/+2 from the rns_vec tables. No ZP vector (the old
;            zp_rns_vec pair $C6/$C7 is freed), and JMP abs is 2 cycles
;            cheaper than the old JMP (zp).
;   INVARIANT: every writer of zp_br_r_s MUST re-select (JSR rns_select
;            or the inlined form) before the next projection, or the
;            dispatch runs a stale shifter. Current writers: br_recip
;            (arith.s), the vcache hit path (seg_xform.s), chain_reuse_v1
;            (lo.s), y_stage (subsector.s).
;
; ALL bodies live in this file, in the LO segment (one CODE region both
; builds; evicted from the stack page 2026-07-12 — page 1 is reserved
; headroom and the banked staging/boot-copy machinery died with it):
; unrolled rns_s5..rns_s9 for the hot shifts, generic rns24 for the
; rare S in [1,4]. Every body computes floor((P + 2^(S-1)) / 2^S) on the
; s24 product in (t2, resl, resh) and RTSes straight back to the
; projection's caller — pure leaves, bit-exact vs Python's rns().
; ============================================================================
.segment "LO"
.segment "RNSPG"                        ; page-ALIGNED segment (cfg align=$100):
                                        ; guarantees all kernel entries share
                                        ; the JMP operand's high byte
rns_go:
   CLC                                     ; hoisted from every kernel: all
                                        ; six bodies enter C=0 (their round
                                        ; ADC is the first carry consumer;
                                        ; rns32 is NOT dispatched here and
                                        ; keeps its own CLC)
rns_go_op = rns_go + 2                     ; SMC patch point: the JMP operand
                                        ; LO byte. ALL select sites store
                                        ; here — NEVER rns_go+1, that is
                                        ; the JMP opcode (the CLC above
                                        ; shifted the encoding, 2026-07-13)
   JMP rns24                               ; operand LO byte = live shifter
                                        ; (SMC by rns_select + the inlined
                                        ; selects; the HI byte is CONSTANT
                                        ; — all six kernel entries share
                                        ; one 256-byte window, asserted
                                        ; below — so a select patches ONE
                                        ; byte, 2026-07-12)

rns_select:
.scope
   LDX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   RTS
.endscope
rns_vec_all:                               ; ONE table, net shift -2..10 in
   .byte <rns_sm2, <rns_sm1, <rns_s0      ; order; the shrink indexes it
rns_vec_l:                                ; with X = net+3, the regular
   .byte <rns24, <rns24, <rns24, <rns24, <rns_s5   ; selects at S (=net)
   .byte <rns_s6, <rns_s7, <rns_s8, <rns_s9, <rns_s10   ; via this alias
; (rns_vec_hi retired: single-page kernels, constant JMP hi byte)

; --- the six kernels: entries must stay inside the first 256 bytes of
; this aligned segment (bodies may spill past); the fence asserts catch
; any growth that pushes an entry over the edge ---
rns_s8:
.scope
; floor((P + $80) / 256): the product's b1/b2 already LIVE in resl/resh
; (2026-07-13 accumulator re-plumb) — the whole kernel is the b0 round
; carry, propagated in place. No copies.
   BIT zp_br_t2                            ; round carry = bit 7 of b0
   BPL s8_done
   INC zp_br_res_l
   BNE s8_done
   INC zp_br_res_h
s8_done:
   RTS
.endscope
rns_s9:
.scope
; floor((P + $100) / 512): round is +1 into b1 (in place), then ASR the
; (resh, resl) pair once.
   INC zp_br_res_l
   BNE s9_nc
   INC zp_br_res_h
s9_nc:
   LDA zp_br_res_h
   CMP #$80                                ; C = sign bit → arithmetic ROR
   ROR A
   STA zp_br_res_h
   ROR zp_br_res_l
   RTS
.endscope

rns_s6:
.scope
; floor((P + $20) / 64) = ((P + $20) << 2) >> 8 — b0 rides in A, b1/b2
; shift in place in resl/resh.
   LDA zp_br_t2
   ADC #$20                                ; C=0 from rns_go
   BCC s6_sh
   INC zp_br_res_l
   BNE s6_sh
   INC zp_br_res_h
s6_sh:
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
   RTS
.endscope

rns_s7:
.scope
; floor((P + $40) / 128) = ((P + $40) << 1) >> 8 — b0 rides in A, one
; in-place shift of resl/resh.
   LDA zp_br_t2
   ADC #$40                                ; C=0 from rns_go
   BCC s7_sh
   INC zp_br_res_l
   BNE s7_sh
   INC zp_br_res_h
s7_sh:
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
   RTS
.endscope

rns_s5:
.scope
; floor((P + $10) / 32) = ((P + $10) << 3) >> 8   (S=5: 59 dispatches/suite
; vs rns24's 129-cycle loop path); b0 rides in A, three in-place shifts.
LDA zp_br_t2
   ADC #$10                                ; C=0 from rns_go
   BCC s5_sh
   INC zp_br_res_l
   BNE s5_sh
   INC zp_br_res_h
s5_sh:
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
   RTS
.endscope
; --- deficit kernels (2026-07-13): a shrink that ran out of exponent
; (S floored at 1) dispatches HERE instead of rounding at S=1 and
; scaling back in an epilogue — net shift <= 0, no rounding stage at
; all (single quantisation: the shrink's own truncations). Result is
; (b0,b1) scaled, shuffled up in place; overflow wraps mod 2^16 (the
; old wide contract). defc is CLAMPED to 3 (engine bound; the harness
; sweeps beyond it and the fp mirror clamps identically). ---
rns_s0:
; deficit 1: net shift 0 — result = P exactly
   LDA zp_br_res_l
   STA zp_br_res_h
   LDA zp_br_t2
   STA zp_br_res_l
   RTS
rns_sm1:
; deficit 2: net shift -1 — result = P << 1 (b1 rides in A: the
; shifted res_l is only ever read back as the new res_h)
   LDA zp_br_res_l
   ASL zp_br_t2
   ROL A
   STA zp_br_res_h
   LDA zp_br_t2
   STA zp_br_res_l
   RTS
rns_sm2:
; deficit 3: net shift -2 — result = P << 2 (b1 rides in A, twice)
   LDA zp_br_res_l
   ASL zp_br_t2
   ROL A
   ASL zp_br_t2
   ROL A
   STA zp_br_res_h
   LDA zp_br_t2
   STA zp_br_res_l
   RTS

rns_s10:
.scope
; floor((P + $200) / 1024): round is +2 into b1 (in place), then drop b0
; and ASR the (resh, resl) pair twice. Reinstated 2026-07-13 so rns24's
; domain is PURE S in [1,4] — where the rounding half fits the low byte
; and the mid-table add + CPX dispatch vanish.
   LDA zp_br_res_l
   ADC #2                                  ; C=0 from rns_go
   STA zp_br_res_l
   LDA zp_br_res_h
   ADC #0                                  ; carry folds into the load
   CMP #$80                                ; C = sign bit → arithmetic ROR
   ROR A
   ROR zp_br_res_l
   CMP #$80
   ROR A
   ROR zp_br_res_l
   STA zp_br_res_h
   RTS
.endscope
; (rns24 follows IN THE SAME LO PAGE — pulled out of the ANG segment
; 2026-07-12 so all six kernel entries share the JMP hi byte; its
; rns_half rounding-constant tables stay in resolve_crossing.s.)
; ============================================================================
rns24:
.scope
; Generic kernel, domain now PURE S in [1,4] (5..10 all have unrolled
; kernels): half = 2^(S-1) <= 8 fits the LO byte, so the old mid-table
; add is a carry propagate and the S=10 arm + CPX dispatch are gone
; (2026-07-13). S=1 is the near-plane crossing reciprocal — hot for
; clipped segs. Result lands one byte LOW (b0, b1): shuffle up at exit.
   LDX zp_br_r_s
   LDA rns_half_l-1,X
   ADC zp_br_t2                            ; C=0 from rns_go
   STA zp_br_t2
   BCC rn_enter
   INC zp_br_res_l
   BNE rn_enter
   INC zp_br_res_h
rn_enter:
   LDA zp_br_res_h                         ; ride b2 in A: its shifted
rn_rloop:                                  ; value is dead at exit (the
   CMP #$80                                ; shuffle overwrites res_h)
   ROR A
   ROR zp_br_res_l
   ROR zp_br_t2
   DEX
   BNE rn_rloop
   LDA zp_br_res_l
   STA zp_br_res_h
   LDA zp_br_t2
   STA zp_br_res_l
   RTS
.endscope
.assert >rns_s6 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s7 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s8 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s9 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s10 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s0 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_sm1 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_sm2 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s5 = >rns24, error, "RNS kernels must share one page (1-byte SMC)"


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
; (BSP_STACK retired 2026-07-14 — traversal runs on the hardware stack; $0A00-$0A3F free)

; Side-test result holder

; --- Node-read scratch ---
