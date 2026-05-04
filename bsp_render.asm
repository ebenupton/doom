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

; Per-vertex working state
zp_br_dx        = $0F       ; s8 wx - px_int
zp_br_dy        = $10
zp_br_vxlo      = $11       ; s16 view-space vx (8.8)
zp_br_vxhi      = $12
zp_br_vylo      = $13
zp_br_vyhi      = $14

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

; ============================================================================
; Aliases for span_clip's exported routines
; ============================================================================
SC_UMUL8        = $2021
SC_UDIV16_8     = $2024
SC_DRAW_S16     = $201E

; And span_clip's ZP slots that umul8/udiv16_8 use
zp_mul_b        = $D9
zp_prod_lo      = $DA
zp_prod_hi      = $DB
zp_div_lo       = $DA
zp_div_hi       = $DB
zp_div_den      = $DC

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
; HELPER: br_rot_int — integer rotation contribution (signed s8 × u8 = s16).
;   Inputs:  zp_ri_d   (s8 integer delta)
;            zp_ri_mag (u8 trig magnitude)
;            zp_ri_neg (1 if trig negative)
;            zp_ri_one (1 if |trig| == 1)
;   Output:  zp_br_resl/resh (s16)
;
;   Python:
;     if unity: val = d_hi << 8
;     else if mag == 0: return 0
;     else: val = m8(d_hi, mag)    # signed s8 × u8 → s16
;     return -val if neg else val
; ============================================================================
zp_ri_d   = $28
zp_ri_mag = $29
zp_ri_neg = $2A
zp_ri_one = $2B

.br_rot_int
{
    LDA zp_ri_one : BEQ ri_not_one
    ; val = d << 8: low = 0, high = d (sign-extend d).
    LDA #0 : STA zp_br_resl
    LDA zp_ri_d : STA zp_br_resh
    JMP ri_apply_neg
.ri_not_one
    LDA zp_ri_mag : BEQ ri_zero
    ; val = signed(d) × u8(mag): take abs(d), umul8, restore sign.
    LDA zp_ri_d : BPL ri_d_pos
    EOR #$FF : CLC : ADC #1       ; |d|
    STA zp_br_t0                  ; t0 = |d|
    LDA #1 : STA zp_br_t1         ; t1 = "d was negative"
    JMP ri_d_done
.ri_d_pos
    STA zp_br_t0
    LDA #0 : STA zp_br_t1
.ri_d_done
    LDA zp_ri_mag : STA zp_mul_b
    LDA zp_br_t0
    JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh
    LDA zp_br_t1 : BEQ ri_apply_neg
    ; d was negative → negate result.
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
    ; dx = wx - px_int = zp_br_dx - zp_br_px_h
    LDA zp_br_dx : SEC : SBC zp_br_px_h : STA zp_br_dx
    ; dy = wy - py_int = zp_br_dy - zp_br_py_h
    LDA zp_br_dy : SEC : SBC zp_br_py_h : STA zp_br_dy

    ; int_vx = rot_int(dx, sin) - rot_int(dy, cos)
    LDA zp_br_dx   : STA zp_ri_d
    LDA zp_br_smag : STA zp_ri_mag
    LDA zp_br_sneg : STA zp_ri_neg
    LDA zp_br_sone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_resl : STA zp_br_vxlo
    LDA zp_br_resh : STA zp_br_vxhi

    LDA zp_br_dy   : STA zp_ri_d
    LDA zp_br_cmag : STA zp_ri_mag
    LDA zp_br_cneg : STA zp_ri_neg
    LDA zp_br_cone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_vxlo : SEC : SBC zp_br_resl : STA zp_br_vxlo
    LDA zp_br_vxhi :       SBC zp_br_resh : STA zp_br_vxhi

    ; int_vy = rot_int(dx, cos) + rot_int(dy, sin)
    LDA zp_br_dx   : STA zp_ri_d
    LDA zp_br_cmag : STA zp_ri_mag
    LDA zp_br_cneg : STA zp_ri_neg
    LDA zp_br_cone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_resl : STA zp_br_vylo
    LDA zp_br_resh : STA zp_br_vyhi

    LDA zp_br_dy   : STA zp_ri_d
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

.end_code
SAVE "bsp_render.bin", $4800, end_code, $4800
