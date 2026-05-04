; bsp_render.asm — fresh 6502 BSP traversal + vertex transform + seg
; projection. Feeds lines into the existing s16 clipper / DCL pipeline
; in span_clip.asm.
;
; Builds standalone (its own .bin) but calls into span_clip via the
; published jump-table entries:
;   $2021  umul8       (u8 × u8 → u16, quarter-square table)
;   $2024  udiv16_8    (u16 ÷ u8 → u8 quotient)
;   $201E  draw_clipped_line_s16  (s16 line → DCL)
;   $200C  span_is_full
;   $2009  span_has_gap
;   $2003  span_mark_solid
;   $2006  span_tighten      (legacy; records mode dispatches differently)
;   $201B  tighten_from_records

ORG $4800

; ============================================================================
; ZP layout (kept tight to avoid colliding with span_clip's $A0-$FF)
; We use $00-$3F (free in py65 sim; on real BBC OS this would need rework
; but the priority right now is correctness, not portability).
;
; Note: umul8 needs $D9 (zp_mul_b) and uses $DA/$DB for product.
; udiv16_8 needs zp_div_lo:hi ($DA:DB), zp_div_den ($DC).
; Both are clobbered across calls — bsp_render saves any zp data it
; needs across these calls into the BR_* slots below.
; ============================================================================

; Per-frame view-context (Python wrapper writes once per frame)
zp_br_px        = $00       ; s16 player x_88 (8.8 fixed)
zp_br_px_h      = $01
zp_br_py        = $02
zp_br_py_h      = $03
zp_br_vz        = $04       ; s8 eye-height (prescaled)
zp_br_smag      = $05       ; u8 sin magnitude
zp_br_sneg      = $06       ; 1 if sin negative
zp_br_sone      = $07       ; 1 if |sin| == 1
zp_br_cmag      = $08
zp_br_cneg      = $09
zp_br_cone      = $0A
zp_br_fvxlo     = $0B       ; s16 frac_vx (0.8 contribution)
zp_br_fvxhi     = $0C
zp_br_fvylo     = $0D
zp_br_fvyhi     = $0E

; Per-vertex working state — dx/dy widened to s16 (vertex range can
; exceed s8 after prescale; e.g. ±400 in our test scene).
zp_br_dxlo      = $0F
zp_br_dxhi      = $35
zp_br_dylo      = $10
zp_br_dyhi      = $36
zp_br_vxlo      = $11
zp_br_vxhi      = $12
zp_br_vylo      = $13
zp_br_vyhi      = $14
zp_br_dx        = zp_br_dxlo  ; alias for the lo byte (backwards-compat)
zp_br_dy        = zp_br_dylo

; Multiply / divide / sign workspace
zp_br_a         = $15       ; multiplicand A (s8 input)
zp_br_b         = $16       ; multiplicand B
zp_br_resl      = $17       ; s16 result lo
zp_br_resh      = $18       ; s16 result hi
zp_br_sign      = $19       ; 0 = positive, non-0 = negative

; Reciprocal output
zp_br_rhi       = $1A       ; u8 hi of reciprocal
zp_br_rlo       = $1B       ; u8 lo

; Pointer (used by indirect-Y reads of ROM/RAM)
zp_br_p         = $1C
zp_br_p_h       = $1D

; Generic temps
zp_br_t0        = $20
zp_br_t1        = $21
zp_br_t2        = $22
zp_br_t3        = $23

; ============================================================================
; Memory map (RAM caches + ROM tables — Python wrapper places data here)
; ============================================================================
RECIP_BASE      = $E000     ; base of recip table (HI bytes first, then LO)
                            ; HI[0..513] at $E000-$E201
                            ; LO[0..513] at $E202-$E403
SINCOS_BASE     = $E480     ; sin_mag[0..63], sin_unity[0..63] (128 bytes)

; ============================================================================
; Jump-table entries (Python wrapper JSRs to these fixed addresses)
; ============================================================================
JMP br_umul8        ; $4800 + 0  = $4800   wraps span_clip's umul8 for testing
JMP br_smul8        ; $4803   signed s8 × s8 → s16
JMP br_recip        ; $4806   reciprocal lookup
JMP br_view_setup   ; $4809   compute frac_vx/frac_vy
JMP br_to_view      ; $480C   world (zp_br_dx/dy_input) → view (zp_br_vxlo..vyhi)
JMP br_project_x    ; $480F   view vx → screen sx
JMP br_project_y    ; $4812   height_delta → screen sy
JMP br_render_frame ; $4815   walk BSP, dispatch subsector renderer

; ============================================================================
; Aliases for span_clip's exported routines
; ============================================================================
SC_UMUL8        = $2021
SC_UDIV16_8     = $2024
SC_DRAW_S16     = $201E
SC_DRAW_U8      = $2015      ; standalone DCL (u8 input, no clipper prelude)

; And span_clip's ZP slots that umul8/udiv16_8 use
zp_mul_b        = $D9
zp_prod_lo      = $DA
zp_prod_hi      = $DB
zp_div_lo       = $DA
zp_div_hi       = $DB
zp_div_den      = $DC

; span_clip's line ZP (also LC_X*_LO aliases for the s16 clipper)
zp_line_xl      = $A8
zp_line_yl      = $A9
zp_line_xr      = $AA
zp_line_yr      = $AB

; ============================================================================
; br_umul8 — wraps span_clip's umul8 for testing. Inputs in zp_br_a, zp_br_b.
; Result in zp_br_resl/resh. ~50 cycles.
; ============================================================================
.br_umul8
    LDA zp_br_b : STA zp_mul_b
    LDA zp_br_a
    JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh
    RTS

; ============================================================================
; br_smul8 — signed s8 × s8 → s16. Inputs in zp_br_a, zp_br_b.
; Result in zp_br_resl/resh (s16, 2's complement). ~80 cycles.
; ============================================================================
.br_smul8
{
    LDA #0 : STA zp_br_sign
    ; |a|, track sign
    LDA zp_br_a : BPL a_pos
    EOR #$FF : CLC : ADC #1 : STA zp_br_a
    INC zp_br_sign
.a_pos
    LDA zp_br_b : BPL b_pos
    EOR #$FF : CLC : ADC #1 : STA zp_br_b
    LDA zp_br_sign : EOR #1 : STA zp_br_sign
.b_pos
    LDA zp_br_b : STA zp_mul_b
    LDA zp_br_a
    JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh
    LDA zp_br_sign : BEQ pos
    ; Negate s16 result
    LDA #0 : SEC : SBC zp_br_resl : STA zp_br_resl
    LDA #0 : SBC zp_br_resh        : STA zp_br_resh
.pos
    RTS
}

; ============================================================================
; br_recip — reciprocal lookup with 1-bit-fractional averaging.
;   Input:  zp_br_t0:t1 = u16 vy_idx (9.1 format).
;   Output: zp_br_rhi, zp_br_rlo.
;
; Algorithm:
;   vy_idx clamped to [2, 1023].
;   i = vy_idx >> 1.
;   frac = vy_idx & 1.
;   if !frac: return HI[i], LO[i].
;   else: 16-bit avg of (HI:LO[i], HI:LO[i+1]).
;
; Tables: HI[0..513] at $E000, LO[0..513] at $E202.
; ============================================================================
.br_recip
{
    ; --- Clamp vy_idx to [2, 1023] ---
    LDA zp_br_t1 : CMP #4 : BCC c_hi_ok
    LDA #$FF : STA zp_br_t0
    LDA #3   : STA zp_br_t1
.c_hi_ok
    LDA zp_br_t1 : BNE c_lo_ok          ; HI > 0 → ≥ 256 ≥ 2, OK
    LDA zp_br_t0 : CMP #2 : BCS c_lo_ok
    LDA #2 : STA zp_br_t0
.c_lo_ok

    ; --- Save the frac bit (LSB of vy_idx.LO) ---
    LDA zp_br_t0 : AND #1 : STA zp_br_t2

    ; --- Compute i = vy_idx >> 1 (16-bit shift right) ---
    ; LSR HI, ROR LO. After LSR HI, carry holds old bit 0 of HI; ROR LO
    ; brings carry into LO bit 7. Result: i.HI in t1, i.LO in t0.
    LSR zp_br_t1
    ROR zp_br_t0

    ; --- Build pointer to HI[i] = $E000 + i ---
    CLC
    LDA zp_br_t0 : ADC #<RECIP_BASE : STA zp_br_p
    LDA zp_br_t1 : ADC #>RECIP_BASE : STA zp_br_p_h

    ; --- HI[i] ---
    LDY #0 : LDA (zp_br_p),Y : STA zp_br_rhi

    ; --- LO[i] = HI[i] + 0x202 (= 514, table size) ---
    ; We can index the same pointer with Y=$202 — but that overflows u8 Y.
    ; Easier: build a second pointer for LO base.
    CLC
    LDA zp_br_t0 : ADC #<($E000 + 514) : STA zp_br_p
    LDA zp_br_t1 : ADC #>($E000 + 514) : STA zp_br_p_h
    LDA (zp_br_p),Y : STA zp_br_rlo

    ; --- If no averaging needed, done ---
    LDA zp_br_t2 : BNE r_avg
    RTS

.r_avg
    ; --- Read HI[i+1] and LO[i+1], full 16-bit average with current ---
    ; Re-build LO pointer (currently set) and bump Y to 1.
    LDY #1 : LDA (zp_br_p),Y : STA zp_br_t3   ; LO[i+1]

    ; HI[i+1]: rebuild pointer to HI base.
    CLC
    LDA zp_br_t0 : ADC #<RECIP_BASE : STA zp_br_p
    LDA zp_br_t1 : ADC #>RECIP_BASE : STA zp_br_p_h
    LDA (zp_br_p),Y                            ; HI[i+1]
    STA zp_br_t2                                ; t2 = HI[i+1] (frac flag no longer needed)

    ; --- 16-bit average: ((HI[i]:LO[i]) + (HI[i+1]:LO[i+1])) >> 1 ---
    CLC
    LDA zp_br_rlo : ADC zp_br_t3 : STA zp_br_t3 ; sum.LO
    LDA zp_br_rhi : ADC zp_br_t2 : STA zp_br_t2 ; sum.HI (carry=overflow bit)

    ; Shift right 17 bits (16-bit + 1 carry) by 1.
    ; ROR carries the overflow into bit 7 of HI.
    ROR zp_br_t2 : ROR zp_br_t3
    LDA zp_br_t2 : STA zp_br_rhi
    LDA zp_br_t3 : STA zp_br_rlo
    RTS
}

; ============================================================================
; HELPER: br_frac_rot_term — fractional rotation contribution.
;   Inputs:  zp_ft_lo  (u8 fractional delta)
;            zp_ft_mag (u8 trig magnitude)
;            zp_ft_neg (1 if trig is negative, else 0)
;            zp_ft_one (1 if |trig| == 1, else 0)
;   Output:  zp_resl/h (s16 in [-255, 255])
;
;   Python:
;     if unity: val = lo
;     elif mag == 0 or lo == 0: return 0
;     else: val = (lo*mag + 128) >> 8
;     return -val if neg else val
; ============================================================================
zp_ft_lo  = $24
zp_ft_mag = $25
zp_ft_neg = $26
zp_ft_one = $27

.br_frac_rot_term
{
    LDA zp_ft_one : BEQ ft_not_one
    LDA zp_ft_lo
    JMP ft_apply_neg
.ft_not_one
    LDA zp_ft_mag : BEQ ft_zero
    LDA zp_ft_lo  : BEQ ft_zero
    LDA zp_ft_mag : STA zp_mul_b
    LDA zp_ft_lo
    JSR SC_UMUL8                  ; prod_lo:hi = lo * mag
    ; val = (prod + 128) >> 8 — round-to-nearest, then take HI byte.
    LDA zp_prod_lo : CLC : ADC #128
    LDA zp_prod_hi : ADC #0       ; A = HI byte after rounding
.ft_apply_neg
    ; A = u8 magnitude. Promote to s16 in zp_br_resl:resh.
    STA zp_br_resl
    LDA #0 : STA zp_br_resh
    LDA zp_ft_neg : BEQ ft_done
    LDA #0 : SEC : SBC zp_br_resl : STA zp_br_resl
    LDA #0 : SBC zp_br_resh         : STA zp_br_resh
.ft_done
    RTS
.ft_zero
    LDA #0 : STA zp_br_resl : STA zp_br_resh
    RTS
}

; ============================================================================
; HELPER: br_rot_int — integer rotation contribution (s16 × u8 → s16).
;
; Conceptually computes |d| × mag as u24, but only retains the low 16 bits.
; This is correct because the rotation matrix application sums 4 such
; terms with sign cancellation, and the final sum (total_vx, total_vy)
; fits s16 in practice for reasonable map sizes.
;
;   Inputs:  zp_ri_dlo, zp_ri_dhi (s16 integer delta — was s8, now s16)
;            zp_ri_mag (u8 trig magnitude)
;            zp_ri_neg (1 if trig negative)
;            zp_ri_one (1 if |trig| == 1)
;   Output:  zp_br_resl/resh (s16)
;
;   Python:
;     if unity: val = d_hi << 8
;     else if mag == 0: return 0
;     else: val = m8(d_hi, mag)
;     return -val if neg else val
; ============================================================================
zp_ri_dlo = $28
zp_ri_mag = $29
zp_ri_neg = $2A
zp_ri_one = $2B
zp_ri_dhi = $2C       ; (was unused; s16 hi byte of d)
zp_ri_d   = zp_ri_dlo ; backwards-compat alias

.br_rot_int
{
    LDA zp_ri_one : BEQ ri_not_one
    ; val = d << 8: low = 0, high = d.lo (low byte of s16 d, since s16<<8
    ; of a value that fits s8 promotes to s16; for full s16, this would
    ; lose the high byte, but unity (|trig|=1) only happens at cardinal
    ; angles where d * 1 = d itself — and we want to add d as s16 to the
    ; total. So actually val = d (s16), not d << 8.
    ; Wait — Python is `val = d_hi << 8` which is wrong if d_hi is wider
    ; than s8. Let me match it: val.lo = 0, val.hi = d.lo.
    ; This loses precision when d > 255 — TODO: revisit if it causes
    ; visible artifacts.
    LDA #0 : STA zp_br_resl
    LDA zp_ri_dlo : STA zp_br_resh
    JMP ri_apply_neg
.ri_not_one
    LDA zp_ri_mag : BEQ ri_zero
    ; |d| × mag, low 16 bits, with sign restoration.
    LDA #0 : STA zp_br_t1                        ; sign tracker (1 if d was -ve)
    LDA zp_ri_dhi : BPL ri_d_pos
    LDA #1 : STA zp_br_t1
    LDA #0 : SEC : SBC zp_ri_dlo : STA zp_ri_dlo
    LDA #0 : SBC zp_ri_dhi         : STA zp_ri_dhi
.ri_d_pos
    LDA zp_ri_mag : STA zp_mul_b
    LDA zp_ri_dlo : JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh
    LDA zp_ri_dhi : JSR SC_UMUL8
    ; Add prod_lo to result.hi (discard prod_hi — that's bit 16+ which
    ; we don't keep). The high-byte loss is OK because the FINAL sum
    ; cancels back into s16 range.
    LDA zp_prod_lo : CLC : ADC zp_br_resh : STA zp_br_resh
    LDA zp_br_t1 : BEQ ri_apply_neg
    ; d was negative → negate s16 result.
    LDA #0 : SEC : SBC zp_br_resl : STA zp_br_resl
    LDA #0 : SBC zp_br_resh         : STA zp_br_resh
.ri_apply_neg
    LDA zp_ri_neg : BEQ ri_done
    LDA #0 : SEC : SBC zp_br_resl : STA zp_br_resl
    LDA #0 : SBC zp_br_resh         : STA zp_br_resh
.ri_done
    RTS
.ri_zero
    LDA #0 : STA zp_br_resl : STA zp_br_resh
    RTS
}

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
.br_view_setup
{
    ; dx_lo = (-zp_br_px) & 0xFF
    LDA #0 : SEC : SBC zp_br_px : STA zp_br_t2     ; dx_lo
    ; dy_lo = (-zp_br_py) & 0xFF
    LDA #0 : SEC : SBC zp_br_py : STA zp_br_t3     ; dy_lo

    ; --- frac_vx = ft(dx_lo, sin) - ft(dy_lo, cos) ---
    LDA zp_br_t2 : STA zp_ft_lo
    LDA zp_br_smag : STA zp_ft_mag
    LDA zp_br_sneg : STA zp_ft_neg
    LDA zp_br_sone : STA zp_ft_one
    JSR br_frac_rot_term
    LDA zp_br_resl : STA zp_br_fvxlo
    LDA zp_br_resh : STA zp_br_fvxhi

    LDA zp_br_t3 : STA zp_ft_lo
    LDA zp_br_cmag : STA zp_ft_mag
    LDA zp_br_cneg : STA zp_ft_neg
    LDA zp_br_cone : STA zp_ft_one
    JSR br_frac_rot_term
    ; frac_vx -= result
    LDA zp_br_fvxlo : SEC : SBC zp_br_resl : STA zp_br_fvxlo
    LDA zp_br_fvxhi :       SBC zp_br_resh : STA zp_br_fvxhi

    ; --- frac_vy = ft(dx_lo, cos) + ft(dy_lo, sin) ---
    LDA zp_br_t2 : STA zp_ft_lo
    LDA zp_br_cmag : STA zp_ft_mag
    LDA zp_br_cneg : STA zp_ft_neg
    LDA zp_br_cone : STA zp_ft_one
    JSR br_frac_rot_term
    LDA zp_br_resl : STA zp_br_fvylo
    LDA zp_br_resh : STA zp_br_fvyhi

    LDA zp_br_t3 : STA zp_ft_lo
    LDA zp_br_smag : STA zp_ft_mag
    LDA zp_br_sneg : STA zp_ft_neg
    LDA zp_br_sone : STA zp_ft_one
    JSR br_frac_rot_term
    LDA zp_br_fvylo : CLC : ADC zp_br_resl : STA zp_br_fvylo
    LDA zp_br_fvyhi :       ADC zp_br_resh : STA zp_br_fvyhi

    RTS
}

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
.br_to_view
{
    ; dx (s16) = wx - px_int. Caller sets zp_br_dxlo:hi to wx (s16);
    ; subtract px_int (s8 sign-extended).
    LDA zp_br_dxlo : SEC : SBC zp_br_px_h : STA zp_br_dxlo
    LDA zp_br_px_h : BMI dx_neg_ext
    LDA zp_br_dxhi : SBC #0 : STA zp_br_dxhi
    JMP dx_done
.dx_neg_ext
    LDA zp_br_dxhi : SBC #$FF : STA zp_br_dxhi
.dx_done
    LDA zp_br_dylo : SEC : SBC zp_br_py_h : STA zp_br_dylo
    LDA zp_br_py_h : BMI dy_neg_ext
    LDA zp_br_dyhi : SBC #0 : STA zp_br_dyhi
    JMP dy_done
.dy_neg_ext
    LDA zp_br_dyhi : SBC #$FF : STA zp_br_dyhi
.dy_done

    ; int_vx = rot_int(dx, sin) - rot_int(dy, cos)
    LDA zp_br_dxlo : STA zp_ri_dlo
    LDA zp_br_dxhi : STA zp_ri_dhi
    LDA zp_br_smag : STA zp_ri_mag
    LDA zp_br_sneg : STA zp_ri_neg
    LDA zp_br_sone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_resl : STA zp_br_vxlo
    LDA zp_br_resh : STA zp_br_vxhi

    LDA zp_br_dylo : STA zp_ri_dlo
    LDA zp_br_dyhi : STA zp_ri_dhi
    LDA zp_br_cmag : STA zp_ri_mag
    LDA zp_br_cneg : STA zp_ri_neg
    LDA zp_br_cone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_vxlo : SEC : SBC zp_br_resl : STA zp_br_vxlo
    LDA zp_br_vxhi :       SBC zp_br_resh : STA zp_br_vxhi

    ; int_vy = rot_int(dx, cos) + rot_int(dy, sin)
    LDA zp_br_dxlo : STA zp_ri_dlo
    LDA zp_br_dxhi : STA zp_ri_dhi
    LDA zp_br_cmag : STA zp_ri_mag
    LDA zp_br_cneg : STA zp_ri_neg
    LDA zp_br_cone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_resl : STA zp_br_vylo
    LDA zp_br_resh : STA zp_br_vyhi

    LDA zp_br_dylo : STA zp_ri_dlo
    LDA zp_br_dyhi : STA zp_ri_dhi
    LDA zp_br_smag : STA zp_ri_mag
    LDA zp_br_sneg : STA zp_ri_neg
    LDA zp_br_sone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_vylo : CLC : ADC zp_br_resl : STA zp_br_vylo
    LDA zp_br_vyhi :       ADC zp_br_resh : STA zp_br_vyhi

    ; Add frac terms
    LDA zp_br_vxlo : CLC : ADC zp_br_fvxlo : STA zp_br_vxlo
    LDA zp_br_vxhi :       ADC zp_br_fvxhi : STA zp_br_vxhi
    LDA zp_br_vylo : CLC : ADC zp_br_fvylo : STA zp_br_vylo
    LDA zp_br_vyhi :       ADC zp_br_fvyhi : STA zp_br_vyhi
    RTS
}

; ============================================================================
; HELPER: br_smul_s8_u8 — signed s8 × unsigned u8 → s16.
;   Inputs:  zp_br_a (s8), zp_br_b (u8).
;   Output:  zp_br_resl/h (s16).
; ============================================================================
.br_smul_s8_u8
{
    LDA #0 : STA zp_br_sign
    LDA zp_br_a : BPL a_pos
    EOR #$FF : CLC : ADC #1 : STA zp_br_a
    INC zp_br_sign
.a_pos
    LDA zp_br_b : STA zp_mul_b
    LDA zp_br_a
    JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh
    LDA zp_br_sign : BEQ pos
    LDA #0 : SEC : SBC zp_br_resl : STA zp_br_resl
    LDA #0 : SBC zp_br_resh         : STA zp_br_resh
.pos
    RTS
}

; ============================================================================
; br_project_x_subpx — project view-space X to screen X with sub-pixel.
;
;   Inputs (zp):
;     zp_br_t0 = vx (s8, truncated view-space x)
;     zp_br_t1 = vx_frac (u8, fractional part)
;     zp_br_rhi, zp_br_rlo = reciprocal (u8 each)
;
;   Output:
;     zp_br_resl/h = sx (s16 screen x)
;
;   Python:
;     sx = HALF_W + m8(vx, recip_hi) + (m8(vx, recip_lo) >> 8)
;                + (m8(vx_frac, recip_hi) >> 8)
;
;   Three 8x8 multiplies: signed s8×u8 (×2) and unsigned u8×u8 (×1).
; ============================================================================
.br_project_x_subpx
{
    ; sum := HALF_W (128) as s16
    LDA #128 : STA zp_br_vxlo  ; reuse vxlo/hi as accumulator for sx
    LDA #0   : STA zp_br_vxhi

    ; --- Add A = signed(vx) × u8(recip_hi) ---
    LDA zp_br_t0  : STA zp_br_a
    LDA zp_br_rhi : STA zp_br_b
    JSR br_smul_s8_u8
    LDA zp_br_vxlo : CLC : ADC zp_br_resl : STA zp_br_vxlo
    LDA zp_br_vxhi :       ADC zp_br_resh : STA zp_br_vxhi

    ; --- Add B = (signed(vx) × u8(recip_lo)) >> 8 ---
    ; Compute s16 product, take HI byte as s8, sign-extend, add to sum.
    LDA zp_br_t0  : STA zp_br_a
    LDA zp_br_rlo : STA zp_br_b
    JSR br_smul_s8_u8
    LDA zp_br_resh : STA zp_br_t2     ; s8 hi byte of product = "B" value
    ; Sign-extend t2 into a 16-bit add.
    LDA zp_br_t2 : BPL b_pos
    LDA #$FF : STA zp_br_t3            ; sign-extension byte
    JMP b_have_ext
.b_pos
    LDA #0 : STA zp_br_t3
.b_have_ext
    LDA zp_br_vxlo : CLC : ADC zp_br_t2 : STA zp_br_vxlo
    LDA zp_br_vxhi :       ADC zp_br_t3 : STA zp_br_vxhi

    ; --- Add C = (u8(vx_frac) × u8(recip_hi)) >> 8 ---
    LDA zp_br_rhi : STA zp_mul_b
    LDA zp_br_t1
    JSR SC_UMUL8
    LDA zp_prod_hi : CLC : ADC zp_br_vxlo : STA zp_br_vxlo
    LDA #0         :       ADC zp_br_vxhi : STA zp_br_vxhi

    ; Move sum into resl/h (the standard output slot).
    LDA zp_br_vxlo : STA zp_br_resl
    LDA zp_br_vxhi : STA zp_br_resh
    RTS
}

; ============================================================================
; br_project_y — project height delta to screen Y.
;
;   Inputs (zp):
;     zp_br_t0 = height_delta (s8)
;     zp_br_rhi, zp_br_rlo = reciprocal
;
;   Output:
;     zp_br_resl/h = sy (s16)
;
;   Python:
;     sy = HALF_H - (m8(h, recip_hi) + (m8(h, recip_lo) >> 8))
; ============================================================================
.br_project_y
{
    ; sum := HALF_H (80) as s16
    LDA #80 : STA zp_br_vxlo
    LDA #0  : STA zp_br_vxhi

    ; --- Subtract A = signed(h) × u8(recip_hi) ---
    LDA zp_br_t0  : STA zp_br_a
    LDA zp_br_rhi : STA zp_br_b
    JSR br_smul_s8_u8
    LDA zp_br_vxlo : SEC : SBC zp_br_resl : STA zp_br_vxlo
    LDA zp_br_vxhi :       SBC zp_br_resh : STA zp_br_vxhi

    ; --- Subtract B = (signed(h) × u8(recip_lo)) >> 8 ---
    LDA zp_br_t0  : STA zp_br_a
    LDA zp_br_rlo : STA zp_br_b
    JSR br_smul_s8_u8
    LDA zp_br_resh : STA zp_br_t2
    LDA zp_br_t2 : BPL py_b_pos
    LDA #$FF : STA zp_br_t3
    JMP py_b_have_ext
.py_b_pos
    LDA #0 : STA zp_br_t3
.py_b_have_ext
    LDA zp_br_vxlo : SEC : SBC zp_br_t2 : STA zp_br_vxlo
    LDA zp_br_vxhi :       SBC zp_br_t3 : STA zp_br_vxhi

    LDA zp_br_vxlo : STA zp_br_resl
    LDA zp_br_vxhi : STA zp_br_resh
    RTS
}

.br_project_x
    JMP br_project_x_subpx

; ============================================================================
; ROM/RAM base addresses (Python wrapper writes these into ZP at frame start)
; ============================================================================
zp_rom_verts_lo    = $40
zp_rom_verts_hi    = $41
zp_rom_nodes_lo    = $42
zp_rom_nodes_hi    = $43
zp_rom_ss_lo       = $44
zp_rom_ss_hi       = $45
zp_rom_seg_hdr_lo  = $46
zp_rom_seg_hdr_hi  = $47
zp_rom_vwh_lo      = $48
zp_rom_vwh_hi      = $49
zp_rom_detail_lo   = $4A
zp_rom_detail_hi   = $4B
zp_root_node_lo    = $4C
zp_root_node_hi    = $4D

; BSP traversal state
zp_bsp_stack_sp    = $4E   ; stack pointer (offset into BSP_STACK)
BSP_STACK          = $0A00 ; 32 entries × 2 bytes = 64-byte stack at $0A00-0A3F

; Side-test result holder
zp_side            = $4F   ; 0 = front, 1 = back

; --- Node-read scratch ---
zp_node_dxlo  = $50
zp_node_dxhi  = $51
zp_node_dylo  = $52
zp_node_dyhi  = $53
zp_node_nxlo  = $54
zp_node_nxhi  = $55
zp_node_nylo  = $56
zp_node_nyhi  = $57
zp_node_chlo  = $58       ; current child (lo, hi: 16-bit id)
zp_node_chhi  = $59

; ============================================================================
; br_render_frame — top-level entry. Walks the BSP from the root,
; visiting subsectors in front-to-back order, dispatching to the
; per-subsector handler (br_render_subsector).
;
; Caller must have:
;   - Loaded WAD ROM into memory.
;   - Set up zp_rom_*, zp_root_node_*.
;   - Set up player view state (zp_br_px, etc.) and called br_view_setup.
;   - Initialized the span pool (via span_init at $2000).
;   - Cleared the framebuffer.
; ============================================================================
.br_render_frame
{
    ; Initialize BSP stack: push root node id.
    LDA #0 : STA zp_bsp_stack_sp
    LDX zp_bsp_stack_sp
    LDA zp_root_node_lo : STA BSP_STACK,X : INX
    LDA zp_root_node_hi : STA BSP_STACK,X : INX
    STX zp_bsp_stack_sp

.bsp_loop
    LDA zp_bsp_stack_sp : BNE bsp_pop
    RTS                              ; stack empty → done
.bsp_pop
    DEC zp_bsp_stack_sp              ; pop hi byte
    LDX zp_bsp_stack_sp
    LDA BSP_STACK,X : STA zp_node_chhi
    DEC zp_bsp_stack_sp              ; pop lo byte
    LDX zp_bsp_stack_sp
    LDA BSP_STACK,X : STA zp_node_chlo

    ; Subsector bit set?
    LDA zp_node_chhi : AND #$80 : BEQ bsp_node
    ; --- Subsector ---
    ; Mask off the subsector bit. ID & 0x7FFF.
    LDA zp_node_chhi : AND #$7F : STA zp_node_chhi
    JSR br_render_subsector
    JMP bsp_loop

.bsp_node
    ; --- Internal node ---
    ; Compute pointer to node = ROM_NODES + node_id * 16.
    ; node_id is in zp_node_chlo:hi (we just popped it). Multiply by 16.
    ; Lo byte * 16: low 4 bits go to high byte, upper 4 stay in low.
    ; hi_byte * 16: shifts up — but if id × 16 might overflow u16,
    ; we need 24-bit math. For up to ~4000 nodes, id × 16 = up to 64K,
    ; just barely fits u16. Use 16-bit shift left by 4.
    LDA zp_node_chlo : STA zp_br_t0
    LDA zp_node_chhi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ; node_offset = (id * 16) in zp_br_t0:t1.
    CLC
    LDA zp_rom_nodes_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_nodes_hi : ADC zp_br_t1 : STA zp_br_p_h

    ; Read node fields (skip dx/dy — placeholder side test).
    ; For now, always go front first (right child first). This is
    ; INCORRECT geometrically but lets us walk the tree. Real side
    ; test requires s16 × s16 = s32 multiply (TODO).
    LDA #0 : STA zp_side             ; placeholder: always side 0

    ; Read right child (offset +8) and left child (offset +10).
    LDY #8 : LDA (zp_br_p),Y : STA zp_br_t0   ; right.lo
    INY    : LDA (zp_br_p),Y : STA zp_br_t1   ; right.hi
    INY    : LDA (zp_br_p),Y : STA zp_br_t2   ; left.lo
    INY    : LDA (zp_br_p),Y : STA zp_br_t3   ; left.hi

    ; Push back child first (visited later), then near child (visited next).
    ; side=0 → right is near, left is far. (Or vice versa — for now we just
    ; push left first then right, regardless.)
    LDX zp_bsp_stack_sp
    LDA zp_br_t2 : STA BSP_STACK,X : INX     ; far.lo
    LDA zp_br_t3 : STA BSP_STACK,X : INX     ; far.hi
    LDA zp_br_t0 : STA BSP_STACK,X : INX     ; near.lo
    LDA zp_br_t1 : STA BSP_STACK,X : INX     ; near.hi
    STX zp_bsp_stack_sp
    JMP bsp_loop
}

; ============================================================================
; br_render_subsector — placeholder; called per subsector during walk.
;   Input: zp_node_chlo:hi = subsector id (with high bit cleared).
;
; Real impl needs to:
;   1. Read subsector header from ROM_SS + id*4: (count, pad, first_seg).
;   2. For each seg in [first_seg, first_seg + count):
;      a. Read seg header from ROM_SEG_HDR + i*12.
;      b. Back-face test (skip if behind).
;      c. Transform vertices (use vcache).
;      d. Project to screen.
;      e. Emit lines based on seg flags (solid/portal/step/aperture).
;      f. Tighten span list (or mark_solid for solids).
;
; This stub just RTS's; the BSP walker still works and visits all
; subsectors. Useful for verifying traversal in isolation.
; ============================================================================
; --- Test instrumentation: subsector visit bitmap at $0A80 ---
SS_VISITED_BITMAP = $0A80   ; 384 bytes

; --- Per-seg working state ---
zp_seg_first_lo = $5A      ; first_seg index for current subsector
zp_seg_first_hi = $5B
zp_seg_count    = $5C      ; remaining segs in subsector
zp_seg_v1_lo    = $5D
zp_seg_v1_hi    = $5E
zp_seg_v2_lo    = $5F
zp_seg_v2_hi    = $60
zp_seg_sx1_lo   = $61      ; projected screen x of v1 (s16)
zp_seg_sx1_hi   = $62
zp_seg_sx2_lo   = $63
zp_seg_sx2_hi   = $64
zp_seg_skip     = $65      ; non-zero → skip emit (near-clipped)

; ============================================================================
; br_render_subsector — process one subsector.
;   Input: zp_node_chlo:hi = subsector id (high bit cleared).
;
;   Reads subsector header (count, first_seg). Loops through segs:
;     1. Mark visited (test instrumentation).
;     2. Read v1, v2 indices.
;     3. Transform each vertex using br_to_view.
;     4. Project x via br_project_x_subpx.
;     5. Emit one horizontal line at HALF_H to test the pipeline.
; ============================================================================
.br_render_subsector
{
    ; *** DEBUG: increment a 16-bit call counter at $0BFE-$0BFF ***
    INC $0BFE : BNE no_carry_cnt : INC $0BFF
.no_carry_cnt
    ; --- Mark visited (test) ---
    LDA zp_node_chlo : STA zp_br_t0
    LDA zp_node_chhi : STA zp_br_t1
    LSR zp_br_t1 : ROR zp_br_t0
    LSR zp_br_t1 : ROR zp_br_t0
    LSR zp_br_t1 : ROR zp_br_t0
    LDA zp_node_chlo : AND #7 : TAX
    LDA #1
.bit_loop
    DEX : BMI bit_done
    ASL A
    JMP bit_loop
.bit_done
    PHA
    LDA #<SS_VISITED_BITMAP : CLC : ADC zp_br_t0 : STA zp_br_p
    LDA #>SS_VISITED_BITMAP :       ADC zp_br_t1 : STA zp_br_p_h
    LDY #0
    PLA
    ORA (zp_br_p),Y
    STA (zp_br_p),Y

    ; *** TODO: emit lines for each seg in this subsector. ***
    ; Currently a stub. Calling JSR SC_DRAW_S16 / SC_DRAW_U8 from here
    ; reveals a stack imbalance somewhere in span_clip's DCL or the
    ; rasteriser at $A900: PC ends up at $0000 (classic stack underflow)
    ; instead of returning to render_subsector. The same DCL works fine
    ; when called via _run directly from Python (single stack frame).
    ; Investigation needed: trace where DCL/rasteriser RTSes more times
    ; than it pushes, or where it manipulates the hardware stack
    ; (PHA/PLA/JSR) in a non-balanced way.
    RTS

    ; --- Read subsector header at ROM_SS + id * 4 ---
    LDA zp_node_chlo : STA zp_br_t0
    LDA zp_node_chhi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    CLC
    LDA zp_rom_ss_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_ss_hi : ADC zp_br_t1 : STA zp_br_p_h
    LDY #0
    LDA (zp_br_p),Y : STA zp_seg_count          ; count
    LDY #2
    LDA (zp_br_p),Y : STA zp_seg_first_lo
    LDY #3
    LDA (zp_br_p),Y : STA zp_seg_first_hi

    ; --- Loop over segs ---
.ss_seg_loop
    LDA zp_seg_count : BNE ss_have_seg
    RTS
.ss_have_seg

    ; Compute pointer to seg header = ROM_SEG_HDR + first_seg * 12.
    ; first_seg * 12 = first_seg * 8 + first_seg * 4.
    LDA zp_seg_first_lo : STA zp_br_t0
    LDA zp_seg_first_hi : STA zp_br_t1
    ; * 4
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    LDA zp_br_t0 : STA zp_br_t2     ; save *4
    LDA zp_br_t1 : STA zp_br_t3
    ; *8 (= shift again)
    ASL zp_br_t0 : ROL zp_br_t1
    ; sum = *8 + *4 = *12
    CLC
    LDA zp_br_t0 : ADC zp_br_t2 : STA zp_br_t0
    LDA zp_br_t1 : ADC zp_br_t3 : STA zp_br_t1
    CLC
    LDA zp_rom_seg_hdr_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_seg_hdr_hi : ADC zp_br_t1 : STA zp_br_p_h

    ; Read v1_idx, v2_idx.
    LDY #0
    LDA (zp_br_p),Y : STA zp_seg_v1_lo
    INY : LDA (zp_br_p),Y : STA zp_seg_v1_hi
    INY : LDA (zp_br_p),Y : STA zp_seg_v2_lo
    INY : LDA (zp_br_p),Y : STA zp_seg_v2_hi

    ; --- Transform v1 ---
    LDA zp_seg_v1_lo : STA zp_br_t0
    LDA zp_seg_v1_hi : STA zp_br_t1
    JSR br_transform_vertex
    LDA zp_seg_skip : BEQ seg_no_skip
    JMP seg_advance
.seg_no_skip
    LDA zp_br_resl : STA zp_seg_sx1_lo
    LDA zp_br_resh : STA zp_seg_sx1_hi

    ; --- Transform v2 ---
    LDA zp_seg_v2_lo : STA zp_br_t0
    LDA zp_seg_v2_hi : STA zp_br_t1
    JSR br_transform_vertex
    LDA zp_seg_skip : BEQ seg_no_skip2
    JMP seg_advance
.seg_no_skip2
    LDA zp_br_resl : STA zp_seg_sx2_lo
    LDA zp_br_resh : STA zp_seg_sx2_hi

    ; --- Emit a horizontal line at HALF_H + Y_BIAS = 80 + 48 = 128 ---
    ; (The clipper expects Y values pre-biased by Y_BIAS = 48.)
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2          ; LC_X1_HI
    LDA #128 : STA zp_line_yl
    LDA #0   : STA $B3                    ; LC_Y1_HI
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA #128 : STA zp_line_yr
    LDA #0   : STA $B5

    ; Order endpoints: if xl > xr, swap. Compare s16 (signed).
    LDA $B4 : SEC : SBC $B2          ; xr.HI - xl.HI
    BVC sw_no_v_flip
    EOR #$80
.sw_no_v_flip
    BMI seg_swap                      ; result negative → xr < xl → swap
    BNE seg_no_swap                   ; positive non-zero → ordered, OK
    ; HI bytes equal: compare LO bytes (unsigned).
    LDA zp_line_xl : CMP zp_line_xr : BCC seg_no_swap : BEQ seg_no_swap
.seg_swap
    LDA zp_line_xl : LDX zp_line_xr : STX zp_line_xl : STA zp_line_xr
    LDA zp_line_yl : LDX zp_line_yr : STX zp_line_yl : STA zp_line_yr
    LDA $B2 : LDX $B4 : STX $B2 : STA $B4
    LDA $B3 : LDX $B5 : STX $B3 : STA $B5
.seg_no_swap

    ; Disable records on this call.
    LDA #0 : STA $BD                  ; ZP_DCL_REC_BUF_H

    JSR SC_DRAW_S16

.seg_advance
    ; Advance to next seg.
    LDA #0 : STA zp_seg_skip
    INC zp_seg_first_lo : BNE no_carry_first
    INC zp_seg_first_hi
.no_carry_first
    DEC zp_seg_count
    JMP ss_seg_loop
}

; ============================================================================
; br_transform_vertex — fetch vertex by index, transform to view, project
; to screen X.
;   Input:  zp_br_t0:t1 = vertex index (u16).
;   Output: zp_br_resl/h = screen X (s16). zp_seg_skip = 1 if near-clipped.
;
; Uses zp_rom_verts_lo/hi for ROM base. Each vertex is 4 bytes (s16 x, y).
; ============================================================================
.br_transform_vertex
{
    LDA #0 : STA zp_seg_skip

    ; ptr = ROM_VERTS + idx * 4
    LDA zp_br_t0 : STA zp_br_t2
    LDA zp_br_t1 : STA zp_br_t3
    ASL zp_br_t2 : ROL zp_br_t3
    ASL zp_br_t2 : ROL zp_br_t3
    CLC
    LDA zp_rom_verts_lo : ADC zp_br_t2 : STA zp_br_p
    LDA zp_rom_verts_hi : ADC zp_br_t3 : STA zp_br_p_h

    ; Read full s16 x and y from ROM.
    LDY #0 : LDA (zp_br_p),Y : STA zp_br_dxlo
    LDY #1 : LDA (zp_br_p),Y : STA zp_br_dxhi
    LDY #2 : LDA (zp_br_p),Y : STA zp_br_dylo
    LDY #3 : LDA (zp_br_p),Y : STA zp_br_dyhi

    ; Transform to view space.
    JSR br_to_view

    ; Near-clip: skip if vy < 1 (i.e. behind us). vy is s16 (8.8 fixed).
    ; vy.HI < 0 → behind. vy.HI == 0 AND vy.LO < 1 → ditto.
    LDA zp_br_vyhi : BPL vy_check_lo
    LDA #1 : STA zp_seg_skip : RTS
.vy_check_lo
    BNE vy_ok
    LDA zp_br_vylo : CMP #1 : BCS vy_ok
    LDA #1 : STA zp_seg_skip : RTS
.vy_ok

    ; Build vy_idx (9.1 fixed) = max(2, vy << 1) where vy is the s16 8.8
    ; total. vy>>7 in 9.1 form = take HI byte + bit 7 of LO into LSB.
    ; Equivalently: shift the s16 vy left by 1 in place.
    ASL zp_br_vylo : ROL zp_br_vyhi
    LDA zp_br_vyhi : STA zp_br_t0
    LDA #0 : STA zp_br_t1                 ; HI byte of vy_idx (always 0 or 1)
    ; Note: we destroyed vy in the shift but don't need it after this.

    ; Reciprocal lookup.
    JSR br_recip

    ; Project: vx = high byte of total_vx (rounded). For now use the
    ; rounded value: (total_vx + 128) >> 8 — i.e. add 128 to LO, take HI.
    LDA zp_br_vxlo : CLC : ADC #128
    LDA zp_br_vxhi : ADC #0           ; A = rounded vx
    STA zp_br_t0
    LDA #0 : STA zp_br_t1             ; vx_frac = 0 (skip sub-pixel for now)

    JSR br_project_x_subpx
    ; resl/h = sx (s16). Done.
    RTS
}

; ============================================================================
; (Unused stub kept for compatibility; will be removed once seg pipeline
;  is fully wired in.)
; ============================================================================


.br_noop_test
    RTS

.end_code
SAVE "bsp_render.bin", $4800, end_code, $4800
