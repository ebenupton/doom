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
zp_br_px        = $00       ; s16 player x_88 (8.8 fixed, prescaled)
zp_br_px_h      = $01
zp_br_py        = $02
zp_br_py_h      = $03
zp_br_vz        = $04       ; s8 eye-height (prescaled)
; Raw (un-prescaled) player position for BSP side test.
zp_br_pxraw_lo  = $71       ; s16 player x relative to map_center (raw)
zp_br_pxraw_hi  = $72
zp_br_pyraw_lo  = $73
zp_br_pyraw_hi  = $74
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
zp_br_resl      = $17       ; s24 result lo
zp_br_resh      = $18       ; s24 result mid (the s16 path stops here)
zp_br_resext    = $2D       ; s24 result high byte (rot_int + to_view extension)
zp_br_vxext     = $2E       ; total view-space x sign-extension byte
zp_br_vyext     = $2F       ; total view-space y sign-extension byte
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

; Vertex cache helper state
zp_seg_v_idx_lo   = $77    ; cached: vertex index (u16)
zp_seg_v_idx_hi   = $78
zp_seg_v_bitm     = $79    ; valid-bitmap mask (1 << (idx & 7))
zp_seg_v_cache_lo = $7A    ; cached: pointer to this vertex's cache entry
zp_seg_v_cache_hi = $7B
; Side test working state (s16 deltas px-nx, py-ny held across fast/slow paths)
zp_seg_dxraw_lo   = $7C
zp_seg_dxraw_hi   = $7D
zp_seg_dyraw_lo   = $7E
zp_seg_dyraw_hi   = $7F
; Frame ROM table base ptrs (Python wrapper writes once)
zp_rom_fhch_lo    = $30
zp_rom_fhch_hi    = $31
zp_rom_bbox_lo    = $32
zp_rom_bbox_hi    = $33
; Bbox routine arg
zp_bbox_side      = $34

; ============================================================================
; Memory map (RAM caches + ROM tables — Python wrapper places data here)
; ============================================================================
RECIP_BASE      = $E000     ; base of recip table (HI bytes first, then LO)
                            ; HI[0..513] at $E000-$E201
                            ; LO[0..513] at $E202-$E403
SINCOS_BASE     = $E480     ; sin_mag[0..63], sin_unity[0..63] (128 bytes)

; Vertex transform cache: per-vertex saved view + projection results.
; Skip redundant transforms when multiple segs share a vertex.
;   8 bytes per entry (shift 3 for indexing).
;   +0 vx_int (s8)   +1 vx_frac (u8)
;   +2 rhi (u8)      +3 rlo (u8)
;   +4 sx_lo (u8)    +5 sx_hi (u8)   (s16 projected screen X)
;   +6 near_clip_flag (non-zero = vertex was near-clipped, skip seg)
;   +7 pad
; Valid bitmap: 1 bit per vertex; cleared at the start of each frame.
VCACHE_BASE       = $0C00
VCACHE_VALID_BASE = $1B00      ; 59 bytes for 467 vertices

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
JMP br_render_subsector ; $4818  process one subsector's segs (caller sets
                        ;        zp_node_chlo:hi to the subsector id). Used
                        ;        by the hybrid Python-BSP + 6502-seg harness
                        ;        to isolate BSP-traversal vs seg-processor
                        ;        divergence.
JMP br_init_frame   ; $481B   clear vcache valid bitmap (for hybrid mode)

; ============================================================================
; Aliases for span_clip's exported routines
; ============================================================================
SC_UMUL8        = $2021
SC_UDIV16_8     = $2024
SC_DRAW_S16     = $201E
SC_DRAW_U8      = $2015      ; standalone DCL (u8 input, no clipper prelude)
SC_MARK_SOLID   = $2003
SC_TIGHTEN      = $2006
SC_TIGHTEN_FROM_RECORDS = $201B

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
    ; Unity: val = d << 8 as s24. resl=0, resh=dlo, resext=dhi.
    LDA #0 : STA zp_br_resl
    LDA zp_ri_dlo : STA zp_br_resh
    LDA zp_ri_dhi : STA zp_br_resext
    JMP ri_apply_neg
.ri_not_one
    LDA zp_ri_mag : BEQ ri_zero
    ; |d| × mag → s24, with sign restoration. Compute as
    ;   res = |d|.lo * mag + (|d|.hi * mag) << 8.
    ; First product: (lo,hi) → resl, resh; resext starts 0.
    ; Second product: (lo,hi) added to resh, resext.
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
    LDA #0 : STA zp_br_resext
    LDA zp_ri_dhi : JSR SC_UMUL8
    CLC
    LDA zp_prod_lo : ADC zp_br_resh   : STA zp_br_resh
    LDA zp_prod_hi : ADC zp_br_resext : STA zp_br_resext
    LDA zp_br_t1 : BEQ ri_apply_neg
    ; d was negative → negate s24 result.
    LDA #0 : SEC : SBC zp_br_resl   : STA zp_br_resl
    LDA #0 :       SBC zp_br_resh   : STA zp_br_resh
    LDA #0 :       SBC zp_br_resext : STA zp_br_resext
.ri_apply_neg
    LDA zp_ri_neg : BEQ ri_done
    LDA #0 : SEC : SBC zp_br_resl   : STA zp_br_resl
    LDA #0 :       SBC zp_br_resh   : STA zp_br_resh
    LDA #0 :       SBC zp_br_resext : STA zp_br_resext
.ri_done
    RTS
.ri_zero
    LDA #0 : STA zp_br_resl : STA zp_br_resh : STA zp_br_resext
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

    ; int_vx = rot_int(dx, sin) - rot_int(dy, cos), as s24
    LDA zp_br_dxlo : STA zp_ri_dlo
    LDA zp_br_dxhi : STA zp_ri_dhi
    LDA zp_br_smag : STA zp_ri_mag
    LDA zp_br_sneg : STA zp_ri_neg
    LDA zp_br_sone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_resl   : STA zp_br_vxlo
    LDA zp_br_resh   : STA zp_br_vxhi
    LDA zp_br_resext : STA zp_br_vxext

    LDA zp_br_dylo : STA zp_ri_dlo
    LDA zp_br_dyhi : STA zp_ri_dhi
    LDA zp_br_cmag : STA zp_ri_mag
    LDA zp_br_cneg : STA zp_ri_neg
    LDA zp_br_cone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_vxlo : SEC : SBC zp_br_resl   : STA zp_br_vxlo
    LDA zp_br_vxhi :       SBC zp_br_resh   : STA zp_br_vxhi
    LDA zp_br_vxext :      SBC zp_br_resext : STA zp_br_vxext

    ; int_vy = rot_int(dx, cos) + rot_int(dy, sin), as s24
    LDA zp_br_dxlo : STA zp_ri_dlo
    LDA zp_br_dxhi : STA zp_ri_dhi
    LDA zp_br_cmag : STA zp_ri_mag
    LDA zp_br_cneg : STA zp_ri_neg
    LDA zp_br_cone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_resl   : STA zp_br_vylo
    LDA zp_br_resh   : STA zp_br_vyhi
    LDA zp_br_resext : STA zp_br_vyext

    LDA zp_br_dylo : STA zp_ri_dlo
    LDA zp_br_dyhi : STA zp_ri_dhi
    LDA zp_br_smag : STA zp_ri_mag
    LDA zp_br_sneg : STA zp_ri_neg
    LDA zp_br_sone : STA zp_ri_one
    JSR br_rot_int
    LDA zp_br_vylo : CLC : ADC zp_br_resl   : STA zp_br_vylo
    LDA zp_br_vyhi :       ADC zp_br_resh   : STA zp_br_vyhi
    LDA zp_br_vyext :      ADC zp_br_resext : STA zp_br_vyext

    ; Add frac terms (s16, sign-extended into ext byte)
    LDA zp_br_vxlo  : CLC : ADC zp_br_fvxlo : STA zp_br_vxlo
    LDA zp_br_vxhi  :       ADC zp_br_fvxhi : STA zp_br_vxhi
    LDA zp_br_fvxhi : BMI bv_fvxneg
    LDA zp_br_vxext : ADC #0 : STA zp_br_vxext
    JMP bv_fvx_done
.bv_fvxneg
    LDA zp_br_vxext : ADC #$FF : STA zp_br_vxext
.bv_fvx_done

    LDA zp_br_vylo  : CLC : ADC zp_br_fvylo : STA zp_br_vylo
    LDA zp_br_vyhi  :       ADC zp_br_fvyhi : STA zp_br_vyhi
    LDA zp_br_fvyhi : BMI bv_fvyneg
    LDA zp_br_vyext : ADC #0 : STA zp_br_vyext
    JMP bv_fvy_done
.bv_fvyneg
    LDA zp_br_vyext : ADC #$FF : STA zp_br_vyext
.bv_fvy_done
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
; HELPER: br_smul_s8_s16 — signed s8 × signed s16 → s16 (low 16 bits of s24).
;   Inputs:  zp_br_a (s8), zp_br_dxlo:dxhi (s16).
;   Output:  zp_br_resl/h (s16).
;
;   For our scene products fit in s16; for larger ones the high bits are
;   silently dropped. Used by the back-face test where we only need sign.
; ============================================================================
.br_smul_s8_s16
{
    LDA #0 : STA zp_br_sign

    ; |a|
    LDA zp_br_a : BPL a_pos
    EOR #$FF : CLC : ADC #1 : STA zp_br_a
    INC zp_br_sign
.a_pos

    ; |dx|, store as zp_br_t0 (lo), zp_br_t1 (hi)
    LDA zp_br_dxlo : STA zp_br_t0
    LDA zp_br_dxhi : STA zp_br_t1
    BPL b_pos
    LDA #0 : SEC : SBC zp_br_t0 : STA zp_br_t0
    LDA #0 :       SBC zp_br_t1 : STA zp_br_t1
    LDA zp_br_sign : EOR #1 : STA zp_br_sign
.b_pos

    ; |a| * t0 (u8 × u8 → u16) — low part of u8 * u16
    LDA zp_br_t0 : STA zp_mul_b
    LDA zp_br_a
    JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh

    ; |a| * t1 (u8 × u8 → u16) — high byte of result; only the low byte of
    ; this product contributes to the s16 result's high byte.
    LDA zp_br_t1 : STA zp_mul_b
    LDA zp_br_a
    JSR SC_UMUL8
    LDA zp_br_resh : CLC : ADC zp_prod_lo : STA zp_br_resh

    ; Apply sign
    LDA zp_br_sign : BEQ ss_pos
    LDA #0 : SEC : SBC zp_br_resl : STA zp_br_resl
    LDA #0 :       SBC zp_br_resh : STA zp_br_resh
.ss_pos
    RTS
}

; ============================================================================
; HELPER: br_smul_s16_s16_s32 — signed s16 × s16 → s32 (4-byte little-endian).
;   Inputs:  zp_br_dxlo:dxhi (A, s16), zp_br_dylo:dyhi (B, s16).
;   Output:  zp_br_t0:t1:t2:t3 (s32).
;   Clobbers: zp_br_dxlo:dxhi, zp_br_dylo:dyhi (negated for sign tracking).
; ============================================================================
.br_smul_s16_s16_s32
{
    LDA #0 : STA zp_br_sign

    ; |A|
    LDA zp_br_dxhi : BPL aa_pos
    LDA #0 : SEC : SBC zp_br_dxlo : STA zp_br_dxlo
    LDA #0 :       SBC zp_br_dxhi : STA zp_br_dxhi
    INC zp_br_sign
.aa_pos
    ; |B|
    LDA zp_br_dyhi : BPL bb_pos
    LDA #0 : SEC : SBC zp_br_dylo : STA zp_br_dylo
    LDA #0 :       SBC zp_br_dyhi : STA zp_br_dyhi
    LDA zp_br_sign : EOR #1 : STA zp_br_sign
.bb_pos

    ; al × bl → t0:t1
    LDA zp_br_dxlo : STA zp_mul_b
    LDA zp_br_dylo
    JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_t0
    LDA zp_prod_hi : STA zp_br_t1

    ; ah × bh → t2:t3
    LDA zp_br_dxhi : STA zp_mul_b
    LDA zp_br_dyhi
    JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_t2
    LDA zp_prod_hi : STA zp_br_t3

    ; al × bh → add to t1:t2:t3
    LDA zp_br_dyhi : STA zp_mul_b
    LDA zp_br_dxlo
    JSR SC_UMUL8
    CLC
    LDA zp_prod_lo : ADC zp_br_t1 : STA zp_br_t1
    LDA zp_prod_hi : ADC zp_br_t2 : STA zp_br_t2
    LDA zp_br_t3   : ADC #0       : STA zp_br_t3

    ; ah × bl → add to t1:t2:t3
    LDA zp_br_dylo : STA zp_mul_b
    LDA zp_br_dxhi
    JSR SC_UMUL8
    CLC
    LDA zp_prod_lo : ADC zp_br_t1 : STA zp_br_t1
    LDA zp_prod_hi : ADC zp_br_t2 : STA zp_br_t2
    LDA zp_br_t3   : ADC #0       : STA zp_br_t3

    ; Apply sign (negate s32 if negative)
    LDA zp_br_sign : BEQ s32_pos
    LDA #0 : SEC : SBC zp_br_t0 : STA zp_br_t0
    LDA #0 :       SBC zp_br_t1 : STA zp_br_t1
    LDA #0 :       SBC zp_br_t2 : STA zp_br_t2
    LDA #0 :       SBC zp_br_t3 : STA zp_br_t3
.s32_pos
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
; br_init_frame — clear vcache valid bitmap (so a fresh frame rebuilds
; vertex transforms). Exposed so the hybrid Python-BSP harness can call
; it before its first subsector pass.
.br_init_frame
    LDA #0
    LDX #59
.bif_clr
    DEX : STA VCACHE_VALID_BASE,X : BNE bif_clr
    RTS

.br_render_frame
{
    JSR br_init_frame

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

    JSR SC_IS_FULL
    BNE bsp_done_full
    LDA zp_node_chhi : AND #$80 : BEQ bsp_node
    LDA zp_node_chhi : AND #$7F : STA zp_node_chhi
    JSR br_render_subsector
    JMP bsp_loop
.bsp_done_full
    LDA #0 : STA zp_bsp_stack_sp
    JMP bsp_loop

.bsp_node
    JSR br_node_setup
    LDA zp_side : EOR #1 : STA zp_bbox_side
    JSR br_bbox_visible
    BEQ bsp_skip_far
    LDX zp_bsp_stack_sp
    LDA BSP_FAR_LO : STA BSP_STACK,X : INX
    LDA BSP_FAR_HI : STA BSP_STACK,X : INX
    STX zp_bsp_stack_sp
.bsp_skip_far
    LDX zp_bsp_stack_sp
    LDA BSP_NEAR_LO : STA BSP_STACK,X : INX
    LDA BSP_NEAR_HI : STA BSP_STACK,X : INX
    STX zp_bsp_stack_sp
    JMP bsp_loop
}

; (br_node_setup moved to bsp_render_lo.bin overflow region — see end of file)

; --- Children-id slots (set per bsp_node visit, used after bbox checks).
BSP_NEAR_LO = $0A68
BSP_NEAR_HI = $0A69
BSP_FAR_LO  = $0A6A
BSP_FAR_HI  = $0A6B

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
; Deferred mark_solid buffer (per-subsector): COUNT bytes (= 2 × num entries)
; followed by entries. Python's packed_render_subsector collects ('solid',
; ilo, ihi) tuples into a list, then applies them after the seg loop. The
; 6502 was applying them immediately per seg; this buffer matches Python's
; timing so within-subsector mark_solids don't affect later segs' has_gap.
DEFERRED_MS_COUNT = $1B3C   ; byte count (= 2 × entries)
DEFERRED_MS_BUF   = $1B3D   ; (ilo, ihi) pairs, up to ~60 bytes available

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
zp_seg_fh       = $66      ; s8 prescaled front floor height
zp_seg_ch       = $67      ; s8 prescaled front ceiling height
zp_seg_top_dlt  = $68      ; s8 ch - vz (height delta for top edge)
zp_seg_bot_dlt  = $69      ; s8 fh - vz (height delta for bottom edge)
; Per-vertex helper outputs (set by br_seg_xform_vertex)
zp_seg_sy_top_lo = $6A     ; s16 projected screen y for top edge
zp_seg_sy_top_hi = $6B
zp_seg_sy_bot_lo = $6C     ; s16 projected screen y for bottom edge
zp_seg_sy_bot_hi = $6D
zp_seg_sx_lo    = $6E      ; s16 projected screen x
zp_seg_sx_hi    = $6F
; Back-sector heights (s8 each) — only meaningful for portal segs.
zp_seg_bfh      = $0A78
zp_seg_bch      = $0A79
zp_seg_btop_dlt = $0A7A    ; bch - vz
zp_seg_bbot_dlt = $0A7B    ; bfh - vz
; Output of bv_proj_one's back-step projection (transient).
zp_seg_sy_btop_lo = $0A7C
zp_seg_sy_btop_hi = $0A7D
zp_seg_sy_bbot_lo = $0A7E
zp_seg_sy_bbot_hi = $0A7F
; Per-seg saved vertex projections live in RAM (ZP $70+ is rasteriser
; territory: RASTER_ZP_SCRSTRT=$70, RASTER_ZP_X0..Y1=$82-$85). Use the
; gap between BSP_STACK ($0A00-$0A3F) and SS_VISITED_BITMAP ($0A80).
SEG_PROJ_BUF      = $0A40
zp_seg_sy1_top_lo = SEG_PROJ_BUF + 0
zp_seg_sy1_top_hi = SEG_PROJ_BUF + 1
zp_seg_sy1_bot_lo = SEG_PROJ_BUF + 2
zp_seg_sy1_bot_hi = SEG_PROJ_BUF + 3
zp_seg_sy2_top_lo = SEG_PROJ_BUF + 4
zp_seg_sy2_top_hi = SEG_PROJ_BUF + 5
zp_seg_sy2_bot_lo = SEG_PROJ_BUF + 6
zp_seg_sy2_bot_hi = SEG_PROJ_BUF + 7
; Per-vertex saved back-step projections.
zp_seg_sy1_btop_lo = SEG_PROJ_BUF + 8
zp_seg_sy1_btop_hi = SEG_PROJ_BUF + 9
zp_seg_sy1_bbot_lo = SEG_PROJ_BUF + 10
zp_seg_sy1_bbot_hi = SEG_PROJ_BUF + 11
zp_seg_sy2_btop_lo = SEG_PROJ_BUF + 12
zp_seg_sy2_btop_hi = SEG_PROJ_BUF + 13
zp_seg_sy2_bbot_lo = SEG_PROJ_BUF + 14
zp_seg_sy2_bbot_hi = SEG_PROJ_BUF + 15
; Per-vertex view-space integer values, for near-plane crossing math.
; Always populated by br_seg_xform_vertex into "current" slots; the seg
; loop copies into v1/v2 slots so we have both vertices' values when
; computing the crossing point.
zp_seg_cur_evy   = $0A50    ; rounded s8 view-y of just-processed vertex
zp_seg_cur_evx   = $0A51    ; truncated s8 view-x
zp_seg_v1_evy    = $0A52
zp_seg_v1_evx    = $0A53
zp_seg_v1_clipped = $0A54
zp_seg_v2_evy    = $0A55
zp_seg_v2_evx    = $0A56
zp_seg_v2_clipped = $0A57
; cross_compute reads zp_seg_v{1,2}_{evy,evx} directly. Output:
zp_clip_cx       = $0A5C    ; output: crossing-point view-x (s8)
; Working-saver for projecting X after project_y trashes vxlo/hi
zp_v_xint       = $37      ; saved integer view-x (s8)
zp_v_xfrac      = $38      ; saved fractional view-x (u8)
; Per-seg back-face / linedef state
zp_seg_lv1x_lo  = $39
zp_seg_lv1x_hi  = $3A
zp_seg_lv1y_lo  = $3B
zp_seg_lv1y_hi  = $3C
zp_seg_ldx      = $3D      ; s8 linedef delta x
zp_seg_ldy      = $3E      ; s8 linedef delta y
zp_seg_flags    = $3F      ; u8

; ============================================================================
; br_back_face_test — test current seg for back-facing.
;   Inputs (zp): zp_seg_lv1x/lv1y (s16), zp_seg_ldx/ldy (s8), zp_seg_flags.
;                zp_br_px_h, zp_br_py_h = player px_int, py_int (s8).
;   Output: zp_seg_skip = 1 if back-facing, 0 if front-facing.
;
;   dot = ldy * (px_int - lv1_x) - ldx * (py_int - lv1_y)
;   if flags & SF_DIR: dot = -dot
;   back-facing if dot <= 0.
; ============================================================================
.br_back_face_test
{
    ; dx = px_int - lv1_x (s16). px_int (s8) sign-extended.
    LDA zp_br_px_h : STA zp_br_dxlo
    LDA #0 : STA zp_br_dxhi
    LDA zp_br_dxlo : BPL bf_px_pos
    LDA #$FF : STA zp_br_dxhi
.bf_px_pos
    LDA zp_br_dxlo : SEC : SBC zp_seg_lv1x_lo : STA zp_br_dxlo
    LDA zp_br_dxhi :       SBC zp_seg_lv1x_hi : STA zp_br_dxhi
    ; dy = py_int - lv1_y (s16)
    LDA zp_br_py_h : STA zp_br_dylo
    LDA #0 : STA zp_br_dyhi
    LDA zp_br_dylo : BPL bf_py_pos
    LDA #$FF : STA zp_br_dyhi
.bf_py_pos
    LDA zp_br_dylo : SEC : SBC zp_seg_lv1y_lo : STA zp_br_dylo
    LDA zp_br_dyhi :       SBC zp_seg_lv1y_hi : STA zp_br_dyhi

    ; --- Fast path for axis-aligned linedefs (~76% of segs).
    ; If ldx == 0: dot = ldy*dx, sign matches iff sign(ldy)==sign(dx).
    ; If ldy == 0: dot = -ldx*dy, sign matches iff sign(ldx)!=sign(dy).
    ; SF_DIR negates dot.
    LDA zp_seg_ldx : BNE bf_ldx_nz
    ; ldx==0
    LDA zp_seg_ldy : BNE bf_ldx0_ldy_nz
    JMP bf_back            ; ldx=0, ldy=0 → dot=0 → back
.bf_ldx0_ldy_nz
    LDA zp_br_dxlo : ORA zp_br_dxhi : BNE bf_ldx0_dx_nz
    JMP bf_back            ; dx == 0 → dot=0 → back
.bf_ldx0_dx_nz
    ; sign(dot) = sign(ldy) XOR sign(dx_hi)
    LDA zp_seg_ldy : EOR zp_br_dxhi
    JMP bf_apply_dir
.bf_ldx_nz
    LDA zp_seg_ldy : BNE bf_general
    ; ldy==0: dot = -ldx*dy.
    LDA zp_br_dylo : ORA zp_br_dyhi : BNE bf_ldy0_dy_nz
    JMP bf_back
.bf_ldy0_dy_nz
    ; sign(dot) = sign(-ldx*dy) = NOT(sign(ldx) XOR sign(dy_hi))
    LDA zp_seg_ldx : EOR zp_br_dyhi : EOR #$80
    JMP bf_apply_dir

.bf_apply_dir
    ; A holds a byte whose top bit = sign of dot (1=neg, 0=pos).
    ; SF_DIR ($01) negates the dot, so XOR top bit with bit 0 of flags shifted.
    ; Simpler: stash, then if SF_DIR set, EOR #$80.
    PHA
    LDA zp_seg_flags : AND #$01 : BEQ bf_apply_no_neg
    PLA : EOR #$80 : JMP bf_check_sign
.bf_apply_no_neg
    PLA
.bf_check_sign
    ; Top bit set → dot < 0 → back. Top bit clear → dot ≥ 0 → check zero.
    BMI bf_back
    ; dot ≥ 0; we already checked dot != 0 above (BEQ branches to bf_back).
    JMP bf_front

.bf_general
    ; ldx and ldy both nonzero — full 2-mul s8×s16 dot product.
    ; ldy * dx → s16 in resl/resh; save in t2:t3.
    LDA zp_seg_ldy : STA zp_br_a
    JSR br_smul_s8_s16
    LDA zp_br_resl : STA zp_br_t2
    LDA zp_br_resh : STA zp_br_t3

    ; ldx * dy → s16 in resl/resh.
    LDA zp_br_dylo : STA zp_br_dxlo
    LDA zp_br_dyhi : STA zp_br_dxhi
    LDA zp_seg_ldx : STA zp_br_a
    JSR br_smul_s8_s16

    ; dot = prod1 - prod2 (s16)
    LDA zp_br_t2 : SEC : SBC zp_br_resl : STA zp_br_t2
    LDA zp_br_t3 :       SBC zp_br_resh : STA zp_br_t3

    ; SF_DIR negate
    LDA zp_seg_flags : AND #$01 : BEQ bf_g_no_neg
    LDA #0 : SEC : SBC zp_br_t2 : STA zp_br_t2
    LDA #0 :       SBC zp_br_t3 : STA zp_br_t3
.bf_g_no_neg
    ; dot <= 0 → back-facing
    LDA zp_br_t3 : BMI bf_back
    BNE bf_front
    LDA zp_br_t2 : BEQ bf_back
.bf_front
    LDA #0 : STA zp_seg_skip : RTS
.bf_back
    LDA #1 : STA zp_seg_skip : RTS
}

; ============================================================================
; br_bbox_visible — visibility test for a child subtree's bounding box.
;
;   Inputs:
;     zp_node_chlo:hi = node id (used by caller; we read bbox by ourselves)
;     zp_bbox_side    = 0 for right child's bbox, 1 for left child's bbox.
;
;   Output: A = 1 if any visible gap in the bbox's screen-X range, else 0.
;
;   Algorithm (matches Python fp_bbox_visible_fixed loosely):
;     1. Compute bbox ptr = ROM_BBOX + node_id*16 + (side<<3).
;     2. Inside test: if (px_int, py_int) inside bbox, return 1 (always visible).
;     3. Transform 4 corners (l,t)(r,t)(r,b)(l,b) through br_to_view.
;     4. For each in front of NEAR plane, project to screen X.
;     5. If all behind near plane → return 0 (off-screen).
;        If any behind near plane → assume visible (set ilo=0, ihi=255).
;        Else min/max projected sx, clamped to [0, 255] → ilo, ihi.
;     6. If ilo > ihi → return 0.
;     7. JSR span_has_gap → return its A.
; ============================================================================
SC_HAS_GAP      = $2009
SC_IS_FULL      = $200C

; Per-corner storage (5 bytes × 4 = 20). bv_proj_one writes here so that a
; second pass can compute near-plane edge crossings between consecutive
; corners. Layout per corner: vx_lo, vx_hi, vy_lo, vy_hi, in_front (0/1).
BBOX_CORNERS    = $0E00
BBOX_CORNER_IDX = $0E14     ; offset into BBOX_CORNERS for current corner

BBOX_SCRATCH    = $0A58     ; 8 bytes: top_lo,top_hi,bot_lo,bot_hi,
                            ;          left_lo,left_hi,right_lo,right_hi
BBOX_FLAGS      = $0A60     ; bit 0 = any_behind, bit 1 = any_front
BBOX_ILO        = $0A61     ; running min sx clamped (u8)
BBOX_IHI        = $0A62     ; running max sx clamped (u8)

.br_bbox_visible
{
    ; --- Compute bbox table pointer = ROM_BBOX + node_id*16 + side*8 ---
    LDA zp_node_chlo : STA zp_br_t0
    LDA zp_node_chhi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1                      ; node_id * 16
    LDA zp_bbox_side : BEQ bv_side_done
    ; side=1: add 8
    LDA zp_br_t0 : CLC : ADC #8 : STA zp_br_t0
    LDA zp_br_t1 :       ADC #0 : STA zp_br_t1
.bv_side_done
    CLC
    LDA zp_rom_bbox_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_bbox_hi : ADC zp_br_t1 : STA zp_br_p_h

    ; Read top, bot, left, right (s16 each, 8 bytes total).
    LDY #0
.bv_read
    LDA (zp_br_p),Y : STA BBOX_SCRATCH,Y
    INY : CPY #8 : BNE bv_read

    ; --- Inside test: px_int (s8) in [left_int, right_int]
    ;     and py_int (s8) in [bot_int, top_int]?
    ; left_int (s8) = high byte of (left_lo:hi >> ?). Actually left_lo:hi
    ; is s16 (raw prescaled units). px_int is s8 (high byte of px_88).
    ; So compare s8 with s16 — sign-extend px_int and compare s16:s16.
    ; Sign-extended px_int = (px_h, $00 or $FF based on px_h).
    LDA zp_br_px_h : STA zp_br_t0
    LDA #0 : STA zp_br_t1
    LDA zp_br_t0 : BPL bv_pxext_done
    LDA #$FF : STA zp_br_t1
.bv_pxext_done
    ; left <= px ?  i.e. (px - left) >= 0 (s16 sub).
    LDA zp_br_t0 : SEC : SBC BBOX_SCRATCH+4 : STA zp_br_t2
    LDA zp_br_t1 :       SBC BBOX_SCRATCH+5 : STA zp_br_t3
    BMI bv_not_inside
    ; px <= right ?  i.e. (right - px) >= 0
    LDA BBOX_SCRATCH+6 : SEC : SBC zp_br_t0
    LDA BBOX_SCRATCH+7 :       SBC zp_br_t1
    BMI bv_not_inside
    ; py_int sign-extend
    LDA zp_br_py_h : STA zp_br_t0
    LDA #0 : STA zp_br_t1
    LDA zp_br_t0 : BPL bv_pyext_done
    LDA #$FF : STA zp_br_t1
.bv_pyext_done
    ; bot <= py ?
    LDA zp_br_t0 : SEC : SBC BBOX_SCRATCH+2
    LDA zp_br_t1 :       SBC BBOX_SCRATCH+3
    BMI bv_not_inside
    ; py <= top ?
    LDA BBOX_SCRATCH+0 : SEC : SBC zp_br_t0
    LDA BBOX_SCRATCH+1 :       SBC zp_br_t1
    BMI bv_not_inside
    ; Player is inside this bbox → call has_gap(0, 255) directly. (Match
    ; Python's fp_bbox_visible_fixed which returns (0, FPW-1) on inside hit
    ; and lets the caller call has_gap; we tail-call has_gap here so the
    ; trace shows the same has_gap event as Python.)
    LDA #0   : STA $C2
    LDA #255 : STA $C3
    JMP SC_HAS_GAP
.bv_not_inside

    ; --- Transform 4 corners and project ---
    ; Init: BBOX_FLAGS = 0, ILO = 255, IHI = 0.
    LDA #0   : STA BBOX_FLAGS
    LDA #255 : STA BBOX_ILO
    LDA #0   : STA BBOX_IHI

    ; Corner 0: (left, top) — store at BBOX_CORNERS + 0
    LDA #0 : STA BBOX_CORNER_IDX
    LDA BBOX_SCRATCH+4 : STA zp_br_dxlo
    LDA BBOX_SCRATCH+5 : STA zp_br_dxhi
    LDA BBOX_SCRATCH+0 : STA zp_br_dylo
    LDA BBOX_SCRATCH+1 : STA zp_br_dyhi
    JSR bv_proj_one

    ; Corner 1: (right, top) — store at BBOX_CORNERS + 5
    LDA #5 : STA BBOX_CORNER_IDX
    LDA BBOX_SCRATCH+6 : STA zp_br_dxlo
    LDA BBOX_SCRATCH+7 : STA zp_br_dxhi
    LDA BBOX_SCRATCH+0 : STA zp_br_dylo
    LDA BBOX_SCRATCH+1 : STA zp_br_dyhi
    JSR bv_proj_one

    ; Corner 2: (right, bot) — store at BBOX_CORNERS + 10
    LDA #10 : STA BBOX_CORNER_IDX
    LDA BBOX_SCRATCH+6 : STA zp_br_dxlo
    LDA BBOX_SCRATCH+7 : STA zp_br_dxhi
    LDA BBOX_SCRATCH+2 : STA zp_br_dylo
    LDA BBOX_SCRATCH+3 : STA zp_br_dyhi
    JSR bv_proj_one

    ; Corner 3: (left, bot) — store at BBOX_CORNERS + 15
    LDA #15 : STA BBOX_CORNER_IDX
    LDA BBOX_SCRATCH+4 : STA zp_br_dxlo
    LDA BBOX_SCRATCH+5 : STA zp_br_dxhi
    LDA BBOX_SCRATCH+2 : STA zp_br_dylo
    LDA BBOX_SCRATCH+3 : STA zp_br_dyhi
    JSR bv_proj_one

    ; --- Near-plane edge crossings: for any edge that straddles NEAR,
    ; project the crossing point's sx and update min/max. This tightens
    ; the bbox sx range (vs the conservative full-screen fallback when
    ; any corner is behind the near plane).
    JSR bv_compute_edge_crossings

    ; --- Reject tests using BBOX_FLAGS bits collected by bv_proj_one ---
    ;   bit 0: any_behind  (corner had vy < NEAR)
    ;   bit 1: any_front   (corner had vy >= NEAR)
    ;   bit 2: any_not_left  (some corner has vx + vy >= 0  → not behind L frustum)
    ;   bit 3: any_not_right (some corner has vx - vy <= 0  → not past R frustum)
    LDA BBOX_FLAGS : AND #$02 : BNE bv_have_front
    LDA #0 : RTS                              ; all behind near plane
.bv_have_front
    LDA BBOX_FLAGS : AND #$04 : BNE bv_have_not_left
    LDA #0 : RTS                              ; all left of L frustum
.bv_have_not_left
    LDA BBOX_FLAGS : AND #$08 : BNE bv_have_not_right
    LDA #0 : RTS                              ; all right of R frustum
.bv_have_not_right
    ; If any corner is behind the near plane, the bbox crosses the near
    ; plane and projection is partial. Conservatively treat as full screen
    ; (so bbox cull doesn't reject visible geometry).
    LDA BBOX_FLAGS : AND #$01 : BEQ bv_all_front
    LDA #0   : STA BBOX_ILO
    LDA #255 : STA BBOX_IHI
.bv_all_front
    ; Degenerate: ilo > ihi → reject.
    LDA BBOX_ILO : CMP BBOX_IHI : BCC bv_query
    BEQ bv_query
    LDA #0 : RTS
.bv_query
    LDA BBOX_ILO : STA $C2     ; zp_ilo
    LDA BBOX_IHI : STA $C3     ; zp_ihi
    JMP SC_HAS_GAP             ; tail-call; result in A
}

; bv_proj_one — process a single corner: transform, project, update min/max.
; Inputs: zp_br_dxlo:dxhi, zp_br_dylo:dyhi (raw prescaled corner s16).
.bv_proj_one
{
    JSR br_to_view             ; → s24 vy in (vyext, vyhi, vylo); s24 vx similarly
    ; Save vx int+frac before project_x_subpx (it uses vxlo/hi as accumulator).
    LDA zp_br_vxhi : STA zp_v_xint
    LDA zp_br_vxlo : STA zp_v_xfrac

    ; Stash s16 (vx, vy) for this corner so a later pass can compute
    ; near-plane edge crossings. (Low 16 bits are enough — for far corners
    ; with vy_ext != 0 we already mark "any-behind" and fall back to full
    ; screen, so edge crossings only matter when corners fit in s16.)
    LDX BBOX_CORNER_IDX
    LDA zp_br_vxlo : STA BBOX_CORNERS+0,X
    LDA zp_br_vxhi : STA BBOX_CORNERS+1,X
    LDA zp_br_vylo : STA BBOX_CORNERS+2,X
    LDA zp_br_vyhi : STA BBOX_CORNERS+3,X

    ; --- Frustum-side flags (run for every corner regardless of near-clip).
    ;   left frustum plane:  vx + vy = 0  (corner to the LEFT of it has vx + vy < 0).
    ;   right frustum plane: vx - vy = 0  (corner to the RIGHT of it has vx > vy).
    ; Set BBOX_FLAGS bit 2 if any corner is NOT to the left  (vx + vy >= 0).
    ; Set BBOX_FLAGS bit 3 if any corner is NOT to the right (vx - vy <= 0).
    ; vx + vy: high byte sign = sign of sum.
    LDA zp_br_vxlo  : CLC : ADC zp_br_vylo
    LDA zp_br_vxhi  :       ADC zp_br_vyhi
    LDA zp_br_vxext :       ADC zp_br_vyext
    BMI bv_lt_neg
    LDA BBOX_FLAGS : ORA #$04 : STA BBOX_FLAGS
.bv_lt_neg
    ; vx - vy: BPL means result >= 0 → vx >= vy → corner past R frustum.
    LDA zp_br_vxlo  : SEC : SBC zp_br_vylo
    LDA zp_br_vxhi  :       SBC zp_br_vyhi
    LDA zp_br_vxext :       SBC zp_br_vyext
    BMI bv_rt_set        ; result < 0 → vx < vy → not past R frustum
    BNE bv_rt_skip       ; result > 0 → vx > vy → past R frustum
    ; result == 0 → also not past (vx <= vy)
.bv_rt_set
    LDA BBOX_FLAGS : ORA #$08 : STA BBOX_FLAGS
.bv_rt_skip

    ; Near-clip test: matches Python's evy >= NEAR where evy = (total_vy + 128) >> 8.
    ; Equivalent to total_vy >= 128 (= half-integer) in 8.8 fixed-point.
    ;   vy_ext < 0  → behind
    ;   vy_ext > 0  → in front (>= 256)
    ;   vy_ext = 0:
    ;     vy_hi != 0 → in front (>= 256)
    ;     vy_hi = 0  → in front iff vy_lo >= $80
    LDA zp_br_vyext : BMI bv_behind
    BNE bv_in_front
    LDA zp_br_vyhi : BNE bv_in_front
    LDA zp_br_vylo : CMP #$80 : BCS bv_in_front
.bv_behind
    LDX BBOX_CORNER_IDX : LDA #0 : STA BBOX_CORNERS+4,X
    LDA BBOX_FLAGS : ORA #$01 : STA BBOX_FLAGS
    RTS
.bv_in_front
    LDX BBOX_CORNER_IDX : LDA #1 : STA BBOX_CORNERS+4,X
    LDA BBOX_FLAGS : ORA #$02 : STA BBOX_FLAGS
    ; If view-space x overflows s16 (vx_ext != 0), br_project_x_subpx (s8 vx
    ; assumption) would produce nonsense sx. Conservatively mark "any behind"
    ; so the final logic falls through to full-screen sx range (and lets
    ; has_gap make the call). RTS without projecting this corner.
    LDA zp_br_vxext : BEQ bv_vx_safe
    LDA BBOX_FLAGS : ORA #$01 : STA BBOX_FLAGS
    RTS
.bv_vx_safe
    ; vy_idx = (vy_ext, vy_hi, vy_lo) >> 7 (== vy_idx in 9.1 form for fp_recip).
    ; The shift folds in vy_ext properly, no clamping needed here — br_recip
    ; clamps to [2, 1023] internally.
    LDA zp_br_vylo : ASL A
    LDA zp_br_vyhi : ROL A
    STA zp_br_t0
    LDA zp_br_vyext : ROL A
    STA zp_br_t1
    JSR br_recip
    LDA zp_v_xint  : STA zp_br_t0
    LDA zp_v_xfrac : STA zp_br_t1
    JSR br_project_x_subpx
    ; Clamp s16 sx in zp_br_resl/h to u8.
    LDA zp_br_resh : BMI bv_sx_clamp_lo
    BEQ bv_sx_in_range
    LDA #255 : JMP bv_update_minmax
.bv_sx_clamp_lo
    LDA #0   : JMP bv_update_minmax
.bv_sx_in_range
    LDA zp_br_resl
.bv_update_minmax
    ; A holds clamped sx. Update min/max.
    CMP BBOX_ILO : BCS bv_no_lo
    STA BBOX_ILO
.bv_no_lo
    CMP BBOX_IHI : BCC bv_no_hi
    STA BBOX_IHI
.bv_no_hi
    RTS
}

; bv_compute_edge_crossings — for any bbox edge that straddles the near
; plane, project the crossing point's sx and update min/max. Called once
; after all 4 corners have been written to BBOX_CORNERS by bv_proj_one.
;
; Currently a no-op: when an edge straddles near, the corresponding corner
; is "behind", BBOX_FLAGS bit 0 fires and bv_have_front falls back to full
; screen [0, 255] anyway. A future tighter implementation would interpolate
; the crossing point and project it, narrowing the sx range further.
.bv_compute_edge_crossings
    RTS

; ============================================================================
; br_render_subsector — process one subsector.
;   Input: zp_node_chlo:hi = subsector id (high bit cleared).
;
;   Reads subsector header (count, first_seg). Loops through segs:
;     1. Mark visited (test instrumentation).
;     2. Read seg header (v1/v2/lv1x/lv1y/ldx/ldy/flags).
;     3. Read fh/ch from FHCH table; compute height deltas.
;     4. Back-face test; skip if back-facing.
;     5. Transform v1, v2; project to screen X and to Y for top+bot edges.
;     6. Emit top + bottom horizontals (and L+R verticals).
; ============================================================================
.br_render_subsector
{
    ; --- Mark visited (test instrumentation) ---
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

    ; --- Read subsector header from ROM_SS + id*4 ---
    LDA zp_node_chlo : STA zp_br_t0
    LDA zp_node_chhi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    CLC
    LDA zp_rom_ss_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_ss_hi : ADC zp_br_t1 : STA zp_br_p_h
    LDY #0 : LDA (zp_br_p),Y : STA zp_seg_count
    LDY #2 : LDA (zp_br_p),Y : STA zp_seg_first_lo
    LDY #3 : LDA (zp_br_p),Y : STA zp_seg_first_hi

    ; Reset deferred mark_solid buffer for this subsector.
    LDA #0 : STA DEFERRED_MS_COUNT

    ; --- Loop over segs ---
.seg_loop
    LDA zp_seg_count : BNE seg_proc
    JMP drain_deferred_ms                ; subsector done — flush deferred mark_solids
.seg_proc
    ; --- ptr to seg header = ROM_SEG_HDR + first_seg * 12 ---
    LDA zp_seg_first_lo : STA zp_br_t0
    LDA zp_seg_first_hi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1                ; *2
    ASL zp_br_t0 : ROL zp_br_t1                ; *4
    LDA zp_br_t0 : STA zp_br_t2
    LDA zp_br_t1 : STA zp_br_t3
    ASL zp_br_t0 : ROL zp_br_t1                ; *8
    CLC
    LDA zp_br_t0 : ADC zp_br_t2 : STA zp_br_t0 ; *12
    LDA zp_br_t1 : ADC zp_br_t3 : STA zp_br_t1
    CLC
    LDA zp_rom_seg_hdr_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_seg_hdr_hi : ADC zp_br_t1 : STA zp_br_p_h
    LDY #0 : LDA (zp_br_p),Y : STA zp_seg_v1_lo
    INY    : LDA (zp_br_p),Y : STA zp_seg_v1_hi
    INY    : LDA (zp_br_p),Y : STA zp_seg_v2_lo
    INY    : LDA (zp_br_p),Y : STA zp_seg_v2_hi
    INY    : LDA (zp_br_p),Y : STA zp_seg_lv1x_lo
    INY    : LDA (zp_br_p),Y : STA zp_seg_lv1x_hi
    INY    : LDA (zp_br_p),Y : STA zp_seg_lv1y_lo
    INY    : LDA (zp_br_p),Y : STA zp_seg_lv1y_hi
    INY    : LDA (zp_br_p),Y : STA zp_seg_ldx
    INY    : LDA (zp_br_p),Y : STA zp_seg_ldy
    INY    : LDA (zp_br_p),Y : STA zp_seg_flags

    ; --- Back-face test ---
    JSR br_back_face_test
    LDA zp_seg_skip : BEQ bf_passed
    JMP s_advance
.bf_passed

    ; --- Read fh, ch, bfh, bch from FHCH table at offset (seg_idx * 4) ---
    LDA zp_seg_first_lo : STA zp_br_t0
    LDA zp_seg_first_hi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1                ; *2
    ASL zp_br_t0 : ROL zp_br_t1                ; *4
    CLC
    LDA zp_rom_fhch_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_fhch_hi : ADC zp_br_t1 : STA zp_br_p_h
    LDY #0 : LDA (zp_br_p),Y : STA zp_seg_fh
    INY    : LDA (zp_br_p),Y : STA zp_seg_ch
    INY    : LDA (zp_br_p),Y : STA zp_seg_bfh
    INY    : LDA (zp_br_p),Y : STA zp_seg_bch
    ; Height deltas (all s8). Front: top_dlt = ch - vz, bot_dlt = fh - vz.
    ; Back: btop_dlt = bch - vz, bbot_dlt = bfh - vz.
    LDA zp_seg_ch  : SEC : SBC zp_br_vz : STA zp_seg_top_dlt
    LDA zp_seg_fh  : SEC : SBC zp_br_vz : STA zp_seg_bot_dlt
    LDA zp_seg_bch : SEC : SBC zp_br_vz : STA zp_seg_btop_dlt
    LDA zp_seg_bfh : SEC : SBC zp_br_vz : STA zp_seg_bbot_dlt

    ; Transform v1. Always copy evy/evx/clipped so both endpoints are
    ; available for near-plane crossing math even when one side is clipped.
    LDA zp_seg_v1_lo : STA zp_br_t0
    LDA zp_seg_v1_hi : STA zp_br_t1
    JSR br_seg_xform_vertex
    LDA zp_seg_cur_evy : STA zp_seg_v1_evy
    LDA zp_seg_cur_evx : STA zp_seg_v1_evx
    LDA zp_seg_skip    : STA zp_seg_v1_clipped
    BNE s_v1_skipped
    JSR copy_seg_to_v1
.s_v1_skipped

    ; Transform v2.
    LDA zp_seg_v2_lo : STA zp_br_t0
    LDA zp_seg_v2_hi : STA zp_br_t1
    JSR br_seg_xform_vertex
    LDA zp_seg_cur_evy : STA zp_seg_v2_evy
    LDA zp_seg_cur_evx : STA zp_seg_v2_evx
    LDA zp_seg_skip    : STA zp_seg_v2_clipped
    BNE s_v2_skipped
    JSR copy_seg_to_v2
.s_v2_skipped

    ; Both vertices xform'd. If both clipped → bail. If exactly one clipped,
    ; reproject from crossing point and copy into that vertex's slots.
    ; Either clipped: bail solid walls (over-occlude when crossed),
    ; reproject portals (no mark_solid → safe to render).
    LDA zp_seg_v1_clipped : ORA zp_seg_v2_clipped
    BEQ s_both_have_proj
    LDA zp_seg_flags : AND #$02 : BNE s_advance_jmp  ; solid → bail
    LDA zp_seg_v1_clipped
    BEQ s_v2_was_clipped
    LDA zp_seg_v2_clipped
    BNE s_advance_jmp                                 ; both clipped
    JSR reproject_at_crossing
    JSR copy_seg_to_v1
    JMP s_both_have_proj
.s_advance_jmp
    JMP s_advance
.s_v2_was_clipped
    JSR reproject_at_crossing
    JSR copy_seg_to_v2
.s_both_have_proj

    ; Match Python's has_gap wrapper:
    ;   ilo = max(0, lo); ihi = min(255, hi); if ihi < ilo: return False
    ; The wrapper-side off-screen test bails BEFORE the 6502 has_gap call,
    ; so we replicate it here. Both endpoints off-screen-left  (both s16 hi
    ; negative) → ihi = -lo_min (negative), ilo = 0  → ihi < ilo, bail.
    ; Both off-screen-right (both s16 hi > 0)         → ilo = lo_max > 255,
    ; clamped to 255; ihi clamped to 255 too — borderline; let has_gap run.
    ; Only the left/negative case bails cleanly with a sign test.
    LDA zp_seg_sx1_hi : BPL hg_sx1_nonneg
    LDA zp_seg_sx2_hi : BPL hg_sx1_nonneg
    JMP s_advance                       ; both s16 hi < 0 → off-screen left
.hg_sx1_nonneg
    ; Both off-screen right? Need BOTH hi bytes strictly positive (>= 1).
    LDA zp_seg_sx1_hi : BMI hg_check_x  ; one negative → mixed, don't bail
    BEQ hg_check_x                      ; one zero → in u8 range, don't bail
    LDA zp_seg_sx2_hi : BMI hg_check_x
    BEQ hg_check_x
    JMP s_advance                       ; both s16 hi > 0 → off-screen right
.hg_check_x

    ; Compute clamped u8 ilo/ihi from sx1/sx2.
    LDA zp_seg_sx1_hi : BMI hg_sx1_neg
    BEQ hg_sx1_lo
    LDA #$FF : STA zp_br_t2 : JMP hg_sx2
.hg_sx1_neg
    LDA #0   : STA zp_br_t2 : JMP hg_sx2
.hg_sx1_lo
    LDA zp_seg_sx1_lo : STA zp_br_t2
.hg_sx2
    LDA zp_seg_sx2_hi : BMI hg_sx2_neg
    BEQ hg_sx2_lo
    LDA #$FF : STA zp_br_t3 : JMP hg_setrange
.hg_sx2_neg
    LDA #0   : STA zp_br_t3 : JMP hg_setrange
.hg_sx2_lo
    LDA zp_seg_sx2_lo : STA zp_br_t3
.hg_setrange
    LDA zp_br_t2 : CMP zp_br_t3 : BCC hg_t2lt
    LDA zp_br_t3 : STA $C2
    LDA zp_br_t2 : STA $C3
    JMP hg_query
.hg_t2lt
    LDA zp_br_t2 : STA $C2
    LDA zp_br_t3 : STA $C3
.hg_query
    JSR SC_HAS_GAP
    BNE hg_pass
    JMP s_advance
.hg_pass

    ; --- Emit top horizontal (front-sector ceiling) ---
    ; Solid wall:        always.
    ; Portal w/ NEEDBT:  iff ch > vz (face above eyeline, ft visible).
    ; Portal w/o NEEDBT: iff bch > ch (back ceiling above front; step visible).
    LDA zp_seg_flags : AND #$02 : BNE ft_emit       ; SF_SOLID → emit
    LDA zp_seg_flags : AND #$04 : BEQ ft_no_needbt
    ; NEEDBT: emit only if ch > vz (s8 compare via signed test on ch - vz).
    LDA zp_seg_ch : SEC : SBC zp_br_vz : BMI ft_skip
    BEQ ft_skip
    JMP ft_emit
.ft_no_needbt
    ; bch > ch ?
    LDA zp_seg_bch : SEC : SBC zp_seg_ch : BMI ft_skip
    BEQ ft_skip
.ft_emit
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sy1_top_lo : STA zp_line_yl
    LDA zp_seg_sy1_top_hi : STA $B3
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA zp_seg_sy2_top_lo : STA zp_line_yr
    LDA zp_seg_sy2_top_hi : STA $B5
    LDA #0   : STA $BD
    JSR SC_DRAW_S16
.ft_skip

    ; --- Emit bottom horizontal (front-sector floor) ---
    ; Solid:             always.
    ; Portal w/ NEEDBB:  iff fh < vz (face below eyeline, fb visible).
    ; Portal w/o NEEDBB: iff bfh < fh (back floor below front; step visible).
    LDA zp_seg_flags : AND #$02 : BNE fb_emit
    LDA zp_seg_flags : AND #$08 : BEQ fb_no_needbb
    ; NEEDBB: emit only if fh < vz (vz - fh > 0).
    LDA zp_br_vz : SEC : SBC zp_seg_fh : BMI fb_skip
    BEQ fb_skip
    JMP fb_emit
.fb_no_needbb
    ; bfh < fh ?
    LDA zp_seg_fh : SEC : SBC zp_seg_bfh : BMI fb_skip
    BEQ fb_skip
.fb_emit
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sy1_bot_lo : STA zp_line_yl
    LDA zp_seg_sy1_bot_hi : STA $B3
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA zp_seg_sy2_bot_lo : STA zp_line_yr
    LDA zp_seg_sy2_bot_hi : STA $B5
    LDA #0   : STA $BD
    JSR SC_DRAW_S16
.fb_skip

    ; --- Portal step edges (back ceiling / floor) ---
    ; Solid walls have no back sector — skip the step emits.
    LDA zp_seg_flags : AND #$02 : BNE step_skip   ; SF_SOLID set → skip steps

    ; Back ceiling step if NEEDBT (= $04) set: emit (sx1, bt1) → (sx2, bt2).
    LDA zp_seg_flags : AND #$04 : BEQ step_no_top
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sy1_btop_lo : STA zp_line_yl
    LDA zp_seg_sy1_btop_hi : STA $B3
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA zp_seg_sy2_btop_lo : STA zp_line_yr
    LDA zp_seg_sy2_btop_hi : STA $B5
    LDA #0   : STA $BD
    JSR SC_DRAW_S16
.step_no_top

    ; Back floor step if NEEDBB (= $08) set: emit (sx1, bb1) → (sx2, bb2).
    LDA zp_seg_flags : AND #$08 : BEQ step_no_bot
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sy1_bbot_lo : STA zp_line_yl
    LDA zp_seg_sy1_bbot_hi : STA $B3
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA zp_seg_sy2_bbot_lo : STA zp_line_yr
    LDA zp_seg_sy2_bbot_hi : STA $B5
    LDA #0   : STA $BD
    JSR SC_DRAW_S16
.step_no_bot
.step_skip

    ; --- Emit verticals ---
    ; Solid wall: full ft-to-fb on both sides.
    ; Portal: ft-to-bt for NEEDBT (top doorframe edge),
    ;         bb-to-fb for NEEDBB (bottom doorframe edge).
    ;         Both for NEEDBT+NEEDBB. Otherwise no vertical.
    ; SF_NOVT1/NOVT2 still suppress verticals at BSP-internal split vertices.

    ; Left vertical (sx1).
    LDA zp_seg_flags : AND #$10 : BNE skip_lvert
    LDA zp_seg_sx1_hi : BNE skip_lvert      ; sx1 off-screen → skip vertical
    LDA zp_seg_flags : AND #$02 : BEQ lvert_portal
    ; Solid: ft1 → fb1
    LDA zp_seg_sy1_top_lo : STA zp_line_yl
    LDA zp_seg_sy1_top_hi : STA $B3
    LDA zp_seg_sy1_bot_lo : STA zp_line_yr
    LDA zp_seg_sy1_bot_hi : STA $B5
    JSR emit_vert_sx1
    JMP skip_lvert
.lvert_portal
    ; NEEDBT? top piece ft1 → bt1
    LDA zp_seg_flags : AND #$04 : BEQ lvert_no_top
    LDA zp_seg_sy1_top_lo : STA zp_line_yl
    LDA zp_seg_sy1_top_hi : STA $B3
    LDA zp_seg_sy1_btop_lo : STA zp_line_yr
    LDA zp_seg_sy1_btop_hi : STA $B5
    JSR emit_vert_sx1
.lvert_no_top
    ; NEEDBB? bottom piece bb1 → fb1
    LDA zp_seg_flags : AND #$08 : BEQ skip_lvert
    LDA zp_seg_sy1_bbot_lo : STA zp_line_yl
    LDA zp_seg_sy1_bbot_hi : STA $B3
    LDA zp_seg_sy1_bot_lo : STA zp_line_yr
    LDA zp_seg_sy1_bot_hi : STA $B5
    JSR emit_vert_sx1
.skip_lvert

    ; Right vertical (sx2).
    LDA zp_seg_flags : AND #$20 : BNE skip_rvert
    LDA zp_seg_sx2_hi : BNE skip_rvert       ; sx2 off-screen → skip vertical
    LDA zp_seg_flags : AND #$02 : BEQ rvert_portal
    LDA zp_seg_sy2_top_lo : STA zp_line_yl
    LDA zp_seg_sy2_top_hi : STA $B3
    LDA zp_seg_sy2_bot_lo : STA zp_line_yr
    LDA zp_seg_sy2_bot_hi : STA $B5
    JSR emit_vert_sx2
    JMP skip_rvert
.rvert_portal
    LDA zp_seg_flags : AND #$04 : BEQ rvert_no_top
    LDA zp_seg_sy2_top_lo : STA zp_line_yl
    LDA zp_seg_sy2_top_hi : STA $B3
    LDA zp_seg_sy2_btop_lo : STA zp_line_yr
    LDA zp_seg_sy2_btop_hi : STA $B5
    JSR emit_vert_sx2
.rvert_no_top
    LDA zp_seg_flags : AND #$08 : BEQ skip_rvert
    LDA zp_seg_sy2_bbot_lo : STA zp_line_yl
    LDA zp_seg_sy2_bbot_hi : STA $B3
    LDA zp_seg_sy2_bot_lo : STA zp_line_yr
    LDA zp_seg_sy2_bot_hi : STA $B5
    JSR emit_vert_sx2
.skip_rvert

    ; --- Compute clamped u8 ilo/ihi for both solid (mark_solid) and
    ;     portal (tighten) cases.
    ; Clamp sx1 to u8 → zp_br_t2
    LDA zp_seg_sx1_hi : BMI ms_sx1_neg
    BEQ ms_sx1_lo
    LDA #$FF : STA zp_br_t2 : JMP ms_sx2
.ms_sx1_neg
    LDA #0   : STA zp_br_t2 : JMP ms_sx2
.ms_sx1_lo
    LDA zp_seg_sx1_lo : STA zp_br_t2
.ms_sx2
    ; Clamp sx2 to u8 → zp_br_t3
    LDA zp_seg_sx2_hi : BMI ms_sx2_neg
    BEQ ms_sx2_lo
    LDA #$FF : STA zp_br_t3 : JMP ms_setrange
.ms_sx2_neg
    LDA #0   : STA zp_br_t3 : JMP ms_setrange
.ms_sx2_lo
    LDA zp_seg_sx2_lo : STA zp_br_t3
.ms_setrange
    ; ilo = min(t2, t3), ihi = max(t2, t3)
    LDA zp_br_t2 : CMP zp_br_t3 : BCC ms_t2lt
    LDA zp_br_t3 : STA $C2          ; ilo = t3
    LDA zp_br_t2 : STA $C3          ; ihi = t2
    JMP ms_dispatch
.ms_t2lt
    LDA zp_br_t2 : STA $C2          ; ilo = t2
    LDA zp_br_t3 : STA $C3          ; ihi = t3
.ms_dispatch
    LDA zp_seg_flags : AND #$02 : BEQ ms_skip
    ; --- Solid wall: defer mark_solid (Python collects them per subsector
    ;     and applies at the end). Append (ilo, ihi) to DEFERRED_MS_BUF. ---
    LDX DEFERRED_MS_COUNT
    LDA $C2 : STA DEFERRED_MS_BUF,X : INX
    LDA $C3 : STA DEFERRED_MS_BUF,X : INX
    STX DEFERRED_MS_COUNT
.ms_skip

.s_advance
    LDA #0 : STA zp_seg_skip
    INC zp_seg_first_lo : BNE s_no_carry
    INC zp_seg_first_hi
.s_no_carry
    DEC zp_seg_count
    JMP seg_loop
}

; drain_deferred_ms — apply queued mark_solid ops at end of subsector.
; Each entry is (ilo, ihi). is_full check between ops matches Python's
; "if clips.is_full(): return" inside the deferred-ops loop.
.drain_deferred_ms
{
    LDX #0
.dms_loop
    CPX DEFERRED_MS_COUNT : BCS dms_done
    LDA DEFERRED_MS_BUF,X : STA $C2
    INX
    LDA DEFERRED_MS_BUF,X : STA $C3
    INX
    STX zp_br_t0                  ; save X across SC_MARK_SOLID call
    LDA #0 : STA $A8              ; zp_ms_emit = 0
    JSR SC_MARK_SOLID
    JSR SC_IS_FULL
    BNE dms_done
    LDX zp_br_t0
    JMP dms_loop
.dms_done
    RTS
}

; emit_vert_sx1 — caller has set yl/yh/yr/yh in zp_line_yl/$B3/zp_line_yr/$B5.
; Fills xl/xh/xr/xh from sx1, clears records hi byte, calls SC_DRAW_S16.
.emit_vert_sx1
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sx1_lo : STA zp_line_xr
    LDA zp_seg_sx1_hi : STA $B4
    LDA #0 : STA $BD
    JMP SC_DRAW_S16

.emit_vert_sx2
    LDA zp_seg_sx2_lo : STA zp_line_xl
    LDA zp_seg_sx2_hi : STA $B2
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA #0 : STA $BD
    JMP SC_DRAW_S16

; ============================================================================
; br_seg_xform_vertex — fetch vertex by index, transform to view, project X.
;   Input:  zp_br_t0:t1 = vertex index (u16).
;   Output: zp_br_resl/h = screen x (s16). zp_seg_skip = 1 if near-clipped.
; ============================================================================
.br_seg_xform_vertex
{
    LDA #0 : STA zp_seg_skip

    ; --- Compute vertex cache index (idx*8 → cache offset) ---
    ; idx is in zp_br_t0:t1 (u16). vc_offset = idx * 8 (s/o offset for valid).
    ; valid_byte_offset = idx >> 3, valid_bit = idx & 7.
    ;
    ; Save idx for later (cache write) at zp_seg_v_idx_lo/hi.
    LDA zp_br_t0 : STA zp_seg_v_idx_lo
    LDA zp_br_t1 : STA zp_seg_v_idx_hi

    ; --- Check valid bit ---
    ; valid_byte_offset = idx_lo >> 3 + idx_hi << 5 (since high byte each adds 32 bytes)
    LDA zp_br_t0 : STA zp_br_t2
    LDA zp_br_t1 : STA zp_br_t3
    LSR zp_br_t3 : ROR zp_br_t2
    LSR zp_br_t3 : ROR zp_br_t2
    LSR zp_br_t3 : ROR zp_br_t2          ; t2:t3 = idx >> 3
    CLC
    LDA #<VCACHE_VALID_BASE : ADC zp_br_t2 : STA zp_br_p
    LDA #>VCACHE_VALID_BASE : ADC zp_br_t3 : STA zp_br_p_h
    ; bit mask = 1 << (idx_lo & 7)
    LDA zp_br_t0 : AND #7 : TAX
    LDA #1
.vc_bitm
    DEX : BMI vc_bitm_done
    ASL A
    JMP vc_bitm
.vc_bitm_done
    STA zp_seg_v_bitm
    LDY #0 : LDA (zp_br_p),Y : AND zp_seg_v_bitm : BNE vc_hit
    JMP vc_miss

.vc_hit
    ; --- Cache hit: load evy, evx, rhi/rlo, sx, near-clip flag from cache ---
    ; Cache offset = idx*8. Compute base ptr.
    LDA zp_seg_v_idx_lo : STA zp_br_t2
    LDA zp_seg_v_idx_hi : STA zp_br_t3
    ASL zp_br_t2 : ROL zp_br_t3                ; *2
    ASL zp_br_t2 : ROL zp_br_t3                ; *4
    ASL zp_br_t2 : ROL zp_br_t3                ; *8
    CLC
    LDA #<VCACHE_BASE : ADC zp_br_t2 : STA zp_br_p
    LDA #>VCACHE_BASE : ADC zp_br_t3 : STA zp_br_p_h
    ; Load evy, evx (offsets 0, 1) into current slots — needed for near-plane
    ; crossing math even when the vertex is clipped or a cache hit.
    LDY #0 : LDA (zp_br_p),Y : STA zp_seg_cur_evy
    INY    : LDA (zp_br_p),Y : STA zp_seg_cur_evx
    ; Check near-clip flag at offset 6
    LDY #6 : LDA (zp_br_p),Y : BEQ vc_hit_ok
    LDA #1 : STA zp_seg_skip : RTS
.vc_hit_ok
    ; Load rhi, rlo, sx from cache.
    LDY #2 : LDA (zp_br_p),Y : STA zp_br_rhi
    INY    : LDA (zp_br_p),Y : STA zp_br_rlo
    INY    : LDA (zp_br_p),Y : STA zp_seg_sx_lo
    INY    : LDA (zp_br_p),Y : STA zp_seg_sx_hi
    ; Project Y for top + bottom (heights vary per seg, can't cache).
    JMP do_project_y

.vc_miss
    ; --- Set valid bit ---
    LDY #0 : LDA (zp_br_p),Y : ORA zp_seg_v_bitm : STA (zp_br_p),Y

    ; --- Compute cache base ptr (idx*8) ---
    LDA zp_seg_v_idx_lo : STA zp_br_t2
    LDA zp_seg_v_idx_hi : STA zp_br_t3
    ASL zp_br_t2 : ROL zp_br_t3
    ASL zp_br_t2 : ROL zp_br_t3
    ASL zp_br_t2 : ROL zp_br_t3                ; *8
    CLC
    LDA #<VCACHE_BASE : ADC zp_br_t2 : STA zp_seg_v_cache_lo
    LDA #>VCACHE_BASE : ADC zp_br_t3 : STA zp_seg_v_cache_hi

    ; --- Read s16 vertex x, y from ROM_VERTS + idx*4 ---
    LDA zp_seg_v_idx_lo : STA zp_br_t2
    LDA zp_seg_v_idx_hi : STA zp_br_t3
    ASL zp_br_t2 : ROL zp_br_t3
    ASL zp_br_t2 : ROL zp_br_t3
    CLC
    LDA zp_rom_verts_lo : ADC zp_br_t2 : STA zp_br_p
    LDA zp_rom_verts_hi : ADC zp_br_t3 : STA zp_br_p_h
    LDY #0 : LDA (zp_br_p),Y : STA zp_br_dxlo
    LDY #1 : LDA (zp_br_p),Y : STA zp_br_dxhi
    LDY #2 : LDA (zp_br_p),Y : STA zp_br_dylo
    LDY #3 : LDA (zp_br_p),Y : STA zp_br_dyhi

    JSR br_to_view

    ; Save view-space x (vxhi=int part, vxlo=frac part) before project_y
    ; clobbers vxlo/hi.
    LDA zp_br_vxhi : STA zp_v_xint
    LDA zp_br_vxlo : STA zp_v_xfrac

    ; Compute evx = vxhi (truncated s8) and evy = (vy + 128) >> 8 from the
    ; full s24 view-y (vyext, vyhi, vylo). Far-behind segs have negative
    ; vyext that overflows the s16 (vyhi:vylo) representation — using
    ; only vyhi misses the sign and lets clipped segs through.
    LDA zp_br_vxhi : STA zp_seg_cur_evx
    LDA zp_br_vylo : ASL A             ; carry = bit 7 of vylo
    LDA zp_br_vyhi : ADC #0            ; A = (vyhi:vylo + 128) >> 8 low byte
    STA zp_seg_cur_evy
    ; If vyext is non-zero, evy doesn't fit s8. Clamp the saved value to
    ; the sign of vyext so the cache + crossing-math see a consistent
    ; "very negative" or "very positive" tag.
    LDA zp_br_vyext : BEQ ev_evy_done
    BMI ev_evy_neg
    LDA #$7F : STA zp_seg_cur_evy
    JMP ev_evy_done
.ev_evy_neg
    LDA #$80 : STA zp_seg_cur_evy
.ev_evy_done

    ; Pre-write evy/evx into cache (offsets 0/1) — needed on any future
    ; cache hit, including the near-clipped path.
    LDA zp_seg_v_cache_lo : STA zp_br_p
    LDA zp_seg_v_cache_hi : STA zp_br_p_h
    LDY #0 : LDA zp_seg_cur_evy : STA (zp_br_p),Y
    INY    : LDA zp_seg_cur_evx : STA (zp_br_p),Y

    ; Near-clip on full s24: clipped iff total_vy < NEAR_88 (= 128 in 8.8).
    ;   vyext < 0 → clipped (very negative)
    ;   vyext > 0 → ok      (very positive, ≥ 256)
    ;   vyext = 0 → check (vyhi + carry from vylo bit 7) >= 1.
    LDA zp_br_vyext : BMI nc_fail
    BNE nc_ok
    LDA zp_seg_cur_evy : BMI nc_fail
    BEQ nc_fail
    JMP nc_ok
.nc_fail
    ; Mark near-clipped in cache, set skip.
    LDY #6 : LDA #1 : STA (zp_br_p),Y
    LDA #1 : STA zp_seg_skip
    RTS
.nc_ok
    ; --- Compute reciprocal (s16 vy_idx — vy_ext ignored per s8 vx contract) ---
    LDA zp_br_vylo : ASL A
    LDA zp_br_vyhi : ROL A
    STA zp_br_t0
    LDA #0 : ROL A
    STA zp_br_t1
    JSR br_recip                        ; rhi/rlo = reciprocal

    ; --- Project X using saved view-x integer + fractional parts ---
    LDA zp_v_xint  : STA zp_br_t0
    LDA zp_v_xfrac : STA zp_br_t1
    JSR br_project_x_subpx
    LDA zp_br_resl : STA zp_seg_sx_lo
    LDA zp_br_resh : STA zp_seg_sx_hi

    ; --- Cache the per-vertex results (rhi, rlo, sx, near-clip=0) ---
    LDA zp_seg_v_cache_lo : STA zp_br_p
    LDA zp_seg_v_cache_hi : STA zp_br_p_h
    LDY #2 : LDA zp_br_rhi : STA (zp_br_p),Y
    INY    : LDA zp_br_rlo : STA (zp_br_p),Y
    INY    : LDA zp_seg_sx_lo : STA (zp_br_p),Y
    INY    : LDA zp_seg_sx_hi : STA (zp_br_p),Y
    INY    : LDA #0 : STA (zp_br_p),Y       ; near_clip = 0

.do_project_y
    ; --- Project Y for top edge (height = ch - vz) ---
    LDA zp_seg_top_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_top_lo
    LDA zp_br_resh : STA zp_seg_sy_top_hi

    ; --- Project Y for bottom edge (height = fh - vz) ---
    LDA zp_seg_bot_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_bot_lo
    LDA zp_br_resh : STA zp_seg_sy_bot_hi

    ; --- Project Y for back ceiling (height = bch - vz) ---
    LDA zp_seg_btop_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_btop_lo
    LDA zp_br_resh : STA zp_seg_sy_btop_hi

    ; --- Project Y for back floor (height = bfh - vz) ---
    LDA zp_seg_bbot_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_bbot_lo
    LDA zp_br_resh : STA zp_seg_sy_bbot_hi
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

; ============================================================================
; OVERFLOW REGION — bsp_render.bin is bound to $4800-$57FF (4096 bytes max,
; framebuffer starts at $5800). Helpers that don't fit live here at $1C00 and
; are loaded as a separate binary by span_clip_6502.py (bsp_render_lo.bin).
; ============================================================================
ORG $1C00
.bsp_lo_start

; reproject_at_crossing — call cross_compute, then project sx + 4 sy values
; using the reciprocal at NEAR. Output → zp_seg_sx_lo/hi, zp_seg_sy_*.
.reproject_at_crossing
{
    JSR cross_compute
    LDA zp_clip_cx : STA zp_br_t0
    LDA #0          : STA zp_br_t1
    JSR br_project_x_subpx
    LDA zp_br_resl : STA zp_seg_sx_lo
    LDA zp_br_resh : STA zp_seg_sx_hi
    LDA zp_seg_top_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_top_lo
    LDA zp_br_resh : STA zp_seg_sy_top_hi
    LDA zp_seg_bot_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_bot_lo
    LDA zp_br_resh : STA zp_seg_sy_bot_hi
    LDA zp_seg_btop_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_btop_lo
    LDA zp_br_resh : STA zp_seg_sy_btop_hi
    LDA zp_seg_bbot_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_bbot_lo
    LDA zp_br_resh : STA zp_seg_sy_bbot_hi
    RTS
}

; copy_seg_to_v1 / copy_seg_to_v2 — copy zp_seg_sx_*/sy_*_* into vN slots,
; biasing sy by Y_BIAS (= 48). Used after both br_seg_xform_vertex and
; reproject_at_crossing fill the "current vertex" slots.
.copy_seg_to_v1
    LDA zp_seg_sx_lo : STA zp_seg_sx1_lo
    LDA zp_seg_sx_hi : STA zp_seg_sx1_hi
    LDA zp_seg_sy_top_lo  : CLC : ADC #48 : STA zp_seg_sy1_top_lo
    LDA zp_seg_sy_top_hi  :       ADC #0  : STA zp_seg_sy1_top_hi
    LDA zp_seg_sy_bot_lo  : CLC : ADC #48 : STA zp_seg_sy1_bot_lo
    LDA zp_seg_sy_bot_hi  :       ADC #0  : STA zp_seg_sy1_bot_hi
    LDA zp_seg_sy_btop_lo : CLC : ADC #48 : STA zp_seg_sy1_btop_lo
    LDA zp_seg_sy_btop_hi :       ADC #0  : STA zp_seg_sy1_btop_hi
    LDA zp_seg_sy_bbot_lo : CLC : ADC #48 : STA zp_seg_sy1_bbot_lo
    LDA zp_seg_sy_bbot_hi :       ADC #0  : STA zp_seg_sy1_bbot_hi
    RTS

.copy_seg_to_v2
    LDA zp_seg_sx_lo : STA zp_seg_sx2_lo
    LDA zp_seg_sx_hi : STA zp_seg_sx2_hi
    LDA zp_seg_sy_top_lo  : CLC : ADC #48 : STA zp_seg_sy2_top_lo
    LDA zp_seg_sy_top_hi  :       ADC #0  : STA zp_seg_sy2_top_hi
    LDA zp_seg_sy_bot_lo  : CLC : ADC #48 : STA zp_seg_sy2_bot_lo
    LDA zp_seg_sy_bot_hi  :       ADC #0  : STA zp_seg_sy2_bot_hi
    LDA zp_seg_sy_btop_lo : CLC : ADC #48 : STA zp_seg_sy2_btop_lo
    LDA zp_seg_sy_btop_hi :       ADC #0  : STA zp_seg_sy2_btop_hi
    LDA zp_seg_sy_bbot_lo : CLC : ADC #48 : STA zp_seg_sy2_bbot_lo
    LDA zp_seg_sy_bbot_hi :       ADC #0  : STA zp_seg_sy2_bbot_hi
    RTS

; cross_compute — near-plane crossing point for a seg with one clipped vertex.
;   Inputs:  zp_clip_C_evy, zp_clip_C_evx (clipped, evy ≤ 0)
;            zp_clip_U_evy, zp_clip_U_evx (unclipped, evy ≥ 1)
;   Outputs: zp_clip_cx (s8 crossing view-x), zp_br_rhi/rlo (recip at NEAR)
;
;   Mirrors fp_near_clip exactly:
;     t   = ((NEAR - vy_C) << 8) / (vy_U - vy_C)    (u8 truncated)
;     dvx = vx_U - vx_C                              (s9: -255..255)
;     cx  = vx_C + (t * dvx) >> 8                    (s8 wraparound)
.cross_compute
{
    ; Compute cx = v1_evx + (t * (v2_evx - v1_evx)) >> 8 where
    ;   t = ((NEAR - v1_evy) << 8) / (v2_evy - v1_evy)
    ; matching Python's fp_near_clip path. Both num and den always share
    ; sign in our cases (one vertex clipped, one not), so t is non-negative.
    ; Use unsigned division on magnitudes; sign of the t*dvx term comes
    ; from dvx alone.

    ; Special case: v2_evy = NEAR. Then |num| = |den|, t would be 256 and
    ; wrap to 0 in u8. Crossing point is v2 itself.
    LDA zp_seg_v2_evy : CMP #1 : BNE c_normal
    LDA zp_seg_v2_evx : STA zp_clip_cx
    JMP c_set_recip
.c_normal

    ; |num| = |1 - v1_evy| via signed abs of (1 - v1_evy).
    LDA #1 : SEC : SBC zp_seg_v1_evy
    BPL c_num_ok
    EOR #$FF : CLC : ADC #1
.c_num_ok
    STA zp_div_hi
    LDA #0 : STA zp_div_lo

    ; |den| = |v2_evy - v1_evy|
    LDA zp_seg_v2_evy : SEC : SBC zp_seg_v1_evy
    BPL c_den_ok
    EOR #$FF : CLC : ADC #1
.c_den_ok
    STA zp_div_den

    JSR SC_UDIV16_8                              ; A = t (u8)
    STA zp_br_a

    ; dvx = v2_evx - v1_evx as s16 (sign-extend then subtract).
    LDA zp_seg_v2_evx : STA zp_br_dxlo
    LDA #0 : STA zp_br_dxhi
    LDA zp_seg_v2_evx : BPL c_v2_pos
    LDA #$FF : STA zp_br_dxhi
.c_v2_pos
    LDA zp_seg_v1_evx : BPL c_v1_pos
    LDA zp_br_dxlo : SEC : SBC zp_seg_v1_evx : STA zp_br_dxlo
    LDA zp_br_dxhi :       SBC #$FF           : STA zp_br_dxhi
    JMP c_have_dvx
.c_v1_pos
    LDA zp_br_dxlo : SEC : SBC zp_seg_v1_evx : STA zp_br_dxlo
    LDA zp_br_dxhi :       SBC #0             : STA zp_br_dxhi
.c_have_dvx

    JSR cross_umul_u8_s16
    LDA zp_seg_v1_evx : CLC : ADC zp_br_resh : STA zp_clip_cx

.c_set_recip
    LDA #2 : STA zp_br_t0
    LDA #0 : STA zp_br_t1
    JMP br_recip
}

; cross_umul_u8_s16 — t (u8 in zp_br_a) × dx (s16 in zp_br_dxlo:dxhi) → s16
; in zp_br_resl:resh. Caller takes resh as the (>>8) result.
.cross_umul_u8_s16
{
    ; |dx|: track sign in zp_br_sign.
    LDA #0 : STA zp_br_sign
    LDA zp_br_dxhi : BPL c2_dxp
    LDA #0 : SEC : SBC zp_br_dxlo : STA zp_br_dxlo
    LDA #0 :       SBC zp_br_dxhi : STA zp_br_dxhi
    INC zp_br_sign
.c2_dxp
    ; t * |dx|_lo (u8 × u8 → u16 → resl:resh)
    LDA zp_br_dxlo : STA zp_mul_b
    LDA zp_br_a
    JSR SC_UMUL8
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh
    ; t * |dx|_hi (u8 × u8 → contributes to resh)
    LDA zp_br_dxhi : STA zp_mul_b
    LDA zp_br_a
    JSR SC_UMUL8
    LDA zp_br_resh : CLC : ADC zp_prod_lo : STA zp_br_resh
    ; sign-flip if dx was negative
    LDA zp_br_sign : BEQ c2_pos
    LDA #0 : SEC : SBC zp_br_resl : STA zp_br_resl
    LDA #0 :       SBC zp_br_resh : STA zp_br_resh
.c2_pos
    RTS
}

; br_node_setup — read node from ROM, compute side, set BSP_NEAR/FAR.
; Called twice per internal node (entry + post-near phases).
.br_node_setup
{
    LDA zp_node_chlo : STA zp_br_t0
    LDA zp_node_chhi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    CLC
    LDA zp_rom_nodes_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_nodes_hi : ADC zp_br_t1 : STA zp_br_p_h
    LDY #0 : LDA (zp_br_p),Y : STA zp_node_nxlo
    INY    : LDA (zp_br_p),Y : STA zp_node_nxhi
    INY    : LDA (zp_br_p),Y : STA zp_node_nylo
    INY    : LDA (zp_br_p),Y : STA zp_node_nyhi
    INY    : LDA (zp_br_p),Y : STA zp_node_dxlo
    INY    : LDA (zp_br_p),Y : STA zp_node_dxhi
    INY    : LDA (zp_br_p),Y : STA zp_node_dylo
    INY    : LDA (zp_br_p),Y : STA zp_node_dyhi
    LDA zp_br_pxraw_lo : SEC : SBC zp_node_nxlo : STA zp_seg_dxraw_lo
    LDA zp_br_pxraw_hi :       SBC zp_node_nxhi : STA zp_seg_dxraw_hi
    LDA zp_br_pyraw_lo : SEC : SBC zp_node_nylo : STA zp_seg_dyraw_lo
    LDA zp_br_pyraw_hi :       SBC zp_node_nyhi : STA zp_seg_dyraw_hi
    LDA zp_node_dxlo : ORA zp_node_dxhi : BNE ns_ndx_nz
    LDA zp_node_dylo : ORA zp_node_dyhi : BEQ ns_jmp_side1
    LDA zp_seg_dxraw_lo : ORA zp_seg_dxraw_hi : BEQ ns_jmp_side1
    LDA zp_node_dyhi : EOR zp_seg_dxraw_hi : BMI ns_jmp_side1
    JMP ns_side0
.ns_jmp_side1
    JMP ns_side1
.ns_ndx_nz
    LDA zp_node_dylo : ORA zp_node_dyhi : BNE ns_general
    LDA zp_seg_dyraw_lo : ORA zp_seg_dyraw_hi : BEQ ns_jmp_side1
    LDA zp_node_dxhi : EOR zp_seg_dyraw_hi : BPL ns_jmp_side1
    JMP ns_side0
.ns_general
    LDA zp_seg_dxraw_lo : STA zp_br_dxlo
    LDA zp_seg_dxraw_hi : STA zp_br_dxhi
    LDA zp_node_dylo : STA zp_br_dylo
    LDA zp_node_dyhi : STA zp_br_dyhi
    JSR br_smul_s16_s16_s32
    LDA zp_br_t0 : STA $0A50
    LDA zp_br_t1 : STA $0A51
    LDA zp_br_t2 : STA $0A52
    LDA zp_seg_dyraw_lo : STA zp_br_dxlo
    LDA zp_seg_dyraw_hi : STA zp_br_dxhi
    LDA zp_node_dxlo : STA zp_br_dylo
    LDA zp_node_dxhi : STA zp_br_dyhi
    JSR br_smul_s16_s16_s32
    LDA $0A50 : SEC : SBC zp_br_t0 : STA $0A50
    LDA $0A51 :       SBC zp_br_t1 : STA $0A51
    LDA $0A52 :       SBC zp_br_t2 : STA $0A52
    LDA $0A52 : BMI ns_side1
    ORA $0A51 : ORA $0A50 : BEQ ns_side1
.ns_side0
    LDA #0 : STA zp_side : JMP ns_done
.ns_side1
    LDA #1 : STA zp_side
.ns_done
    ; Re-fetch node ptr (br_smul_s16_s16_s32 may have clobbered zp_br_p).
    LDA zp_node_chlo : STA zp_br_t0
    LDA zp_node_chhi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    CLC
    LDA zp_rom_nodes_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_nodes_hi : ADC zp_br_t1 : STA zp_br_p_h
    LDA zp_side : BNE ns_back
    LDY #8  : LDA (zp_br_p),Y : STA BSP_NEAR_LO
    INY     : LDA (zp_br_p),Y : STA BSP_NEAR_HI
    INY     : LDA (zp_br_p),Y : STA BSP_FAR_LO
    INY     : LDA (zp_br_p),Y : STA BSP_FAR_HI
    RTS
.ns_back
    LDY #10 : LDA (zp_br_p),Y : STA BSP_NEAR_LO
    INY     : LDA (zp_br_p),Y : STA BSP_NEAR_HI
    LDY #8  : LDA (zp_br_p),Y : STA BSP_FAR_LO
    INY     : LDA (zp_br_p),Y : STA BSP_FAR_HI
    RTS
}

.bsp_lo_end
SAVE "bsp_render_lo.bin", $1C00, bsp_lo_end, $1C00
