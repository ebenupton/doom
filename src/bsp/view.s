
; ============================================================================
; br_view_setup — compute frac_vx, frac_vy for the current frame.
;
;   Inputs (zp):  zp_br_px (s16), zp_br_py (s16),
;                 zp_br_smag, zp_br_sneg, zp_br_sone,
;                 zp_br_cmag, zp_br_cneg, zp_br_cone.
;   Outputs (zp): zp_br_fvxlo/hi, zp_br_fvylo/hi (each s16).
;
;   Python:
;     dx_lo = (-vx_88) & 0xFF
;     dy_lo = (-vy_88) & 0xFF
;     frac_vx = ft(dx_lo, sin) - ft(dy_lo, cos)
;     frac_vy = ft(dx_lo, cos) + ft(dy_lo, sin)
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
PAGE BANK_L2
JSR jt_bca_frame
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
; ============================================================================
br_to_view:
.scope
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
LDA zp_br_dxlo
STA zp_ri_dlo
LDA zp_br_dxhi
STA zp_ri_dhi
LDY #0
JSR br_rot_int
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
LDY #3
JSR br_rot_int
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
LDY #3
JSR br_rot_int
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
LDY #0
JSR br_rot_int
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

JMP tv_add_fracs
.endscope

; tv_add_fracs — add the per-frame fractional rotation terms (s16,
; sign-extended) to the s24 vx/vy accumulators. Shared by br_to_view and
; the bbox corner combine.
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
;   Output:  zp_br_resl/h (s16).
; ============================================================================
br_smul_s8_u8:
.scope
; Split positive/negative paths up front: no sign flag, no |a|
; writeback, single result copy (negative path negates during copy).
LDA zp_br_b
STA zp_mul_b
LDA zp_br_a
BMI a_neg
; --- inlined umul8(A, mag) — 56% of all umul8 calls go through here ---
STA zp_tmp0
SEC
SBC zp_mul_b
BCS up_pos
EOR #$FF
ADC #1
up_pos:
TAY
LDA zp_tmp0
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
STA zp_tmp0
SEC
SBC zp_mul_b
BCS un_pos
EOR #$FF
ADC #1
un_pos:
TAY
LDA zp_tmp0
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

; ============================================================================
; HELPER: br_smul_s8_s16 — signed s8 × signed s16 → s16 (low 16 bits of s24).
;   Inputs:  zp_br_a (s8), zp_br_dxlo:dxhi (s16).
;   Output:  zp_br_resl/h (s16).
;
;   For our scene products fit in s16; for larger ones the high bits are

; (banked MAIN is fatter — PAGE emits code — and hit its $5800 ceiling;
;  this PAGE-free leaf relocates to the banked W region ($3900, 221 free;
;  D_BK is bounded at $40 by anim_drv at $3C00 — learned the hard way). Flat
;  placement unchanged.)
.if ::BANKED
.segment "W_BK"
.endif
;   silently dropped. Used by the back-face test where we only need sign.
; ============================================================================
br_smul_s8_s16:
.scope
ZERO zp_br_sign

; |a|
LDA zp_br_a
BPL a_pos
EOR #$FF
BUMP
STA zp_br_a
INC zp_br_sign
a_pos:

; |dx|, store as zp_br_t0 (lo), zp_br_t1 (hi)
LDA zp_br_dxlo
STA zp_br_t0
LDA zp_br_dxhi
STA zp_br_t1
BPL b_pos
LDA #0
SEC
SBC zp_br_t0
STA zp_br_t0
LDA #0
SBC zp_br_t1
STA zp_br_t1
LDA zp_br_sign
EOR #1
STA zp_br_sign
b_pos:

; |a| * t0 (u8 × u8 → u16) — low part of u8 * u16
LDA zp_br_t0
STA zp_mul_b
LDA zp_br_a
JSR SC_UMUL8
LDA zp_prod_lo
STA zp_br_resl
LDA zp_prod_hi
STA zp_br_resh

; |a| * t1 (u8 × u8 → u16) — high byte of result; only the low byte of
; this product contributes to the s16 result's high byte.
LDA zp_br_t1
STA zp_mul_b
LDA zp_br_a
JSR SC_UMUL8
LDA zp_br_resh
CLC
ADC zp_prod_lo
STA zp_br_resh

; Apply sign
LDA zp_br_sign
BEQ ss_pos
LDA #0
SEC
SBC zp_br_resl
STA zp_br_resl
LDA #0
SBC zp_br_resh
STA zp_br_resh
ss_pos:
RTS
.endscope
.if ::BANKED
.segment "MAIN"
.endif


; ============================================================================
; HELPER: br_smul_s16_s16_s32 — signed s16 × s16 → s32 (4-byte little-endian).
;   Inputs:  zp_br_dxlo:dxhi (A, s16), zp_br_dylo:dyhi (B, s16).
;   Output:  zp_br_t0:t1:t2:t3 (s32).
;   Clobbers: zp_br_dxlo:dxhi, zp_br_dylo:dyhi (negated for sign tracking).
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
LDA zp_prod_lo
STA zp_br_t0
LDA zp_prod_hi
STA zp_br_t1

; ah × bh → t2:t3
LDA zp_br_dxhi
STA zp_mul_b
LDA zp_br_dyhi
JSR SC_UMUL8
LDA zp_prod_lo
STA zp_br_t2
LDA zp_prod_hi
STA zp_br_t3

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
