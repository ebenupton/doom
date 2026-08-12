
; ============================================================================
; br_project_x — project view-space X to screen X with sub-pixel.
;   THE single X projector (2026-07-12: the old narrow/wide/_auto trio
;   rolled up — narrow and wide each had exactly one caller, _auto, which
;   staged v_x* into t0/t1 and post-staged resext; all of that is gone).
;
;   Inputs (zp):
;     zp_br_vx_x:zp_br_vx_h = s16 integer view-x, zp_br_vx_l = u8 fraction
;     zp_br_r_m8 = M8 (recip mantissa), zp_br_r_s = S (recip shift)
;
;   Output:
;     zp_br_res_l/h = sx (s16 screen x) — ZP ONLY (the Y/A register
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
; (px_shrink + ps_patch + the classic br_project_x entry DELETED
; 2026-08-11, unreachability PROVEN analytically (see the commit):
; no symbolic refs, no fall-through, no SMC vector's value set
; contains them; s16 int parts cannot occur under count-native
; totals, so the shrink's domain is empty by construction.)

; TRUE16 counts entry (2026-08-10): input = s16 view COUNTS in
; zp_br_vx_l/h (vx_x is DEAD — the narrow body derives sign from the
; hi byte and never reads the ext). Exact identity:
;   sx = 128 + rns(X88*m9, S+8)  with X88 = counts<<3
;      = 128 + rns(counts*m9, S+5)        (rns(8B, k+3) == rns(B, k))
; i.e. the EXISTING narrow body at net shift S-3 — and px_shrink's
; dispatch table already covers net in [-2, 7] (X = net+3 = S in
; [1,10]). The whole projection is a kernel select + fall-in: ZERO
; bytes of operand staging. zp_br_r_s keeps the TRUE S (VWHC key /
; y-stage contract); only the selected kernel differs.
; --- M8 == 0 rare cell (2026-07-26, Eben: same mostly-taken BNE as the
; y-side; zero M8 = crossing recip / power-of-two depths only). Hoisted
; above the entry, still inside the scope; the head BEQs back here.
px_m8_zero:
   LDA zp_br_vx_l
   STA zp_br_t2
   LDX #0                                  ; ext = sign(vx): b123 = vx<<8
   LDA zp_br_vx_h                          ; mid = vx_h rides A into the
   BPL pxz_go                              ; shared px_shift stores (the
   DEX                                     ; py_m8_zero idiom, 2026-07-26)
pxz_go:
   JMP px_shift
px_frac_z:
   STA zp_br_t2                            ; A = 0 (the BEQ's operand)
   JMP px_no_frac

::br_project_x_c:
   LDX zp_br_r_s                           ; X = net+3 = S: EVERY net is a
   LDA rns_vec_all-1,X                     ; baked kernel now (s1..s4 landed
   STA px_go_op                            ; 2026-08-10) — one flat select
                                        ; into px's PRIVATE tail-jump
                                        ; (2026-08-12); FALLS INTO the
                                        ; body — the rare cells moved
                                        ; above the entry (2026-08-12)
px_narrow:                                  ; entered by br_project_x_c only
; --- b123 := (frac*M8 >> 8) + frac  (u9; both terms vanish when frac=0) ---
   ZERO zp_br_res_l

; (res_h zeroing DELETED 2026-07-26, py insight ported: on the narrow
; path b123 = vx*m9 with |vx| < 128, m9 <= 511 => |b123| < 65408 fits
; s16 — the ext byte is the PURE SIGN of the arm and each arm delivers
; it as a constant in X to px_shift. res_l seeds the frac carry only;
; the mid byte rides A into the shared store.)
; M8 == 0 (m9 = 256 exactly): both products are zero — b123 = frac + vx<<8.
   LDA zp_br_r_m8
   BEQ px_m8_zero                          ; rare cell hoisted above the
                                           ; entry (2026-07-26) — the common
                                           ; mul path falls through
   LDA zp_br_vx_l
   BEQ px_frac_z                           ; frac==0 rare (18%, census
                                           ; 2026-07-27): island above the
                                           ; entry — frac path falls through
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
   BCC pxf_pdarm                           ; arm swap 2026-08-12 (suite:
   LDA sqr2_l,X                            ;  no-ovf 232 vs uo 200) — the
   CMP sqr_l,Y                             ;  hotter arm falls into the join
   LDA sqr2_h,X
   SBC sqr_h,Y
   JMP pxf_have
pxf_pdarm:
   LDA sqr_l,X
   CMP sqr_l,Y                            ; C = lo borrow (hi-only: no store)
   LDA sqr_h,X
   SBC sqr_h,Y
pxf_have:
   CLC
   ADC zp_br_vx_l
   STA zp_br_t2
   BCC px_no_frac
   INC zp_br_res_l                            ; t3 pre-zeroed at entry
px_no_frac:

; --- += smul(vx, M8), SIGN FUSED INTO THE ACCUMULATE (inlined
; 2026-07-12): positive vx ADDS the unsigned product, negative vx
; SUBTRACTS it (arm below the tail) — the signed product never
; materialises, so the old two-fixup ext dance (carry bump + product-
; sign correction) is one carry/borrow bump per arm. ---
   LDA zp_br_vx_h
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
   BCC pxm_ppd                             ; arm swap 2026-08-12 (uo = 2
   LDA sqr2_l,X                            ;  suite execs vs 228): the JMP
   SBC sqr_l,Y                            ; moved to the cold arm (C set
   STA zp_br_a                            ;  on this arm from the BCC)
   LDA sqr2_h,X
   SBC sqr_h,Y
   JMP pxm_pacc
pxm_ppd:
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_br_a                             ; prod lo (scratch)
   LDA sqr_h,X
   SBC sqr_h,Y
pxm_pacc:
   TAX                                     ; X = prod hi
   LDA zp_br_a
   CLC
   ADC zp_br_t2
   STA zp_br_t2
; --- POSITIVE TAIL (px_p_pos/px_vx_n dispatch DELETED 2026-07-26, py
; insight ported): the vx<<8 add folds into the mid chain in A — the
; arm already knows the sign, so the re-load/BMI re-dispatch was lard.
; Carry proof (unsigned-only): prod_hi = hi(vx*M8) <= hi(127*255) =
; $7E; res_l <= 1 (frac carry only); C(lo add) <= 1 => first sum <=
; $80, carry-out 0. Then + vx_h <= $7F => <= $FF: no carry either —
; both old INC-ext sites were provably dead, and no CLC is needed
; between the adds. Ext = CONSTANT 0 (b123 in [0, 65407]). ---
   TXA
   ADC zp_br_res_l                         ; mid = prod_hi + frac_c + C(lo)
   ADC zp_br_vx_h                          ; += vx (the <<8 fold); C=0 proven
   LDX #0                                  ; ext = sign of the arm
px_shift:
   STA zp_br_res_l                         ; single shared store pair — all
   STX zp_br_res_h                         ; three arms deliver (A=mid, X=ext)

; --- sx = 128 + rns(b123, S): TAIL-CALL dispatch (Eben's design,
; 2026-08-12). px has its OWN SMC JMP (br_project_x_c pokes px_go_op
; instead of rns_go_op — same instruction count, no select changes),
; so the kernel's RTS returns STRAIGHT to br_project_x_c's caller and
; the old JSR rns_go + tail + RTS round trip is gone. The +128 bias
; moved INTO both call sites, fused with their struct/plane landing
; stores (the res writeback died with it — the two sites are the only
; sx consumers). rns_go itself remains for the y side, whose miss-path
; writeback must run after the kernel and keeps the JSR shape. ---
px_go:
   CLC                                     ; kernels enter C=0 (the neg-vx
   JMP rns_s8                              ; arm exits with C=1) — SMC:
px_go_op = px_go + 2                       ; operand LO poked per call
pxm_neg:
; negative vx: b123 -= |vx|*M8 (unsigned product, subtractive accumulate)
   EOR #$FF
   BUMP_TAX                                ; A = X = |vx| (CPU-forked pair:
                                           ; NMOS TAX/INX/TXA saves a byte,
                                           ; C02 keeps INA/TAX — Eben)
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
   BCC pxm_npd                             ; arm swap 2026-08-12 (nuo = 2
   LDA sqr2_l,X                            ;  suite execs vs 243)
   SBC sqr_l,Y
   STA zp_br_a
   LDA sqr2_h,X
   SBC sqr_h,Y
   JMP pxm_nacc
pxm_npd:
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_br_a                             ; prod lo
   LDA sqr_h,X
   SBC sqr_h,Y
pxm_nacc:
   STA zp_mul_b                            ; prod hi (scratch — the mul that
                                        ; owned this byte is inlined now)
   SEC
   LDA zp_br_t2
   SBC zp_br_a
   STA zp_br_t2
; --- NEGATIVE TAIL (py insight ported, 2026-07-26): vx < 0 => b123 =
; vx*m9 in [-65408, -2] (|vx| <= 128, m9 <= 511, vx <= -1/256) — the
; ext byte is the CONSTANT $FF, so the borrow-out of the mid subtract
; (the old BCS/DEC pair) and the old <<8-arm DEC are both discarded:
; mod-2^16 arithmetic on (t2, mid) is exact regardless. The vx<<8 add
; folds into the mid chain in A (CLC needed: the SBC's borrow-out is
; data-dependent); mid rides A to the shared px_shift stores. ---
   LDA zp_br_res_l
   SBC zp_mul_b                            ; mid partial (borrow-out dropped)
   CLC
   ADC zp_br_vx_h                          ; += vx (the <<8 fold)
   LDX #$FF                                ; ext = sign of the arm
   JMP px_shift

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
; --- M8 == 0 rare cell (2026-07-26, Eben's catch at :397: the BNE at
; the mul head is almost always taken — zero M8 is only the near-plane
; crossing recip and power-of-two depths). Hoisted ABOVE the entries so
; the hot path falls straight into the inlined mul; the head BEQs back
; up here. Contract: A == 0 on arrival (it IS the BEQ's operand).
py_m8_zero:
   STA zp_br_t2
   TAX
   LDA zp_br_t0                            ; mid = h rides A to py_shift
   BPL pymz_go
   DEX
pymz_go:
   JMP py_shift

; (br_project_y_paged RETIRED 2026-07-26, Eben's question: ZERO
; callers anywhere — every caller pages L2 itself per the y_stage/apv
; once-per-run contract and enters with A = h. It was a vestige of
; the pre-2026-07-21 caller-pages era.)
br_project_y:
.scope
   STA zp_br_t0                            ; h (tag compare + raw body reads)
   EOR zp_br_r_m8
   TAX                                     ; probe idx = h ^ rhi
; Staggered partial-key update (the CPM_ENTRY idiom, 2026-07-19):
; compares run LDA zp / CMP plane, so a miss at stage k arrives with
; the mismatched zp byte in A and enters the key-store ladder there —
; the stages BEFORE k matched, the planes already hold them, their
; stores are skipped. R_S still doubles as the valid flag (a real S is
; never 0, so fresh slots always miss at stage 0 and write everything).
; R_M8 IS IMPLIED (2026-07-26, Eben's hot-sequence pass): the probe
; index is h ^ rhi, so once the KEY plane confirms h, rhi = X ^ h is
; DETERMINED — two entries can only share a slot with the same h if
; they also share rhi. The R_M8 plane and its compare are redundant
; and retired (equate + plane freed in resolve_crossing.s); collision
; safety: same slot + same h => same rhi, and rlo (the valid flag —
; a real S is never 0) is still compared. Zero-filled fresh slots
; miss at the R_S stage exactly as before.
   LDA zp_br_r_s
   CMP VWHC_R_S,X
   BNE pym0
   LDA zp_br_t0
   CMP VWHC_KEY,X
   BNE pym2
   LDY VWHC_L,X                           ; REG CONTRACT: Y = lo, A = hi
   LDA VWHC_H,X                           ; (zp_br_res store-backs dropped
   RTS                                     ; 2026-07-19: every engine caller
                                           ; consumes the registers; the unit
                                           ; test reads mpu.a/mpu.y now)
pym0:
   STA VWHC_R_S,X
   LDA zp_br_t0
pym2:
   STA VWHC_KEY,X
   STX zp_pyc_idx                          ; slot for the tail's VALUE stores;
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
   BEQ py_m8_zero                          ; rare cell hoisted above the
                                           ; entries (2026-07-26) — the
                                           ; common mul path falls through
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
   BCC pym_ppd                             ; arm swap 2026-08-12 (puo = 20
   LDA sqr2_l,X                           ;  suite execs vs 392): f(x+y)
   SBC sqr_l,Y                            ;  overflowed into the +256
   STA zp_br_t2                           ;  window (carry in = 1, from
   LDA sqr2_h,X                           ;  the BCC)
   SBC sqr_h,Y
   JMP pym_ptail                           ; A = hi(h*M8) — positive tail
pym_ppd:
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_br_t2                            ; P24 lo
   LDA sqr_h,X
   SBC sqr_h,Y
; --- POSITIVE TAIL: h > 0 => P24 >= 257 => mid in [1,127]: ext is the
; CONSTANT 0 (same fence). The puo arm falls in; the no-overflow arm
; JMPs here. Ext rides X into py_shift's shared STX (hand edit).
pym_ptail:
   CLC
   ADC zp_br_t0                            ; mid = hi(h*M8) + h
   LDX #0
   JMP py_shift
pym_neg:
; negative h: |h| through the quarter-square, negate during the copy-out
   EOR #$FF
   BUMP_TAX                                ; A = X = |h| (CPU-forked pair)
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
   BCC pym_npd                             ; arm swap 2026-08-12 (nuo = 5
   LDA sqr2_l,X                            ;  suite execs vs 309)
   SBC sqr_l,Y
   STA zp_br_t2
   LDA sqr2_h,X
   SBC sqr_h,Y
   JMP pym_nneg
pym_npd:
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_br_t2                            ; |prod| lo (negated below)
   LDA sqr_h,X
   SBC sqr_h,Y
pym_nneg:
   TAX                                     ; X = |prod| hi
   SEC
   LDA #0
   SBC zp_br_t2
   STA zp_br_t2                            ; lo = -|prod| lo
   TXA
   EOR #$FF
; --- NEGATIVE TAIL (pym_join split into pure divergent flow,
; 2026-07-26, Eben). |h| <= 64 is PACK-ASSERTED (the projection bound
; fence in doom_wireframe.py, 2026-07-12): |h*m9| <= 64*511 < 2^15, so
; P24 fits s16 and the ext byte is PURE SIGN of the mid byte. On THIS
; arm h < 0 => P24 <= -257 => mid = P24>>8 in [-128,-2]: the sign is
; the CONSTANT $FF — the branchless spread (ASL/ADC/EOR, 11 cyc)
; constant-folds away. A violating map fails the PACK, not the render.
; FUSED (Eben, 2026-07-26): the old ADC #0 (hi = ~|hi| + (lo==0)) and
; CLC/ADC t0 collapse into ONE add — C here is STILL the lo-negate's
; (lo==0) carry, and the intermediate carry-out was provably 0
; (product = |h|*M8 >= 1 on this arm), so ~|hi| + h + C in one ADC is
; byte-identical. -4 bytes, -4 cycles.
   ADC zp_br_t0                            ; mid = ~|hi| + h + (lo==0)
   LDX #$FF
::py_shift:                                ; (:: 2026-07-26: the hoisted
                                           ; M8==0 cell JMPs here from
                                           ; outside the raw-body scope)
   STA zp_br_res_l
   STX zp_br_res_h

; --- sy = 128 - rns(P24, S) (per-vertex vectored shifter) ---
; De-larded 2026-07-26 (Eben's hot-sequence pass): X = slot BEFORE the
; subtract, lo rides A through TAY into its plane store (TAY preserves
; A), hi goes straight from the SBC to its plane — the res_h
; write-back/reload and the TYA shuttle were staged-then-copied lard.
; (zp_br_res_h is NOT an output: the hit path never writes it, so no
; caller may rely on it — the register contract is the whole truth.)
   JSR rns_go
   LDX zp_pyc_idx
   LDA #128
   SEC
   SBC zp_br_res_l
   TAY                                     ; REG CONTRACT: Y = sy lo, A = sy hi
; --- VWHC writeback, VALUE half (the raw body is only ever entered
; through the cache front's miss path above, which already wrote the
; key bytes via the staggered ladder) ---
   STA VWHC_L,X                           ; A still = lo (TAY preserves)
   LDA #0
   SBC zp_br_res_h
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
;   INVARIANT: every rns_go dispatch must be DOMINATED by a select on
;            its own path (a stale poke = a stale shifter). Current
;            shape (audited 2026-08-12): br_project_x_c self-pokes on
;            every x projection; every y projection sits inside a
;            poked cluster (the five y-stage selects in seg_emit +
;            vsx_expl's RNS_SELECT). Recip writers do NOT poke — the
;            far arm's fossil select was deleted (rotvar.s), the near
;            arm never had one.
;
; ALL bodies live in this file, in the LO segment (one CODE region both
; builds; evicted from the stack page 2026-07-12 — page 1 is reserved
; headroom and the banked staging/boot-copy machinery died with it):
; unrolled rns_s5..rns_s9 for the hot shifts, generic rns24 for the
; rare S in [1,4]. Every body computes floor((P + 2^(S-1)) / 2^S) on the
; s24 product in (t2, resl, resh) and RTSes straight back to the
; projection's caller — pure leaves, bit-exact vs Python's rns().
; ============================================================================
SEG_CODE
; (rns_go + the vector tables moved BELOW the fence 2026-08-10: only
; the kernel ENTRY bytes must share the SMC hi-byte page, and the
; baked rns_s1..s4 squeezed it — dispatch site and data read full
; 16-bit addresses.)
.align $100                             ; the rns kernel window must sit in
                                        ; ONE page (the vector patches only
                                        ; the JMP operand LO byte) — the CODE
                                        ; segment carries align=$100 in both
                                        ; cfgs so this .align is honoured

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
; --- rns_s1..rns_s4 (TRUE16 claw-back, 2026-08-10): BAKED twins of
; what was rns24's domain. The counts projector maps the common depth
; band (S in [4,7]) onto net = S-3 in [1,4], which made rns24's
; generic loop + the ps_rns24 save/restore dance the HOT path — these
; kernels restore flat one-select dispatch, and every OTHER S-in-[1,4]
; select (y-stage, shrink) rides them too. s1/s2 shift RIGHT (fewer
; trios + the s0-style shuffle), s3/s4 shift LEFT like rns_s5 (result
; lands in res_l/h, no shuffle) — each form at its cheaper end. ---
rns_s1:
.scope
; floor((P + 1) / 2): bias into b0, one arithmetic ROR of the 3-byte P,
; result = its low 16 (b0,b1) shuffled up.
   LDA zp_br_t2
   ADC #1                                  ; C=0 from rns_go
   STA zp_br_t2
   BCC s1_sh
   INC zp_br_res_l
   BNE s1_sh
   INC zp_br_res_h
s1_sh:
   LDA zp_br_res_h                         ; b2 rides A (dead at exit)
   CMP #$80
   ROR A
   ROR zp_br_res_l
   ROR zp_br_t2
   LDA zp_br_res_l
   STA zp_br_res_h
   LDA zp_br_t2
   STA zp_br_res_l
   RTS
.endscope
rns_s2:
.scope
; floor((P + 2) / 4): two right trios, then the shuffle.
   LDA zp_br_t2
   ADC #2                                  ; C=0 from rns_go
   STA zp_br_t2
   BCC s2_sh
   INC zp_br_res_l
   BNE s2_sh
   INC zp_br_res_h
s2_sh:
   LDA zp_br_res_h
   CMP #$80
   ROR A
   ROR zp_br_res_l
   ROR zp_br_t2
   CMP #$80
   ROR A
   ROR zp_br_res_l
   ROR zp_br_t2
   LDA zp_br_res_l
   STA zp_br_res_h
   LDA zp_br_t2
   STA zp_br_res_l
   RTS
.endscope
rns_s3:
.scope
; floor((P + 4) / 8) = ((P + 4) << 5) >> 8 — the rns_s5 left form.
   LDA zp_br_t2
   ADC #4                                  ; C=0 from rns_go
   BCC s3_sh
   INC zp_br_res_l
   BNE s3_sh
   INC zp_br_res_h
s3_sh:
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
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
rns_s4:
.scope
; floor((P + 8) / 16) = ((P + 8) << 4) >> 8 — left form.
   LDA zp_br_t2
   ADC #8                                  ; C=0 from rns_go
   BCC s4_sh
   INC zp_br_res_l
   BNE s4_sh
   INC zp_br_res_h
s4_sh:
   ASL A
   ROL zp_br_res_l
   ROL zp_br_res_h
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
; (S floored at 1) — net shift <= 0, no rounding stage (single
; quantisation: the shrink's own truncations). Result is (b0,b1)
; scaled, shuffled up; overflow wraps mod 2^16. CORPUS-UNSEEN — page-
; fence trampolines (2026-08-10: the baked s1..s4 squeezed the page;
; only the 3-byte entries must share the SMC hi byte). ---
rns_s0:
   JMP rns_s0_body
rns_sm1:
   JMP rns_sm1_body
rns_sm2:
   JMP rns_sm2_body

rns_s10:
   JMP rns_s10_body                        ; page-fence trampoline (rare)
; (rns24 follows IN THE SAME LO PAGE — pulled out of the ANG segment
; 2026-07-12 so all six kernel entries share the JMP hi byte; its
; rns_half rounding-constant tables stay in resolve_crossing.s.)
; ============================================================================
; (rns24 DELETED 2026-08-11 — unreachable, proven: no table entry
;  selects it and every rns_go dispatch is select-dominated.)
.assert >rns_s6 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s7 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s9 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s10 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s0 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_sm1 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_sm2 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s5 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s1 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s2 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s3 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"
.assert >rns_s4 = >rns_s8, error, "RNS kernels must share one page (1-byte SMC)"

rns_go:
   CLC                                     ; hoisted from every kernel: all
                                        ; bodies enter C=0 (their round
                                        ; ADC is the first carry consumer;
                                        ; rns32 is NOT dispatched here and
                                        ; keeps its own CLC)
rns_go_op = rns_go + 2                     ; SMC patch point: the JMP operand
                                        ; LO byte. ALL select sites store
                                        ; here — NEVER rns_go+1, that is
                                        ; the JMP opcode (the CLC above
                                        ; shifted the encoding, 2026-07-13)
   JMP rns_s8                              ; operand LO byte = live shifter
                                        ; (power-on default: PROVEN never
                                        ; executed — every dispatch is
                                        ; select-dominated; rns_s8 is an
                                        ; arbitrary live kernel)
                                        ; (SMC by the inlined selects; the
                                        ; HI byte is CONSTANT — all kernel
                                        ; entries share one 256-byte
                                        ; window, asserted above — so a
                                        ; select patches ONE byte)

; (the rns_select SUBROUTINE is retired 2026-07-15: RNS_SELECT macro
; in bsp/header.s expands at every select site — each already had S in
; A, so the JSR/RTS and the zp_br_r_s reload were pure tax.)
rns_vec_all:                               ; ONE table, net shift -2..10 in
   .byte <rns_sm2, <rns_sm1, <rns_s0      ; order; the shrink indexes it
rns_vec_l:                                ; with X = net+3, the regular
   .byte <rns_s1, <rns_s2, <rns_s3, <rns_s4, <rns_s5   ; selects at S (=net)
   .byte <rns_s6, <rns_s7, <rns_s8, <rns_s9, <rns_s10   ; via this alias
; (rns_vec_hi retired: single-page kernels, constant JMP hi byte)

; --- out-of-page bodies (trampolined entries above) ---
rns_s10_body:
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
rns_s0_body:
; deficit 1: net shift 0 — result = P exactly
   LDA zp_br_res_l
   STA zp_br_res_h
   LDA zp_br_t2
   STA zp_br_res_l
   RTS
rns_sm1_body:
; deficit 2: net shift -1 — result = P << 1 (b1 rides in A: the
; shifted res_l is only ever read back as the new res_h)
   LDA zp_br_res_l
   ASL zp_br_t2
   ROL A
   STA zp_br_res_h
   LDA zp_br_t2
   STA zp_br_res_l
   RTS
rns_sm2_body:
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


SEG_CODE
; ============================================================================
; ROM/RAM base addresses (Python wrapper writes these into ZP at frame start)
; "zp_"-named for history but these live in the $0BEC-$0BF7 absolute page —
; cold, read a few times per seg via indirect-pointer setup. They point at
; the packed WAD arrays built by wad_packed.build_packed (vertices,
; subsector SoA pages, seg headers, VWH heights, seg detail).
; ============================================================================
; ($0BF4/$0BF5 freed 2026-07-10: zp_rom_vwh retired — no 6502 reader)
; (zp_rom_detail_lo/hi $0BF6/7 RETIRED 2026-07-27: zero readers —
; canary-proven dead across the full suite; $0B00 is now a psi plane)

; BSP traversal state
; (BSP_STACK retired 2026-07-14 — traversal runs on the hardware stack; $0A00-$0A3F free)

; Side-test result holder

; --- Node-read scratch ---
