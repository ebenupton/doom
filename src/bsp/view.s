
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
   ASL A
   ASL A
   ASL A                                   ; ft wants 8.8 scale: mag5 << 3
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
   ASL A
   ASL A
   ASL A                                   ; ft wants 8.8 scale: mag5 << 3
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
   ASL A
   ASL A
   ASL A                                   ; ft wants 8.8 scale: mag5 << 3
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
   ASL A
   ASL A
   ASL A                                   ; ft wants 8.8 scale: mag5 << 3
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

; --- fracs -> COUNTS (2026-08-10): fv_c = rns(fv_88, 3) per axis,
; in place. EXACT vs the mirror's ref_c = rns(rot_88 + fv_88, 3):
; rot_88 = 8*rot5 passes through the shift, so ref_c = rot5 +
; rns(fv_88, 3) identically. Sign-rotate with the fused round bit
; (the vq3 idiom); |fv| <= ~500 so the ripple INC can't overflow. ---
   LDA zp_br_fvx_h
   CMP #$80
   ROR A
   ROR zp_br_fvx_l
   CMP #$80
   ROR A
   ROR zp_br_fvx_l
   CMP #$80
   ROR A
   ROR zp_br_fvx_l
   STA zp_br_fvx_h
   LDA zp_br_fvx_l                         ; C = bit 2 = the round bit
   ADC #0
   STA zp_br_fvx_l
   BCC fq_x_ok
   INC zp_br_fvx_h
fq_x_ok:
   LDA zp_br_fvy_h
   CMP #$80
   ROR A
   ROR zp_br_fvy_l
   CMP #$80
   ROR A
   ROR zp_br_fvy_l
   CMP #$80
   ROR A
   ROR zp_br_fvy_l
   STA zp_br_fvy_h
   LDA zp_br_fvy_l
   ADC #0
   STA zp_br_fvy_l
   BCC fq_y_ok
   INC zp_br_fvy_h
fq_y_ok:

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
; --- ROT_CORE: the operand-paired rotate, ONE source TWO expansions
; (V16, 2026-08-09): the position path (br_to_view below — dy gets the
; py subtract) and the pure-vertex path (rot_w_signed — dy is wy
; verbatim; the base must be position-independent). The three JSR
; operands are per-expansion SMC sites: rot_select patches BOTH sets
; each frame (s13/s2/s4 and s13w/s2w/s4w).
.macro ROT_CORE s13, s2, s4, wmode
.local dx_ok, dy_ok
.if wmode = 0
; position path: d1's sign is dynamic (subtract) — abs-negate ladder
   BPL dx_ok
   INC zp_ri_sgn
   SEC
   LDA #0
   SBC zp_ri_d_l
   STA zp_ri_d_l
   LDA #0
   SBC zp_ri_d_h
   STA zp_ri_d_h
dx_ok:
.endif
; (pure path: |wx| + sign arrive PRE-RESOLVED from the sign-magnitude
;  planes — the caller staged zp_ri_d = |wx| and zp_ri_sgn; no ladder)
s13:
   JSR rot_gen_pair                        ; dx pair, ONE call (2026-07-19):
                                           ; sin*dx -> zp_rs, cos*dx ->
                                           ; zp_br_res, shared d==0 test.
                                           ; rot_select patches this site:
                                           ; gen+gen = the fused variant,
                                           ; else rot_pair_thunk (rare)
; (res->vy copy DELETED 2026-07-27: the fused pair writes vy directly
;  via rot_core_cosv_nz; the thunk adapts internally on rare frames)
   ZERO zp_ri_sgn
.if wmode
; pure path: wy is SIGN-MAGNITUDE from the packed planes — resolve the
; sign off the hi byte, no negate ladder
   LDA zp_br_dy_h
   BPL dy_ok                               ; bit 7 = sign
   INC zp_ri_sgn
   AND #$7F
dy_ok:
   STA zp_ri_d_h
   LDA zp_br_dy_l
   STA zp_ri_d_l
.else
; (off-by-one fix 2026-08-10: seed C from the py frac's borrow — the
; frac terms carry (0 - p_88) & 255, so the int part is
; -py_int - (frac != 0). See the dx twin above btv_dx_signed.)
   LDA #0
   SEC
   SBC zp_br_py                         ; C = (py frac == 0); result dead
   LDA zp_br_dy_l
   SBC zp_br_py_h
   STA zp_ri_d_l
   LDA zp_br_dy_h
   SBC zp_br_py_x
   STA zp_ri_d_h
   BPL dy_ok
   INC zp_ri_sgn
   SEC
   LDA #0
   SBC zp_ri_d_l
   STA zp_ri_d_l
   LDA #0
   SBC zp_ri_d_h
   STA zp_ri_d_h
dy_ok:
.endif
s2:
   JSR rot_gen_cos                         ; d2*cos -> zp_br_res
; vx = d1*sin - d2*cos, straight from the two result slots (rs still
; holds s1's product — s3 wrote zp_br_res and s2 overwrote it, neither
; touches rs). COUNT-NATIVE (2026-08-10): products are s16 counts
; (mag5 operands) — the sums ARE the s16 count outputs, no quantize.
   LDA zp_rs_l
   SEC
   SBC zp_br_res_l
   STA zp_br_vx_l
   LDA zp_rs_h
   SBC zp_br_res_h
   STA zp_br_vx_h
s4:
   JSR rot_gen_sin                         ; d2*sin -> zp_rs
   LDA zp_br_vy_l
   CLC
   ADC zp_rs_l
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ADC zp_rs_h
   STA zp_br_vy_h
.endmacro

; (V16Q retired same-day: the quantize fused into rot_w_signed as
;  (v+2) & ~3 — see there.)

   ZERO zp_ri_sgn
; OFF-BY-ONE FIX (2026-08-10): the frac terms are (0 - p_88) & 255 —
; the low byte of the FULL negate — so this integer subtract must take
; the low byte's BORROW (C = 0 iff px frac != 0): the int part of
; -p_88 is -px_int - 1 whenever the frac is nonzero. The old SEC seed
; rendered from a viewpoint one unit off per fractional axis, snapping
; at integer crossings (Eben's quantised-jumping report; fp mirror
; fixed identically in fp_view_context).
   LDA #0
   SEC
   SBC zp_br_px                         ; C = (px frac == 0); result dead
   LDA zp_br_dx_l
   SBC zp_br_px_h
   STA zp_ri_d_l
   LDA zp_br_dx_h
   SBC zp_br_px_x
   STA zp_ri_d_h
btv_dx_signed:                          ; N = delta sign (internal only
                                        ; since V16 — the vertex fetch
                                        ; goes to rot_w_signed)
   ROT_CORE rot_s13, rot_s2, rot_s4, 0
   RTS                                  ; s16 COUNTS out (2026-08-10);
                                        ; the caller (vxc_frame) adds the
                                        ; pre-quantized count fracs —
                                        ; tv_add_fracs DIED with the 8.8
                                        ; position path

; (tv_add_fracs DELETED 2026-08-10 — count-native position path:
;  vxc_frame adds the pre-quantized s16 count fracs itself.)

; ============================================================================
; rot_w_signed — V16 pure-vertex rotate + q64 (2026-08-09).
;   In:  zp_ri_d_l/h = wx (N staged by the caller's last load),
;        zp_br_dy_l/h = wy, zp_ri_sgn zeroed.
;   Out: zp_br_vx_l/h, zp_br_vy_l/h = the s16 COUNT base rot5(w)
;        (1/32 unit, EXACT — 5-bit mag5 operands, no rounding stage).
;        Position-independent: NO py subtract, NO frac terms — those
;        live entirely in vxc_ref (= rot(-p_int) + fracs, staged once
;        per frame). total := (base16 << 2) + ref at the callers' join.
;   Callers: seg_xform vfoff + vxcon cold arms (both sides).
; ============================================================================
; (vxq_shr2 / vxq_shl2 deleted 2026-08-10 — TRUE16: the planes store
;  counts, which ARE the working form; the birth shift dance died.)

; ============================================================================
; rot_w_signed — REGISTER ABI (Eben, 2026-08-09): the wx operand
; arrives in registers and the sign-magnitude resolve lives HERE, once,
; instead of at every fetch site (it was expanded 6x):
;   A = VP_XHI raw (bit 7 = sign, low 7 = |wx| hi), X = VP_XLO,
;   N = A's sign — callers ride the VP_XHI load's flags through the
;   JSR (JSR/JMP/STX are flag-transparent; nothing may intervene).
; wy stays zp-staged (zp_br_dy_l/h): Y is the plane index until the
; last load, so no register is left to carry it — and ROT_CORE resolves
; wy internally between the mul pairs anyway (the old caller-side wx /
; core-side wy asymmetry was forced by the shared zp_ri_d mul slot:
; wx occupies it during s13. This prologue keeps that slot discipline —
; it IS the old call-site ladder, relocated).
rot_w_signed:
   STX zp_ri_d_l                           ; (STX: flags untouched)
   BPL rws_pos                             ; N = wx sign (caller's load)
   AND #$7F
   STA zp_ri_d_h
   LDA #1
   STA zp_ri_sgn
   BNE rws_go                              ; (A = 1: always)
rws_pos:
   STA zp_ri_d_h
   ZERO zp_ri_sgn
rws_go:
   ROT_CORE rot_s13w, rot_s2w, rot_s4w, 1
; COUNT-NATIVE (2026-08-10, 5-bit trig): the cores multiply |d| x mag5
; so the ROT_CORE sums land as s16 view counts DIRECTLY — the RN>>3
; quantize tail died (rot5(w) == rns(rot_88(w), 3) exactly: 8.8 mags
; are multiples of 8). Python: rns(rot_88, 3) in fp_to_view_totals_t16
; over the quantized table — bit-identical.
   RTS

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
