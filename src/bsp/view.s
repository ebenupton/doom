
; ============================================================================
; view_setup — compute frac_vx, frac_vy for the current frame.
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
;                 per-frame vertex-cache mode chosen (vxcache_frame).
;   Clobbers: A, X, Y, zp_br_t2/t3, zp_ft_* staging, mul workspace.
;
;   Python:
;     dx_lo = (-vx_88) & 0xFF
;     dy_lo = (-vy_88) & 0xFF
;     frac_vx = ft(dx_lo, sin) - ft(dy_lo, cos)
;     frac_vy = ft(dx_lo, cos) + ft(dy_lo, sin)
;   where ft = _frac_rot_term: unity → lo; else (lo*mag + 128) >> 8, then
;   negate if trig negative (see frac_rot_term in arith.s).

view_setup:
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
   LDA zp_br_smag                          ; mag8 staged (2026-08-31): ft
   STA zp_ft_mag                           ; wants 8.8 scale, which it IS
   LDA zp_br_sneg
   STA zp_ft_neg
   LDA zp_br_sone
   STA zp_ft_one
   JSR frac_rot_term
   LDA zp_br_res_l
   STA zp_br_fvx_l
   LDA zp_br_res_h
   STA zp_br_fvx_h

   LDA zp_br_t3
   STA zp_ft_lo
   LDA zp_br_cmag                          ; mag8 staged (2026-08-31)
   STA zp_ft_mag
   LDA zp_br_cneg
   STA zp_ft_neg
   LDA zp_br_cone
   STA zp_ft_one
   JSR frac_rot_term
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
   LDA zp_br_cmag                          ; mag8 staged (2026-08-31)
   STA zp_ft_mag
   LDA zp_br_cneg
   STA zp_ft_neg
   LDA zp_br_cone
   STA zp_ft_one
   JSR frac_rot_term
   LDA zp_br_res_l
   STA zp_br_fvy_l
   LDA zp_br_res_h
   STA zp_br_fvy_h

   LDA zp_br_t3
   STA zp_ft_lo
   LDA zp_br_smag                          ; mag8 staged (2026-08-31): ft
   STA zp_ft_mag                           ; wants 8.8 scale, which it IS
   LDA zp_br_sneg
   STA zp_ft_neg
   LDA zp_br_sone
   STA zp_ft_one
   JSR frac_rot_term
   LDA zp_br_fvy_l
   CLC
   ADC zp_br_res_l
   STA zp_br_fvy_l
   LDA zp_br_fvy_h
   ADC zp_br_res_h
   STA zp_br_fvy_h

; --- fracs -> COUNTS: fv_c = rns(fv_88, 3) per axis, in place.  The
; mirror models THIS split exactly (2026-08-31, 8-bit trig restored):
; ref_c = rns(rot_88(N_int), 3) + rns(fv_88, 3) -- two roundings, both
; sides.  Sign-rotate with the fused round bit (the vq3 idiom);
; |fv| <= ~500 so the ripple INC can't overflow. ---
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
   PAGE BANK_WALK
   JSR bca_frame                           ; rcache epoch keeper (rcache.s);
                                           ; the D-cache classifier call is
                                           ; gone — D disabled 2026-07-20
   vxcache_frame                           ; translation-coherence vertex cache
   RTS
.endscope

; (VF_FETCH_ARM + the vf_plain0/1 standalone arms RETIRED 2026-08-09 —
;  the plain fetch lives inline in seg_xform.s SXV_BODY, both at the
;  vfoff vector target and in the vxcache_on cold arms; single callers all.)


; (br_to_view_fetch fully retired 2026-07-27 round 2: the vxcache cold
; arms JSR their side's vf_plain directly.)
.assert <ROM_VERTS_C = 0, error, "vertex planes assume page-aligned ROM_VERTS_C"


; (br_to_view + ROT_CORE + tv_add_fracs ALL DELETED 2026-08-11: the
;  position path rides rot_w_pages too — vxcache_frame decomposes
;  -p_int - (frac != 0) into the same page/offset form (the off-by-one
;  borrow seed lives THERE now), so ONE rotate body serves everything
;  and the fused-pair/variant/thunk machinery died with its sites.)

; ============================================================================
; rot_w_pages — PAGE-DECOMPOSED vertex rotate (Eben's concept,
; 2026-08-11): the stored vertex is an UNSIGNED u8 offset pair + a
; senior-bits nibble, and rot() is linear:
;     base_c = PB[page] + ox*rot(ex) + oy*rot(ey)
; The four products are unsigned u8 x mag5 quarter-squares, and their
; combine signs depend ONLY on the frame's trig signs (offsets are
; never negative): rot_select patches the four combine-op pairs
; (CLC/ADC <-> SEC/SBC, sites rwp_o*) once per frame and rebuilds the
; 16-entry page-base tables once per angle epoch. DEAD: the per-vertex
; sign ladders, the reg-ABI sign ride, the hi partials (seniors live
; in the tables), the d==0 tests, AND the unity/zero variant dispatch
; for this path — mag5 unity = 32 fits the u8 multiplier (sqr index
; <= 255+32, inside the 2-page tables) and zero mags multiply to
; genuine zeros. Overflow-safe: |PB| <= 24,576, each product <= 8,160,
; so no intermediate leaves s16 (max 32,736).
;   In:  zp_ri_d_l = ox, zp_br_dy_l = oy, zp_ri_d_h = page nibble.
;   Out: zp_br_vx_l/h, zp_br_vy_l/h = s16 count base (rot5(w) EXACT —
;        python fp_to_view_totals_t16 over the signed w, identical by
;        linearity; the mirror's math never changed).
;   Callers: seg_xform vxcache_on cold + vfoff (both sides), lo.s cr_plain.
;   Clobbers: A, X, Y, zp_rs_l/h, zp_br_res_l/h.
; ============================================================================
.macro RWP_MUL src, d1l, d1h, s1l, s1h, dstl, dsth
; product = f(x+m) - f(x-m), BOTH sides single indexed loads (Eben's
; <16 question flushed the |x-m| staging out; his reuse catch kept the
; LO table shared, 2026-08-11): the sum side keeps the page-aligned
; base+mag trick (1-byte poke). The diff LO side reads sqr_l ITSELF at
; base sqr_l-mag — f is even and the 32-byte SQR_MIRROR prefix sits
; directly below sqr_l, so negative differences land on mirrors; with
; mag in 1..32 the operand hi byte is CONSTANT (>sqr_l - 1): 1-byte
; poke. The diff HI side reads the dedicated SQD_H (sqr_h's prefix
; bytes are live sqr_l entries): 2-byte poke. The SBC/branch/negate/
; TAY staging died: ~-10 cyc/product. INVARIANT: the general body is
; never dispatched with mag 0 (rot_select's cardinal classes own
; those), so the borrow into the LO base's hi byte always happens.
   LDX src                                                                ;# |          1.4
s1l: LDA sqr_l,X                           ; +1 SMC = mag5 (base+mag trick) ;# ||         1.9
   SEC                                                                    ;# |          1.0
d1l: SBC sqr_l-1,X                         ; +1 SMC = (-mag5) & 255       ;# ||||       4.6
   STA dstl                                                               ;# |          1.4
s1h: LDA sqr_h,X                           ; +1 SMC = mag5                ;# |||        4.0
d1h: SBC SQD_H+32,X                        ; +1/+2 SMC = SQD_H+32-mag5    ;# |||||||    8.3
   STA dsth                                                               ;# |          1.4
.endmacro

; RWP_MULX -- RWP_MUL body with X pre-loaded (the interleaved corr muls
; share the fast mul's LDX; same src, different SMC bases/dst).
.macro RWP_MULX d1l, d1h, s1l, s1h, dstl, dsth
s1l: LDA sqr_l,X
   SEC
d1l: SBC sqr_l-1,X
   STA dstl
s1h: LDA sqr_h,X
d1h: SBC SQD_H+32,X
   STA dsth
.endmacro


; rwp_stamp — the SMC-validity stamp, IN THE CODE IMAGE (Eben's
; testbench-tax catch, 2026-08-11): assembled 0, written $A5 when
; rot_select applies the mag/sign/dispatch patches. Any flow that
; reloads the code image (harness setup_wad, a future loader) resets
; it to 0, so the epoch gate self-invalidates — no per-frame patching,
; no harness protocol, no stale-gate class.
rwp_stamp:
   .byte 0

rot_w_pages:
; P1 = ox*|sin| -> rs, P2 = oy*|cos| -> res
   RWP_MUL zp_ri_d_l, ::rwp_d1l, ::rwp_d1h, ::rwp_s1l, ::rwp_s1h, zp_rs_l, zp_rs_h
   RWP_MULX ::rwp_f1l, ::rwp_f1h, ::rwp_fs1l, ::rwp_fs1h, zp_rc1_l, zp_rc1_h
   RWP_MUL zp_br_dy_l, ::rwp_d2l, ::rwp_d2h, ::rwp_s2l, ::rwp_s2h, zp_br_res_l, zp_br_res_h
   RWP_MULX ::rwp_f2l, ::rwp_f2h, ::rwp_fs2l, ::rwp_fs2h, zp_rc2_l, zp_rc2_h ;# ||||||||||11.6
; vx = PB_X[page] (+sin)P1 (-cos)P2 — op pairs SMC'd per frame
   LDX zp_ri_d_h                           ; page nibble                  ;# |          1.4
   LDA PB_XL,X                                                            ;# ||         1.9
::rwp_o1s:
   CLC                                     ; SMC: CLC/SEC = sin sign      ;# |          1.0
::rwp_o1l:
   ADC zp_rs_l                             ; SMC: ADC/SBC zp              ;# |          1.4
   STA zp_br_vx_l                                                         ;# |          1.4
   LDA PB_XH,X                                                            ;# ||         1.9
::rwp_o1h:
   ADC zp_rs_h                                                            ;# |          1.4
   STA zp_br_vx_h                                                         ;# |          1.4
::rwp_o2s:
   SEC                                     ; SMC: SEC/CLC = NOT cos sign  ;# |          1.0
   LDA zp_br_vx_l                                                         ;# |          1.4
::rwp_o2l:
   SBC zp_br_res_l                         ; SMC: SBC/ADC zp              ;# |          1.4
   STA zp_br_vx_l                                                         ;# |          1.4
   LDA zp_br_vx_h                                                         ;# |          1.4
::rwp_o2h:
   SBC zp_br_res_h                                                        ;# |          1.4
   STA zp_br_vx_h                                                         ;# |          1.4
; --- FINE CORRECTIONS (2026-08-31, the smoothness fix).  The fast
; products use mag5' = (mag8-1)>>3; these four use eps = mag8 - 8*mag5'
; (1..8, so the RWP_MUL borrow invariant holds and unity = 31/8 rides
; the general body).  8*(mag5' products) + eps products == the full
; 8-bit-mag rotation, so after one rns(err,3) per axis the count totals
; are BIT-EQUAL to rns(rot88(w),3) on the restored table -- which is
; what re-staggers the per-vertex depth residues the 5-bit table had
; collapsed into whole-scene 4-unit lumps (the corridor jerk Eben
; bisected to TRIG5).  Signs ride the same patched op-pair scheme
; (rwp_g*, copied from the o-sites at epoch patch), seeded from 0.
; Fused err combine + rns(,3) + fold, per axis.  The #4 seed pre-adds the
; round bias (rns(e,3) == floor((e+4)/8), ties up), so the shift is a pure
; floor and the fused-round carry tail dies; hi rides A end-to-end and the
; fold writes the axis slots directly.  Signs are the same patched op
; pairs (rwp_g*) rot_select already pokes -- operands unchanged.
   LDA #4
::rwp_g1s:
   CLC                                     ; SMC: sin sign (as rwp_o1s)
::rwp_g1l:
   ADC zp_rc1_l
   STA zp_rs_l                             ; lo(err_x + 4) part 1
   LDA #0
::rwp_g1h:
   ADC zp_rc1_h                            ; hi rides A
   TAY
   LDA zp_rs_l
::rwp_g2s:
   SEC                                     ; SMC: NOT cos sign (as rwp_o2s)
::rwp_g2l:
   SBC zp_rc2_l
   STA zp_rs_l
   TYA
::rwp_g2h:
   SBC zp_rc2_h                            ; A:zp_rs_l = err_x + 4
   CMP #$80
   ROR A
   ROR zp_rs_l
   CMP #$80
   ROR A
   ROR zp_rs_l
   CMP #$80
   ROR A
   TAY                                     ; hi(rns) -> Y (C untouched)
   ROR zp_rs_l
   CLC
   LDA zp_br_vx_l
   ADC zp_rs_l
   STA zp_br_vx_l
   TYA
   ADC zp_br_vx_h
   STA zp_br_vx_h                          ; vx += rns(err_x, 3)
; P3 = ox*|cos| -> rs, P4 = oy*|sin| -> res
   RWP_MUL zp_ri_d_l, ::rwp_d3l, ::rwp_d3h, ::rwp_s3l, ::rwp_s3h, zp_rs_l, zp_rs_h ;# ||||||||||11.5
   RWP_MULX ::rwp_f3l, ::rwp_f3h, ::rwp_fs3l, ::rwp_fs3h, zp_rc1_l, zp_rc1_h
   RWP_MUL zp_br_dy_l, ::rwp_d4l, ::rwp_d4h, ::rwp_s4l, ::rwp_s4h, zp_br_res_l, zp_br_res_h ;# ||||||     7.2
   RWP_MULX ::rwp_f4l, ::rwp_f4h, ::rwp_fs4l, ::rwp_fs4h, zp_rc2_l, zp_rc2_h
; vy = PB_Y[page] (+cos)P3 (+sin)P4
   LDX zp_ri_d_h                                                          ;# |          1.4
   LDA PB_YL,X                                                            ;# ||         1.9
::rwp_o3s:
   CLC                                     ; SMC: CLC/SEC = cos sign      ;# |          1.0
::rwp_o3l:
   ADC zp_rs_l                                                            ;# |          1.4
   STA zp_br_vy_l                                                         ;# |          1.4
   LDA PB_YH,X                                                            ;# ||         1.9
::rwp_o3h:
   ADC zp_rs_h                                                            ;# |          1.4
   STA zp_br_vy_h                                                         ;# |          1.4
::rwp_o4s:
   CLC                                     ; SMC: CLC/SEC = sin sign      ;# |          1.0
   LDA zp_br_vy_l                                                         ;# |          1.4
::rwp_o4l:
   ADC zp_br_res_l                                                        ;# |          1.4
   STA zp_br_vy_l                                                         ;# |          1.4
   LDA zp_br_vy_h                                                         ;# |          1.4
::rwp_o4h:
   ADC zp_br_res_h                                                        ;# |          1.4
   STA zp_br_vy_h                                                         ;# |          1.4
   LDA #4
::rwp_g3s:
   CLC                                     ; SMC: cos sign (as rwp_o3s)
::rwp_g3l:
   ADC zp_rc1_l
   STA zp_rs_l
   LDA #0
::rwp_g3h:
   ADC zp_rc1_h
   TAY
   LDA zp_rs_l
::rwp_g4s:
   CLC                                     ; SMC: sin sign (as rwp_o4s)
::rwp_g4l:
   ADC zp_rc2_l
   STA zp_rs_l
   TYA
::rwp_g4h:
   ADC zp_rc2_h                            ; A:zp_rs_l = err_y + 4
   CMP #$80
   ROR A
   ROR zp_rs_l
   CMP #$80
   ROR A
   ROR zp_rs_l
   CMP #$80
   ROR A
   TAY
   ROR zp_rs_l
   CLC
   LDA zp_br_vy_l
   ADC zp_rs_l
   STA zp_br_vy_l
   TYA
   ADC zp_br_vy_h
   STA zp_br_vy_h                          ; vy += rns(err_y, 3)
   RTS


; ============================================================================
; rwp_card_su / rwp_card_cu — CARDINAL-frame twins of rot_w_pages
; (Eben's mid-flight catch, 2026-08-11: a full quarter-square mul by 0
; or by unity-32 throws the fast frames away). At mag5 scale a
; cardinal epoch is EXACTLY "one trig zero, the other unity", so
; rot_select patches the five rot-w JSR sites to one of the three
; bodies per epoch and the zero muls never execute:
;   sin = +-32, cos = 0 (ab 64/192):  vx = PB_X +-s ox<<5,
;                                     vy = PB_Y +-s oy<<5
;   cos = +-32, sin = 0 (ab 0/128):   vx = PB_X -+c oy<<5,
;                                     vy = PB_Y +-c ox<<5
; The <<5 is the nibble splice (u8 -> u13); the combine signs ride the
; same SMC op-pair scheme (sites rwc_*), patched at epoch build.
; ============================================================================
.macro RWP_SHL5 src
   LDA src
   LSR A
   LSR A
   LSR A
   STA zp_rs_h                             ; src >> 3
   LDA src
   ASL A
   ASL A
   ASL A
   ASL A
   ASL A
   STA zp_rs_l                             ; (src << 5) & FF
.endmacro

.macro RWP_CARD a1, a2, o1s, o1l, o1h, o2s, o2l, o2h
   RWP_SHL5 a1
   LDX zp_ri_d_h                           ; page nibble
   LDA PB_XL,X
o1s: CLC                                   ; SMC: sign op pair
o1l: ADC zp_rs_l
   STA zp_br_vx_l
   LDA PB_XH,X
o1h: ADC zp_rs_h
   STA zp_br_vx_h
   RWP_SHL5 a2
   LDA PB_YL,X
o2s: CLC                                   ; SMC: sign op pair
o2l: ADC zp_rs_l
   STA zp_br_vy_l
   LDA PB_YH,X
o2h: ADC zp_rs_h
   STA zp_br_vy_h
   RTS
.endmacro

.pushseg
.segment "RWCARD"
rwp_card_su:                               ; sin unity: vx from ox, vy from oy
   RWP_CARD zp_ri_d_l, zp_br_dy_l, ::rwc_s1s, ::rwc_s1l, ::rwc_s1h, ::rwc_s2s, ::rwc_s2l, ::rwc_s2h
rwp_card_cu:                               ; cos unity: vx from -oy, vy from ox
   RWP_CARD zp_br_dy_l, zp_ri_d_l, ::rwc_c1s, ::rwc_c1l, ::rwc_c1h, ::rwc_c2s, ::rwc_c2l, ::rwc_c2h
.popseg

; rwp_contrib — one 4-entry epoch contrib table T[k] = (k-2)*V,
; signed, V 16-BIT (2026-08-31: V = mag8<<5 counts, full 8-bit trig).
; In: zp_rs_l/h = V, X = neg flag, Y = dest offset (0 = PB_TS,
; 8 = PB_TC). Entries interleaved lo,hi at dest + k*2:
;   T[2] = 0, T[3] = +V, T[1] = -V, T[0] = -2V, all negated when
; X != 0.  V <= $2000, so 2V <= $4000: s16 throughout.
.include "sqd.inc"
; (the 2026-08-25 bank-7 eviction of SQD_H was REVERTED the same day:
;  the VXCACHE fat paths execute FROM bank C and ride rot_w_pages, so the
;  table must be in ALWAYS-MAPPED main — the far-pose banked frames
;  collapsed to a third of their lines. bankedcmp caught it.)

.pushseg
.segment "RWC"
; rwsel_derive — the per-axis mag decomposition (rot_select calls it
; twice).  A = staged mag8 (0 encodes unity-256; the mod-256 arithmetic
; gives mag5' 31 / eps 8 there by construction).
;   Out: zp_br_t2 = mag5' = (mag8-1)>>3, zp_br_t3 = eps = mag8 - 8*mag5'
;        zp_rs_l = (-mag5')&255, zp_rs_h = (-eps)&255
;        Y = >sqr_l - (mag5' >= 1)   (the diff-LO base hi byte)
rwsel_derive:
   STA zp_rs_h                             ; stash mag8
   SEC
   SBC #1
   LSR A
   LSR A
   LSR A
   STA zp_br_t2                            ; mag5'
   TAX
   ASL A
   ASL A
   ASL A
   STA zp_br_t3                            ; 8*mag5'
   LDA zp_rs_h
   SEC
   SBC zp_br_t3
   STA zp_br_t3                            ; eps (1..8)
   LDA #0
   SEC
   SBC zp_br_t2
   STA zp_rs_l                             ; (-mag5') & 255
   LDA #0
   SEC
   SBC zp_br_t3
   STA zp_rs_h                             ; (-eps) & 255
   LDY #>sqr_l
   CPX #0
   BEQ :+
   LDY #>sqr_l - 1
:  RTS

rwp_contrib:
.scope
   LDA #0
   STA PB_TS+4,Y                           ; T[2] = 0
   STA PB_TS+5,Y
   ; nv = -V (16-bit)
   SEC
   SBC zp_rs_l
   STA zp_br_t2                            ; nv lo
   LDA #0
   SBC zp_rs_h
   STA zp_br_t3                            ; nv hi
   CPX #0
   BNE negged
   ; positive trig: T[3] = +V, T[1] = -V, T[0] = -2V
   LDA zp_rs_l
   STA PB_TS+6,Y
   LDA zp_rs_h
   STA PB_TS+7,Y
   LDA zp_br_t3
   STA PB_TS+3,Y                           ; T[1] hi
   LDA zp_br_t2
   STA PB_TS+2,Y                           ; T[1] lo
   ASL A                                   ; -2V = 2*(-V) (s16 shift)
   STA PB_TS+0,Y
   LDA zp_br_t3
   ROL A
   STA PB_TS+1,Y
   RTS
negged:
   ; negative trig: T[3] = -V, T[1] = +V, T[0] = +2V
   LDA zp_br_t2
   STA PB_TS+6,Y
   LDA zp_br_t3
   STA PB_TS+7,Y
   LDA zp_rs_h
   STA PB_TS+3,Y                           ; T[1] hi
   LDA zp_rs_l
   STA PB_TS+2,Y                           ; T[1] lo
   ASL A
   STA PB_TS+0,Y
   LDA zp_rs_h
   ROL A
   STA PB_TS+1,Y
   RTS
.endscope
.popseg

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
; frame from view_setup with bank C paged; every store below targets
; resident MAIN, so bank state only matters for FETCHING this code.
;   sin -> rot_s1/rot_s4, cos -> rot_s2/rot_s3. General thunks get the
;   frame's mag/neg poked into their immediates (offsets +1 / +5).
; Clobbers A, X.
; ============================================================================
SEG_HIGH
; (rot_select is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)
SEG_CODE
