; --- CPU target: every builder MUST pass -D C02=0 (plain 6502) or -D C02=1
;     (enable 65C02 opcodes). STZ/INC A/PHX/etc are gated on C02 throughout. ---
.if ::C02
.setcpu "65C02"
.endif
; ZERO addr: zero a byte. 65C02 = STZ (A preserved); 6502 = LDA #0:STA (A
; clobbered) — only use where A is dead afterwards.
.macro ZERO addr
.if ::C02
STZ addr
.else
LDA #0
STA addr
.endif
.endmacro

; BUMP: A = A + 1. 65C02 = INC A (no carry); 6502 = CLC : ADC #1. Use only
; where the carry/overflow OUT is dead (negate, single-byte increments).
.macro BUMP
.if ::C02
ina
.else
CLC
ADC #1
.endif
.endmacro

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
BANK_L0 = 4                             ; nodes, ss, seg_hdr, verts
BANK_C = 6                              ; clipper + rasteriser
BANK_L2 = 7                             ; angle tables, bbox, recip, VWH, VWHC cache ($C000+ relocated)
; PAGE b : page sideways bank b ($FE30). No-op in the flat build, so flat stays
; bit-exact. A is clobbered — only invoke at A-dead points.
.macro PAGE bank
.if ::BANKED
LDA #bank
STA $FE30
.endif
.endmacro

.segment "MAIN"

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
; Raw (un-prescaled) player position for BSP side test.
; NOTE: these lived at $71-$74, but the NJ rasteriser at $A900 uses
; $74-$76/$79-$7A/$80-$88 as scratch — every drawn line corrupted
; zp_br_pyraw_hi and flipped point_on_side decisions mid-walk.
; $90-$9F is unclaimed by span_clip, the rasteriser, and this module.

; Per-vertex working state — dx/dy widened to s16 (vertex range can
; exceed s8 after prescale; e.g. ±400 in our test scene).
zp_br_dx = zp_br_dxlo                   ; alias for the lo byte (backwards-compat)
zp_br_dy = zp_br_dylo

; Multiply / divide / sign workspace

; Reciprocal output

; Pointer (used by indirect-Y reads of ROM/RAM)

; Generic temps

; Vertex cache helper state
; Side test working state (s16 deltas px-nx, py-ny held across fast/slow paths)
; Frame ROM table base ptrs (Python wrapper writes once)
zp_rom_fhch_lo = $0BE8
zp_rom_fhch_hi = $0BE9
zp_rom_bbox_lo = $0BEA
zp_rom_bbox_hi = $0BEB
; Bbox routine arg

; ============================================================================
; Memory map (RAM caches + ROM tables — Python wrapper places data here)
; ============================================================================
; recip/sincos: milestone keeps them flat ($E000/$E480), reachable in the
; banked_mem model (above the $8000-$BFFF window). Real-HW will bank these with
; the rest of the $C000+ subsystems (separate relocation step).
; $C000+ subsystems relocate to bank L2 for real HW. L2 window layout:
;   TA_LO $8000 TA_HI $8400 VATOX $8800 (angle tables, slope_div.asm)
;   bbox $8D00  recip $9C00  VWH $A100  VWHC cache $A600
.if ::BANKED
; L2 window (no overlaps): TA_LO$8000 TA_HI$8400 VATOX$8900 bbox$8E00
;   recip$9D00 VWH$A200 VWHC$A700
RECIP_BASE = $9D00                      ; bank L2
L2_BBOX = $8E00                         ; bank L2 (harness/loader points zp_rom_bbox here)
L2_VWH = $A200                          ; bank L2 (harness/loader points zp_rom_vwh here)
.else
RECIP_BASE = $E000                      ; recip table (HI bytes first, then LO)
.endif
SINCOS_BASE = $E480                     ; sin_mag[0..63], sin_unity[0..63] (128 bytes)

; Vertex transform cache: per-vertex saved view + projection results.
; Skip redundant transforms when multiple segs share a vertex.
;   8 bytes per entry (shift 3 for indexing).
;   +0 vx_int (s8)   +1 vx_frac (u8)
;   +2 rhi (u8)      +3 rlo (u8)
;   +4 sx_lo (u8)    +5 sx_hi (u8)   (s16 projected screen X)
;   +6 near_clip_flag (non-zero = vertex was near-clipped, skip seg)
;   +7 pad
; Valid bitmap: 1 bit per vertex; cleared at the start of each frame.
VCACHE_BASE = $0C00
VCACHE_VALID_BASE = $1B00               ; 59 bytes for 467 vertices


; ============================================================================
; Jump-table entries (Python wrapper JSRs to these fixed addresses)
; ============================================================================
jt_br_umul8: JMP br_umul8                            ; $4800 + 0  = $4800   wraps span_clip's umul8 for testing
jt_br_smul8: JMP br_smul8                            ; $4803   signed s8 × s8 → s16
jt_br_recip: JMP br_recip                            ; $4806   reciprocal lookup
jt_br_view_setup: JMP br_view_setup                       ; $4809   compute frac_vx/frac_vy
jt_br_to_view: JMP br_to_view                          ; $480C   world (zp_br_dx/dy_input) → view (zp_br_vxlo..vyhi)
jt_br_project_x_subpx: JMP br_project_x_subpx                  ; $480F   view vx → screen sx
jt_br_project_y: JMP br_project_y                        ; $4812   height_delta → screen sy
jt_br_render_frame: JMP br_render_frame                     ; $4815   walk BSP, dispatch subsector renderer
jt_br_render_subsector: JMP br_render_subsector                 ; $4818  process one subsector's segs (caller sets
;        zp_node_chlo:hi to the subsector id). Used
;        by the hybrid Python-BSP + 6502-seg harness
;        to isolate BSP-traversal vs seg-processor
;        divergence.
jt_br_init_frame: JMP br_init_frame                       ; $481B   clear vcache valid bitmap (for hybrid mode)

; ============================================================================
; Aliases for span_clip's exported routines
; ============================================================================
; SC_UMUL8 / SC_UDIV16_8 are now local labels (see .SC_UMUL8 / .SC_UDIV16_8
; in the $4800 region) — banked port decouples them from span_clip.
; Clipper jump table is at $2000 (flat) or $8000 (bank C). SC_BASE offsets all.
; Imported from span_clip (same link; the jump-table indirection is kept so
; entries stay uniformly callable from the harness).
.import jt_mark_solid, jt_has_gap, jt_is_full
.import seg_zero_rec_solid
.import jt_tighten_from_records, jt_draw_clip, jt_draw_clip_s16
SC_DRAW_S16 = jt_draw_clip_s16
SC_DRAW_U8 = jt_draw_clip                ; standalone DCL (u8 input, no clipper prelude)
SC_MARK_SOLID = jt_mark_solid
SC_TIGHTEN_FROM_RECORDS = jt_tighten_from_records

; And span_clip's ZP slots that umul8/udiv16_8 use
; quarter-square tables (loaded by harness) — for inlining umul8 at hot sites
.if ::BANKED
sqr_lo = $2000
sqr_hi = $2100
; low RAM (matches span_clip banked sqr)
sqr2_lo = $2200
sqr2_hi = $2300
.else
sqr_lo = $A500
sqr_hi = $A600
sqr2_lo = $A700
sqr2_hi = $A800
.endif

; span_clip's line ZP (also LC_X*_LO aliases for the s16 clipper)

; ============================================================================
; br_umul8 — wraps span_clip's umul8 for testing. Inputs in zp_br_a, zp_br_b.
; Result in zp_br_resl/resh. ~50 cycles.
; ============================================================================
; Local copies of umul8 / udiv16_8 (was SC_UMUL8/SC_UDIV16_8 in span_clip).
; Decouples bsp_render's transform arithmetic from the clipper so the clipper
; can move to a sideways-RAM bank: these stay in low RAM (always mapped),
; reached during the data-bank phase. Bit-identical to span_clip's versions;
; same ZP map + sqr tables. (BBC banked port.)
SC_UMUL8:
.scope
STA zp_tmp0
SEC
SBC zp_mul_b
BCS pos
EOR #$FF
ADC #1
pos:
TAY
LDA zp_tmp0
CLC
ADC zp_mul_b
TAX
BCS uo
LDA sqr_lo,X
SEC
SBC sqr_lo,Y
STA zp_prod_lo
LDA sqr_hi,X
SBC sqr_hi,Y
STA zp_prod_hi
RTS
uo:
LDA sqr2_lo,X
SBC sqr_lo,Y
STA zp_prod_lo
LDA sqr2_hi,X
SBC sqr_hi,Y
STA zp_prod_hi
RTS
.endscope
SC_UDIV16_8:
.scope
LDA zp_div_hi
CMP zp_div_den
BCS d16
LDX zp_div_lo
STX zp_div_hi
LDX #0
STX zp_div_lo
ASL zp_div_hi
ROL A
BCS dskip_c8
CMP zp_div_den
BCS dskip_c8
ASL zp_div_hi
ROL A
BCS dskip_c7
CMP zp_div_den
BCS dskip_c7
ASL zp_div_hi
ROL A
BCS dskip_c6
CMP zp_div_den
BCS dskip_c6
ASL zp_div_hi
ROL A
BCS dskip_c5
CMP zp_div_den
BCS dskip_c5
ASL zp_div_hi
ROL A
BCS dskip_c4
CMP zp_div_den
BCS dskip_c4
ASL zp_div_hi
ROL A
BCS dskip_c3
CMP zp_div_den
BCS dskip_c3
ASL zp_div_hi
ROL A
BCS dskip_c2
CMP zp_div_den
BCS dskip_c2
ASL zp_div_hi
ROL A
BCS dskip_c1
CMP zp_div_den
BCS dskip_c1
LDA #0
RTS
dskip_c8:
LDX #8
BNE dskip_commit
dskip_c7:
LDX #7
BNE dskip_commit
dskip_c6:
LDX #6
BNE dskip_commit
dskip_c5:
LDX #5
BNE dskip_commit
dskip_c4:
LDX #4
BNE dskip_commit
dskip_c3:
LDX #3
BNE dskip_commit
dskip_c2:
LDX #2
BNE dskip_commit
dskip_c1:
LDX #1
dskip_commit:
SBC zp_div_den
INC zp_div_lo
DEX
BNE dl
LDA zp_div_lo
RTS
d16:
LDA #0
LDX #16
dl:
ASL zp_div_lo
ROL zp_div_hi
ROL A
BCS dl_over
CMP zp_div_den
BCC ds
SBC zp_div_den
dl_commit:
INC zp_div_lo
ds:
DEX
BNE dl
LDA zp_div_lo
RTS
dl_over:
SBC zp_div_den
JMP dl_commit
.endscope
