
; ============================================================================
; br_view_setup — compute frac_vx, frac_vy for the current frame.
;
; Per-frame view-context setup, mirror of fp_view_context (fp.py): the
; vertex fraction is always 0, so the fractional part of the rotated
; player-relative delta is frame-constant (= rotate(-player_frac)).
; Precomputing it here (≤4 muls, once per frame) lets the hot per-vertex
; transform (br_to_view) handle only the integer part. Also hoists the
; frame-constant inputs of the angle-space bbox check and picks the
; coherence-cache variants for this frame.
;
;   Inputs (zp):  zp_br_px (s16 8.8 prescaled player x; int part s16 at
;                 zp_br_px_h/px_e), zp_br_py / zp_br_py_h/py_e (same for y),
;                 zp_br_smag, zp_br_sneg, zp_br_sone,  (sin: u8 magnitude,
;                 zp_br_cmag, zp_br_cneg, zp_br_cone    neg flag, |t|=1 flag)
;                 bca_ab = view-angle byte (frame preset).
;   Outputs (zp): zp_br_fvxlo/hi, zp_br_fvylo/hi (each s16);
;                 bca_afn ($3B/$3C) = ab<<4 fine angle (hoisted);
;                 bca_pxs/pys ($8D/$8E, $9B/$9C) = player pos s16 copies;
;                 jt_bca_check SMC-patched (cached vs original bbox check);
;                 per-frame vertex-cache mode chosen (vxc_frame).
;   Clobbers: A, X, Y, zp_br_t2/t3, zp_ft_* staging, mul workspace.
;
;   Python:
;     dx_lo = (-vx_88) & 0xFF
;     dy_lo = (-vy_88) & 0xFF
;     frac_vx = ft(dx_lo, sin) - ft(dy_lo, cos)
;     frac_vy = ft(dx_lo, cos) + ft(dy_lo, sin)
;   where ft = _frac_rot_term: unity → lo; else (lo*mag + 128) >> 8, then
;   negate if trig negative (see br_frac_rot_term in arith.s).
; ============================================================================
br_view_setup:
.scope
; a_fine = ab<<4 is frame-constant; hoist it here (once/frame) instead of
; recomputing inside bbox_check_angle on every one of the ~650 bbox checks.
; bca_afn ($3B/$3C) is untouched by the perspective path between checks.
   LDA bca_ab
   LSR A
   LSR A
   LSR A
   LSR A
   STA $3C
; bca_afn+1 = ab>>4
   LDA bca_ab
   ASL A
   ASL A
   ASL A
   ASL A
   STA $3B
; bca_afn = (ab<<4)&FF
; Player px,py sign-extended to s16 (bca_pxs $8D/$8E, bca_pys $9B/$9C) is
; also frame-constant; hoist it (was recomputed per bbox check).
   LDA zp_br_px_h
   STA $8D
   LDA zp_br_px_e
   STA $8E
   LDA zp_br_py_h
   STA $9B
   LDA zp_br_py_e
   STA $9C
; |px| / |py| magnitudes for the diagonal back-face C-form (frame-
; constant; signs are read live from px_e/py_e bit7 at test time)
   LDA zp_br_px_h
   STA zp_bf_pxm_lo
   LDA zp_br_px_e
   STA zp_bf_pxm_hi
   BPL vs_pxm_pos
   LDA #0
   SEC
   SBC zp_bf_pxm_lo
   STA zp_bf_pxm_lo
   LDA #0
   SBC zp_bf_pxm_hi
   STA zp_bf_pxm_hi
vs_pxm_pos:
   LDA zp_br_py_h
   STA zp_bf_pym_lo
   LDA zp_br_py_e
   STA zp_bf_pym_hi
   BPL vs_pym_pos
   LDA #0
   SEC
   SBC zp_bf_pym_lo
   STA zp_bf_pym_lo
   LDA #0
   SBC zp_bf_pym_hi
   STA zp_bf_pym_hi
vs_pym_pos:
; --- Fractional deltas: low byte of the NEGATED 8.8 player position
; (vertex frac is 0, so frac(vertex - player) = frac(-player)). ---
; dx_lo = (-zp_br_px) & 0xFF
   LDA #0
   SEC
   SBC zp_br_px
   STA zp_br_t2
; dx_lo
; dy_lo = (-zp_br_py) & 0xFF
   LDA #0
   SEC
   SBC zp_br_py
   STA zp_br_t3
; dy_lo

; --- frac_vx = ft(dx_lo, sin) - ft(dy_lo, cos) ---
; Each ft call stages (lo, mag, neg, one) into the zp_ft_* slots and
; returns an s16 in zp_br_resl/resh.
   LDA zp_br_t2
   STA zp_ft_lo
   LDA zp_br_smag
   STA zp_ft_mag
   LDA zp_br_sneg
   STA zp_ft_neg
   LDA zp_br_sone
   STA zp_ft_one
   JSR br_frac_rot_term
   LDA zp_br_resl
   STA zp_br_fvxlo
   LDA zp_br_resh
   STA zp_br_fvxhi

   LDA zp_br_t3
   STA zp_ft_lo
   LDA zp_br_cmag
   STA zp_ft_mag
   LDA zp_br_cneg
   STA zp_ft_neg
   LDA zp_br_cone
   STA zp_ft_one
   JSR br_frac_rot_term
; frac_vx -= result
   LDA zp_br_fvxlo
   SEC
   SBC zp_br_resl
   STA zp_br_fvxlo
   LDA zp_br_fvxhi
   SBC zp_br_resh
   STA zp_br_fvxhi

; --- frac_vy = ft(dx_lo, cos) + ft(dy_lo, sin) ---
   LDA zp_br_t2
   STA zp_ft_lo
   LDA zp_br_cmag
   STA zp_ft_mag
   LDA zp_br_cneg
   STA zp_ft_neg
   LDA zp_br_cone
   STA zp_ft_one
   JSR br_frac_rot_term
   LDA zp_br_resl
   STA zp_br_fvylo
   LDA zp_br_resh
   STA zp_br_fvyhi

   LDA zp_br_t3
   STA zp_ft_lo
   LDA zp_br_smag
   STA zp_ft_mag
   LDA zp_br_sneg
   STA zp_ft_neg
   LDA zp_br_sone
   STA zp_ft_one
   JSR br_frac_rot_term
   LDA zp_br_fvylo
   CLC
   ADC zp_br_resl
   STA zp_br_fvylo
   LDA zp_br_fvyhi
   ADC zp_br_resh
   STA zp_br_fvyhi

; Rotation-coherence: choose cached vs original bbox_check_angle for this
; frame (SMC-patches jt_bca_check) by whether the integer player position
; moved. Cheap (~40 cyc/frame); zero per-check overhead on moved frames.
; Banked: the cache code+data live in the bank L2 window — page it in
; (no-op macro on flat; callers re-page before their next engine call).
   PAGE BANK_C
   JSR rot_select                          ; SMC: specialize rot_s1..s4 for this
                                        ; frame's trig (SEL, main $2C00 —
                                        ; runs under any bank)
   PAGE BANK_L2
   JSR jt_bca_frame
   JSR br_dcache_frame                     ; forward-coherence bbox cache (bbox.s)
   JSR vxc_frame                           ; translation-coherence vertex cache
   RTS
.endscope

; ============================================================================
; br_to_view — world (wx, wy) → view (vx_88, vy_88).
;
;   Inputs (zp):
;     zp_br_dx = wx (s8 prescaled vertex world X — caller has already
;                    computed wx - px_int, OR set zp_br_dx = wx and we'll
;                    do the subtract here)
;     zp_br_dy = wy
;     ... and view-context state in zp_br_*.
;
;   To match Python's call site exactly: the caller writes RAW wx/wy into
;   zp_br_dx / zp_br_dy and we subtract px_int/py_int here.
;
;   Outputs (zp):
;     zp_br_vxlo/hi = total_vx (s16, 8.8)
;     zp_br_vylo/hi = total_vy (s16, 8.8)
;
;   Python:
;     dx_hi = wx - px_int
;     dy_hi = wy - py_int
;     int_vx = rot_int(dx_hi, sin) - rot_int(dy_hi, cos)
;     int_vy = rot_int(dx_hi, cos) + rot_int(dy_hi, sin)
;     total_vx = int_vx + frac_vx
;     total_vy = int_vy + frac_vy
;
;   px_int = high byte of zp_br_px. The wrapper precomputes this and
;   stores it at zp_br_px_h (we use the HI byte of the s16 player pos).
;
;   Accumulators are s24 (lo/hi/ext) — the intermediate rot_int terms are
;   8.8 with an s16 integer delta, so single terms can exceed s16; the
;   final sums are consumed as 8.8 (hi byte = integer view coord).
;   Mirrors fp_to_view (fp.py) up to the total_vx/total_vy sums; the
;   >>8 truncation/rounding happens in the caller (br_seg_xform_vertex).
;   Clobbers: A, Y, zp_ri_dlo/dhi, mul workspace, zp_br_res*.
; ============================================================================
; br_to_view_fetch — vertex-fetch entry (2026-07-11): pages L2, builds the
; ROM_VERTS pointer from zp_seg_v_idx and loads wx/wy into zp_br_dx/dy,
; then falls into br_to_view. Pushed down from seg_xform's vc_miss: the
; VXC warm path never reads the world coords, so the fetch (and its PAGE)
; now costs only the paths that actually rotate. Callers with dx/dy
; already staged (jt harness, vxc_frame's ref probe) enter at br_to_view.
br_to_view_fetch:
.assert <ROM_VERTS_C = 0, error, "vertex fetch assumes page-aligned ROM_VERTS_C"
   PAGE BANK_L2                            ; verts live in the L2 window
   LDA zp_seg_v_idx_lo
   ASL A
   ASL A                                   ; (idx*4) lo = lo<<2 mod 256 —
   STA zp_br_p                             ; page-aligned base: no lo add
   LDA zp_seg_v_idx_b
   LSR A
   LSR A
   LSR A                                   ; B>>3 = idx>>6 = (idx*4) hi
   CLC
   ADC #>ROM_VERTS_C                       ; layout.inc constant
   STA zp_br_p_h
   LDY #0
   LDA (zp_br_p),Y
   STA zp_br_dxlo
   INY
   LDA (zp_br_p),Y
   STA zp_br_dxhi
   INY
   LDA (zp_br_p),Y
   STA zp_br_dylo
   INY
   LDA (zp_br_p),Y
   STA zp_br_dyhi
br_to_view:
; (no .scope: rot_s1..rot_s4 must be GLOBAL labels — rot_select patches
; their operands — and the body has no local labels; same rule as
; vxc_jsr_site in seg_xform.s.)
; --- Integer deltas: d = vertex_world - player_int (both axes, s16). ---
; dx (s16) = wx - px_int (s16: px_h lo, px_e hi).
   LDA zp_br_dxlo
   SEC
   SBC zp_br_px_h
   STA zp_br_dxlo
   LDA zp_br_dxhi
   SBC zp_br_px_e
   STA zp_br_dxhi
   LDA zp_br_dylo
   SEC
   SBC zp_br_py_h
   STA zp_br_dylo
   LDA zp_br_dyhi
   SBC zp_br_py_e
   STA zp_br_dyhi

; int_vx = rot_int(dx, sin) - rot_int(dy, cos), as s24
; (rot_s1..rot_s4 are SMC call sites — rot_select points them at the
; per-frame trig variants in arith.s; result s24 in resl/resh/resext.)
   LDA zp_br_dxlo
   STA zp_ri_dlo
   LDA zp_br_dxhi
   STA zp_ri_dhi
rot_s1:
   JSR rot_gen_sin                         ; operand SMC'd per frame (rot_select)
   LDA zp_br_resl
   STA zp_br_vxlo
   LDA zp_br_resh
   STA zp_br_vxhi
   LDA zp_br_resext
   STA zp_br_vxext

   LDA zp_br_dylo
   STA zp_ri_dlo
   LDA zp_br_dyhi
   STA zp_ri_dhi
rot_s2:
   JSR rot_gen_cos                         ; operand SMC'd per frame
   LDA zp_br_vxlo
   SEC
   SBC zp_br_resl
   STA zp_br_vxlo
   LDA zp_br_vxhi
   SBC zp_br_resh
   STA zp_br_vxhi
   LDA zp_br_vxext
   SBC zp_br_resext
   STA zp_br_vxext

; int_vy = rot_int(dx, cos) + rot_int(dy, sin), as s24
   LDA zp_br_dxlo
   STA zp_ri_dlo
   LDA zp_br_dxhi
   STA zp_ri_dhi
rot_s3:
   JSR rot_gen_cos                         ; operand SMC'd per frame
   LDA zp_br_resl
   STA zp_br_vylo
   LDA zp_br_resh
   STA zp_br_vyhi
   LDA zp_br_resext
   STA zp_br_vyext

   LDA zp_br_dylo
   STA zp_ri_dlo
   LDA zp_br_dyhi
   STA zp_ri_dhi
rot_s4:
   JSR rot_gen_sin                         ; operand SMC'd per frame
   LDA zp_br_vylo
   CLC
   ADC zp_br_resl
   STA zp_br_vylo
   LDA zp_br_vyhi
   ADC zp_br_resh
   STA zp_br_vyhi
   LDA zp_br_vyext
   ADC zp_br_resext
   STA zp_br_vyext

; (falls through into tv_add_fracs — its RTS is br_to_view's return)

; ============================================================================
; tv_add_fracs — add the per-frame fractional rotation terms (s16,
; sign-extended) to the s24 vx/vy accumulators. Tail of br_to_view (the
; old second caller — the perspective bbox corner combine — is long
; retired; the JMP became fall-through 2026-07-11).
;
;   Inputs (zp):  zp_br_vxlo/vxhi/vxext, zp_br_vylo/vyhi/vyext (s24
;                 integer-rotation sums), zp_br_fvxlo/hi, zp_br_fvylo/hi
;                 (s16 per-frame fracs from br_view_setup).
;   Outputs (zp): the same accumulators, += sign-extended frac:
;                 total_v* = int_v* + frac_v*   (Python: fp_to_view's sums)
;   Clobbers: A.
;
;   The frac term is s16; its sign extension into the ext byte is done by
;   adding #$00 (frac >= 0) or #$FF (frac < 0) with the carry propagated
;   from the hi-byte add.
; ============================================================================
tv_add_fracs:
.scope
   LDA zp_br_vxlo
   CLC
   ADC zp_br_fvxlo
   STA zp_br_vxlo
   LDA zp_br_vxhi
   ADC zp_br_fvxhi
   STA zp_br_vxhi
   LDA zp_br_fvxhi
   BMI bv_fvxneg
   LDA zp_br_vxext
   ADC #0
   STA zp_br_vxext
   JMP bv_fvx_done
bv_fvxneg:
   LDA zp_br_vxext
   ADC #$FF
   STA zp_br_vxext
bv_fvx_done:

   LDA zp_br_vylo
   CLC
   ADC zp_br_fvylo
   STA zp_br_vylo
   LDA zp_br_vyhi
   ADC zp_br_fvyhi
   STA zp_br_vyhi
   LDA zp_br_fvyhi
   BMI bv_fvyneg
   LDA zp_br_vyext
   ADC #0
   STA zp_br_vyext
   JMP bv_fvy_done
bv_fvyneg:
   LDA zp_br_vyext
   ADC #$FF
   STA zp_br_vyext
bv_fvy_done:
   RTS
.endscope

; ============================================================================
; HELPER: br_smul_s8_u8 — signed s8 × unsigned u8 → s16.
;   Inputs:  zp_br_a (s8), zp_br_b (u8).
;   Output:  zp_br_resl/h (s16 = a * b, exact: |a|<=128, b<=255 fits s16).
;   Clobbers: A, X, Y, zp_tmp0, zp_mul_b, zp_prod_lo/hi.
;
;   res = umul8(|a|, b), negated if a < 0. The quarter-square umul8 body
;   (see SC_UMUL8 in header.s) is inlined in BOTH sign paths — 56% of all
;   umul8 calls come through here, so the JSR/RTS and the sign-flag
;   bookkeeping are worth flattening.
; ============================================================================
br_smul_s8_u8:
.scope
; Split positive/negative paths up front: no sign flag, no |a|
; writeback, single result copy (negative path negates during copy).
   LDA zp_br_b
   STA zp_mul_b
   LDA zp_br_a
; br_smul_am — register-contract entry (dead-write tracker 2026-07-11):
; caller pre-stores zp_mul_b (u8 = b) and arrives with a (s8) in A, the
; N flag still live from its own LDA — JSR preserves flags, so the BMI
; below is the first instruction that needs them. Drops the zp_br_a/
; zp_br_b staging round-trip (12 cycles) at every hot call site.
::br_smul_am:
   BMI a_neg
; --- inlined umul8(A, mag) — 56% of all umul8 calls go through here ---
   TAX                                     ; stash a in X (was zp_tmp0)
   SEC
   SBC zp_mul_b
   BCS up_pos
   EOR #$FF
   ADC #1
up_pos:
   TAY
   TXA
   CLC
   ADC zp_mul_b
   TAX
   BCS up_uo
   LDA sqr_lo,X
   SEC
   SBC sqr_lo,Y
   STA zp_prod_lo
   LDA sqr_hi,X
   SBC sqr_hi,Y
   STA zp_prod_hi
   JMP up_done
up_uo:
   LDA sqr2_lo,X
   SBC sqr_lo,Y
   STA zp_prod_lo
   LDA sqr2_hi,X
   SBC sqr_hi,Y
   STA zp_prod_hi
up_done:
   LDA zp_prod_lo
   STA zp_br_resl
   LDA zp_prod_hi
   STA zp_br_resh
   RTS
a_neg:
   EOR #$FF
   BUMP
; --- inlined umul8(|a|, mag) ---
   TAX                                     ; stash a in X (was zp_tmp0)
   SEC
   SBC zp_mul_b
   BCS un_pos
   EOR #$FF
   ADC #1
un_pos:
   TAY
   TXA
   CLC
   ADC zp_mul_b
   TAX
   BCS un_uo
   LDA sqr_lo,X
   SEC
   SBC sqr_lo,Y
   STA zp_prod_lo
   LDA sqr_hi,X
   SBC sqr_hi,Y
   STA zp_prod_hi
   JMP un_done
un_uo:
   LDA sqr2_lo,X
   SBC sqr_lo,Y
   STA zp_prod_lo
   LDA sqr2_hi,X
   SBC sqr_hi,Y
   STA zp_prod_hi
un_done:
   SEC
   LDA #0
   SBC zp_prod_lo
   STA zp_br_resl
   LDA #0
   SBC zp_prod_hi
   STA zp_br_resh
   RTS
.endscope

; (br_smul_s8_s16 deleted 2026-07-09: its only caller was the back-face
; mul arm, which now compares unsigned u24 magnitudes directly — exact,
; where the old s16-truncating dot was not.)


; ============================================================================
; HELPER: br_smul_s16_s16_s32 — signed s16 × s16 → s32 (4-byte little-endian).
;   Inputs:  zp_br_dxlo:dxhi (A, s16), zp_br_dylo:dyhi (B, s16).
;   Output:  zp_br_t0:t1:t2:t3 (s32).
;   Clobbers: zp_br_dxlo:dxhi, zp_br_dylo:dyhi (negated for sign tracking),
;             A, X, Y, zp_br_sign, mul workspace.
;
;   Algorithm: sign-magnitude schoolbook with 4 u8×u8 partial products —
;     t0:t1  = al*bl
;     t2:t3  = ah*bh                        # the <<16 term
;     t1:t2:t3 += al*bh + ah*bl             # the two <<8 cross terms
;   then negate the s32 if the operand signs differed. Exact: |A|,|B|
;   <= 32768, product < 2^31. Used by the general point_on_side cascade.
; ============================================================================
br_smul_s16_s16_s32:
.scope
   ZERO zp_br_sign

; |A|
   LDA zp_br_dxhi
   BPL aa_pos
   LDA #0
   SEC
   SBC zp_br_dxlo
   STA zp_br_dxlo
   LDA #0
   SBC zp_br_dxhi
   STA zp_br_dxhi
   INC zp_br_sign
aa_pos:
; |B|
   LDA zp_br_dyhi
   BPL bb_pos
   LDA #0
   SEC
   SBC zp_br_dylo
   STA zp_br_dylo
   LDA #0
   SBC zp_br_dyhi
   STA zp_br_dyhi
   LDA zp_br_sign
   EOR #1
   STA zp_br_sign
bb_pos:

; al × bl → t0:t1
   LDA zp_br_dxlo
   STA zp_mul_b
   LDA zp_br_dylo
   JSR SC_UMUL8
   STA zp_br_t1                            ; A = prod_hi (umul8 contract)
   LDA zp_prod_lo
   STA zp_br_t0

; ah × bh → t2:t3
   LDA zp_br_dxhi
   STA zp_mul_b
   LDA zp_br_dyhi
   JSR SC_UMUL8
   STA zp_br_t3                            ; A = prod_hi (umul8 contract)
   LDA zp_prod_lo
   STA zp_br_t2

; al × bh → add to t1:t2:t3
   LDA zp_br_dyhi
   STA zp_mul_b
   LDA zp_br_dxlo
   JSR SC_UMUL8
   CLC
   LDA zp_prod_lo
   ADC zp_br_t1
   STA zp_br_t1
   LDA zp_prod_hi
   ADC zp_br_t2
   STA zp_br_t2
   LDA zp_br_t3
   ADC #0
   STA zp_br_t3

; ah × bl → add to t1:t2:t3
   LDA zp_br_dylo
   STA zp_mul_b
   LDA zp_br_dxhi
   JSR SC_UMUL8
   CLC
   LDA zp_prod_lo
   ADC zp_br_t1
   STA zp_br_t1
   LDA zp_prod_hi
   ADC zp_br_t2
   STA zp_br_t2
   LDA zp_br_t3
   ADC #0
   STA zp_br_t3

; Apply sign (negate s32 if negative)
   LDA zp_br_sign
   BEQ s32_pos
   LDA #0
   SEC
   SBC zp_br_t0
   STA zp_br_t0
   LDA #0
   SBC zp_br_t1
   STA zp_br_t1
   LDA #0
   SBC zp_br_t2
   STA zp_br_t2
   LDA #0
   SBC zp_br_t3
   STA zp_br_t3
s32_pos:
   RTS
.endscope

; ============================================================================
; rot_select — per-frame SMC specialization of the br_to_view rotation
; call sites (SEL region: banked = main $2C00 since 2026-07-10 — no code
; in banks without explicit permission;
; flat = the free page below the quarter-square tables). Runs once per
; frame from br_view_setup with bank C paged; every store below targets
; resident MAIN, so bank state only matters for FETCHING this code.
;   sin -> rot_s1/rot_s4, cos -> rot_s2/rot_s3. General thunks get the
;   frame's mag/neg poked into their immediates (offsets +1 / +5).
; Clobbers A, X.
; ============================================================================
.segment "SEL"
rot_select:
.scope
; --- sin variant -> A/X = lo/hi ---
   LDA zp_br_sone
   BEQ sin_notone
   LDA zp_br_sneg
   BEQ sin_up
   LDA #<rot_unity_neg
   LDX #>rot_unity_neg
   BNE sin_have                            ; (hi byte never 0 — always taken)
sin_up:
   LDA #<rot_unity_pos
   LDX #>rot_unity_pos
   BNE sin_have
sin_notone:
   LDA zp_br_smag
   BNE sin_gen
   LDA #<rot_zero
   LDX #>rot_zero
   BNE sin_have
sin_gen:
   STA rot_gen_sin+1                       ; mag immediate
   LDA zp_br_sneg
   STA rot_gen_sin+5                       ; neg immediate
   LDA #<rot_gen_sin
   LDX #>rot_gen_sin
sin_have:
   STA rot_s1+1
   STX rot_s1+2
   STA rot_s4+1
   STX rot_s4+2
; --- cos variant -> rot_s2 / rot_s3 ---
   LDA zp_br_cone
   BEQ cos_notone
   LDA zp_br_cneg
   BEQ cos_up
   LDA #<rot_unity_neg
   LDX #>rot_unity_neg
   BNE cos_have
cos_up:
   LDA #<rot_unity_pos
   LDX #>rot_unity_pos
   BNE cos_have
cos_notone:
   LDA zp_br_cmag
   BNE cos_gen
   LDA #<rot_zero
   LDX #>rot_zero
   BNE cos_have
cos_gen:
   STA rot_gen_cos+1
   LDA zp_br_cneg
   STA rot_gen_cos+5
   LDA #<rot_gen_cos
   LDX #>rot_gen_cos
cos_have:
   STA rot_s2+1
   STX rot_s2+2
   STA rot_s3+1
   STX rot_s3+2
   RTS
.endscope
.segment "MAIN"
