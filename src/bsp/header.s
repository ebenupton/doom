; ============================================================================
; bsp/header.s — build flags, macros, THE JUMP TABLE, cross-unit imports.
;
; CONTEXT: included FIRST by src/bsp_render.s (after zp.inc). The jump
; table below is the driver/harness ABI: it must sit at the very start
; of the MAIN segment, which the cfgs pin first in the CODE region —
; banked $2C00, flat $3670 (= abi ENGINE_JT, link-asserted both builds;
; gen_abi.py owns the constants). PAGE is the bank-select macro: LDA
; #bank / STA $FE30 banked, NOTHING flat — so PAGE clobbers A + flags
; only (X/Y ride through), and flat builds CANNOT catch a missing PAGE
; (jsbeeb/bare-boot are the catchers).
; ============================================================================

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
; (BANK_L0/C/L2 come from abi.inc via zp.inc — one table, no copies)
; PAGE b : page sideways bank b ($FE30). No-op in the flat build, so flat stays
; bit-exact. A is clobbered — only invoke at A-dead points.
; --- Node/subsector SoA pages (head of ROM_MAIN; see wad_packed.py).
; n_nodes, n_ss <= 256, so every field is a constant-base LDA abs,X.
; Layout mirrors wad_packed.build_packed: 13 node pages (one page per
; field byte, index X = node id) then 3 subsector pages (index X = ss id):
;   pg 0/1  nx lo/hi   partition-line origin, map-centre-relative raw s16
;   pg 2/3  ny lo/hi
;   pg 4/5  dx lo/hi   partition-line direction (raw s16)
;   pg 6/7  dy lo/hi
;   pg 8/9  right child id lo/hi   (WAD encoding: bit 15 set = subsector)
;   pg 10/11 left child id lo/hi
;   pg 12   baked partition type (NT_*: skips the axis test AND the
;           unused field loads — 73% of E1M1 nodes are axis-aligned)
;   pg 13   subsector seg count
;   pg 14/15 subsector first-seg index lo/hi
.include "layout.inc"

; NODE_SOA comes from layout.inc (NODE_SOA_C): banked = L0 window head,
; flat = $B600 (the hole the retired FHCH stream vacated 2026-07-11 —
; the stride-16 headers with inlined heights at +10..15 own $6C00 now).
NODE_SOA = NODE_SOA_C
NODE_NXLO = NODE_SOA + $000
NODE_NXHI = NODE_SOA + $100
NODE_NYLO = NODE_SOA + $200
NODE_NYHI = NODE_SOA + $300
NODE_DXLO = NODE_SOA + $400
NODE_DXHI = NODE_SOA + $500
NODE_DYLO = NODE_SOA + $600
NODE_DYHI = NODE_SOA + $700
NODE_CRLO = NODE_SOA + $800             ; right child (side 0 = near)
NODE_CRHI = NODE_SOA + $900
NODE_CLLO = NODE_SOA + $A00             ; left child
NODE_CLHI = NODE_SOA + $B00
NODE_TYPE = NODE_SOA + $C00             ; 0 general, 1 dx==0, 2 dy==0
SS_CNT    = NODE_SOA + $D00
SS_FLO    = NODE_SOA + $E00
SS_FHI    = NODE_SOA + $F00

; Page-alignment contracts for the byte-at-a-time pointer builds
; (br_bbox_visible, bcac_index, the seg_xform vcache indexers):
.assert (VCACHE_BASE & $FF) = 0, error, "VCACHE_BASE must be page-aligned"

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
; udiv16_8 needs zp_div_l:hi ($DA:DB), zp_div_den ($DC).
; Both are clobbered across calls — bsp_render saves any zp data it
; needs across these calls into the BR_* slots below.
; ============================================================================

; Per-frame view-context (Python wrapper writes once per frame)
; Raw (un-prescaled) player position for BSP side test.
; NOTE: these lived at $71-$74, but the NJ rasteriser at $A900 uses
; $74-$76/$79-$7A/$80-$88 as scratch — every drawn line corrupted
; zp_br_pyraw_h and flipped point_on_side decisions mid-walk.
; $90-$9F is unclaimed by span_clip, the rasteriser, and this module.

; Per-vertex working state — dx/dy widened to s16 (vertex range can
; exceed s8 after prescale; e.g. ±400 in our test scene).
zp_br_dx = zp_br_dx_l                   ; alias for the lo byte (backwards-compat)
zp_br_dy = zp_br_dy_l

; Multiply / divide / sign workspace

; Reciprocal output

; Pointer (used by indirect-Y reads of ROM/RAM)

; Generic temps

; Vertex cache helper state
; Side test working state (s16 deltas px-nx, py-ny held across fast/slow paths)
; Frame ROM table base ptrs (Python wrapper writes once)
; ($0BE8-$0BF7 ROM-pointer block RETIRED 2026-07-10: the packed layout is
; static — bases are layout.inc assembly-time constants; loaders no longer
; poke pointers and the walk_drv ptrtab is gone. Page-$0B bytes freed.)
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
jt_br_to_view: JMP br_to_view                          ; $480C   world (zp_br_dx/dy_input) → view (zp_br_vx_l..vyhi)
jt_br_project_x: JMP br_project_x                  ; $480F   view vx → screen sx
jt_br_project_y: JMP br_project_y_paged                  ; $4812   height_delta → screen sy (pages L2)
jt_br_render_frame: JMP br_render_frame                     ; $4815   walk BSP, dispatch subsector renderer
jt_br_render_subsector: JMP br_render_subsector                 ; $4818  process one subsector's segs (caller sets
;        zp_node_ch_l:hi to the subsector id). Used
;        by the hybrid Python-BSP + 6502-seg harness
;        to isolate BSP-traversal vs seg-processor
;        divergence.
jt_br_init_frame: JMP br_init_frame                       ; $481B   clear vcache valid bitmap (for hybrid mode)
; Animated-sector entries (bodies in anim.s): kept in THIS table so the
; beebasm drivers see one pinned dispatch block and everything after the
; MAIN segment can float freely inside the CODE region.
jt_anim_tick: JMP anim_tick                          ; +$1E  (driver: PAGE BANK_L2, JSR)
jt_anim_init: JMP anim_init                          ; +$21
; (anim_tick/anim_init are same-unit labels — anim.s is part of this link unit)
.export jt_anim_tick, jt_anim_init
; The drivers reach these via the abi.inc constants (JT_*); MAIN must
; stay FIRST in the CODE region and the table must not move. Asserted
; in BOTH builds — ENGINE_JT carries the per-build base.
.assert jt_br_umul8 = ENGINE_JT, error, "jump table moved off ENGINE_JT (driver ABI)"
.assert jt_br_view_setup = JT_VIEW_SETUP, error
.assert jt_br_render_frame = JT_RENDER_FRAME, error
.assert jt_br_init_frame = JT_INIT_FRAME, error
.assert jt_anim_tick = JT_ANIM_TICK, error
.assert jt_anim_init = JT_ANIM_INIT, error

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
.import jt_draw_clip_s16_h
SC_DRAW_S16 = jt_draw_clip_s16
SC_DRAW_S16_H = jt_draw_clip_s16_h        ; horizontal: x read from zp_seg_sx1/2
SC_DRAW_U8 = jt_draw_clip                ; standalone DCL (u8 input, no clipper
; prelude). NO NATIVE CALLER (verified 2026-07-12): production lines all
; enter through the s16 front (SC_DRAW_S16/_H); this alias exists for
; harness parity tests only — keep unless the clipper jt slot itself dies.
SC_MARK_SOLID = jt_mark_solid
SC_TIGHTEN_FROM_RECORDS = jt_tighten_from_records

; And span_clip's ZP slots that umul8/udiv16_8 use
; quarter-square tables (loaded by harness) — for inlining umul8 at hot sites
; abi.inc owns the table base (SQR_BASE, flat/banked variants there)
sqr_l = SQR_LO
sqr_h = SQR_HI
sqr2_l = SQR2_LO
sqr2_h = SQR2_HI

; span_clip's line ZP (zp_line_* lo bytes + zp_line_*_hi for the s16 clipper)

; ============================================================================
; br_umul8 — wraps span_clip's umul8 for testing. Inputs in zp_br_a, zp_br_b.
; Result in zp_br_res_l/resh. ~50 cycles.
; ============================================================================
; Local copies of umul8 / udiv16_8 (was SC_UMUL8/SC_UDIV16_8 in span_clip).
; Decouples bsp_render's transform arithmetic from the clipper so the clipper
; can move to a sideways-RAM bank: these stay in low RAM (always mapped),
; reached during the data-bank phase. Bit-identical to span_clip's versions;
; same ZP map + sqr tables. (BBC banked port.)
;
; ============================================================================
; SC_UMUL8 — u8 × u8 → u16 via quarter-square tables. ~50 cycles, no loop.
;   Inputs:  A = a, zp_mul_b = b.
;   Output:  zp_prod_l/hi = a * b (u16).
;   Clobbers: A, X, Y, zp_tmp0.
;
;   Identity: a*b = qsqr(a+b) - qsqr(|a-b|), where qsqr(n) = floor(n²/4).
;   Pseudocode:
;     d = |a - b|                       # Y index
;     s = a + b                         # X index (9 bits)
;     if s < 256:  prod = sqr[s]  - sqr[d]
;     else:        prod = sqr2[s & $FF] - sqr[d]   # sqr2[n] = qsqr(n+256)
;   The sqr2 tables absorb the 9th bit of a+b, so no 16-bit indexing is
;   needed. (The uo path enters SBC with carry set from the ADC overflow,
;   which is exactly the required borrow-clear.)
; ============================================================================
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
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_prod_l
   LDA sqr_h,X
   SBC sqr_h,Y
   STA zp_prod_h
   RTS
uo:
   LDA sqr2_l,X
   SBC sqr_l,Y
   STA zp_prod_l
   LDA sqr2_h,X
   SBC sqr_h,Y
   STA zp_prod_h
   RTS
.endscope
; ============================================================================
; SC_UDIV16_8 — restoring shift-subtract division, u16 ÷ u8.
;   Inputs:  zp_div_l/hi = numerator (u16), zp_div_den = denominator (u8).
;   Output:  A = quotient low byte (also in zp_div_l; on the 16-bit path
;            zp_div_h holds the quotient high byte). Remainder discarded.
;   Clobbers: A, X, zp_div_l/hi.
;
;   Two paths, selected on div_hi vs den:
;   - div_hi < den → quotient fits u8. The numerator is pre-shifted left 8
;     (lo→hi, lo:=0) so only 8 loop iterations remain, and the leading
;     zero bits of the quotient are skipped by an unrolled compare-only
;     prelude: ASL/ROL + CMP den per bit, with NO quotient bookkeeping
;     until the first bit that commits (remainder >= den, or a carry out
;     of ROL). That bit jumps to dskip_cN, which loads X = bits remaining
;     and falls into the shared loop via dskip_commit. If all 8 compares
;     miss, the quotient is exactly 0 (early RTS).
;   - div_hi >= den → d16: full 16-iteration loop. Quotient bits shift
;     into div_lo:div_hi from the right as the numerator shifts out into
;     the remainder accumulating in A; dl_over handles remainder bit 8
;     popping out of ROL (subtract always fits, CMP skipped).
; ============================================================================
SC_UDIV16_8:
.scope
   LDA zp_div_h
   CMP zp_div_den
   BCS d16
; --- u8-quotient fast path: numerator <<= 8, then find the first
;     committing quotient bit with compare-only steps. ---
   LDX zp_div_l
   STX zp_div_h
   LDX #0
   STX zp_div_l
   ASL zp_div_h
   ROL A
   BCS dskip_c8
   CMP zp_div_den
   BCS dskip_c8
   ASL zp_div_h
   ROL A
   BCS dskip_c7
   CMP zp_div_den
   BCS dskip_c7
   ASL zp_div_h
   ROL A
   BCS dskip_c6
   CMP zp_div_den
   BCS dskip_c6
   ASL zp_div_h
   ROL A
   BCS dskip_c5
   CMP zp_div_den
   BCS dskip_c5
   ASL zp_div_h
   ROL A
   BCS dskip_c4
   CMP zp_div_den
   BCS dskip_c4
   ASL zp_div_h
   ROL A
   BCS dskip_c3
   CMP zp_div_den
   BCS dskip_c3
   ASL zp_div_h
   ROL A
   BCS dskip_c2
   CMP zp_div_den
   BCS dskip_c2
   ASL zp_div_h
   ROL A
   BCS dskip_c1
   CMP zp_div_den
   BCS dskip_c1
   LDA #0
   RTS
; all 8 compares missed → quotient = 0
; --- dskip ladder: entered from the prelude at the first committing
;     quotient bit; X = loop iterations remaining (this bit included). ---
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
; Commit the first quotient bit: remainder -= den, quotient bit → 1,
; then continue in the generic loop for the remaining X-1 bits.
   SBC zp_div_den
   INC zp_div_l
   DEX
   BNE dl
   LDA zp_div_l
   RTS
; --- 16-bit path: A = remainder, X = 16 iterations; quotient shifts
;     into div_lo:div_hi behind the departing numerator bits. ---
d16:
   LDA #0
   LDX #16
dl:
   ASL zp_div_l
   ROL zp_div_h
   ROL A
   BCS dl_over
   CMP zp_div_den
   BCC ds
   SBC zp_div_den
dl_commit:
   INC zp_div_l
ds:
   DEX
   BNE dl
   LDA zp_div_l
   RTS
dl_over:
; remainder bit 8 carried out of ROL → remainder >= 256 > den:
; the subtract always fits (carry already set), skip the CMP.
   SBC zp_div_den
   JMP dl_commit
.endscope
