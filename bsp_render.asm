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

; --- BBC banked port (path B), selected by beebasm -D BANKED=0|1 ---
; Sideways-RAM bank numbers (RAM banks confirmed on jsbeeb B; loader copies here)
BANK_L0 = 4    ; nodes, ss, seg_hdr, verts
BANK_C  = 6    ; clipper + rasteriser
BANK_L2 = 7    ; angle tables, bbox, recip, VWH, VWHC cache ($C000+ relocated)
; PAGE b : page sideways bank b ($FE30). No-op in the flat build, so flat stays
; bit-exact. A is clobbered — only invoke at A-dead points.
MACRO PAGE bank
IF BANKED
  LDA #bank : STA &FE30
ENDIF
ENDMACRO

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
; NOTE: these lived at $71-$74, but the NJ rasteriser at $A900 uses
; $74-$76/$79-$7A/$80-$88 as scratch — every drawn line corrupted
; zp_br_pyraw_hi and flipped point_on_side decisions mid-walk.
; $90-$9F is unclaimed by span_clip, the rasteriser, and this module.
zp_br_pxraw_lo  = $90       ; s16 player x relative to map_center (raw)
zp_br_pxraw_hi  = $91
zp_br_pyraw_lo  = $92
zp_br_pyraw_hi  = $93
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
zp_rom_fhch_lo    = $0BE8
zp_rom_fhch_hi    = $0BE9
zp_rom_bbox_lo    = $0BEA
zp_rom_bbox_hi    = $0BEB
; Bbox routine arg
zp_bbox_side      = $34

; ============================================================================
; Memory map (RAM caches + ROM tables — Python wrapper places data here)
; ============================================================================
; recip/sincos: milestone keeps them flat ($E000/$E480), reachable in the
; banked_mem model (above the $8000-$BFFF window). Real-HW will bank these with
; the rest of the $C000+ subsystems (separate relocation step).
; $C000+ subsystems relocate to bank L2 for real HW. L2 window layout:
;   TA_LO $8000 TA_HI $8400 VATOX $8800 (angle tables, slope_div.asm)
;   bbox $8D00  recip $9C00  VWH $A100  VWHC cache $A600
IF BANKED
  ; L2 window (no overlaps): TA_LO$8000 TA_HI$8400 VATOX$8900 bbox$8E00
  ;   recip$9D00 VWH$A200 VWHC$A700
  RECIP_BASE  = $9D00       ; bank L2
  L2_BBOX     = $8E00       ; bank L2 (harness/loader points zp_rom_bbox here)
  L2_VWH      = $A200       ; bank L2 (harness/loader points zp_rom_vwh here)
ELSE
  RECIP_BASE  = $E000       ; recip table (HI bytes first, then LO)
ENDIF
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
JMP br_project_x_subpx ; $480F   view vx → screen sx
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
; SC_UMUL8 / SC_UDIV16_8 are now local labels (see .SC_UMUL8 / .SC_UDIV16_8
; in the $4800 region) — banked port decouples them from span_clip.
; Clipper jump table is at $2000 (flat) or $8000 (bank C). SC_BASE offsets all.
IF BANKED
  SC_BASE = $8000
ELSE
  SC_BASE = $2000
ENDIF
SC_DRAW_S16     = SC_BASE + $1E
SC_DRAW_U8      = SC_BASE + $15   ; standalone DCL (u8 input, no clipper prelude)
SC_MARK_SOLID   = SC_BASE + $03
SC_TIGHTEN      = SC_BASE + $06
SC_TIGHTEN_FROM_RECORDS = SC_BASE + $1B

; And span_clip's ZP slots that umul8/udiv16_8 use
zp_mul_b        = $D9
zp_prod_lo      = $DA
zp_prod_hi      = $DB
zp_div_lo       = $DA
zp_div_hi       = $DB
zp_div_den      = $DC
zp_tmp0         = $DE        ; umul8 scratch (matches span_clip); free outside span_clip
; quarter-square tables (loaded by harness) — for inlining umul8 at hot sites
IF BANKED
  sqr_lo  = $2000 : sqr_hi  = $2100   ; low RAM (matches span_clip banked sqr)
  sqr2_lo = $2200 : sqr2_hi = $2300
ELSE
  sqr_lo  = $A500 : sqr_hi  = $A600
  sqr2_lo = $A700 : sqr2_hi = $A800
ENDIF

; span_clip's line ZP (also LC_X*_LO aliases for the s16 clipper)
zp_line_xl      = $A8
zp_line_yl      = $A9
zp_line_xr      = $AA
zp_line_yr      = $AB

; ============================================================================
; br_umul8 — wraps span_clip's umul8 for testing. Inputs in zp_br_a, zp_br_b.
; Result in zp_br_resl/resh. ~50 cycles.
; ============================================================================
; Local copies of umul8 / udiv16_8 (was SC_UMUL8/SC_UDIV16_8 in span_clip).
; Decouples bsp_render's transform arithmetic from the clipper so the clipper
; can move to a sideways-RAM bank: these stay in low RAM (always mapped),
; reached during the data-bank phase. Bit-identical to span_clip's versions;
; same ZP map + sqr tables. (BBC banked port.)
.SC_UMUL8
{
    STA zp_tmp0
    SEC : SBC zp_mul_b : BCS pos
    EOR #$FF : ADC #1
.pos TAY
    LDA zp_tmp0 : CLC : ADC zp_mul_b
    TAX : BCS uo
    LDA sqr_lo,X : SEC : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr_hi,X : SBC sqr_hi,Y : STA zp_prod_hi : RTS
.uo
    LDA sqr2_lo,X : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr2_hi,X : SBC sqr_hi,Y : STA zp_prod_hi : RTS
}
.SC_UDIV16_8
{
    LDA zp_div_hi : CMP zp_div_den : BCS d16
    LDX zp_div_lo : STX zp_div_hi
    LDX #0 : STX zp_div_lo
    ASL zp_div_hi : ROL A : BCS dskip_c8 : CMP zp_div_den : BCS dskip_c8
    ASL zp_div_hi : ROL A : BCS dskip_c7 : CMP zp_div_den : BCS dskip_c7
    ASL zp_div_hi : ROL A : BCS dskip_c6 : CMP zp_div_den : BCS dskip_c6
    ASL zp_div_hi : ROL A : BCS dskip_c5 : CMP zp_div_den : BCS dskip_c5
    ASL zp_div_hi : ROL A : BCS dskip_c4 : CMP zp_div_den : BCS dskip_c4
    ASL zp_div_hi : ROL A : BCS dskip_c3 : CMP zp_div_den : BCS dskip_c3
    ASL zp_div_hi : ROL A : BCS dskip_c2 : CMP zp_div_den : BCS dskip_c2
    ASL zp_div_hi : ROL A : BCS dskip_c1 : CMP zp_div_den : BCS dskip_c1
    LDA #0 : RTS
.dskip_c8 LDX #8 : BNE dskip_commit
.dskip_c7 LDX #7 : BNE dskip_commit
.dskip_c6 LDX #6 : BNE dskip_commit
.dskip_c5 LDX #5 : BNE dskip_commit
.dskip_c4 LDX #4 : BNE dskip_commit
.dskip_c3 LDX #3 : BNE dskip_commit
.dskip_c2 LDX #2 : BNE dskip_commit
.dskip_c1 LDX #1
.dskip_commit
    SBC zp_div_den
    INC zp_div_lo
    DEX : BNE dl
    LDA zp_div_lo : RTS
.d16 LDA #0
    LDX #16
.dl ASL zp_div_lo : ROL zp_div_hi : ROL A
    BCS dl_over
    CMP zp_div_den : BCC ds
    SBC zp_div_den
.dl_commit
    INC zp_div_lo
.ds DEX : BNE dl
    LDA zp_div_lo : RTS
.dl_over
    SBC zp_div_den
    JMP dl_commit
}
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
    PAGE BANK_L2                ; recip table lives in bank L2
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
zp_ft_lo  = $0BF8      ; absolute (swapped with zp_seg_lv1x/y); cold
zp_ft_mag = $0BF9
zp_ft_neg = $0BFA
zp_ft_one = $0BFB

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
zp_ri_neg = $2A
zp_ri_dhi = $2C       ; (was unused; s16 hi byte of d)
\ ($29, $2B were unused zp_ri_mag/zp_ri_one -> reclaimed for zp_seg_bfh/bch)
zp_ri_d   = zp_ri_dlo ; backwards-compat alias

; br_rot_int — Y = 0 (sin) or 3 (cos); mag/neg/one are read directly
; from the contiguous trig ZP block at $05 (smag,sneg,sone,cmag,cneg,cone)
; via abs,Y. Callers no longer stage zp_ri_mag/neg/one. neg is captured
; up front because SC_UMUL8 clobbers Y.
.br_rot_int
{
    LDA $0006,Y : STA zp_ri_neg
    LDA $0007,Y : BEQ ri_not_one
    ; Unity: val = d << 8 as s24. resl=0, resh=dlo, resext=dhi.
    LDA #0 : STA zp_br_resl
    LDA zp_ri_dlo : STA zp_br_resh
    LDA zp_ri_dhi : STA zp_br_resext
    JMP ri_apply_neg
.ri_not_one
    LDA $0005,Y : BNE ri_mag_nz : JMP ri_zero   ; (ri_zero now >127 away after inline)
.ri_mag_nz
    STA zp_mul_b
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
    ; --- inlined umul8(zp_ri_dlo, mag) — saves JSR/RTS in the hot rotation ---
    LDA zp_ri_dlo : STA zp_tmp0
    SEC : SBC zp_mul_b : BCS um1_pos
    EOR #$FF : ADC #1
.um1_pos
    TAY
    LDA zp_tmp0 : CLC : ADC zp_mul_b : TAX : BCS um1_uo
    LDA sqr_lo,X : SEC : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr_hi,X : SBC sqr_hi,Y : STA zp_prod_hi
    JMP um1_done
.um1_uo
    LDA sqr2_lo,X : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr2_hi,X : SBC sqr_hi,Y : STA zp_prod_hi
.um1_done
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh
    LDA #0 : STA zp_br_resext
    ; --- inlined umul8(zp_ri_dhi, mag) ---
    LDA zp_ri_dhi : STA zp_tmp0
    SEC : SBC zp_mul_b : BCS um2_pos
    EOR #$FF : ADC #1
.um2_pos
    TAY
    LDA zp_tmp0 : CLC : ADC zp_mul_b : TAX : BCS um2_uo
    LDA sqr_lo,X : SEC : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr_hi,X : SBC sqr_hi,Y : STA zp_prod_hi
    JMP um2_done
.um2_uo
    LDA sqr2_lo,X : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr2_hi,X : SBC sqr_hi,Y : STA zp_prod_hi
.um2_done
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
    ; a_fine = ab<<4 is frame-constant; hoist it here (once/frame) instead of
    ; recomputing inside bbox_check_angle on every one of the ~650 bbox checks.
    ; bca_afn ($3B/$3C) is untouched by the perspective path between checks.
    LDA bca_ab : LSR A : LSR A : LSR A : LSR A : STA $3C   ; bca_afn+1 = ab>>4
    LDA bca_ab : ASL A : ASL A : ASL A : ASL A : STA $3B   ; bca_afn = (ab<<4)&FF
    ; Player px,py sign-extended to s16 (bca_pxs $8D/$8E, bca_pys $9B/$9C) is
    ; also frame-constant; hoist it (was recomputed per bbox check).
    LDX #0 : LDA zp_br_px_h : STA $8D : BPL vs_px : DEX
.vs_px
    STX $8E
    LDX #0 : LDA zp_br_py_h : STA $9B : BPL vs_py : DEX
.vs_py
    STX $9C
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
    LDY #0
    JSR br_rot_int
    LDA zp_br_resl   : STA zp_br_vxlo
    LDA zp_br_resh   : STA zp_br_vxhi
    LDA zp_br_resext : STA zp_br_vxext

    LDA zp_br_dylo : STA zp_ri_dlo
    LDA zp_br_dyhi : STA zp_ri_dhi
    LDY #3
    JSR br_rot_int
    LDA zp_br_vxlo : SEC : SBC zp_br_resl   : STA zp_br_vxlo
    LDA zp_br_vxhi :       SBC zp_br_resh   : STA zp_br_vxhi
    LDA zp_br_vxext :      SBC zp_br_resext : STA zp_br_vxext

    ; int_vy = rot_int(dx, cos) + rot_int(dy, sin), as s24
    LDA zp_br_dxlo : STA zp_ri_dlo
    LDA zp_br_dxhi : STA zp_ri_dhi
    LDY #3
    JSR br_rot_int
    LDA zp_br_resl   : STA zp_br_vylo
    LDA zp_br_resh   : STA zp_br_vyhi
    LDA zp_br_resext : STA zp_br_vyext

    LDA zp_br_dylo : STA zp_ri_dlo
    LDA zp_br_dyhi : STA zp_ri_dhi
    LDY #0
    JSR br_rot_int
    LDA zp_br_vylo : CLC : ADC zp_br_resl   : STA zp_br_vylo
    LDA zp_br_vyhi :       ADC zp_br_resh   : STA zp_br_vyhi
    LDA zp_br_vyext :      ADC zp_br_resext : STA zp_br_vyext

    JMP tv_add_fracs
}

; tv_add_fracs — add the per-frame fractional rotation terms (s16,
; sign-extended) to the s24 vx/vy accumulators. Shared by br_to_view and
; the bbox corner combine.
.tv_add_fracs
{
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
    ; Split positive/negative paths up front: no sign flag, no |a|
    ; writeback, single result copy (negative path negates during copy).
    LDA zp_br_b : STA zp_mul_b
    LDA zp_br_a : BMI a_neg
    ; --- inlined umul8(A, mag) — 56% of all umul8 calls go through here ---
    STA zp_tmp0
    SEC : SBC zp_mul_b : BCS up_pos
    EOR #$FF : ADC #1
.up_pos
    TAY
    LDA zp_tmp0 : CLC : ADC zp_mul_b : TAX : BCS up_uo
    LDA sqr_lo,X : SEC : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr_hi,X : SBC sqr_hi,Y : STA zp_prod_hi
    JMP up_done
.up_uo
    LDA sqr2_lo,X : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr2_hi,X : SBC sqr_hi,Y : STA zp_prod_hi
.up_done
    LDA zp_prod_lo : STA zp_br_resl
    LDA zp_prod_hi : STA zp_br_resh
    RTS
.a_neg
    EOR #$FF : CLC : ADC #1
    ; --- inlined umul8(|a|, mag) ---
    STA zp_tmp0
    SEC : SBC zp_mul_b : BCS un_pos
    EOR #$FF : ADC #1
.un_pos
    TAY
    LDA zp_tmp0 : CLC : ADC zp_mul_b : TAX : BCS un_uo
    LDA sqr_lo,X : SEC : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr_hi,X : SBC sqr_hi,Y : STA zp_prod_hi
    JMP un_done
.un_uo
    LDA sqr2_lo,X : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr2_hi,X : SBC sqr_hi,Y : STA zp_prod_hi
.un_done
    SEC
    LDA #0 : SBC zp_prod_lo : STA zp_br_resl
    LDA #0 : SBC zp_prod_hi : STA zp_br_resh
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
.br_project_y_raw
{
    ; sum := HALF_H + Y_BIAS (80 + 48) as s16 — the bias every consumer
    ; previously added (copy_seg_to_vx, ap2_solid_proj) is folded into
    ; the projection constant. Same final values, no per-store adds.
    LDA #128 : STA zp_br_vxlo
    LDA #0   : STA zp_br_vxhi

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

; ============================================================================
; ROM/RAM base addresses (Python wrapper writes these into ZP at frame start)
; ============================================================================
zp_rom_verts_lo    = $0BEC
zp_rom_verts_hi    = $0BED
zp_rom_nodes_lo    = $42
zp_rom_nodes_hi    = $43
zp_rom_ss_lo       = $0BF0
zp_rom_ss_hi       = $0BF1
zp_rom_seg_hdr_lo  = $0BF2
zp_rom_seg_hdr_hi  = $0BF3
zp_rom_vwh_lo      = $0BF4
zp_rom_vwh_hi      = $0BF5
zp_rom_detail_lo   = $0BF6
zp_rom_detail_hi   = $0BF7
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
    ; The VWH projection cache is self-validating: its key is the COMPLETE
    ; input (rhi,rlo,h) to br_project_y_raw, a pure function — so a hit is
    ; correct regardless of age (stale key -> mismatch -> miss). Per-frame
    ; invalidation is therefore unnecessary; we skip the 256-byte clear and
    ; let entries persist (a free cross-frame hit-rate bonus under motion).
    ; (VWHC_VALID must be zeroed ONCE at boot; the key check is the backstop
    ;  for any residual garbage. The vcache below IS player-relative and must
    ;  still clear every frame.)
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

    PAGE BANK_C
    JSR SC_IS_FULL
    BNE bsp_done_full
.bsp_dispatch
    ; Entry kinds (hi byte): $80|sshi = subsector, $40|side<<5 = deferred
    ; far child (bbox-checked at pop time), else plain node id.
    LDA zp_node_chhi : AND #$40 : BNE bsp_deferred
    LDA zp_node_chhi : AND #$80 : BEQ bsp_node
    LDA zp_node_chhi : AND #$7F : STA zp_node_chhi
    JSR br_render_subsector
    JMP bsp_loop
.bsp_done_full
    LDA #0 : STA zp_bsp_stack_sp
    JMP bsp_loop

.bsp_deferred
    ; Deferred far child of node (chlo, chhi&$1F), side = bit 5.
    ; Python checks the far side AFTER the near subtree has rendered —
    ; this pop-time check sees exactly that span state.
    LDA zp_node_chhi : AND #$20 : BEQ bsp_df_s0
    LDA #1 : BNE bsp_df_have
.bsp_df_s0
    LDA #0
.bsp_df_have
    STA zp_bbox_side
    LDA zp_node_chhi : AND #$1F : STA zp_node_chhi
    JSR br_bbox_visible
    BEQ bsp_loop_j                   ; far side invisible/occluded → skip
    JSR bsp_resolve_child            ; ch := node.children[side]
    JMP bsp_dispatch
.bsp_loop_j
    JMP bsp_loop

.bsp_node
    JSR br_node_setup
    ; Push the far child as a DEFERRED (node, farside) entry — its
    ; bbox/has_gap runs at pop time, after the near subtree.
    LDX zp_bsp_stack_sp
    LDA zp_node_chlo : STA BSP_STACK,X : INX
    LDA zp_side : EOR #1
    ASL A : ASL A : ASL A : ASL A : ASL A     ; farside << 5
    ORA #$40
    ORA zp_node_chhi : STA BSP_STACK,X : INX
    STX zp_bsp_stack_sp
    ; Near child: bbox + has_gap NOW (Python checks near at visit time;
    ; the old walk pushed near unconditionally and over-visited).
    LDA zp_side : STA zp_bbox_side
    JSR br_bbox_visible
    BEQ bsp_loop_j                   ; near side invisible → skip subtree
    LDX zp_bsp_stack_sp
    LDA BSP_NEAR_LO : STA BSP_STACK,X : INX
    LDA BSP_NEAR_HI : STA BSP_STACK,X : INX
    STX zp_bsp_stack_sp
    JMP bsp_loop
}

; (bsp_resolve_child lives in the D region.)

; (br_node_setup moved to bsp_render_lo.bin overflow region — see end of file)

; --- Children-id slots (set per bsp_node visit, used after bbox checks).
BSP_NEAR_LO = $096B
BSP_NEAR_HI = $096C
BSP_FAR_LO  = $096D
BSP_FAR_HI  = $096E

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
; (Deferred mark_solid buffer replaced by the unified DEFQ op queue at
; $0600 — see DEFQ_BASE above. It preserves seg ORDER across solid and
; tighten ops, matching Python's deferred list.)

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
zp_seg_bfh      = $29      ; ZP (reclaimed unused zp_ri_mag); per-seg back floor
zp_seg_bch      = $2B      ; ZP (reclaimed unused zp_ri_one); per-seg back ceil
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
; Hot per-vertex view coords promoted to real ZP (were $0A50.. absolute) —
; safe-free ZP (0-access incl. rasteriser; not used by the angle module).
zp_seg_cur_evy   = $D3      ; rounded s8 view-y of just-processed vertex
zp_seg_cur_evx   = $D4      ; truncated s8 view-x
zp_seg_v1_evy    = $D6
zp_seg_v1_evx    = $DD
zp_seg_v1_clipped = $E1
zp_seg_v2_evy    = $E4
zp_seg_v2_evx    = $8F
zp_seg_v2_clipped = $9F
; cross_compute reads zp_seg_v{1,2}_{evy,evx} directly. Output:
zp_clip_cx       = $0A5C    ; output: crossing-point view-x (s16 lo)
zp_clip_cx_hi    = $0A5D    ; output: crossing-point view-x (s16 hi)
; Working-saver for projecting X after project_y trashes vxlo/hi
zp_v_xint       = $37      ; saved integer view-x (s8)
zp_v_xfrac      = $38      ; saved fractional view-x (u8)
zp_v_xext       = $94      ; saved view-x s24 extension byte (wide-vx path)
zp_br_t4        = $95      ; bbox corner/edge loop counter
zp_seg_hdr_p    = $96      ; persistent seg-header ptr (advances +12/seg)
zp_seg_hdr_p_h  = $97
zp_fhch_p       = $98      ; persistent FHCH ptr (advances +6/seg)
zp_fhch_p_h     = $99
zp_pyc_idx      = $9A      ; projection-cache probe index (X save)
; Per-seg back-face / linedef state
zp_seg_lv1x_lo  = $24      ; ZP (swapped with zp_ft_*); hot per-seg back-face in
zp_seg_lv1x_hi  = $25
zp_seg_lv1y_lo  = $26
zp_seg_lv1y_hi  = $27
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
    LDA zp_br_dylo : ORA zp_br_dyhi : BEQ bf_back   ; dy==0 -> back (was BNE+JMP)
.bf_ldy0_dy_nz
    ; sign(dot) = sign(-ldx*dy) = NOT(sign(ldx) XOR sign(dy_hi))
    LDA zp_seg_ldx : EOR zp_br_dyhi : EOR #$80
    ; falls through to bf_apply_dir
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
SC_HAS_GAP      = SC_BASE + $09
SC_IS_FULL      = SC_BASE + $0C

; Per-corner storage (5 bytes × 4 = 20). bv_proj_one writes here so that a
; second pass can compute near-plane edge crossings between consecutive
; corners. Layout per corner: vx_lo, vx_hi, vy_lo, vy_hi, in_front (0/1).
; NOTE: these previously lived at $0E00/$0E14 — INSIDE the vertex cache
; ($0C00 + 8x467 = $1A98) — so every bbox visibility check corrupted the
; cached transforms of vertices ~64-66. $0960-$0974 is free scratch
; (span_clip's LC_* scratch ends at $0958).
BBOX_CORNERS    = $0A40     ; 4 x 8: vx16, vy16, front, vy24 (lo,hi,ext)
; (overlays the per-seg projection scratch — disjoint phases)
BBOX_CORNER_IDX = $09FD     ; offset into BBOX_CORNERS for current corner

; Deferred per-subsector op queue (mirrors Python's packed_render_subsector
; `deferred` list): seg-ordered solid/tighten ops, applied at subsector end.
;   entry: $00, ilo, ihi                                  (solid)
;          $01, ilo, ihi, top block, bot block            (tighten)
;   where each block is (count, 6*count record bytes) snapshotted from
;   TOP_RECORDS/$0700 / BOT_RECORDS/$0800 at seg end — later segs' DCL
;   emission overwrites those buffers before the drain, exactly the
;   problem Python solves with its '__rec__' snapshots.
DEFQ_BASE       = $0600     ; 256 bytes (free: span pool ends $059F)
DEFQ_TAIL       = $09FB     ; queue tail offset (u8)
DEFQ_OVF        = $09FC     ; set if an op was dropped (queue full) — debug

; Near-plane edge-crossing scratch. Reuses the per-seg ZP block — bbox
; visibility runs during node processing, when the seg-loop variables
; ($5D-$6F) are dead.
zp_crx_num      = $5D       ; |1 - vy0| u16
zp_crx_den      = $5F       ; |dvy| u16
zp_crx_q        = $61       ; t = (num<<8)/den, u16 (<= 256)
zp_crx_dvx      = $63       ; |dvx| u16
zp_crx_neg      = $65       ; 1 if dvx negative
zp_crx_p        = $66       ; t*|dvx| u24
zp_crx_v        = $69       ; division: shifted divisor u24
zp_crx_d        = $6C       ; division: dividend u24

BBOX_SCRATCH    = $0960     ; 8 bytes: top_lo,top_hi,bot_lo,bot_hi,
                            ;          left_lo,left_hi,right_lo,right_hi
BBOX_FLAGS      = $0968     ; bit 0 = any_behind, bit 1 = any_front
BBOX_ILO        = $0969     ; running min sx clamped (u8)
BBOX_IHI        = $096A     ; running max sx clamped (u8)

; --- Angle-space bbox module (bsp_render_ang.bin @ $E940; tables $DC00/$E400/$F200).
;     Replaces the perspective corner-projection path below (now dead code).
; angle module + bca workspace relocate when banked (must match slope_div.asm:
;   code -> $3400 (entry+3 = $3403); bca workspace -> BCA_WS $3A00).
IF BANKED
  BCA_CHECK = $3403
  BCA_WS    = $3A00
ELSE
  BCA_CHECK = $E943          ; JSR -> bbox_check_angle (point_to_angle inlined out)
  BCA_WS    = $FA00
ENDIF
bca_top   = BCA_WS+$10      ; box input: top,bot,left,right = +$10,$12,$14,$16
bca_ilo   = BCA_WS+$30      ; output: left column (u8)
bca_ihi   = BCA_WS+$31      ; output: right column (u8)
bca_vis   = BCA_WS+$32      ; output: 1=visible, 0=cull
bca_ab    = BCA_WS+$2F      ; per-frame view angle (set by render setup)

.br_bbox_visible
{
    PAGE BANK_L2                ; bbox + angle tables (TA/VATOX) live in bank L2
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

    ; Point bca_boxp ($86/$87) at the ROM box; bbox_check_angle reads it via
    ; (bca_boxp),Y — no 8-byte copy into a work area.
    LDA zp_br_p   : STA $86
    LDA zp_br_p_h : STA $87

    ; --- Angle-space visibility (px=$01, py=$03, ab=$FA2F preset per frame) ---
    JSR BCA_CHECK
    LDA bca_vis : BNE bv_anglevis
    LDA #0 : RTS
.bv_anglevis
    LDA bca_ilo : STA $C2
    LDA bca_ihi : STA $C3
    PAGE BANK_C
    JMP SC_HAS_GAP

}

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
    PAGE BANK_L0                ; ss / seg_hdr / verts / sincos live in bank L0
    ; --- Mark visited (test instrumentation) ---
    LDA zp_node_chlo : STA zp_br_t0
    LDA zp_node_chhi : STA zp_br_t1
    LSR zp_br_t1 : ROR zp_br_t0
    LSR zp_br_t1 : ROR zp_br_t0
    LSR zp_br_t1 : ROR zp_br_t0
    LDA zp_node_chlo : AND #7 : TAX
    LDA vc_bit_mask,X
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

    ; Persistent per-seg pointers: computed once here, advanced by the
    ; loop (+12 header, +6 FHCH) — the old code re-multiplied si*12 and
    ; si*6 on every seg. fhch_ptr_si6 leaves si*6 in t0/t1; one more
    ; shift gives si*12.
    JSR fhch_ptr_si6
    LDA zp_br_p   : STA zp_fhch_p
    LDA zp_br_p_h : STA zp_fhch_p_h
    ASL zp_br_t0 : ROL zp_br_t1                ; si*12
    CLC
    LDA zp_rom_seg_hdr_lo : ADC zp_br_t0 : STA zp_seg_hdr_p
    LDA zp_rom_seg_hdr_hi : ADC zp_br_t1 : STA zp_seg_hdr_p_h

    ; Reset deferred op queue for this subsector.
    LDA #0 : STA DEFQ_TAIL

    ; --- Loop over segs ---
.seg_loop
    LDA zp_seg_count : BNE seg_proc
    PAGE BANK_C                          ; defq_drain only does clip ops (bank C)
    JMP defq_drain                       ; subsector done — apply deferred ops
.seg_proc
    PAGE BANK_L0                ; re-page L0 each seg (prev seg ended in bank C)
    ; Reset DCL records buffers (used by portal tighten). Python's
    ; packed_render_seg calls _span_clip_6502.reset_records() at the
    ; top of each seg, mirrored here.
    LDA #0
    STA $0700                      ; TOP_RECORDS count
    STA $0800                      ; BOT_RECORDS count
    STA $BC                        ; ZP_DCL_REC_BUF lo
    STA $BD                        ; ZP_DCL_REC_BUF hi (= "no records buffer")

    ; --- seg header via the persistent pointer ---
    LDA zp_seg_hdr_p   : STA zp_br_p
    LDA zp_seg_hdr_p_h : STA zp_br_p_h
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

    ; --- Read fh, ch, bfh, bch from the 6-byte/seg FHCH table:
    ;     [fh, ch, bfh|apv1_ch, bch|apv1_fh, apv2_ch, apv2_fh].
    ;     Bytes 4/5 carry the solid-seg APV2 aperture heights (the seg
    ;     detail ROM is not resident on the 6502). ---
    LDA zp_fhch_p   : STA zp_br_p
    LDA zp_fhch_p_h : STA zp_br_p_h
    LDY #0 : LDA (zp_br_p),Y : STA zp_seg_fh
    INY    : LDA (zp_br_p),Y : STA zp_seg_ch
    INY    : LDA (zp_br_p),Y : STA zp_seg_bfh
    INY    : LDA (zp_br_p),Y : STA zp_seg_bch
    ; Height deltas (all s8). Front: top_dlt = ch - vz, bot_dlt = fh - vz.
    ; Back: btop_dlt = bch - vz, bbot_dlt = bfh - vz.
    LDA zp_seg_ch  : SEC : SBC zp_br_vz : STA zp_seg_top_dlt
    LDA zp_seg_fh  : SEC : SBC zp_br_vz : STA zp_seg_bot_dlt
    ; Back deltas are consumed ONLY by do_project_y, which reads them only when
    ; NEEDBT($04)/NEEDBB($08)/APEDGE1($40) is set. Skip the 2 subtractions for
    ; plain solids/portals (the common case) — conservative: this superset
    ; never skips a delta do_project_y will read.
    LDA zp_seg_flags : AND #$4C : BEQ skip_bdlt
    LDA zp_seg_bch : SEC : SBC zp_br_vz : STA zp_seg_btop_dlt
    LDA zp_seg_bfh : SEC : SBC zp_br_vz : STA zp_seg_bbot_dlt
.skip_bdlt

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
    ; Python near-clips ALL front-facing segs (fp_near_clip), so solid
    ; walls reproject too — their clamped mark_solid range comes from the
    ; crossing projection (e.g. mark_solid(0,81) from sx=-2176 at
    ; (800,-3400,96); bailing solids loses that occlusion entirely).
    LDA zp_seg_v1_clipped : ORA zp_seg_v2_clipped
    BEQ s_both_have_proj
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
    PAGE BANK_C
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
    ; If portal-lip case (!SOLID, !NEEDBT, bch>ch reached here), ft IS the
    ; new top of the aperture and needs TOP_RECORDS. Solid walls and
    ; NEEDBT segs (where bt has the role) get no records.
    LDA zp_seg_flags : AND #$06 : BNE ft_no_rec  ; SOLID or NEEDBT → no rec
    LDA #$07 : STA $BD                            ; portal-lip → TOP_RECORDS
    JMP ft_set_line
.ft_no_rec
    LDA #0   : STA $BD
.ft_set_line
    LDA #0   : STA $BC
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sy1_top_lo : STA zp_line_yl
    LDA zp_seg_sy1_top_hi : STA $B3
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA zp_seg_sy2_top_lo : STA zp_line_yr
    LDA zp_seg_sy2_top_hi : STA $B5
    PAGE BANK_C
    JSR SC_DRAW_S16
    LDA #0   : STA $BC : STA $BD
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
    ; Mirror of ft_emit: fb gets BOT_RECORDS in the portal-lip case
    ; (!SOLID, !NEEDBB, bfh<fh reached here).
    LDA zp_seg_flags : AND #$0A : BNE fb_no_rec  ; SOLID or NEEDBB → no rec
    LDA #$08 : STA $BD                            ; portal-lip → BOT_RECORDS
    JMP fb_set_line
.fb_no_rec
    LDA #0   : STA $BD
.fb_set_line
    LDA #0   : STA $BC
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sy1_bot_lo : STA zp_line_yl
    LDA zp_seg_sy1_bot_hi : STA $B3
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA zp_seg_sy2_bot_lo : STA zp_line_yr
    LDA zp_seg_sy2_bot_hi : STA $B5
    PAGE BANK_C
    JSR SC_DRAW_S16
    LDA #0   : STA $BC : STA $BD
.fb_skip

    ; --- Portal step edges (back ceiling / floor) ---
    ; Solid walls have no back sector — skip the step emits.
    LDA zp_seg_flags : AND #$02 : BEQ step_cont   ; SF_SOLID set → skip steps
    JMP step_skip                                 ; (trampoline: PAGE inserts
.step_cont                                        ;  pushed the branch out of range)

    ; Back ceiling step if NEEDBT (= $04) set: emit (sx1, bt1) → (sx2, bt2).
    ; bt is the new TOP of the aperture — populate TOP_RECORDS so the
    ; tighten_from_records call at end of seg has the right per-span
    ; verdict data. Matches Python's roles={yt_idx: TOP_RECORDS}.
    LDA zp_seg_flags : AND #$04 : BEQ step_no_top
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sy1_btop_lo : STA zp_line_yl
    LDA zp_seg_sy1_btop_hi : STA $B3
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA zp_seg_sy2_btop_lo : STA zp_line_yr
    LDA zp_seg_sy2_btop_hi : STA $B5
    LDA #0   : STA $BC
    LDA #$07 : STA $BD             ; TOP_RECORDS = $0700
    PAGE BANK_C
    JSR SC_DRAW_S16
    LDA #0   : STA $BC : STA $BD   ; reset records pointer
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
    LDA #0   : STA $BC
    LDA #$08 : STA $BD             ; BOT_RECORDS = $0800
    PAGE BANK_C
    JSR SC_DRAW_S16
    LDA #0   : STA $BC : STA $BD
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

    ; --- NOVT aperture-edge verticals (SF_APEDGE1/2) ---
    JSR ap_edges

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
    LDA zp_seg_flags : AND #$02 : BNE ms_solid_path
    ; --- Portal: DEFER the tighten to the subsector drain (Python defers
    ;     both solids and tightens in seg order — applying the tighten at
    ;     seg end mutates spans BEFORE an earlier sibling's mark_solid,
    ;     producing off-by-one span anchors). Records are snapshotted into
    ;     the queue because later segs' DCL emission overwrites
    ;     TOP_RECORDS/BOT_RECORDS before the drain. Skip if no records
    ;     were populated — mirrors Python's wrapper test
    ;     `if mem[TOP_RECORDS] == 0 and mem[BOT_RECORDS] == 0: return`.
    LDA $0700 : ORA $0800 : BEQ ms_skip
    JSR defq_append_tighten
    JMP ms_skip
.ms_solid_path
    ; --- Solid wall: defer mark_solid (Python collects them per subsector
    ;     and applies at the end). ---
    JSR defq_append_solid
.ms_skip

.s_advance
    LDA #0 : STA zp_seg_skip
    INC zp_seg_first_lo : BNE s_no_carry
    INC zp_seg_first_hi
.s_no_carry
    CLC
    LDA zp_seg_hdr_p : ADC #12 : STA zp_seg_hdr_p
    LDA zp_seg_hdr_p_h : ADC #0 : STA zp_seg_hdr_p_h
    CLC
    LDA zp_fhch_p : ADC #6 : STA zp_fhch_p
    LDA zp_fhch_p_h : ADC #0 : STA zp_fhch_p_h
    DEC zp_seg_count
    JMP seg_loop
}

; (drain_deferred_ms replaced by defq_drain — see the $0B00 region.)

; emit_vert_sx1 — caller has set yl/yh/yr/yh in zp_line_yl/$B3/zp_line_yr/$B5.
; Fills xl/xh/xr/xh from sx1, clears records hi byte, calls SC_DRAW_S16.
.emit_vert_sx1
    LDA zp_seg_sx1_lo : STA zp_line_xl
    LDA zp_seg_sx1_hi : STA $B2
    LDA zp_seg_sx1_lo : STA zp_line_xr
    LDA zp_seg_sx1_hi : STA $B4
    LDA #0 : STA $BD
    PAGE BANK_C
    JMP SC_DRAW_S16

.emit_vert_sx2
    LDA zp_seg_sx2_lo : STA zp_line_xl
    LDA zp_seg_sx2_hi : STA $B2
    LDA zp_seg_sx2_lo : STA zp_line_xr
    LDA zp_seg_sx2_hi : STA $B4
    LDA #0 : STA $BD
    PAGE BANK_C
    JMP SC_DRAW_S16

; ============================================================================
; br_seg_xform_vertex — fetch vertex by index, transform to view, project X.
;   Input:  zp_br_t0:t1 = vertex index (u16).
;   Output: zp_br_resl/h = screen x (s16). zp_seg_skip = 1 if near-clipped.
; ============================================================================
.br_seg_xform_vertex
{
    PAGE BANK_L0                ; reads verts (L0) on vcache miss; prior seg's
                               ; projection may have left L2/C paged
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
    ; bit mask = 1 << (idx_lo & 7), via table (was a 0..7-iteration shift loop)
    LDA zp_br_t0 : AND #7 : TAX
    LDA vc_bit_mask,X : STA zp_seg_v_bitm
    LDY #0 : LDA (zp_br_p),Y : AND zp_seg_v_bitm : BEQ vc_miss  ; (was BNE+JMP)
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

    ; Save view-space x (vxext:vxhi=int part s16, vxlo=frac part) before
    ; project_y clobbers vxlo/hi.
    LDA zp_br_vxhi : STA zp_v_xint
    LDA zp_br_vxlo : STA zp_v_xfrac
    LDA zp_br_vxext : STA zp_v_xext

    ; Compute evx = vxhi (truncated s8) and evy = (vy + 128) >> 8 from the
    ; full s24 view-y (vyext, vyhi, vylo). Far-behind segs have negative
    ; vyext that overflows the s16 (vyhi:vylo) representation — using
    ; only vyhi misses the sign and lets clipped segs through.
    LDA zp_br_vxhi : STA zp_seg_cur_evx
    LDA zp_br_vylo : ASL A             ; carry = bit 7 of vylo
    LDA zp_br_vyhi : ADC #0            ; A = (vyhi:vylo + 128) >> 8 low byte
    STA zp_seg_cur_evy
    ; Clamp evy to s8 only when the rounded evy16 truly exceeds s8 —
    ; vyext=$FF is NORMAL for negative vy (s24 sign extension), not an
    ; overflow. Helper consumes the carry-out of the rounding add.
    JSR ev_clamp_evy16

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
    BNE nc_ok                       ; evy>0 -> ok (was BEQ+JMP)
.nc_fail
    ; Mark near-clipped in cache, set skip.
    LDY #6 : LDA #1 : STA (zp_br_p),Y
    LDA #1 : STA zp_seg_skip
    RTS
.nc_ok
    ; --- Compute reciprocal: vy_idx = s24 total_vy >> 7 (9.1). The old
    ; code dropped vy_ext ('per s8 vx contract') — but wide-vx segs are
    ; projected now, and a vertex with vy >= 256 view units got an index
    ; computed mod 65536 (e.g. vy=262 -> idx 10 instead of 524, recip 23x
    ; too big, sx=-2296 instead of 77). br_recip clamps to [2,1023]. ---
    LDA zp_br_vylo : ASL A
    LDA zp_br_vyhi : ROL A
    STA zp_br_t0
    LDA zp_br_vyext : ROL A
    STA zp_br_t1
    JSR br_recip                        ; rhi/rlo = reciprocal

    ; --- Project X using saved view-x integer + fractional parts ---
    ; br_project_x_auto goes wide when the s16 view-x (vxext:vxint)
    ; doesn't fit s8: Python projects these full-width (sx far
    ; off-screen) and their mark_solid and clipped draws still count —
    ; skipping the seg loses occlusion (e.g. mark_solid(0,81) at
    ; (800,-3400,96)) and over-emits behind it.
    JSR br_project_x_auto
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
    JMP do_project_y
}

; do_project_y — project the four per-seg heights (top/bot/btop/bbot)
; with the current reciprocal into the zp_seg_sy_* slots. Global so the
; crossing reprojection can tail-call it instead of duplicating it.
.do_project_y
{
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

    ; --- Back-pair projections only when a consumer exists: every use of
    ; sy_btop/sy_bbot is gated on (SOLID & APEDGE1) — the APV1 aperture
    ; vertical — or (portal & NEEDBT/NEEDBB). Skipping unused projections
    ; is output-identical and saves 2 projections (4 muls) per vertex on
    ; plain solid walls. ---
    LDA zp_seg_flags : AND #$02 : BEQ dpy_portal
    LDA zp_seg_flags : AND #$40 : BNE dpy_btop     ; solid + APEDGE1 → both
    RTS                                            ; plain solid → neither
.dpy_portal
    LDA zp_seg_flags : AND #$04 : BEQ dpy_chk_bb   ; NEEDBT?
.dpy_btop
    ; --- Project Y for back ceiling (height = bch - vz) ---
    LDA zp_seg_btop_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_btop_lo
    LDA zp_br_resh : STA zp_seg_sy_btop_hi
    LDA zp_seg_flags : AND #$02 : BNE dpy_bbot     ; solid+APEDGE1 → both
.dpy_chk_bb
    LDA zp_seg_flags : AND #$08 : BEQ dpy_done     ; NEEDBB?
.dpy_bbot
    ; --- Project Y for back floor (height = bfh - vz) ---
    LDA zp_seg_bbot_dlt : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_seg_sy_bbot_lo
    LDA zp_br_resh : STA zp_seg_sy_bbot_hi
.dpy_done
    RTS
}

; ============================================================================
.vc_bit_mask
    EQUB 1, 2, 4, 8, 16, 32, 64, 128   ; 1 << (idx & 7) for the vertex cache

.end_code
ASSERT end_code <= $5800
IF BANKED
  SAVE "bsp_render_bk.bin", $4800, end_code, $4800
ELSE
  SAVE "bsp_render.bin", $4800, end_code, $4800
ENDIF

; ============================================================================
; B REGION ($0AA0-$0BFF) — deferred-op queue + helpers. This space is the
; unused tail of the old 384-byte SS_VISITED_BITMAP allocation (237
; subsectors need only 30 bytes, $0A80-$0A9D). Loaded as a separate binary
; (bsp_render_b.bin) by span_clip_6502.py.
; ============================================================================
IF BANKED
  ORG $3A40                  ; above PAGE (directly *LOAD-able; avoids relocate-down)
ELSE
  ORG $0AA0
ENDIF
.bsp_b_start

; defq_append_solid — append ($00, ilo, ihi) from $C2/$C3 to the op queue.
.defq_append_solid
{
    LDX DEFQ_TAIL
    CPX #$FD : BCS dqs_ovf            ; need 3 bytes
    LDA #0  : STA DEFQ_BASE,X : INX
    LDA $C2 : STA DEFQ_BASE,X : INX
    LDA $C3 : STA DEFQ_BASE,X : INX
    STX DEFQ_TAIL
    RTS
.dqs_ovf
    LDA #1 : STA DEFQ_OVF
    RTS
}

; defq_append_tighten — append ($01, ilo, ihi, top block, bot block) where
; each block is (count, 6*count bytes) copied from $0700 / $0800.
; Caller guarantees at least one count is non-zero.
.defq_append_tighten
{
    ; size check: 5 + 6*(tc+bc) must fit in the remaining queue space.
    LDA $0700 : CLC : ADC $0800 : BCS dqt_ovf    ; n = tc + bc
    STA zp_br_t0
    ASL A : BCS dqt_ovf                          ; 2n
    STA zp_br_t1
    ASL A : BCS dqt_ovf                          ; 4n
    CLC : ADC zp_br_t1 : BCS dqt_ovf             ; 6n
    CLC : ADC #5 : BCS dqt_ovf                   ; entry size
    CLC : ADC DEFQ_TAIL : BCS dqt_ovf            ; tail + size > 255 → drop

    LDX DEFQ_TAIL
    LDA #1  : STA DEFQ_BASE,X : INX
    LDA $C2 : STA DEFQ_BASE,X : INX
    LDA $C3 : STA DEFQ_BASE,X : INX

    ; copy top block: 1 + 6*tc bytes from $0700
    LDA $0700 : JSR defq_blocklen
    LDY #0
.dqt_cp_top
    LDA $0700,Y : STA DEFQ_BASE,X : INX
    INY
    CPY zp_br_t1 : BNE dqt_cp_top

    ; copy bot block: 1 + 6*bc bytes from $0800
    LDA $0800 : JSR defq_blocklen
    LDY #0
.dqt_cp_bot
    LDA $0800,Y : STA DEFQ_BASE,X : INX
    INY
    CPY zp_br_t1 : BNE dqt_cp_bot

    STX DEFQ_TAIL
    RTS
.dqt_ovf
    LDA #1 : STA DEFQ_OVF
    RTS
}

; defq_blocklen — A = record count (<= 42) → zp_br_t1 = 1 + 6*count.
; No CLCs needed: 6*42 = 252, so no intermediate carry is possible.
.defq_blocklen
    ASL A : STA zp_br_t1
    ASL A : ADC zp_br_t1
    ADC #1 : STA zp_br_t1
    RTS

; defq_drain — apply queued ops in seg order at subsector end. Mirrors
; Python's deferred loop: each op then `if clips.is_full(): return`.
.defq_drain
{
    LDX #0
.dd_loop
    CPX DEFQ_TAIL : BCS dd_done
    LDA DEFQ_BASE,X : INX : STA zp_br_t3         ; type
    LDA DEFQ_BASE,X : INX : STA $C2
    LDA DEFQ_BASE,X : INX : STA $C3
    LDA zp_br_t3 : BNE dd_tighten
    ; solid: mark_solid(ilo, ihi), no line emission.
    STX zp_br_t2
    LDA #0 : STA $A8                             ; zp_ms_emit = 0
    JSR SC_MARK_SOLID                            ; (bank C paged by caller)
    JMP dd_after
.dd_tighten
    ; restore top block to $0700
    LDA DEFQ_BASE,X : JSR defq_blocklen
    LDY #0
.dd_cp_top
    LDA DEFQ_BASE,X : STA $0700,Y : INX
    INY
    CPY zp_br_t1 : BNE dd_cp_top
    ; restore bot block to $0800
    LDA DEFQ_BASE,X : JSR defq_blocklen
    LDY #0
.dd_cp_bot
    LDA DEFQ_BASE,X : STA $0800,Y : INX
    INY
    CPY zp_br_t1 : BNE dd_cp_bot
    STX zp_br_t2
    JSR SC_TIGHTEN_FROM_RECORDS                  ; (bank C paged by caller)
.dd_after
    JSR SC_IS_FULL                               ; (bank C paged by caller)
    BNE dd_done
    LDX zp_br_t2
    JMP dd_loop
.dd_done
    RTS
}

; ============================================================================
; ev_clamp_evy16 — clamp zp_seg_cur_evy to s8 range using the s24 view-y.
; Called with C = carry-out of (vyhi + bit7(vylo)), i.e. the rounding add
; that produced zp_seg_cur_evy. evy16 hi byte = vyext + C. The vertex fits
; s8 iff that hi byte is the sign-extension of the lo byte. (The old
; `vyext != 0 → clamp` collapsed every behind-the-viewer vertex to
; evy=-128, corrupting crossing math: t = (1-evy_C)<<8/(evy_U-evy_C)
; needs the true evy_C — e.g. evy=-4 became -128 and a crossed solid
; wall projected sx=-2560 instead of Python's -2176.)
; ============================================================================
.ev_clamp_evy16
{
    LDA zp_br_vyext : ADC #0           ; hi byte of rounded evy16
    BEQ ev_case_zero
    CMP #$FF : BEQ ev_case_ff
    ASL A : BCS ev_clamp_neg           ; carry = sign of hi byte
    LDA #$7F : BNE ev_store
.ev_clamp_neg
    LDA #$80 : BNE ev_store
.ev_case_ff
    LDA zp_seg_cur_evy : BMI ev_done       ; $FF:%1xxxxxxx → fits s8
    LDA #$80 : BNE ev_store                ; -256..-129 → clamp
.ev_case_zero
    LDA zp_seg_cur_evy : BPL ev_done       ; $00:%0xxxxxxx → fits s8
    LDA #$7F                               ; 128..255 → clamp
.ev_store
    STA zp_seg_cur_evy
.ev_done
    RTS
}

; ============================================================================
; br_project_x_auto — project saved view-x (zp_v_xext:zp_v_xint . zp_v_xfrac)
; to screen X, choosing the 3-mul narrow path when the integer part fits
; s8 and the 5-mul wide path otherwise. Output: zp_br_resl/h = sx (s16).
; ============================================================================
.br_project_x_auto
{
    ; Narrow iff xext equals the sign-extension of xint's bit 7.
    LDA zp_v_xint : ASL A              ; C = sign of int part
    LDA #0 : ADC #$FF : EOR #$FF       ; A = $FF if C else $00
    CMP zp_v_xext : BNE a_wide
    LDA zp_v_xint  : STA zp_br_t0
    LDA zp_v_xfrac : STA zp_br_t1
    JSR br_project_x_subpx
    ; Narrow sx always fits s16 (|evx|<=127, rxh<=127 → |sx|<=16383);
    ; set the s24 extension byte so callers can classify uniformly.
    LDX #0
    LDA zp_br_resh : BPL a_pos
    DEX
.a_pos
    STX zp_br_resext
    RTS
.a_wide
    JMP br_project_x_wide
}

.bsp_b_end
IF BANKED
  SAVE "bsp_render_b_bk.bin", $3A40, bsp_b_end, $3A40
ELSE
  ASSERT bsp_b_end <= $0C00
  SAVE "bsp_render_b.bin", $0AA0, bsp_b_end, $0AA0
ENDIF

; ============================================================================
; D REGION ($0978-$09FF) — near-plane edge-crossing math for bbox
; visibility. Free space after span_clip's LC_* scratch ($0958) and the
; BBOX_CORNERS/DEFQ vars ($0960-$0976). Loaded as bsp_render_d.bin.
; ============================================================================
IF BANKED
  ORG $3BC0                  ; above PAGE (directly *LOAD-able)
ELSE
  ORG $0978
ENDIF
.bsp_d_start

; bsp_resolve_child — ch := children[zp_bbox_side] of node ch.
;   ptr = rom_nodes + id*16; child_r at +8, child_l at +10.
.bsp_resolve_child
{
    PAGE BANK_L0                ; nodes table lives in bank L0
    ; Node ids fit one byte (<= 235): id*16 via single-byte shifts.
    LDA zp_node_chlo
    LSR A : LSR A : LSR A : LSR A : STA zp_br_t1
    LDA zp_node_chlo
    ASL A : ASL A : ASL A : ASL A
    CLC : ADC zp_rom_nodes_lo : STA zp_br_p
    LDA zp_br_t1 : ADC zp_rom_nodes_hi : STA zp_br_p_h
    LDA zp_bbox_side : ASL A : CLC : ADC #8 : TAY
    LDA (zp_br_p),Y : STA zp_node_chlo
    INY
    LDA (zp_br_p),Y : STA zp_node_chhi
    RTS
}

.bsp_d_end
IF BANKED
  SAVE "bsp_render_d_bk.bin", $3BC0, bsp_d_end, $3BC0
ELSE
  ASSERT bsp_d_end <= $09FB   ; $09FB-$09FD hold DEFQ_TAIL/OVF + corner idx
  SAVE "bsp_render_d.bin", $0978, bsp_d_end, $0978
ENDIF





; ============================================================================
; W REGION ($DAC0-$DFFF) — Y-projection cache. Free RAM between the
; harness-loaded bbox table (ends $D4BF) and the recip table ($E000);
; the cache arrays occupy $D4C0-$DABF. Loaded as bsp_render_w.bin.
;
; br_project_y is now a caching front for br_project_y_raw: the key is
; the COMPLETE input set (rhi, rlo, h), so a hit returns the previously
; computed value — bit-identical by construction. 58-64%% of projections
; repeat within a frame (measured); a raw projection costs ~315 cycles
; end-to-end, a hit ~45.
; ============================================================================
; VWHC y-projection cache: flat @ $D4C0; banked -> bank L2 ($A600). br_project_y
; (this code) -> banked low RAM ($3900, clipper-vacated space) since $DAC0 is in
; MOS-ROM space on a real Model B.
IF BANKED
  VWHC_VALID = $A700 : VWHC_RHI = $A800 : VWHC_RLO = $A900
  VWHC_H     = $AA00 : VWHC_LO  = $AB00 : VWHC_HI  = $AC00
  ORG $3900
ELSE
  VWHC_VALID = $D4C0 : VWHC_RHI = $D5C0 : VWHC_RLO = $D6C0
  VWHC_H     = $D7C0 : VWHC_LO  = $D8C0 : VWHC_HI  = $D9C0
  ORG $DAC0
ENDIF
.bsp_w_start

.br_project_y
{
    PAGE BANK_L2                ; recip + VWHC cache live in bank L2
    ; probe: idx = (rlo + h + rhi) & 255
    LDA zp_br_rlo : CLC : ADC zp_br_t0 : ADC zp_br_rhi : TAX
    LDA VWHC_VALID,X : BEQ pyc_miss
    LDA VWHC_RHI,X : CMP zp_br_rhi : BNE pyc_miss
    LDA VWHC_RLO,X : CMP zp_br_rlo : BNE pyc_miss
    LDA VWHC_H,X   : CMP zp_br_t0  : BNE pyc_miss
    LDA VWHC_LO,X : STA zp_br_resl
    LDA VWHC_HI,X : STA zp_br_resh
    RTS
.pyc_miss
    STX zp_pyc_idx
    JSR br_project_y_raw
    LDX zp_pyc_idx
    LDA #1 : STA VWHC_VALID,X
    LDA zp_br_rhi  : STA VWHC_RHI,X
    LDA zp_br_rlo  : STA VWHC_RLO,X
    LDA zp_br_t0   : STA VWHC_H,X
    LDA zp_br_resl : STA VWHC_LO,X
    LDA zp_br_resh : STA VWHC_HI,X
    RTS
}

; vwhc_clear — invalidate the projection + rotation-product caches (per frame).
.vwhc_clear
{
    LDA #0
    LDX #0
.vc_loop
    STA VWHC_VALID,X
    INX : BNE vc_loop
    ; (RPC rotation-product cache removed: $DC00 reclaimed for angle TA_LO.)
    RTS
}

.bsp_w_end
ASSERT bsp_w_end <= $DC00       ; stay below angle TA_LO (was RPC_VALID, removed)
IF BANKED
  SAVE "bsp_render_w_bk.bin", $3900, bsp_w_end, $3900
ELSE
  SAVE "bsp_render_w.bin", $DAC0, bsp_w_end, $DAC0
ENDIF

; ============================================================================
; OVERFLOW REGION — bsp_render.bin is bound to $4800-$57FF (4096 bytes max,
; framebuffer starts at $5800). Helpers that don't fit live here at $1C00 and
; are loaded as a separate binary by span_clip_6502.py (bsp_render_lo.bin).
; ============================================================================
ORG $1B40
.bsp_lo_start

; reproject_at_crossing — call cross_compute, then project sx + 4 sy values
; using the reciprocal at NEAR. Output → zp_seg_sx_lo/hi, zp_seg_sy_*.
.reproject_at_crossing
{
    JSR cross_compute
    ; Project cx with frac=0 (Python passes fvx_c=0 for clipped endpoints).
    ; cx is s16; br_project_x_auto dispatches narrow/wide on its hi byte.
    LDA zp_clip_cx    : STA zp_v_xint
    LDA zp_clip_cx_hi : STA zp_v_xext
    LDA #0            : STA zp_v_xfrac
    JSR br_project_x_auto
    LDA zp_br_resl : STA zp_seg_sx_lo
    LDA zp_br_resh : STA zp_seg_sx_hi
    JMP do_project_y
}

; copy_seg_to_v1 / copy_seg_to_v2 — copy zp_seg_sx_*/sy_*_* into vN slots,
; biasing sy by Y_BIAS (= 48). Used after both br_seg_xform_vertex and
; reproject_at_crossing fill the "current vertex" slots.
.copy_seg_to_v1
    LDX #0
    LDY #0
    BEQ copy_seg_to_vx
.copy_seg_to_v2
    LDX #4
    LDY #2
; copy_seg_to_vx — X = sy-slot offset (0=v1, 4=v2), Y = sx-slot offset
; (0=v1, 2=v2). SEG_PROJ_BUF pairs: vK_top at +0/+4, btop at +8/+12,
; bbot at +10/+14; sx slots at $61/$63. Y values biased by Y_BIAS (48).
.copy_seg_to_vx
    ; Y values arrive pre-biased from br_project_y (HALF_H + Y_BIAS).
    LDA zp_seg_sx_lo : STA $0061,Y
    LDA zp_seg_sx_hi : STA $0062,Y
    LDA zp_seg_sy_top_lo  : STA SEG_PROJ_BUF+0,X
    LDA zp_seg_sy_top_hi  : STA SEG_PROJ_BUF+1,X
    LDA zp_seg_sy_bot_lo  : STA SEG_PROJ_BUF+2,X
    LDA zp_seg_sy_bot_hi  : STA SEG_PROJ_BUF+3,X
    LDA zp_seg_sy_btop_lo : STA SEG_PROJ_BUF+8,X
    LDA zp_seg_sy_btop_hi : STA SEG_PROJ_BUF+9,X
    LDA zp_seg_sy_bbot_lo : STA SEG_PROJ_BUF+10,X
    LDA zp_seg_sy_bbot_hi : STA SEG_PROJ_BUF+11,X
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
    LDA #0 : STA zp_clip_cx_hi
    LDA zp_seg_v2_evx : BPL c_sc_done
    LDA #$FF : STA zp_clip_cx_hi
.c_sc_done
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
    ; cx (s16) = sext(v1_evx) + sext(resh). With both endpoint evx in s8
    ; and t in [0,256], cx lies between them so s16 always holds it; cx
    ; itself can still fall outside s8 (sum of two s8) — the caller
    ; dispatches narrow/wide projection on the hi byte.
    LDA #0 : STA zp_br_t2
    LDA zp_seg_v1_evx : BPL c_cx_v1p
    LDA #$FF : STA zp_br_t2
.c_cx_v1p
    LDA #0 : STA zp_br_t3
    LDA zp_br_resh : BPL c_cx_rp
    LDA #$FF : STA zp_br_t3
.c_cx_rp
    LDA zp_seg_v1_evx : CLC : ADC zp_br_resh : STA zp_clip_cx
    LDA zp_br_t2 :           ADC zp_br_t3    : STA zp_clip_cx_hi

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
    PAGE BANK_L0                ; nodes table lives in bank L0
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
    LDA zp_node_dyhi : EOR zp_seg_dxraw_hi : BPL ns_side0   ; (was BMI+JMP)
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

; ============================================================================
; br_project_x_wide — project a view-space X whose integer part is s16
; (doesn't fit s8) to screen X, bit-exact with Python's full-width
;   sx = 128 + evx*rxh + (evx*rxl >> 8) + (frac*rxh >> 8)   (mod 2^16)
; where evx = (zp_v_xext : zp_v_xint) s16, frac = zp_v_xfrac u8,
; rxh in [0,127] (recip 8.8 clamped to $7FFF), rxl u8.
;
; Byte decomposition (5 8x8 muls; wide path only, |evx| >= 128):
;   evx*rxh mod 2^16 = umul8(xint,rxh) + (smul_s8_u8(xext,rxh).lo << 8)
;   evx*rxl >> 8     = smul_s8_u8(xext,rxl) + umul8(xint,rxl).hi
;     (exact floor: evx*rxl = 256*(xext*rxl) + xint*rxl with xint*rxl >= 0)
;   frac*rxh >> 8    = umul8(xfrac,rxh).hi
;
;   Inputs:  zp_v_xext/zp_v_xint/zp_v_xfrac, zp_br_rhi/zp_br_rlo
;   Output:  zp_br_resl/h = sx (s16, mod 2^16 of Python's value)
;   Clobbers: zp_br_a/b, zp_br_vxlo/hi, zp_mul_b, zp_prod_lo/hi
; ============================================================================
.br_project_x_wide
{
    ; 24-bit accumulation: the bbox corner path needs the true sign of
    ; sx when |sx| exceeds s16 (off-screen side classification); the seg
    ; path uses the low 16 only (matches Python's value at the s16 ZP
    ; interface). Accumulator: vxlo/vxhi/t2 (lo/mid/ext).

    ; sum := 128 + umul8(xint, rxh)
    LDA zp_br_rhi : STA zp_mul_b
    LDA zp_v_xint
    JSR SC_UMUL8
    CLC
    LDA zp_prod_lo : ADC #128 : STA zp_br_vxlo
    LDA zp_prod_hi : ADC #0   : STA zp_br_vxhi
    LDA #0         : ADC #0   : STA zp_br_t2

    ; sum += smul_s8_u8(xext, rxh) << 8   (s16 product into mid/ext)
    LDA zp_v_xext : STA zp_br_a
    LDA zp_br_rhi : STA zp_br_b
    JSR br_smul_s8_u8
    LDA zp_br_resl : CLC : ADC zp_br_vxhi : STA zp_br_vxhi
    LDA zp_br_resh :       ADC zp_br_t2   : STA zp_br_t2

    ; sum += sext24(smul_s8_u8(xext, rxl))   (s16 part of evx*rxl >> 8)
    LDA zp_v_xext : STA zp_br_a
    LDA zp_br_rlo : STA zp_br_b
    JSR br_smul_s8_u8
    LDX #0
    LDA zp_br_resh : BPL pw_t2_pos
    DEX                                      ; X = $FF sign extension
.pw_t2_pos
    LDA zp_br_resl : CLC : ADC zp_br_vxlo : STA zp_br_vxlo
    LDA zp_br_resh :       ADC zp_br_vxhi : STA zp_br_vxhi
    TXA            :       ADC zp_br_t2   : STA zp_br_t2

    ; sum += umul8(xint, rxl).hi   (u8, the non-negative floor remainder)
    LDA zp_br_rlo : STA zp_mul_b
    LDA zp_v_xint
    JSR SC_UMUL8
    LDA zp_prod_hi : CLC : ADC zp_br_vxlo : STA zp_br_vxlo
    LDA #0         :       ADC zp_br_vxhi : STA zp_br_vxhi
    LDA #0         :       ADC zp_br_t2   : STA zp_br_t2

    ; sum += umul8(xfrac, rxh).hi  (sub-pixel term)
    LDA zp_br_rhi : STA zp_mul_b
    LDA zp_v_xfrac
    JSR SC_UMUL8
    LDA zp_prod_hi : CLC : ADC zp_br_vxlo : STA zp_br_resl
    LDA #0         :       ADC zp_br_vxhi : STA zp_br_resh
    LDA #0         :       ADC zp_br_t2   : STA zp_br_resext
    RTS
}

; (ev_clamp_evy16 moved to the B region.)

; (br_project_x_auto moved to the B region.)

ASSERT bsp_lo_end <= $2000


; ============================================================================
; ap_edges — NOVT aperture-edge verticals (SF_APEDGE1=$40 / SF_APEDGE2=$80).
; Mirrors the Python reference:
;   SOLID seg, APEDGE_K: draw (sxK, bchK', sxK, bfhK') where (bch,bfh) are
;     the colinear portal's aperture heights, projected with endpoint K's
;     reciprocal. For K=1 the packer overlays them on the bfh/bch slots,
;     so sy1_bbot/sy1_btop ALREADY hold the projections. For K=2 they sit
;     in seg detail bytes 12/13 and are projected by ap2_solid_proj.
;   PORTAL seg (has steps), APEDGE_K: draw (sxK, bt|ft, sxK, bb|fb) — all
;     four projections already in the SEG_PROJ_BUF slots.
; Off-screen endpoints (sx hi != 0) are skipped like the other verticals:
; Python computes then AP-skips or DCL-clips them; pixel output matches.
; X = sy-slot offset (0=v1, 4=v2), Y = sx-slot offset (0=v1, 2=v2).
; ============================================================================
.ap_edges
{
    LDA zp_seg_flags : AND #$40 : BEQ ap_chk2
    LDX #0
    LDY #0
    JSR ap_edge_one
.ap_chk2
    LDA zp_seg_flags : AND #$80 : BEQ ap_done
    LDX #4
    LDY #2
    JSR ap_edge_one
.ap_done
    RTS
}

.ap_edge_one
{
    LDA $0062,Y : BNE ap_rts            ; sx off-screen → skip
    LDA zp_seg_flags : AND #$02 : BNE ap_solid
    ; portal: top edge = bt if NEEDBT else ft; bot = bb if NEEDBB else fb
    LDA zp_seg_flags : AND #$04 : BEQ ap_top_ft
    LDA SEG_PROJ_BUF+8,X : STA zp_line_yl
    LDA SEG_PROJ_BUF+9,X : STA $B3
    JMP ap_bot
.ap_top_ft
    LDA SEG_PROJ_BUF+0,X : STA zp_line_yl
    LDA SEG_PROJ_BUF+1,X : STA $B3
.ap_bot
    LDA zp_seg_flags : AND #$08 : BEQ ap_bot_fb
    LDA SEG_PROJ_BUF+10,X : STA zp_line_yr
    LDA SEG_PROJ_BUF+11,X : STA $B5
    JMP ap_emit_y
.ap_bot_fb
    LDA SEG_PROJ_BUF+2,X : STA zp_line_yr
    LDA SEG_PROJ_BUF+3,X : STA $B5
    JMP ap_emit_y
.ap_solid
    CPX #0 : BNE ap2_solid_jmp
    ; v1 solid: line from sy1_bbot (APV1_CH proj) to sy1_btop (APV1_FH)
    LDA SEG_PROJ_BUF+10,X : STA zp_line_yl
    LDA SEG_PROJ_BUF+11,X : STA $B3
    LDA SEG_PROJ_BUF+8,X : STA zp_line_yr
    LDA SEG_PROJ_BUF+9,X : STA $B5
.ap_emit_y
    ; vertical at the endpoint's sx ($61/$63 via Y)
    LDA $0061,Y : STA zp_line_xl : STA zp_line_xr
    LDA $0062,Y : STA $B2 : STA $B4
    LDA #0 : STA $BD
    PAGE BANK_C
    JMP SC_DRAW_S16
.ap2_solid_jmp
    JMP ap2_solid_proj
.ap_rts
    RTS
}

; ap2_solid_proj — project the solid seg's APV2 aperture heights with
; endpoint 2's reciprocal and emit the vertical at sx2.
;   v2 crossed → recip = recip(NEAR) = (127,255) constant (Python idx2).
;   else       → recip from v2's vertex cache entry (offsets 2,3).
.ap2_solid_proj
{
    LDA zp_seg_v2_clipped : BEQ a2_cached
    LDA #127 : STA zp_br_rhi
    LDA #255 : STA zp_br_rlo
    JMP a2_have_recip
.a2_cached
    ; cache ptr = VCACHE_BASE + v2_idx*8 (the ZP cache ptr is rasteriser-
    ; clobbered scratch by now — recompute).
    LDA zp_seg_v2_lo : STA zp_br_t0
    LDA zp_seg_v2_hi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1
    CLC
    LDA #<VCACHE_BASE : ADC zp_br_t0 : STA zp_br_p
    LDA #>VCACHE_BASE : ADC zp_br_t1 : STA zp_br_p_h
    LDY #2 : LDA (zp_br_p),Y : STA zp_br_rhi
    INY    : LDA (zp_br_p),Y : STA zp_br_rlo
.a2_have_recip
    LDA zp_fhch_p   : STA zp_br_p
    LDA zp_fhch_p_h : STA zp_br_p_h
    ; bch2' = project(APV2_CH - vz)  (FHCH byte 4)
    LDY #4 : LDA (zp_br_p),Y
    SEC : SBC zp_br_vz : STA zp_br_t0
    JSR br_project_y                    ; output pre-biased
    LDA zp_br_resl : STA zp_line_yl
    LDA zp_br_resh : STA $B3
    ; bfh2' = project(APV2_FH - vz)  (FHCH byte 5)
    LDY #5 : LDA (zp_br_p),Y
    SEC : SBC zp_br_vz : STA zp_br_t0
    JSR br_project_y
    LDA zp_br_resl : STA zp_line_yr
    LDA zp_br_resh : STA $B5
    JMP emit_vert_sx2
}


; fhch_ptr_si6 — zp_br_p := rom_fhch + zp_seg_first*6 (the 6-byte/seg
; height table: fh, ch, bfh|apv1_ch, bch|apv1_fh, apv2_ch, apv2_fh).
.fhch_ptr_si6
{
    LDA zp_seg_first_lo : STA zp_br_t0
    LDA zp_seg_first_hi : STA zp_br_t1
    ASL zp_br_t0 : ROL zp_br_t1                ; *2
    LDA zp_br_t0 : STA zp_br_t2
    LDA zp_br_t1 : STA zp_br_t3
    ASL zp_br_t0 : ROL zp_br_t1                ; *4
    CLC
    LDA zp_br_t0 : ADC zp_br_t2 : STA zp_br_t0 ; *6
    LDA zp_br_t1 : ADC zp_br_t3 : STA zp_br_t1
    CLC
    LDA zp_rom_fhch_lo : ADC zp_br_t0 : STA zp_br_p
    LDA zp_rom_fhch_hi : ADC zp_br_t1 : STA zp_br_p_h
    RTS
}

.bsp_lo_end
IF BANKED
  SAVE "bsp_render_lo_bk.bin", $1B40, bsp_lo_end, $1B40
ELSE
  SAVE "bsp_render_lo.bin", $1B40, bsp_lo_end, $1B40
ENDIF
