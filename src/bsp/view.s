
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
s4:
   JSR rot_gen_sin                         ; d2*sin -> zp_rs
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

; ============================================================================
; rot_w_signed — V16 pure-vertex rotate + q64 (2026-08-09).
;   In:  zp_ri_d_l/h = wx (N staged by the caller's last load),
;        zp_br_dy_l/h = wy, zp_ri_sgn zeroed.
;   Out: zp_br_vx_l/h, zp_br_vy_l/h = base16 = ((rot(w) + 2) >> 2), the
;        RN 1/64-unit s16 base (ext bytes dead — range-proved s16).
;        Position-independent: NO py subtract, NO frac terms — those
;        live entirely in vxc_ref (= rot(-p_int) + fracs, staged once
;        per frame). total := (base16 << 2) + ref at the callers' join.
;   Callers: seg_xform vfoff + vxcon cold arms (both sides).
; ============================================================================
; vxq_shr2 / vxq_shl2 — V16 cold-store shift pair (side-independent,
; shared by both SXV sides; cold arc only — once per vertex per angle
; epoch). >>2 takes the widened-masked s24 base to its s16 stored form
; (exact: low 2 bits are 0); <<2 restores it for the ref add.
; ============================================================================
vxq_shr2:
   LDA zp_br_vx_x
   CMP #$80
   ROR zp_br_vx_x
   ROR zp_br_vx_h
   ROR zp_br_vx_l
   LDA zp_br_vx_x
   CMP #$80
   ROR zp_br_vx_x
   ROR zp_br_vx_h
   ROR zp_br_vx_l
   LDA zp_br_vy_x
   CMP #$80
   ROR zp_br_vy_x
   ROR zp_br_vy_h
   ROR zp_br_vy_l
   LDA zp_br_vy_x
   CMP #$80
   ROR zp_br_vy_x
   ROR zp_br_vy_h
   ROR zp_br_vy_l
   RTS
vxq_shl2:
   ASL zp_br_vx_l
   ROL zp_br_vx_h
   ROL zp_br_vx_x
   ASL zp_br_vx_l
   ROL zp_br_vx_h
   ROL zp_br_vx_x
   ASL zp_br_vy_l
   ROL zp_br_vy_h
   ROL zp_br_vy_x
   ASL zp_br_vy_l
   ROL zp_br_vy_h
   ROL zp_br_vy_x
   RTS

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
; RN-quantize FUSED with the widen (2026-08-09 round 2): the consumer
; adds widen(q64(v)) = ((v+2)>>2)<<2 = (v+2) & ~3 — a ripple +2 and one
; AND, NO shifts. The s24 slots exit holding the widened quantized base
; (low 2 bits zero, ext byte LIVE); only the cold store pays a real
; shift pair (>>2 to the s16 planes, <<2 back — exact: low bits are 0).
; RARE-RIPPLE RN (claw-back, 2026-08-09): the +2 only carries out of
; the lo byte when lo >= $FE — the hi/ext ADC #0 chains become a
; branch-guarded stub (bit-identical; the stub re-seeds C=0 for the
; next axis / exit). Common path: 15 cyc/axis vs 28.
   CLC
   LDA zp_br_vx_l
   ADC #2
   AND #$FC
   STA zp_br_vx_l
   BCS vq_xrip
vq_x_done:
   LDA zp_br_vy_l                          ; C = 0 (BCC arc / stub CLC)
   ADC #2
   AND #$FC
   STA zp_br_vy_l
   BCS vq_yrip
   RTS
vq_xrip:
   INC zp_br_vx_h                          ; (INC leaves C — cleared below)
   BNE vq_xr1
   INC zp_br_vx_x
vq_xr1:
   CLC
   BCC vq_x_done                           ; (always)
vq_yrip:
   INC zp_br_vy_h
   BNE vq_yr1
   INC zp_br_vy_x
vq_yr1:
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
