
; ============================================================================
; back_face_test — is the current seg back-facing?  [pipeline stage 1]
;
; CONTEXT: sole caller is the seg loop (subsector.s), which stages
; zp_seg_flags and JMPs here (no JSR). TAIL-DISPATCHED exits:
;   front  -> JMP ::bf_seg_front (seg_emit.s, the seg pipeline resumes)
;   back   -> JMP ::s_advance_l0 (seg_emit.s, next seg — one hop; the
;                                 old bf_seg_back trampoline died 2026-07-12)
; There is NO flag/return contract: control flow IS the verdict.
;
;   Inputs (zp): zp_seg_hdr_p -> the 12-byte seg header (form at +4, C16
;                or lv1x at +5/+6, lv1y split lo +7 / hi +9);
;                zp_br_px_h/px_e, zp_br_py_h/py_e = player int pos (s16);
;                zp_bf_pxm_l/hi, zp_bf_pym_l/hi = |px|,|py| (staged
;                once per frame by view_setup, view.s).
;   Clobbers: A, X, Y; zp_br_dx/dy lo+hi, zp_br_t2..t5, zp_br_sign,
;             zp_bf_dir, zp_br_a, the mul workspace (via umul8).
;   Bank state: caller holds BANK_L0 paged (header reads); no paging here.
;
; ALGORITHM (uniform C-form, 2026-07-11 — see the banner inside the
; scope for the full derivation): dot = dy'*px - dx'*py - C, with
; (dx',dy') the seg's primitive linedef direction (gcd-reduced,
; SF_SAMEDIR folded into its SIGN at pack time — the flag byte is never
; read here) and C a pack-time constant.
;   - Axis-aligned linedefs (form 0-3, ~76% of segs): dot's sign is ONE
;     s16 compare of px or py against C16 (header +5/+6). Zero muls.
;   - Diagonals (form >= 4): (form-4) indexes the DIR tables at
;     ROM_DIRS_C (layout.inc; |dx'| / |dy'| / sign byte planes,
;     MAX_DIRS=160 apart). Delta form: dot = dy'*(px-lv1x) - dx'*(py-lv1y)
;     — the deltas stay SMALL, which keeps the products 1-mul most of
;     the time (senior-byte-clear fast path). A C-form on raw coords was
;     measured 4-mul WORSE — small operands are load-bearing here.
;     Sign shortcut first (opposite product signs decide with no mul);
;     |dx'|/|dy'| magnitudes load LAZILY in the mul tier via zp_bf_dir
;     (sign-shortcut exits never read them, 2026-07-11).
;   Ties (dot == 0): DIAGONALS refine via bf_tie (frac products).
;   AXIS ties are resolved at PACK time (2026-08-25): truncation is a
;   floor, so a truncated tie means the true position is on the '>'
;   side; the packer ships C-1 for the '>' forms (0/2) and this file's
;   strict compares need NO change -- 'coord > C-1' IS 'coord >= C'.
;   The '<' forms keep C (their tie->back was already correct), so
;   exactly one twin survives everywhere, frac-0 poses included.
;
; Python mirror: packed_render_seg's bf_form dispatch (doom_wireframe.py)
; — bit-identical by construction; the packer (wad_packed.py) emits
; form/C/DIR data in the same loop that sets the flags.
; ============================================================================
back_face_test:
.scope
; ============================================================================
; UNIFORM C-FORM (2026-07-11, stride-16 header): dot = dy'*px - dx'*py - C
; with (dx',dy') the primitive linedef direction (SF_SAMEDIR folded into
; its sign at pack time) and C = dy'*lv1x - dx'*lv1y a pack-time s24.
;   header +4  form: 0 front iff px>C16, 1 px<C16, 2 py>C16, 3 py<C16,
;              >= 4: diagonal, (form-4) indexes the DIR tables
;   header +5..7 C (s24; axis compares use only +5/6 as s16)
; DIR tables (ROM_DIRS_C, one entry per distinct primitive direction):
;   +0*MAX |dx'| , +1*MAX |dy'| , +2*MAX sign byte (b7 dy'<0, b6 dx'<0)
; |px|/|py| are staged per frame by view_setup (zp_bf_p?m_*); signs
; read live from px_e/py_e bit7. Axis ties: pack-time C-1 bake (banner).
; TAIL-DISPATCHED: exits JMP bf_seg_front / s_advance (no RTS).
; Ranges: |P1|,|P2| <= 127*2600 < 2^19; |dot|+|C| < 2^21 — s24 exact,
; no overflow handling needed anywhere.
; ============================================================================
   LDY #4
   LDA (zp_seg_hdr_p),Y
   CMP #4
   BCS bf_diag
   LSR A                                   ; C = strict-side (0 '>', 1 '<')
   BNE bf_ax_py                            ; A = 0 px : 1 py
; --- px vs C16 ---
   BCS bf_ax_px_lt
; form 0: front iff px > C16 — REVERSED subtract (2026-07-16): C16 - px
; is strictly negative iff front, so ties fall to BACK on the sign test
; alone and the old STA/ORA/BEQ tie chain is gone ('<' arms always
; worked this way; the reversed decode shares their overflow stub).
; (2026-08-25: 'ties fall to BACK' here is now the C-1 BAKE doing the
; work -- see the banner; the emitted constant already encodes >=.)
   INY                                     ; -> C lo (+5)
   LDA (zp_seg_hdr_p),Y
   CMP zp_br_px_h                          ; borrow seed (result dead)
   INY
   LDA (zp_seg_hdr_p),Y
   SBC zp_br_px_x                          ; C16 - px
; (no V decode: pack-time axis-extent assert — see wad_packed; N IS the
;  sign on all four arms)
   BMI bf_ax_front                         ; C16 < px -> front
   BPL bf_ax_back                          ; tie/less -> back (always)
bf_ax_px_lt:
; form 1: front iff px < C16  <=>  (px - C) < 0
; (C=1 = the LSR's strict-side bit — the BCS that got us here)
   LDA zp_br_px_h
   INY
   SBC (zp_seg_hdr_p),Y
   INY
   LDA zp_br_px_x
   SBC (zp_seg_hdr_p),Y
   BMI bf_ax_front                         ; diff < 0
bf_ax_back:
   JMP s_advance_l0
bf_ax_front:
   JMP bf_seg_front
; --- py vs C16 (forms 2/3) ---
bf_ax_py:
   BCS bf_ax_py_lt
; form 2: front iff py > C16 — reversed like form 0
   INY
   LDA (zp_seg_hdr_p),Y
   CMP zp_br_py_h
   INY
   LDA (zp_seg_hdr_p),Y
   SBC zp_br_py_x
   BMI bf_ax_front
   BPL bf_ax_back                          ; (always)
bf_ax_py_lt:
; form 3: front iff py < C16
; (C=1 = the LSR's strict-side bit — the BCS that got us here)
   LDA zp_br_py_h
   INY
   SBC (zp_seg_hdr_p),Y
   INY
   LDA zp_br_py_x
   SBC (zp_seg_hdr_p),Y
   BMI bf_ax_front
   BPL bf_ax_back

; --- diagonal: DELTA form with table primitives (2026-07-11 v2) ---
; dot = dy'*(px - lv1x) - dx'*(py - lv1y) > 0. The deltas stay SMALL
; near walls (senior-byte-clear -> 1-mul products), which measured
; FASTER than the C-form's raw-coordinate 4-mul products. Primitives
; (magnitudes + sign byte) come from the DIR tables; lv1x at +5/6,
; lv1 via the deduped LV1 records (u8 id at +SH_DIAG); SF_SAMEDIR is
; folded into the primitive signs at pack time, so the old flags-EOR
; mode twist is gone.
bf_diag:
; (no SEC: the CMP #4 / BCS that got us here left C=1)
   SBC #4
   TAX                                     ; X = dir index
   LDA ROM_DIRS_C + 2*LAY_MAX_DIRS,X       ; sign byte (b7 dy', b6 dx')
   STA zp_br_sign
   STX zp_bf_dir                           ; mags load lazily in the mul tier
; lv1 comes from the DEDUPED LV1 records (2026-08-17): 159 diagonal segs
; share 99 reference points, so the header carries a u8 id at +SH_DIAG and
; X indexes four abs,X planes — cheaper than the four (zp),Y reads it
; replaced (no Y reload, 4 cycles a load instead of 5), and it took 4 bytes
; out of EVERY header. None of LDA/LDY/TAX touches C, so the SBC #4's C=1
; still seeds the first subtract.
   LDY #LAY_SH_DIAG
   LDA (zp_seg_hdr_p),Y
   TAX                                     ; X = LV1 record id
   STX zp_bf_lv1                           ; (bf_band reads the K plane)
; dx = px - lv1x (s16); dxhi rides A for the zero test
   LDA zp_br_px_h
   SBC ROM_LV1X_LO_C,X
   STA zp_br_dx_l
   LDA zp_br_px_x
   SBC ROM_LV1X_HI_C,X
   STA zp_br_dx_h
; (the dx==0 / dy==0 shortcut arms DELETED 2026-08-25: their verdicts
; were TRUNCATED too — dx_int == 0 only means the viewpoint's integer
; grid cell aligns, and the exact dot can sit either side. The general
; mul path handles zero deltas correctly and, crucially, routes them
; through the BAND refinement like everything else. Their ~50 bytes
; part-fund bf_band below.)
; dy = py - lv1y
   LDA zp_br_py_h
   SEC
   SBC ROM_LV1Y_LO_C,X
   STA zp_br_dy_l
   LDA zp_br_py_x
   SBC ROM_LV1Y_HI_C,X
   STA zp_br_dy_h
bf_g_both:
; ============================================================================
; EXACT BANDED BACKFACE (2026-08-25). The truncated dot's total error
; (viewpoint fraction + lv1 rounding) is provably < 256 dot units
; (primitive sums <= 58, residues <= 4/8), so:
;   |dot_int| >= 256  ->  the truncated sign IS the exact sign;
;   |dot_int| <  256  ->  bf_band refines with the dropped fraction and
;                         the LV1 K residue — an EXACT verdict.
; This replaced the shared CROSS_MAG_DECIDE expansion: backface needs
; BOTH tails (difference for same-sign products, sum for opposite) and
; the band; the node core keeps the plain macro. The witness that
; forced it: seg 121 at X=9C.C9 Y=4E.F8 R=F4 — dot_int -4, exact +4612,
; a front SOLID wall culled, the maze bleeding through its columns.
; ============================================================================
; sign(P1) = sgn(dy') ^ sgn(dxhi); sign(P2) = sgn(dx') ^ sgn(dyhi)
   LDA zp_br_sign                          ; b7 = sgn dy'
   EOR zp_br_dx_h                          ; b7 = sign(P1)
   TAX
   LDA zp_br_sign
   ASL A                                   ; b6 (dx' sign) -> b7
   EOR zp_br_dy_h                          ; b7 = sign(P2)
   STA zp_br_t2
   TXA
   EOR zp_br_t2                            ; b7 set = opposite signs
   STA zp_ys_bs                            ; opposite flag (the stage-4 byte
                                        ; — backface is stage 0, it is dead
                                        ; here and rewritten there)
   STX zp_br_sign                          ; b7 = sign(P1): the verdict key
   BPL bfx_same                            ; same-sign: the mul path
; opposite signs: dot = sign(P1)*(|P1|+|P2|) — the OLD code decided here
; mul-free, and the band only matters when BOTH products are tiny. Any
; |delta| >= 128 makes |dot| >= 128 (primitives >= 1): screen mul-free
; and only the viewer-hugging-the-reference case pays the products.
   LDA zp_br_dx_h
   BEQ bfo_dxp
   CMP #$FF
   BNE bfo_far
   LDA zp_br_dx_l
   BPL bfo_far                             ; dx <= -129
   BMI bfo_dy
bfo_dxp:
   LDA zp_br_dx_l
   BMI bfo_far                             ; dx >= 128
bfo_dy:
   LDA zp_br_dy_h
   BEQ bfo_dyp
   CMP #$FF
   BNE bfo_far
   LDA zp_br_dy_l
   BPL bfo_far
   BMI bfx_same                            ; both tiny: sum tail via muls
bfo_dyp:
   LDA zp_br_dy_l
   BMI bfo_far
   BPL bfx_same
bfo_far:
   LDA zp_br_sign                          ; |dot| >= 128: exact by sign
   BMI bfo_back
   JMP bf_seg_front
bfo_back:
   JMP s_advance_l0
bfx_same:
; --- |dx|, |dy| (the macro's abs section, inlined) ---
   LDX zp_br_dx_h
   BPL bfx_dx_pos
   LDA #0
   SEC
   SBC zp_br_dx_l
   STA zp_br_dx_l
   LDA #0
   SBC zp_br_dx_h
   STA zp_br_dx_h
bfx_dx_pos:
   LDX zp_br_dy_h
   BPL bfx_dy_pos
   LDA #0
   SEC
   SBC zp_br_dy_l
   STA zp_br_dy_l
   LDA #0
   SBC zp_br_dy_h
   STA zp_br_dy_h
bfx_dy_pos:
; --- |P1| = |dy'| * |dx| -> (t2, t3, t4) u24 ---
   LDX zp_bf_dir
   LDA ROM_DIRS_C + LAY_MAX_DIRS,X         ; |dy'|
   STA zp_br_a
   LDX zp_br_dx_l
   STX zp_mul_b
   JSR umul8
   STA zp_br_t3
   LDA zp_prod_l
   STA zp_br_t2
   LDA zp_br_dx_h
   BEQ bfx_p1_nc                           ; senior partial (out of line —
   JMP bfx_p1_hi                           ; past branch range)
bfx_p1_nc:
   STA zp_br_t4
bfx_p1_done:
; --- |P2| = |dx'| * |dy| -> (t0, t1, t5) u24 ---
   LDX zp_bf_dir
   LDA ROM_DIRS_C,X                        ; |dx'|
   STA zp_br_a
   LDX zp_br_dy_l
   STX zp_mul_b
   JSR umul8
   STA zp_br_t1
   LDA zp_prod_l
   STA zp_br_t0
   LDA zp_br_dy_h
   BEQ bfx_p2_nc                           ; senior partial (out of line —
   JMP bfx_p2_hi                           ; past branch range)
bfx_p2_nc:
   STA zp_br_t5
bfx_p2_done:
   BIT zp_ys_bs
   BPL bfx_diff                            ; (bfx_sum moved past branch
   JMP bfx_sum                             ; range — rare arm pays the JMP)
bfx_diff:
; --- same-sign tail: the old compare chain's EARLY-OUT restored, with
; a |d| < 128 band underneath (the total truncation + lv1 error is
; provably < 87 dot units — primitive sums are pack-asserted <= 63 —
; so any |d| >= 128 verdict is exact). The chain only computes the
; low-byte difference when hi and mid leave the verdict within a page.
   LDA zp_br_t4
   CMP zp_br_t5
   BEQ bfx_hi_eq                           ; senior products differ (rare;
   JMP bfx_hi_diff                         ; the arm left branch range)
bfx_hi_eq:
   LDA zp_br_t3
   CMP zp_br_t1
   BEQ bfx_mid_eq
; mids differ: in-band only when they differ by exactly 1 AND the low
; bytes pull the difference back inside +/-128
   BCC bfx_mid_lt
   SBC zp_br_t1                            ; C=1: A = t3 - t1 exactly
   CMP #1
   BNE bfx_out_front                       ; diff >= 2: d >= 256+ — exact
; d = 256 + (t2 - t0) in (0, 512)
   LDA zp_br_t2
   SEC
   SBC zp_br_t0
   BCS bfx_out_front                       ; t2 >= t0: d >= 256 — exact
   CMP #$80                                ; C=0: A = 256-(t0-t2) = d itself
   BCS bfx_out_front                       ; d >= 128 — exact
   STA zp_br_t0                            ; d < 128: refine
   JMP bfx_bandp
bfx_mid_lt:
   LDA zp_br_t1
   SEC
   SBC zp_br_t3                            ; A = t1 - t3 (u8 exact)
   CMP #1
   BNE bfx_out_back                        ; diff >= 2: d <= -256- — exact
; d = -256 + (t2 - t0) in (-512, 0)
   LDA zp_br_t0
   SEC
   SBC zp_br_t2
   BCS bfx_out_back                        ; t0 >= t2: d <= -256 — exact
   CMP #$80                                ; C=0: A = 256-(t2-t0) = |d|
   BCS bfx_out_back                        ; |d| >= 128 — exact
   STA zp_br_t0                            ; |d| < 128: refine
   JMP bfx_bandn
bfx_mid_eq:
; hi and mid equal: d = t2 - t0 in (-256, 256) — refine iff |d| < 128
   LDA zp_br_t2
   SBC zp_br_t0                            ; C=1 from the CMP equality
   BCC bfx_lo_neg
   CMP #$80
   BCS bfx_out_front                       ; d in [128, 255] — exact
   STA zp_br_t0
   JMP bfx_bandp
bfx_lo_neg:
   CMP #$80
   BCC bfx_out_back                        ; d in [-256, -129] — exact
   EOR #$FF                                ; |d| = -d < 128
   CLC
   ADC #1
   STA zp_br_t0
   JMP bfx_bandn
; Band gates: bound = ROM_DBOUND_C[dir] = 1.5*(|dx'|+|dy'|) + 1, BAKED
; (2026-08-26 grind — bfx_bound's runtime arithmetic died). Certificate:
; |dot_true/256 - dot_int| < |dy'|*ex + |dx'|*ey
; + 32*4*(|dy'|+|dx'|)/256 < sum*(1 + 1/2), with ex,ey < 1 the dropped
; viewpoint fractions and |k| <= 4 the LV1 residues. Any |d| >= bound
; is therefore EXACT by sign — the fixed |d| < 128 band over-refined
; ~3x (sums are pack-asserted <= 63 so the bound is <= 95).
bfx_bandp:
; shared band entry, d > 0: t0 holds |dot_int| (stored by the site)
   LDX zp_bf_dir
   LDA ROM_DBOUND_C,X
   CMP zp_br_t0
   BCC bfx_of2                             ; bound < |d| <= exact by sign
   BEQ bfx_of2                             ; (BEQ covers bound == |d|)
   LDA zp_br_sign
   STA zp_br_t1
   JMP bf_band
bfx_of2:
   JMP bfx_out_front                       ; d > 0 = |P1| > |P2|
bfx_bandn:
; shared band entry, d < 0: dot's sign flips P1's
   LDX zp_bf_dir
   LDA ROM_DBOUND_C,X
   CMP zp_br_t0
   BCC bfx_ob2
   BEQ bfx_ob2
   LDA zp_br_sign
   EOR #$80
   STA zp_br_t1
   JMP bf_band
bfx_ob2:
   JMP bfx_out_back                        ; d < 0 = |P1| < |P2|
bfx_out_front:
; |dot| out of band with |P1| > |P2|: verdict = sign(P1)
   LDA zp_br_sign
   BMI bfx_back
   JMP bf_seg_front
bfx_out_back:
; |dot| out of band with |P1| < |P2|: verdict = NOT sign(P1)
   LDA zp_br_sign
   BPL bfx_back
   JMP bf_seg_front
bfx_back:
   JMP s_advance_l0
bfx_hi_diff:
; senior bytes differ: |d| >= 65536 - 65535 — decide by the compare's C
; (the pre-band code's verdict, exact out here: |d| >= 256 always when
; the seniors differ by >= 1 page and the mid/lo can pull back at most
; 255+255 < 512... a 1-page senior gap CAN land inside +/-128, so run
; the full subtraction on this RARE path)
   SEC
   LDA zp_br_t2
   SBC zp_br_t0
   STA zp_br_t0                            ; d lo
   LDA zp_br_t3
   SBC zp_br_t1
   STA zp_br_t1                            ; d mid
   LDA zp_br_t4
   SBC zp_br_t5                            ; d hi; C = sign
   BCC bfx_hd_neg
   ORA zp_br_t1
   BNE bfx_out_front                       ; d >= 256 — exact
   LDA zp_br_t0
   BMI bfx_out_front                       ; d in [128,255] — exact
   JMP bfx_bandp
bfx_hd_neg:
   AND zp_br_t1
   CMP #$FF
   BNE bfx_out_back                        ; d <= -257 — exact
   LDA zp_br_t0
   BEQ bfx_out_back                        ; d = -256 — exact
   BPL bfx_out_back                        ; d in [-256,-129] — exact
   EOR #$FF
   CLC
   ADC #1
   STA zp_br_t0
   JMP bfx_bandn
bfx_sum:
; --- opposite-sign tail: dot = sign(P1) * (|P1| + |P2|). Only reached
; with BOTH |deltas| < 128 (the mul-free screen), so the products are
; < 57*128 and the senior bytes are structurally zero — the mid test
; suffices. ---
   LDA zp_br_t3
   ORA zp_br_t1
   BNE bfx_sfar
   LDA zp_br_t2
   CLC
   ADC zp_br_t0
   BCS bfx_sfar                            ; sum >= 256
   STA zp_br_t0
   JMP bfx_bandp
bfx_sfar:
   LDA zp_br_sign                          ; |dot| >= 256: P1's sign decides
   BMI bfx_back
   JMP bf_seg_front
; --- out-of-line senior partials (shared bodies in header.s) ---
bfx_p1_hi:
   JSR cross_p1_hi
   JMP bfx_p1_done
bfx_p2_hi:
   JSR cross_p2_hi
   JMP bfx_p2_done

; ============================================================================
; bf_band — the EXACT in-band verdict (2026-08-25; supersedes bf_tie,
; which refined dot == 0 only and trusted the ROUNDED lv1 to sit on the
; line — it doesn't, by up to half a prescaled unit).
;
;   In: zp_br_t0 = |dot_int| (u8), zp_br_t1 b7 = sign(dot_int),
;       zp_bf_dir = DIR index, zp_bf_lv1 = LV1 record id.
;   T (s24, t2/t3/t4) = 256*dot_int + (dy'*fx - dx'*fy) +/- BKT[rec]
;   (BKT = -32*(cdy*kx - cdx*ky) baked canonical; - for the neg twin)
;   = 256 * the FULL-PRECISION dot against the true (world-vertex)
;   reference point: fx/fy are the viewpoint's 8.8 fractions, (kx,ky)
;   the reference point's sub-prescale residues (the packed K plane,
;   |k| <= 4 — so the K terms pre-shift into the multiplier: |k|<<5 is
;   u8 and the product needs no post-shift).
;   Verdict: T > 0 front, T < 0 back, T == 0 -> front iff dy' > 0
;   (the full-precision tie-break; exactly one twin survives).
; ============================================================================
bf_band:
   LDA #0
   STA zp_br_t2                            ; T = dot_int << 8 (signed)
   TAX                                     ; X = 0 (the positive hi byte)
   LDA zp_br_t0
   BEQ bb_ipos                             ; dot_int == 0 (mid_eq lo-equal
                                           ; arrives here with EITHER staged
                                           ; sign): hi ext MUST be 0 — the
                                           ; negate path would write $FF
   BIT zp_br_t1
   BPL bb_ipos
   EOR #$FF                                ; negative: mid = -|dot|, hi = $FF
   CLC                                     ; (|dot| > 0 on this path — the
   ADC #1                                  ; -256 edge stayed out of band)
   LDX #$FF
bb_ipos:
   STA zp_br_t3
   STX zp_br_t4
; term 1: + dy' * fx (subtract iff dy' < 0)
   LDX zp_bf_dir
   LDA ROM_DIRS_C + 2*LAY_MAX_DIRS,X       ; b7 = sgn dy'
   STA zp_br_t5
   LDA ROM_DIRS_C + LAY_MAX_DIRS,X         ; |dy'|
   LDX zp_br_px                            ; fx = px88's 8.8 low byte
   STX zp_mul_b
   JSR umul8
   JSR bb_apply
; term 2: - dx' * fy (subtract iff dx' > 0)
   LDX zp_bf_dir
   LDA ROM_DIRS_C + 2*LAY_MAX_DIRS,X
   ASL A                                   ; b7 = sgn dx'
   EOR #$80
   STA zp_br_t5
   LDA ROM_DIRS_C,X                        ; |dx'|
   LDX zp_br_py                            ; fy
   STX zp_mul_b
   JSR umul8
   JSR bb_apply
; terms 3/4 FUSED (2026-08-26 grind): the whole K-residue term ships
; BAKED per record as BKT = -32*(cdy*kx - cdx*ky) against the record's
; CANONICAL dir (cdy > 0) — one s16 fold replaces two unpack+multiply
; blocks. This seg's dir is either the canonical one or its negation:
; the DIR sign plane's b7 (sgn dy') says which, and the negated twin
; SUBTRACTS the baked term.
   LDX zp_bf_dir
   LDA ROM_DIRS_C + 2*LAY_MAX_DIRS,X       ; b7 = sgn dy'
   BMI bb_ksub
   LDX zp_bf_lv1
   LDY ROM_BKTHI_C,X                       ; Y = hi (sign for the s24 ext)
   LDA zp_br_t2
   CLC
   ADC ROM_BKTLO_C,X
   STA zp_br_t2
   LDA zp_br_t3
   ADC ROM_BKTHI_C,X
   STA zp_br_t3
   TYA                                     ; N = sgn(BKT), C preserved
   BMI bb_ka_neg
   LDA zp_br_t4                            ; s24 += positive s16: ext 0
   ADC #0
   STA zp_br_t4
   JMP bb_verdict
bb_ka_neg:
   LDA zp_br_t4                            ; s24 += negative s16: ext $FF
   ADC #$FF
   STA zp_br_t4
   JMP bb_verdict
bb_ksub:
   LDX zp_bf_lv1
   LDY ROM_BKTHI_C,X
   LDA zp_br_t2
   SEC
   SBC ROM_BKTLO_C,X
   STA zp_br_t2
   LDA zp_br_t3
   SBC ROM_BKTHI_C,X
   STA zp_br_t3
   TYA
   BMI bb_ks_neg
   LDA zp_br_t4                            ; s24 -= positive s16: ext 0
   SBC #0
   STA zp_br_t4
   JMP bb_verdict
bb_ks_neg:
   LDA zp_br_t4                            ; s24 -= negative s16: ext $FF
   SBC #$FF
   STA zp_br_t4
bb_verdict:
   LDA zp_br_t4
   BMI bb_back                             ; T < 0 -> back
   ORA zp_br_t3
   ORA zp_br_t2
   BEQ bb_zero
   JMP bf_seg_front                        ; T > 0 -> front
bb_back:
   JMP s_advance_l0
bb_zero:
; exact zero: full-precision tie — front iff dy' > 0
   LDX zp_bf_dir
   LDA ROM_DIRS_C + 2*LAY_MAX_DIRS,X
   BMI bb_back
   JMP bf_seg_front
; (bb_apply moved to header.s as ::bb_apply 2026-08-26 — node_band
;  shares it for the exact node refine's fraction terms)
.endscope
; (24-byte layout-keeper pad stripped 2026-07-26 in the all-pads
; sweep: free space consolidates at the CODE segment end; page-cross
; dice re-rolled and measured as one lump.)
; ============================================================================
; bbox_visible — visibility test for a child subtree's bounding box.
;
; NOTE: the routine itself lives in src/bsp/bbox.s. The algorithm sketch
; below (steps 1-7) describes the RETIRED perspective corner-projection
; implementation; the live code dispatches to the angle-space BCA module
; instead (see the banner near the ang-module imports below). This block is kept for
; the I/O contract and the scratch-layout documentation that follows.
;
;   Inputs:
;     zp_node_ch_l:hi = node id (used by caller; we read bbox by ourselves)
;     zp_bbox_side    = 0 for right child's bbox, 1 for left child's bbox.
;
;   Output: A = 1 if any visible gap in the bbox's screen-X range, else 0.
;
;   Algorithm (matches Python fp_bbox_visible_fixed loosely):
;     1. Compute bbox ptr = ROM_BBOX + node_id*16 + (side<<3).
;     2. Inside test: if (px_int, py_int) inside bbox, return 1 (always visible).
;     3. Transform 4 corners (l,t)(r,t)(r,b)(l,b) through br_to_view.
;     4. For each in front of NEAR plane, project to screen X.
;     5. If all behind near plane → return 0 (off-screen).
;        If any behind near plane → assume visible (set ilo=0, ihi=255).
;        Else min/max projected sx, clamped to [0, 255] → ilo, ihi.
;     6. If ilo > ihi → return 0.
;     7. JSR span_has_gap → return its A.
; ============================================================================

; Per-corner storage (5 bytes × 4 = 20) — legacy perspective-path scratch
; (dead with the angle module; layout retained). bv_proj_one writes here so
; that a second pass can compute near-plane edge crossings between
; consecutive corners. Layout per corner: vx_lo, vx_hi, vy_lo, vy_hi,
; in_front (0/1).
; NOTE: these previously lived at $0E00/$0E14 — INSIDE the vertex cache
; ($0C00 + 8x467 = $1A98) — so every bbox visibility check corrupted the
; cached transforms of vertices ~64-66. $0960-$0974 is free scratch
; (span_clip's LC_* scratch ends at $0958).
BBOX_CORNERS = $0C20                    ; 4 x 8: vx16, vy16, front, vy24 (lo,hi,ext)
; (overlays the per-seg projection scratch — disjoint phases)

; Deferred per-subsector op queue (mirrors Python's packed_render_subsector
; `deferred` list): seg-ordered solid/tighten ops, applied at subsector end.
;   entry: $00, ilo, ihi                                  (solid)
;          $01, ilo, ihi, top block, bot block            (tighten)
;   where each block is (count, 6*count record bytes) snapshotted from
;   TOP_RECORDS/$0700 / BOT_RECORDS/$0800 at seg end — later segs' DCL
;   emission overwrites those buffers before the drain, exactly the
;   problem Python solves with its '__rec__' snapshots.
;   (Correction: records are 4 bytes each now — blocks are
;   (count, 4*count bytes); see defq_append_tighten in defq.s and the
;   Python snapshot `TOP_RECORDS : TOP_RECORDS + 1 + tc*4`.)
; (DEFQ_BASE/TAIL/OVF deleted 2026-07-16 with the deferral itself:
;  $0600 is a FREE page again, zp $2B free, $09FC free.)

; Near-plane edge-crossing scratch. Reuses the per-seg ZP block — bbox
; visibility runs during node processing, when the seg-loop variables
; ($5D-$6F) are dead.


; --- Angle-space bbox module (bsp_render_ang.bin @ $E940; tables $DC00/$E400/$F200).
;     Replaced the perspective corner-projection path, which was
;     DELETED long ago -- only its scratch equates survived, and they
;     went too on 2026-08-29 (BBOX_SCRATCH/FLAGS/ILO/IHI/CORNER_IDX,
;     $0A60-$0A6A + $0AFD: 12 bytes back to the scratch page).
; angle module + bca workspace relocate when banked (must match slope_div.asm:
;   code -> $3400 (entry+3 = $3403); bca workspace -> BCA_WS $3A00).
; (the bbox_check_angle / bca_frame imports died 2026-09-04 with the
;  extent cache -- neither symbol exists.)                ; the bbox.s
.import box_classify                    ; pristine tier (bbox_visible dispatches
                                        ; on zp_bv_mode — SMC retired)
                                        ; call site bca_check_op is SMC-
                                        ; retargeted by bca_frame (rcache.s)
; (BCA_WS retired 2026-07-26 — the val[] slots were engine-dead and
; bca_ab is ZP $64 now, registered in zp.inc for both units.)
bca_ilo = zp_i_l                        ; output: left column (u8) — ALIASED
bca_ihi = zp_i_h                        ; to zp_i_l/h (2026-07-18, see ang)
; (bca_vis retired 2026-07-20 — verdict rides the exit flags. Its old
; $64 'slot' was never reusable: $64 is zp_bv_entry's HI byte.)
