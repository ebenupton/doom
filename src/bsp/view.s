
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
;                 bca_afn ($3B/$3C) = ab<<4 + 512 fine angle (hoisted, biased);
;                 bca_pxs/pys ($8D/$8E, $9B/$9C) = player pos s16 copies;
;                 bca_check_op SMC-patched (cached vs original bbox check);
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
   CLC
   ADC #2                                  ; BIAS TRICK (2026-07-16): afn +=
   AND #$0F                                ; 512 (mod 4096) at the hoist, so
   STA $3C                                 ; corner_phi emits r = phi+512
; bca_afn+1 = (ab>>4 + 2) & $0F            ; directly: the FOV window becomes
;                                          ; r in [0,1024] (right test = raw
;                                          ; compare, VATOX index = r), and
;                                          ; the bias CANCELS in the rcache
;                                          ; psi stores (afn' - r = afn - phi)
   LDA bca_ab
   ASL A
   ASL A
   ASL A
   ASL A
   ORA #EPSILON_F                          ; +EPS rides the hoist FREE (the
   STA $3B                                 ; low nibble of ab<<4 is empty, so
; bca_afn = ((ab<<4)&FF) + EPS             ; ORA = add, no carry): corner_phi
;                                          ; now emits r = phi+512+EPS, the
;                                          ; right window's biased operand
;                                          ; ITSELF — its 16-cycle build in
;                                          ; bca_tail collapsed to a mask
   ZERO pa_ptr                            ; pa_ptr lo is 0 FOREVER: the TA and
                                           ; VATOX lookups ride Y against page-
                                           ; aligned bases and only ever write
                                           ; the hi byte (re-assert per frame,
                                           ; belt and braces)
; Player px,py sign-extended to s16 (bca_pxs $8D/$8E, bca_pys $9B/$9C) is
; also frame-constant; hoist it (was recomputed per bbox check).
; HI bytes OFFSET-BINNED (^$80, 2026-07-19) to match the biased BBP
; plane hi bytes (wad_packed): classify compares go UNSIGNED hi-first;
; the ZCF subtractions cancel the bias — deltas stay bit-identical.
   LDA zp_br_px_h
   STA $8D
   LDA zp_br_px_x
   EOR #$80
   STA $8E
   LDA zp_br_py_h
   STA $9B
   LDA zp_br_py_x
   EOR #$80
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
; frame (SMC-patches bca_check_op) by whether the integer player position
; moved. Cheap (~40 cyc/frame); zero per-check overhead on moved frames.
; Banked: the cache code+data live in the bank L2 window — page it in
; (no-op macro on flat; callers re-page before their next engine call).
   PAGE BANK_C
   rot_select                          ; SMC: specialize rot_s1..s4 for this
                                        ; frame's trig (SEL, main $2C00 —
                                        ; runs under any bank)
   PAGE BANK_L2
   JSR bca_frame                           ; rcache epoch keeper (rcache.s);
                                           ; the D-cache classifier call is
                                           ; gone — D disabled 2026-07-20
   vxc_frame                           ; translation-coherence vertex cache
   RTS
.endscope

; (VF_FETCH_ARM + the vf_plain0/1 standalone arms RETIRED 2026-08-09 —
;  the plain fetch lives inline in seg_xform.s SXV_BODY, both at the
;  vfoff vector target and in the vxcon cold arms; single callers all.)


; (br_to_view_fetch fully retired 2026-07-27 round 2: the vxc cold
; arms JSR their side's vf_plain directly.)
.assert <ROM_VERTS_C = 0, error, "vertex planes assume page-aligned ROM_VERTS_C"

br_to_view:
; (no .scope: rot_s1..rot_s4 must be GLOBAL labels — rot_select patches
; their operands — and the body has no local labels; same rule as
; vxc_jsr_site in seg_xform.s.)
; OPERAND-PAIRED rotate (2026-07-19): each delta is staged as |d| ONCE
; (sign banked in zp_ri_sgn) and feeds BOTH its trig calls — the four
; per-call stagings and the cores' in-place abs died. rot_select's
; wiring is unchanged: s1/s4 = the sin variant, s2/s3 = cos; the call
; ORDER regroups by operand (dx: s1 sin -> vx, s3 cos -> vy;
; dy: s2 cos -> vx -=, s4 sin -> vy +=) — same formulas:
;   int_vx = dx*sin - dy*cos ; int_vy = dx*cos + dy*sin  (s24)
;
; The delta d = vertex_world - player_int SUBTRACTS STRAIGHT INTO the
; rotate staging (2026-07-19): the old in-place zp_br_dx delta + copy
; round is gone — zp_br_dx/dy keep the RAW world coords (dead after;
; walk/backface stage their own deltas there), the SBC's N flag is the
; sign test, and the dy subtract waits until its pair (the cores don't
; touch zp_br_dy).
   ZERO zp_ri_sgn
   LDA zp_br_dx_l
   SEC
   SBC zp_br_px_h
   STA zp_ri_d_l
   LDA zp_br_dx_h
   SBC zp_br_px_x
   STA zp_ri_d_h
btv_dx_signed:                          ; fetch enters here, N = delta sign
   BPL dx_abs_ok
   INC zp_ri_sgn
   SEC
   LDA #0
   SBC zp_ri_d_l
   STA zp_ri_d_l
   LDA #0
   SBC zp_ri_d_h
   STA zp_ri_d_h
dx_abs_ok:
rot_s13:
   JSR rot_gen_pair                        ; dx pair, ONE call (2026-07-19):
                                           ; sin*dx -> zp_rs, cos*dx ->
                                           ; zp_br_res, shared d==0 test.
                                           ; rot_select patches this site:
                                           ; gen+gen = the fused variant,
                                           ; else rot_pair_thunk (rare)
; (res->vy copy DELETED 2026-07-27: the fused pair writes vy directly
;  via rot_core_cosv_nz; the thunk adapts internally on rare frames)
   ZERO zp_ri_sgn
   LDA zp_br_dy_l
   SEC
   SBC zp_br_py_h
   STA zp_ri_d_l
   LDA zp_br_dy_h
   SBC zp_br_py_x
   STA zp_ri_d_h
   BPL dy_abs_ok
   INC zp_ri_sgn
   SEC
   LDA #0
   SBC zp_ri_d_l
   STA zp_ri_d_l
   LDA #0
   SBC zp_ri_d_h
   STA zp_ri_d_h
dy_abs_ok:
rot_s2:
   JSR rot_gen_cos                         ; dy*cos -> zp_br_res
; vx = dx*sin - dy*cos, straight from the two result slots (rs still
; holds s1's product — s3 wrote zp_br_res and s2 overwrote it, neither
; touches rs).
   LDA zp_rs_l
   SEC
   SBC zp_br_res_l
   STA zp_br_vx_l
   LDA zp_rs_h
   SBC zp_br_res_h
   STA zp_br_vx_h
   LDA zp_rs_x
   SBC zp_br_res_x
   STA zp_br_vx_x
rot_s4:
   JSR rot_gen_sin                         ; dy*sin -> zp_rs
   LDA zp_br_vy_l
   CLC
   ADC zp_rs_l
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ADC zp_rs_h
   STA zp_br_vy_h
   LDA zp_br_vy_x
   ADC zp_rs_x
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
   BCS bv_fvx_c                            ; +frac carry rare (census
                                           ; 2026-07-27): island below
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
   BCS bv_fvy_c                            ; +frac carry rare: below
bv_fvy_done:
   RTS
bv_fvy_c:
   INC zp_br_vy_x
   RTS
bv_fvx_c:
   INC zp_br_vx_x
   JMP bv_fvx_done
bv_fvxneg:
   BCS bv_fvx_nod                          ; -frac: carry SET is a no-op
   DEC zp_br_vx_x                          ; (ADC #$FF == ext-1+C)
bv_fvx_nod:
   JMP bv_fvx_done
bv_fvyneg:
   BCC bv_fvy_b                            ; -frac borrow: rare (carry SET
   RTS                                     ; is a no-op — ADC #$FF == ext-1+C)
bv_fvy_b:
   DEC zp_br_vy_x
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
SEG_HIGH
; (rot_select is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)
SEG_CODE
