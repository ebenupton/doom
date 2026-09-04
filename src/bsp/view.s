
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
   STA bca_afn+1                                 ; corner_phi emits r = phi+512
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
   STA bca_afn                                 ; low nibble of ab<<4 is empty, so
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
   STA bca_pxs
   LDA zp_br_px_x
   EOR #$80
   STA bca_pxs+1
   LDA zp_br_py_h
   STA bca_pys
   LDA zp_br_py_x
   EOR #$80
   STA bca_pys+1
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
                                        ; (JSR bca_frame -- the rcache epoch
                                        ; keeper -- died 2026-09-04 with the
                                        ; extent cache.  The PAGE above stays
                                        ; for vxcache_frame below.)
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
; TP_WALK — one full-mag quarter-square product, BOTH sides single
; indexed loads (t16p2, 2026-09-01): sum side base = SQR_LO/HI + M
; (2-byte SMC), diff side base = SQR_LO/HI - M, which lands in the
; even-mirror pages for o < M — f is even and the 255-byte mirrors sit
; directly below each plane, so f(|o-M|) needs no abs staging for ANY
; M in 0..256.  Unity (M=256) rides the same body: the staged mag byte
; is M&255 = 0 and the sum-base hi bytes carry the +$100.  The mag5'
; fast products + eps correction pyramid (8 walks, 2 rns tails, SQD_H,
; rwsel_derive) died here — 4 wide walks + one 3-byte rns per axis
; measured 346 vs 472 cyc/call on the corpus call trace
; (tools/t16p_compare).
.macro TP_WALK ssl, sdl, ssh, sdh, dstl, dsth, first
ssl: LDA SQR_LO,X                          ; +2-byte SMC = SQR_LO + M
.if first
   SEC                                     ; walks 2-4 inherit C=1: the hi
.endif                                     ;  SBC never borrows out (product
sdl: SBC SQR_MIR_LO,X                      ;  >= 0 exactly)
   STA dstl                                ; lo-byte SMC = (SQR_LO-M) & $FF
ssh: LDA SQR_HI,X                          ;   (diff hi bytes CONSTANT)
sdh: SBC SQR_MIR_HI,X
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
; P1 = ox*Ms -> rs, P3 = ox*Mc -> rc1 (X shared),
; P2 = oy*Mc -> res, P4 = oy*Ms -> rc2 (X shared)
   LDX zp_ri_d_l
   TP_WALK ::rwp_s1l, ::rwp_d1l, ::rwp_s1h, ::rwp_d1h, zp_rs_l, zp_rs_h, 1
   TP_WALK ::rwp_s3l, ::rwp_d3l, ::rwp_s3h, ::rwp_d3h, zp_rc1_l, zp_rc1_h, 0
   LDX zp_br_dy_l
   TP_WALK ::rwp_s2l, ::rwp_d2l, ::rwp_s2h, ::rwp_d2h, zp_br_res_l, zp_br_res_h, 0
   TP_WALK ::rwp_s4l, ::rwp_d4l, ::rwp_s4h, ::rwp_d4h, zp_rc2_l, zp_rc2_h, 0
; x axis: S = 4 (+sin)P1 (-cos)P2 as 3 bytes (the #4 seed pre-adds the
; rns round bias; byte2 is carries/borrows only, stashed in Y), then a
; 3-byte floor >>3 and the PB fold.  Sign ops are the SMC pairs
; rot_select pokes; the byte2 ops (o*b) are ADC#0/SBC#0 twins.
   LDA #4
::rwp_o1s:
   CLC                                     ; SMC: sin sign
::rwp_o1l:
   ADC zp_rs_l
   STA zp_rws_l
   LDA #0
::rwp_o1h:
   ADC zp_rs_h
   STA zp_rws_m
   LDA #0
::rwp_o1b:
   ADC #0                                  ; SMC: $69/$E9 follows o1l
   TAY
   LDA zp_rws_l
::rwp_o2s:
   SEC                                     ; SMC: NOT cos sign
::rwp_o2l:
   SBC zp_br_res_l
   STA zp_rws_l
   LDA zp_rws_m
::rwp_o2h:
   SBC zp_br_res_h
   STA zp_rws_m
   TYA
::rwp_o2b:
   SBC #0                                  ; SMC: follows o2l
; S>>3 by table compose (SHR3/SHL5, page-aligned $5600/$5700): result
; is exact mod 2^16 -- the true vx-PB fits s16, so byte2's bits beyond
; <<5 truncate away.  26 cyc/axis vs the 42-cyc triple-ROR ladder.
   TAY                                     ; Y = byte2
   LDX zp_rws_m
   LDA SHR3,X
   ORA SHL5,Y
   TAY                                     ; Y = result mid
   LDA SHL5,X                              ; (X still = mid)
   LDX zp_rws_l
   ORA SHR3,X                              ; A = result lo
   LDX zp_ri_d_h                           ; page nibble
   CLC
   ADC PB_XL,X
   STA zp_br_vx_l
   TYA
   ADC PB_XH,X
   STA zp_br_vx_h
; y axis: S = 4 (+cos)P3 (+sin)P4 ; vy = PB_Y[pg] + S>>3 (X preserved)
   LDA #4
::rwp_o3s:
   CLC                                     ; SMC: cos sign
::rwp_o3l:
   ADC zp_rc1_l
   STA zp_rws_l
   LDA #0
::rwp_o3h:
   ADC zp_rc1_h
   STA zp_rws_m
   LDA #0
::rwp_o3b:
   ADC #0
   TAY
   LDA zp_rws_l
::rwp_o4s:
   CLC                                     ; SMC: sin sign
::rwp_o4l:
   ADC zp_rc2_l
   STA zp_rws_l
   LDA zp_rws_m
::rwp_o4h:
   ADC zp_rc2_h
   STA zp_rws_m
   TYA
::rwp_o4b:
   ADC #0
   TAY
   LDX zp_rws_m
   LDA SHR3,X
   ORA SHL5,Y
   TAY
   LDA SHL5,X
   LDX zp_rws_l
   ORA SHR3,X
   LDX zp_ri_d_h
   CLC
   ADC PB_YL,X
   STA zp_br_vy_l
   TYA
   ADC PB_YH,X
   STA zp_br_vy_h
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

.pushseg
.segment "RWC"
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

; ============================================================================
; SHR3 / SHL5 — the shift-compose tables for the rotate's 3-byte >>3
; (page-aligned so the abs,X/abs,Y reads never pay a crossing; static
; content, shipped, zero boot cost).
; ============================================================================
.pushseg
.segment "SHTAB"
.align 256
SHR3:
.repeat 256, i
   .byte i >> 3
.endrepeat
SHL5:
.repeat 256, i
   .byte (i << 5) & $FF
.endrepeat
.popseg
