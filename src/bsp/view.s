
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
;   Outputs (zp): zp_br_fvx_l/hi, zp_br_fvy_l/hi (each s16);
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
   LDA zp_br_px_x
   STA $8E
   LDA zp_br_py_h
   STA $9B
   LDA zp_br_py_x
   STA $9C
; (the |px|/|py| staging died with the delta-form conversion of the
; diagonal back-face test, 2026-07-11 — write-only since; deleted
; 2026-07-16 and the four zp_bf_p?m slots freed)
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
; returns an s16 in zp_br_res_l/resh.
   LDA zp_br_t2
   STA zp_ft_lo
   LDA zp_br_smag
   STA zp_ft_mag
   LDA zp_br_sneg
   STA zp_ft_neg
   LDA zp_br_sone
   STA zp_ft_one
   JSR br_frac_rot_term
   LDA zp_br_res_l
   STA zp_br_fvx_l
   LDA zp_br_res_h
   STA zp_br_fvx_h

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
   LDA zp_br_fvx_l
   SEC
   SBC zp_br_res_l
   STA zp_br_fvx_l
   LDA zp_br_fvx_h
   SBC zp_br_res_h
   STA zp_br_fvx_h

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
   LDA zp_br_res_l
   STA zp_br_fvy_l
   LDA zp_br_res_h
   STA zp_br_fvy_h

   LDA zp_br_t3
   STA zp_ft_lo
   LDA zp_br_smag
   STA zp_ft_mag
   LDA zp_br_sneg
   STA zp_ft_neg
   LDA zp_br_sone
   STA zp_ft_one
   JSR br_frac_rot_term
   LDA zp_br_fvy_l
   CLC
   ADC zp_br_res_l
   STA zp_br_fvy_l
   LDA zp_br_fvy_h
   ADC zp_br_res_h
   STA zp_br_fvy_h

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
;     zp_br_dx_l/dxhi = wx (s16 RAW prescaled vertex world X — the s16
;                       player-relative subtract happens HERE)
;     zp_br_dy_l/dyhi = wy (s16)
;     ... and view-context state in zp_br_* (br_view_setup ran).
;
;   To match Python's call site exactly: the caller writes RAW wx/wy and
;   this routine subtracts px_int/py_int (s16, zp_br_px_h/px_e etc).
;
;   Outputs (zp):
;     zp_br_vx_l/vxhi/vxext = total_vx (s24: 8.8 + sign/overflow ext)
;     zp_br_vy_l/vyhi/vyext = total_vy (s24)
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
;   Clobbers: A, Y, zp_ri_d_l/dhi, mul workspace, zp_br_res*.
; ============================================================================
; br_to_view_fetch — vertex-fetch entry (2026-07-11): pages L2, builds the
; ROM_VERTS pointer from zp_seg_v_idx and loads wx/wy into zp_br_dx/dy,
; then falls into br_to_view. Pushed down from seg_xform's vc_miss: the
; VXC warm path never reads the world coords, so the fetch (and its PAGE)
; now costs only the paths that actually rotate. Callers with dx/dy
; already staged (jt harness, vxc_frame's ref probe) enter at br_to_view.
br_to_view_fetch:
.assert <ROM_VERTS_C = 0, error, "vertex planes assume page-aligned ROM_VERTS_C"
; Page-split vertex planes (VP_*, header.s): senior-bit arm with the
; plane page BAKED — the idx*4 pointer build is gone (2026-07-15).
   PAGE BANK_L2                            ; vert planes live in the L2 window
   LDA zp_seg_v_idx_b
   AND #$20                                ; senior: idx >= 256 (B >= 32)
   BNE vf_hi
   LDY zp_seg_v_idx_l
   LDA VP_XLO,Y
   STA zp_br_dx_l
   LDA VP_XHI,Y
   STA zp_br_dx_h
   LDA VP_YLO,Y
   STA zp_br_dy_l
   LDA VP_YHI,Y
   STA zp_br_dy_h
   JMP br_to_view
vf_hi:
   LDY zp_seg_v_idx_l
   LDA VP_XLO+$100,Y
   STA zp_br_dx_l
   LDA VP_XHI+$100,Y
   STA zp_br_dx_h
   LDA VP_YLO+$100,Y
   STA zp_br_dy_l
   LDA VP_YHI+$100,Y
   STA zp_br_dy_h
; falls into br_to_view
br_to_view:
; (no .scope: rot_s1..rot_s4 must be GLOBAL labels — rot_select patches
; their operands — and the body has no local labels; same rule as
; vxc_jsr_site in seg_xform.s.)
; --- Integer deltas: d = vertex_world - player_int (both axes, s16). ---
; dx (s16) = wx - px_int (s16: px_h lo, px_e hi).
   LDA zp_br_dx_l
   SEC
   SBC zp_br_px_h
   STA zp_br_dx_l
   LDA zp_br_dx_h
   SBC zp_br_px_x
   STA zp_br_dx_h
   LDA zp_br_dy_l
   SEC
   SBC zp_br_py_h
   STA zp_br_dy_l
   LDA zp_br_dy_h
   SBC zp_br_py_x
   STA zp_br_dy_h

; int_vx = rot_int(dx, sin) - rot_int(dy, cos), as s24
; (rot_s1..rot_s4 are SMC call sites — rot_select points them at the
; per-frame trig variants in arith.s; result s24 in resl/resh/resext.)
   LDA zp_br_dx_l
   STA zp_ri_d_l
   LDA zp_br_dx_h
   STA zp_ri_d_h
rot_s1:
   JSR rot_gen_sin                         ; operand SMC'd per frame (rot_select)
   LDA zp_br_res_l
   STA zp_br_vx_l
   LDA zp_br_res_h
   STA zp_br_vx_h
   LDA zp_br_res_x
   STA zp_br_vx_x

   LDA zp_br_dy_l
   STA zp_ri_d_l
   LDA zp_br_dy_h
   STA zp_ri_d_h
rot_s2:
   JSR rot_gen_cos                         ; operand SMC'd per frame
   LDA zp_br_vx_l
   SEC
   SBC zp_br_res_l
   STA zp_br_vx_l
   LDA zp_br_vx_h
   SBC zp_br_res_h
   STA zp_br_vx_h
   LDA zp_br_vx_x
   SBC zp_br_res_x
   STA zp_br_vx_x

; int_vy = rot_int(dx, cos) + rot_int(dy, sin), as s24
   LDA zp_br_dx_l
   STA zp_ri_d_l
   LDA zp_br_dx_h
   STA zp_ri_d_h
rot_s3:
   JSR rot_gen_cos                         ; operand SMC'd per frame
   LDA zp_br_res_l
   STA zp_br_vy_l
   LDA zp_br_res_h
   STA zp_br_vy_h
   LDA zp_br_res_x
   STA zp_br_vy_x

   LDA zp_br_dy_l
   STA zp_ri_d_l
   LDA zp_br_dy_h
   STA zp_ri_d_h
rot_s4:
   JSR rot_gen_sin                         ; operand SMC'd per frame
   LDA zp_br_vy_l
   CLC
   ADC zp_br_res_l
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ADC zp_br_res_h
   STA zp_br_vy_h
   LDA zp_br_vy_x
   ADC zp_br_res_x
   STA zp_br_vy_x

; (falls through into tv_add_fracs — its RTS is br_to_view's return)

; ============================================================================
; tv_add_fracs — add the per-frame fractional rotation terms (s16,
; sign-extended) to the s24 vx/vy accumulators. Tail of br_to_view (the
; old second caller — the perspective bbox corner combine — is long
; retired; the JMP became fall-through 2026-07-11).
;
;   Inputs (zp):  zp_br_vx_l/vxhi/vxext, zp_br_vy_l/vyhi/vyext (s24
;                 integer-rotation sums), zp_br_fvx_l/hi, zp_br_fvy_l/hi
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
   LDA zp_br_vx_l
   CLC
   ADC zp_br_fvx_l
   STA zp_br_vx_l
   LDA zp_br_vx_h
   ADC zp_br_fvx_h
   STA zp_br_vx_h
   LDA zp_br_fvx_h
   BMI bv_fvxneg
   BCC bv_fvx_done                         ; +frac: ext += hi-add carry
   INC zp_br_vx_x                         ; (BCC/INC beats LDA/ADC/STA/JMP
   JMP bv_fvx_done                         ; on both carry outcomes)
bv_fvxneg:
   BCS bv_fvx_done                         ; -frac: ADC #$FF == ext-1+C, so
   DEC zp_br_vx_x                         ; carry SET is a no-op
bv_fvx_done:

   LDA zp_br_vy_l
   CLC
   ADC zp_br_fvy_l
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ADC zp_br_fvy_h
   STA zp_br_vy_h
   LDA zp_br_fvy_h
   BMI bv_fvyneg
   BCC bv_fvy_done                         ; +frac: ext += hi-add carry
   INC zp_br_vy_x                         ; (BCC/INC beats LDA/ADC/STA/JMP
   RTS                                     ; on both carry outcomes)
bv_fvyneg:
   BCS bv_fvy_done                         ; -frac: ADC #$FF == ext-1+C, so
   DEC zp_br_vy_x                         ; carry SET is a no-op
bv_fvy_done:
   RTS
.endscope

; (br_smul_s8_u8 + its br_smul_am register entry deleted 2026-07-13:
; the py projector inlined the body 2026-07-12 and the wide X projector
; — the last caller — is replaced by br_project_x's shrink path. The
; quarter-square idiom lives on inlined at its call sites.)

; (br_smul_s8_s16 deleted 2026-07-09: its only caller was the back-face
; mul arm, which now compares unsigned u24 magnitudes directly — exact,
; where the old s16-truncating dot was not.)


; ============================================================================
; HELPER: br_smul_s16_s16_s32 — signed s16 × s16 → s32 (4-byte little-endian).
;   Inputs:  zp_br_dx_l:dxhi (A, s16), zp_br_dy_l:dyhi (B, s16).
;   Output:  zp_br_t0:t1:t2:t3 (s32).
;   Clobbers: zp_br_dx_l:dxhi, zp_br_dy_l:dyhi (negated for sign tracking),
;             A, X, Y, zp_br_sign, mul workspace.
;
;   Algorithm: sign-magnitude schoolbook with 4 u8×u8 partial products —
;     t0:t1  = al*bl
;     t2:t3  = ah*bh                        # the <<16 term
;     t1:t2:t3 += al*bh + ah*bl             # the two <<8 cross terms
;   then negate the s32 if the operand signs differed. Exact: |A|,|B|
;   <= 32768, product < 2^31. Used by the general point_on_side cascade.
; (br_smul_s16_s16_s32 deleted 2026-07-15: its only callers were the
; node point_on_side raw-product cascade, replaced by the DIR delta
; form sharing CROSS_MAG_DECIDE.)

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
   STA rot_sqs1l+1                         ; sum-side table bases: lo byte
   STA rot_sqs1h+1                         ; = mag (SQR pages page-aligned,
   STA rot_sqs2l+1                         ; hi byte static; abs,X crosses
   STA rot_sqs2h+1                         ; into the contiguous 2nd page)
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
   STA rot_sqc1l+1                         ; cos sum-side bases (see sin)
   STA rot_sqc1h+1
   STA rot_sqc2l+1
   STA rot_sqc2h+1
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
