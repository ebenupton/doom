; span_clip.asm -- Standalone 6502 span-clipper for a DOOM-style BSP renderer
;
; This module manages a linked list of 'spans' representing the visible
; aperture on each horizontal column of the screen (0-255).  Each span stores
; a line definition (top/bot Y at two anchor X's) and an active column range.
; The BSP front-to-back traversal calls three main operations:
;   has_gap    -- quick check whether any column in [lo,hi] is still open
;   tighten    -- narrow the aperture top/bot using a new wall segment
;   mark_solid -- remove a column range entirely (wall fully occludes)
;
; All arithmetic uses 8-bit fixed point with quarter-square lookup tables
; for multiply and restoring division loops for divide.  The span pool is
; 28 nine-byte slots at $0400; slot 0 is the null sentinel.
;
; Pool at POOL ($0400), 28 x 9-byte slots.  Slot 0 = null.
; Slot layout: next(u8), xlo(u8), xhi(u8), tl(u8), bl(u8), tr(u8), br(u8),
;              xstart(u8), xend(u8)
; Access: LDX span_offset; LDA POOL_XLO,X  (fast absolute indexed)
;
; Division by 256 (ex=0): just take high byte of multiply (shift, no loop).
; Otherwise: restoring division loop, 8 iterations.

; --- Build flags ---
EMIT_LINES = TRUE     ; set FALSE to disable line emission (pure clip benchmark)

; --- Code origin: $2000 in BBC Micro memory map ---
ORG $2000

; --- Jump table: fixed entry points for each public operation ---
; Callers (Python harness, game engine) JSR to $2000 + 3*N.
; JMP is 3 bytes, so entries are evenly spaced.
JMP span_init       ; $2000                                             ; |
JMP span_mark_solid ; $2003                                             ; |
JMP span_tighten    ; $2006                                             ; |
JMP span_has_gap    ; $2009                                             ; |||
JMP span_is_full    ; $200C
JMP span_read       ; $200F
JMP interp_store    ; $2012  (kept for test_interp verification)
JMP draw_clipped_line ; $2015

; === Pool constants and field offsets ===
; The span pool is a flat array at $0400.  Each slot is 9 bytes, so slot N
; lives at byte offset N*9.  Absolute indexed addressing (LDA POOL_TL,X
; where X = slot offset) gives O(1) field access.  The linked list is
; threaded through the NEXT byte (+0) of each slot.
; Span pool — 9-byte slots, 28 slots total ($400-$4FB).
; Slot 0 is the null sentinel; slot 1 (offset 9) is the initial active span;
; slots 2..27 (offsets 18, 27, ..., 243) start on the free list.
;
; Field layout per slot:
;   +0 NEXT   linked-list next (byte offset, 0 = end)
;   +1 XLO    line anchor x left  (immutable after span creation)
;   +2 XHI    line anchor x right (immutable)
;   +3 TL     top y at XLO
;   +4 BL     bot y at XLO
;   +5 TR     top y at XHI
;   +6 BR     bot y at XHI
;   +7 XSTART active range start (mutable: shrunk by mark_solid / tighten fragments)
;   +8 XEND   active range end   (mutable)
;
; Spans interpolate y at any column x ∈ [XSTART, XEND] using the line through
; (XLO, TL/BL) — (XHI, TR/BR). XLO/XHI need not equal XSTART/XEND once a span
; has been narrowed: the line is preserved across mark_solid splits and across
; left/right-fragment creation in tighten, so no interp_store is needed for
; those operations.
POOL        = $0400
POOL_NEXT   = $0400
POOL_XLO    = $0401
POOL_XHI    = $0402
POOL_TL     = $0403
POOL_BL     = $0404
POOL_TR     = $0405
POOL_BR     = $0406
POOL_XSTART = $0407
POOL_XEND   = $0408
SLOT_SIZE   = 9
SLOT_END    = 28*SLOT_SIZE   ; one past the last byte offset (= 252)

; Quarter-square multiply tables (pre-loaded by the Python harness).
; sqr[n]  = floor(n^2/4) for n in [0,255]; sqr2[n] = floor((n+256)^2/4)
; used when a+b overflows u8.
sqr_lo  = $5400 : sqr_hi  = $5500
sqr2_lo = $5600 : sqr2_hi = $5700

; === Seg value cache ($A0-$A4) — separate from crossover working set ===
; Caches the right-endpoint new-seg values from the previous overlapping span
; for reuse when the next span shares the boundary column (abutting model).
zp_cache_ox1  = $A0    ; cached ox1 ($FF = invalid)
zp_cache_nt   = $A1    ; cached nt_r (seg top lo)
zp_cache_nt_h = $A2    ; cached nt_rh (seg top hi)
zp_cache_nb   = $A3    ; cached nb_r (seg bot lo)
zp_cache_nb_h = $A4    ; cached nb_rh (seg bot hi)
; === Running seg bounds ($A5-$A7) — progressively tighter seg extremes ===
; Initialized at tg_go with clamped max(yt1,yt2) and min(yb1,yb2); narrowed
; after each non-old-dom span. Used by the unified tiered dominance check.
zp_bb_yt_max  = $A5    ; max(seg top clamped) over remaining overlap range
zp_bb_yb_min  = $A6    ; min(seg bot clamped) over remaining overlap range
zp_bb_flags   = $A7    ; $40 = all on-screen (new-dom + narrowing valid), $00 = disabled
zp_ms_emit    = $A8    ; mark_solid: $FF = emit wall edge lines, $00 = skip

; === Draw-clipped-line ZP ($A8-$B9) — reuses $A8 (ms_emit) since non-overlapping ===
; Caller sets xl/yl/xr/yr; routine computes dx/dy/ylo/yhi.
zp_line_xl  = $A8    ; u8, left X (oriented left-to-right)
zp_line_yl  = $A9    ; u8, Y at xl
zp_line_xr  = $AA    ; u8, right X
zp_line_yr  = $AB    ; u8, Y at xr
zp_line_dx  = $AC    ; u8, xr - xl (>= 0)
zp_line_dy  = $AD    ; s8, yr - yl
zp_line_ylo = $AE    ; u8, min(yl, yr) — running Y bbox
zp_line_yhi = $AF    ; u8, max(yl, yr) — running Y bbox
zp_seg_start_x = $B0 ; u8, $FF = NULL (no segment started)
zp_seg_start_y = $B1  ; u8, Y at seg_start_x
zp_tg_cont    = $BA   ; portal continuation: $FF=inactive, else=prev span xend
; CB clip working set ($B2-$B9)
zp_cb_cx1   = $B2    ; u8, clipped left X
zp_cb_cy1   = $B3    ; u8, clipped left Y (line Y at cx1)
zp_cb_cx2   = $B4    ; u8, clipped right X
zp_cb_cy2   = $B5    ; u8, clipped right Y (line Y at cx2)
zp_cb_top1  = $B6    ; u8, span top at cx1
zp_cb_top2  = $B7    ; u8, span top at cx2
zp_cb_bot1  = $B8    ; u8, span bot at cx1
zp_cb_bot2  = $B9    ; u8, span bot at cx2

; === Line output buffer ($0200) ===
; Lines emitted during tighten (portal edges) and mark_solid (wall edges).
; Format: byte count at $0200, then x1,y1,x2,y2 tuples at $0201+.
; Drained by Python after each tighten/mark_solid call.
LINE_OUT_COUNT = $0200
LINE_OUT_BUF   = $0201

; === NJ rasteriser integration ===
; When rasteriser is loaded at $A900, emit_line calls it directly.
; ZP $82-$85 = x0,y0,x1,y1 (rasteriser inputs, no conflict with clipper ZP).
; ZP $70 = screen start hi byte (set once by Python before frame).
RASTER_ENTRY = $A900
RASTER_ZP_X0 = $82
RASTER_ZP_Y0 = $83
RASTER_ZP_X1 = $84
RASTER_ZP_Y1 = $85
RASTER_ZP_SCRSTRT = $70

; === Zero-page workspace ($C0-$FF) ===
; Layout: list management (head, free), input params (seg coords s16),
; interpolation temps (i_x, i_y0, mul_b, prod, div), scratch (tmp0-3),
; and tighten state (overlap bounds, crossover X, boundary values).
; Note: prod_lo aliases div_lo -- multiply output feeds directly into
; division input, saving two loads per interp call.
zp_head  = $C0 : zp_free  = $C1
zp_ilo   = $C2 : zp_ihi   = $C3
; Seg parameters: 16-bit (lo/hi pairs). Values can be outside [0,255].
zp_sx1   = $C4   ; s16: seg left X  (lo, hi)
zp_sx1h  = $C5
zp_sx2   = $C6   ; s16: seg right X
zp_sx2h  = $C7
zp_yt1   = $C8   ; s16: top Y at sx1
zp_yt1h  = $C9
zp_yt2   = $CA   ; s16: top Y at sx2
zp_yt2h  = $CB
zp_yb1   = $CC   ; s16: bot Y at sx1
zp_yb1h  = $CD
zp_yb2   = $CE   ; s16: bot Y at sx2
zp_yb2h  = $CF
zp_hg_cache = $D0    ; has_gap coherence cache: last-matching span offset
zp_i_x0  = $D1
zp_i_y0  = $D2 : zp_i_y0h = $D3   ; s16 Y for seg interp
zp_i_x1  = $D4 : zp_i_y1  = $D5 : zp_i_y1h = $D6
zp_i_res = $D7 : zp_i_resh = $D8
zp_mul_b = $D9
zp_prod_lo = $DA : zp_div_lo = $DA   ; shared: mul output = div input
zp_prod_hi = $DB : zp_div_hi = $DB
zp_div_den = $DC : zp_div_rem = $DD
zp_tmp0  = $DE : zp_tmp1  = $DF : zp_tmp2  = $E0
zp_tmp3  = $E1 : zp_prev  = $E2
zp_buf   = $E3  ; u16 pointer ($E3/$E4)
zp_save0 = $E5  ; safe scratch (not clobbered by interp)
zp_save1 = $E6  ; safe scratch #2
zp_save2 = $E7  ; safe scratch #3 (alias for tighten zp_new_tail; mark_solid only)

; ======================================================================
; SPAN_INIT: reset the clipper to one full-screen span
;
; Builds two structures:
;   FREE LIST -- singly-linked chain of unused slots 2..27
;   ACTIVE LIST -- single span (slot 1) covering [0,255] x [0,159]
;
; Called once per frame. Runtime is negligible (< 0.5% of total).
; ======================================================================
.span_init
{
    ; Free list: slots 2..27 (byte offsets 18..243).
    LDX #2*SLOT_SIZE       ; slot 2                                     ; |
    STX zp_free                                                         ; |
.il  TXA : CLC : ADC #SLOT_SIZE                                         ; ||
    CMP #SLOT_END          ; reached end? (= 252)                       ; |
    BCS id                                                              ; |
    STA POOL_NEXT,X : TAX                                               ; ||
    BNE il                 ; always taken                               ; |
.id  LDA #0 : STA POOL_NEXT,X                                           ; |
    ; Active list: slot 1 = full screen, line and active range both [0, 255].
    LDX #SLOT_SIZE         ; slot 1 (offset 9)                          ; |
    STX zp_head                                                         ; |
    STA POOL_NEXT,X : STA POOL_XLO,X : STA POOL_XSTART,X                ; |
    STA POOL_TL,X : STA POOL_TR,X                                       ; |
    LDA #255 : STA POOL_XHI,X : STA POOL_XEND,X                         ; |
    LDA #159                                                            ; |
    STA POOL_BL,X : STA POOL_BR,X                                       ; |
    STX zp_hg_cache         ; init cache to slot 1 (the initial span)   ; |
    RTS                                                                 ; |
}

; ======================================================================
; ALLOC_SPAN / FREE_SPAN: O(1) pool allocator via free-list push/pop
;
; alloc_span: pops free list head into X.  Z=0 on success, Z=1 if empty.
; free_span:  pushes slot X back onto free list.  Tail-callable (JMP).
; ======================================================================
.alloc_span
    ; Returns X = new span offset.  Z=1 if failed (X=0), Z=0 if success.
    ; Caller is responsible for setting POOL_NEXT (tg_append_x or mark_solid linking).
    LDX zp_free : BEQ af                                                ; |
    LDA POOL_NEXT,X : STA zp_free                                       ; |
    TXA                     ; A=X≠0, sets Z=0                           ; |
.af RTS                                                                 ; |

.free_span
    LDA zp_free : STA POOL_NEXT,X : STX zp_free : RTS                   ; |||

; ======================================================================
; UMUL8: unsigned 8x8 multiply via quarter-square identity
;
; Computes A * zp_mul_b using: a*b = sqr(a+b) - sqr(a-b)
; where sqr(n) = floor(n^2/4).  Two table sets handle a+b < 256 vs
; a+b >= 256.  |a-b| is always < 256 so uses sqr_lo/hi in both cases.
; Result: zp_prod_lo:zp_prod_hi (u16).
;
; This is the hottest subroutine -- called by every interpolation.
; ======================================================================
.umul8
{
    STA zp_tmp0                                                         ; |
    SEC : SBC zp_mul_b : BCS pos                                        ; |||
    EOR #$FF : ADC #1    ; |diff| (C was 0 from SBC, so ADC adds +0+1)  ; ||
.pos TAY                  ; Y = |diff|                                  ; |
    LDA zp_tmp0 : CLC : ADC zp_mul_b                                    ; ||||
    TAX : BCS uo          ; X = sum; overflow if carry from ADC          ; ||
    ; sum < 256: sqr tables for sum
    LDA sqr_lo,X : SEC : SBC sqr_lo,Y : STA zp_prod_lo                  ; |||||
    LDA sqr_hi,X : SBC sqr_hi,Y : STA zp_prod_hi : RTS                  ; |||||||
.uo ; sum >= 256: sqr2 tables for sum (carry already set from BCS)
    LDA sqr2_lo,X : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr2_hi,X : SBC sqr_hi,Y : STA zp_prod_hi : RTS
}

EQUB 0   ; 1-byte pad: optimal alignment for umul8

; (interp_core removed — inlined into interp_store below.)

; --- SMUL8: signed 8-bit x unsigned 8-bit multiply ---
; If A >= 0, falls through to umul8.  If A < 0, negates, calls umul8,
; correction.  Result: zp_prod_lo:zp_prod_hi (s16).
; s8 × u8: A(s8) × zp_mul_b(u8) → zp_prod_lo:zp_prod_hi(s16)
.smul8
{
    BPL umul8                                                           ; |
    ; A is negative (s8). Compute using unsigned interpretation:
    ; A_s8 * B = A_u8 * B - 256 * B. So: umul8(A_u8, B), then prod_hi -= B.
    JSR umul8                                                           ; |
    LDA zp_prod_hi : SEC : SBC zp_mul_b : STA zp_prod_hi : RTS          ; |
}

; ======================================================================
; UDIV16_8: unsigned 16/8 restoring division
;
; Divides zp_div_lo:hi by zp_div_den, quotient returned in A.
; FAST PATH (most common): div_hi < den => quot fits u8, 8 iterations.
; SLOW PATH: div_hi >= den (seg extrapolation), 16 iterations.
;
; Uses the INC-shift trick: as bits ASL out of div_lo, quotient bits
; accumulate via INC in the vacated positions.  After N iterations,
; div_lo == quotient.
;
; *** HOTTEST LOOP *** -- the 3-instruction shift chain (ASL/ROL/ROL)
; plus trial subtraction account for ~20% of all clipper cycles.
; ======================================================================
.udiv16_8
{
    LDA zp_div_hi : CMP zp_div_den : BCS d16
    ; FAST PATH: quotient fits in 8 bits.  Setup: rem = div_hi,
    ; div_hi = div_lo, div_lo = 0.  Then skip leading zero-bit
    ; iterations: shift rem:div_hi left, checking rem vs den each
    ; time.  Each skip iteration (~19 cyc) is cheaper than the main
    ; loop iteration (~33 cyc when the trial subtract fails), saving
    ; ~14 cyc per skipped iteration.
    LDX zp_div_lo : STX zp_div_hi
    LDX #0 : STX zp_div_lo
    ; --- Unrolled skip: consume leading zero quotient bits ---
    ; 8 copies; each branches to its own per-copy commit handler that sets
    ; X directly (saves DEX per skipped copy: −2 cyc per skip iteration).
    ASL zp_div_hi : ROL A : BCS dskip_c8 : CMP zp_div_den : BCS dskip_c8
    ASL zp_div_hi : ROL A : BCS dskip_c7 : CMP zp_div_den : BCS dskip_c7
    ASL zp_div_hi : ROL A : BCS dskip_c6 : CMP zp_div_den : BCS dskip_c6
    ASL zp_div_hi : ROL A : BCS dskip_c5 : CMP zp_div_den : BCS dskip_c5
    ASL zp_div_hi : ROL A : BCS dskip_c4 : CMP zp_div_den : BCS dskip_c4
    ASL zp_div_hi : ROL A : BCS dskip_c3 : CMP zp_div_den : BCS dskip_c3
    ASL zp_div_hi : ROL A : BCS dskip_c2 : CMP zp_div_den : BCS dskip_c2
    ASL zp_div_hi : ROL A : BCS dskip_c1 : CMP zp_div_den : BCS dskip_c1
    ; All 8 iterations zero → quotient = 0
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
    SBC zp_div_den         ; carry already set (from BCS)
    INC zp_div_lo          ; set this quotient bit
    DEX : BNE dl           ; remaining iterations via main loop (rem in A)
    LDA zp_div_lo : RTS
.d16 LDA #0
    LDX #16
    ; Main loop: remainder kept in A (saves LDA/STA zp_div_rem per iter)
.dl ASL zp_div_lo : ROL zp_div_hi : ROL A                               ; ||||||||||||||||||||||||||||||||||||||||
    BCS dl_over                                                         ; |||||
    CMP zp_div_den : BCC ds                                             ; |||||||||||||||||||||||||||||
    SBC zp_div_den                                                      ; |
.dl_commit
    INC zp_div_lo                                                       ; |||||
.ds DEX : BNE dl                                                        ; |||||||||||||
    LDA zp_div_lo : RTS                                                 ; |||
.dl_over
    SBC zp_div_den          ; carry already set from BCS dl_over
    JMP dl_commit
}
; (pad removed after udiv16_8)

; ======================================================================
; SEG_INTERP_STORE: interpolate seg Y at column X (s16 result)
;
; Evaluates: y0 + round_nearest(dy * offset / ex)
;   dy = y1 - y0 (s8), offset = x - sx1 (u8), ex = sx2 - sx1 (u8)
;
; Seg Y values are s16 (may be off-screen).  The remap step guarantees
; |dy| <= 127 and ex <= 255, keeping the s8*u8 multiply and u16/u8
; divide within range.  Short-circuits on dy==0 and prod==0.
; Returns: A = lo byte, Y = hi byte of s16 result.
; ======================================================================
.seg_interp_store
{
    ; offset = x - sx1 (A holds x on entry)
    SEC : SBC zp_sx1 : BEQ sis_y0 : CMP zp_div_den : BEQ sis_y1         ; |||||
    STA zp_mul_b                                                         ; |
    ; dy = y1 - y0 (BEQ sis_y0 catches dy==0 constant-line shortcut)
    LDA zp_i_y1 : SEC : SBC zp_i_y0 : BEQ sis_y0                        ; |||||
    JSR smul8                                                           ; ||
    ; prod guaranteed nonzero (offset!=0 AND dy!=0, verified exhaustively)
    ; ex always in [1,255] post-remap; bias = ex/2 for round-to-nearest
    LDA zp_div_den : LSR A                                              ; |
    CLC : ADC zp_prod_lo : STA zp_prod_lo                               ; ||
    LDA zp_prod_hi : ADC #0 : STA zp_prod_hi                            ; ||
    BMI sis_neg                                                         ; |
    ; Positive: result = y0 + quot (s16). Returns A=lo, Y=hi.
    JSR udiv16_8                                                        ; |
    CLC : ADC zp_i_y0 : TAX     ; X = result_lo (udiv leaves X=0, safe to clobber)  ; |
    LDA zp_div_hi : ADC zp_i_y0h : TAY                                  ; |
    TXA : RTS                                                           ; |
.sis_neg
    ; Negate the biased product, divide, then result = y0 - quot (s16)
    SEC : LDA zp_div_den : SBC #1 : SBC zp_prod_lo : STA zp_div_lo      ; ||
    LDA #0 : SBC zp_prod_hi : STA zp_div_hi                             ; |
    JSR udiv16_8                                                        ; |
    SEC : LDA zp_i_y0 : SBC zp_div_lo : TAX                             ; |
    LDA zp_i_y0h : SBC zp_div_hi : TAY                                  ; |
    TXA : RTS                                                           ; |
.sis_y0
    LDY zp_i_y0h                ; Y = y0 high, A = y0 low (RTS caller)  ; |
    LDA zp_i_y0 : RTS                                                   ; ||
.sis_y1
    LDY zp_i_y1h                ; Y = y1 high, A = y1 low (offset==den) ; |
    LDA zp_i_y1 : RTS                                                   ; ||
}

; (seg_interp_core removed — inlined into seg_interp_store above.)

; ======================================================================
; INTERP_STORE: interpolate old span Y at column X (u8 result)
;
; Same formula as seg_interp_store but for spans whose boundaries are
; always u8 in [0,159].  Simpler tail: u8 add/sub instead of s16.
; Caller pre-computes den = xhi - xlo once per span and reuses it
; for all 4 boundary interps (tl, tr, bl, br).
;
; Input: A = x (eval point), zp_i_x0, zp_i_y0, zp_i_y1, zp_div_den
; Output: A = interpolated Y (u8)
; ======================================================================
.interp_store
{
    ; offset = x - x0 (A holds x on entry)
    SEC : SBC zp_i_x0 : BEQ is_y0                                        ; |||
    CMP zp_div_den : BEQ is_y1                                           ; ||
    STA zp_mul_b                                                         ; |
    ; dy = y1 - y0 (BEQ is_y0 catches constant-line short-circuit)
    LDA zp_i_y1 : SEC : SBC zp_i_y0 : BEQ is_y0                         ; |||||
    JSR smul8                                                           ; |
    ; prod guaranteed nonzero (offset!=0 AND dy!=0, verified exhaustively)
    ; Add ex/2 to product for round-to-nearest. ex always in [1,255].
    LDA zp_div_den : LSR A                                              ; |
    CLC : ADC zp_prod_lo : STA zp_prod_lo                               ; |
    LDA zp_prod_hi : ADC #0 : STA zp_prod_hi                            ; |
    BMI is_neg                                                          ; |
    ; Positive: result = y0 + quot (u8)
    JSR udiv16_8                                                        ; |
    CLC : ADC zp_i_y0 : RTS                                             ; |
.is_neg
    ; Negate the biased product, divide, then result = y0 - quot (u8)
    SEC : LDA zp_div_den : SBC #1 : SBC zp_prod_lo : STA zp_div_lo      ; |
    LDA #0 : SBC zp_prod_hi : STA zp_div_hi                             ; |
    JSR udiv16_8                                                        ; |
    EOR #$FF : SEC : ADC zp_i_y0 : RTS                                  ; |
.is_y0
    LDA zp_i_y0 : RTS                                                   ; ||
.is_y1
    LDA zp_i_y1 : RTS                                                   ; ||
}

; (interp_span removed — mark_solid no longer interpolates)

; (interp_span removed — padding removed to preserve page alignment of later code)

; 0-byte pad: optimal alignment for narrowed-BB layout

; ======================================================================
; MARK_SOLID: punch out [ilo, ihi] from the span list (solid wall)
;
; LAZY operation: only adjusts XSTART/XEND on affected spans.
; Line params (XLO/XHI/TL/BL/TR/BR) are NEVER modified -- zero interp
; calls needed.  When a solid range splits a span in the middle, a
; sibling slot is allocated and the 6 line bytes are copied verbatim.
;
; Three cases per span:
;   1. No left frag (xstart >= ilo): shrink xstart or free entirely
;   2. Left only (xend <= ihi): truncate xend = ilo - 1
;   3. Middle split: alloc sibling for right frag, truncate original
; ======================================================================
.span_mark_solid
{
    ; mark_solid is now LAZY: it only updates the active range (XSTART/XEND)
    ; on existing spans. The line params (XLO/XHI/TL/BL/TR/BR) never change,
    ; so no interp_store calls happen here. Splitting a span in the middle
    ; just allocates a sibling and copies the 6 line bytes verbatim.
    LDA zp_ihi : CMP zp_ilo : BCS mss                                   ; |
    RTS
.mss
IF EMIT_LINES
    ; --- Wall edge line emission pre-pass (if seg params provided) ---
    LDA zp_ms_emit : BEQ ms_no_emit                                     ; |
    JSR ms_emit_lines                                                    ; |
.ms_no_emit
ENDIF
    LDA #$FF : STA zp_prev                                              ; |
    LDA zp_head : TAX : BNE msl : RTS                                   ; |

.ms_chk_after_y
    TYA : TAX                                                            ; Y→X for overlap code
.ms_chk_after
    ; Done if xstart > ihi (span starts after solid range).
    ; Load xstart once and reuse for both ihi and ilo comparisons.
    LDA POOL_XSTART,X                                                    ; |
    CMP zp_ihi : BEQ ms_overlap : BCS ms_rts_x                          ; |||
.ms_overlap
    ; A = xstart (from ms_chk_after). Check left fragment.
    ; xstart < ilo  → keep a left fragment   (xend may need clip too)
    ; xstart >= ilo → no left fragment       (this span is entirely in or right of [ilo,ihi])
    CMP zp_ilo : BCC ms_has_left                                         ; ||
    ; --- No left fragment ---
    ; xend > ihi  → shrink in place (BCC past ms_free)
    ; xend <= ihi → fully covered → fall through to ms_free
    LDA zp_ihi : CMP POOL_XEND,X : BCC ms_shrink                        ; |

    ; --- Fully covered: free this span (fall-through, no JMP) ---
.ms_free
    LDA POOL_NEXT,X : STA zp_tmp0                                       ; |
    JSR free_span                                                       ; |
    LDA zp_prev : CMP #$FF : BNE ms_unlink_span                         ; |
    LDA zp_tmp0 : STA zp_head : TAX : BNE msl : RTS                     ; |
.ms_unlink_span
    LDY zp_prev : LDA zp_tmp0 : STA POOL_NEXT,Y
    TAX : BNE msl : RTS                                                 ; |

.ms_shrink
    ; A holds ihi; carry clear from BCC
    ADC #1 : STA POOL_XSTART,X                                          ; |
    STX zp_prev : LDA POOL_NEXT,X : TAX : BEQ ms_rts_x
    ; Fall through to msl (common: continue scanning)

.msl ; X = current span — fall-through from shrink, branch target from free
.msl_x
    LDA POOL_XEND,X : CMP zp_ilo : BCS ms_chk_after                     ; ||||
    STX zp_prev : LDY POOL_NEXT,X : BEQ ms_rts_x                        ; ||
.msl_y
    LDA POOL_XEND,Y : CMP zp_ilo : BCS ms_chk_after_y                   ; ||||
    STY zp_prev : LDX POOL_NEXT,Y : BNE msl_x                           ; ||
.ms_rts_x RTS

.ms_has_left
    ; xstart < ilo. Has right fragment? xend > ihi?
    LDA zp_ihi : CMP POOL_XEND,X : BCS ms_left_only                     ; |
    ; --- Middle split: allocate sibling for the right fragment ---
    STX zp_prev                                                         ; |
    JSR alloc_span : BEQ ms_left_only_after_fail                        ; |
    LDY zp_prev   ; Y = original span (the left fragment)               ; |
    ; Copy line params from Y to X (sibling shares the same line)
    LDA POOL_XLO,Y  : STA POOL_XLO,X                                    ; |
    LDA POOL_XHI,Y  : STA POOL_XHI,X                                    ; |
    LDA POOL_TL,Y   : STA POOL_TL,X                                     ; |
    LDA POOL_BL,Y   : STA POOL_BL,X                                     ; |
    LDA POOL_TR,Y   : STA POOL_TR,X                                     ; |
    LDA POOL_BR,Y   : STA POOL_BR,X                                     ; |
    ; Sibling's active range = [ihi+1, original xend]
    ; carry already clear: BCS ms_left_only fell through (C=0) and alloc_span/STAs don't change C
    LDA zp_ihi : ADC #1 : STA POOL_XSTART,X                             ; |
    LDA POOL_XEND,Y : STA POOL_XEND,X                                   ; |
    ; Insert sibling after original
    LDA POOL_NEXT,Y : STA POOL_NEXT,X                                   ; |
    TXA : STA POOL_NEXT,Y                                               ; |
    ; Original (Y) now becomes the left fragment: xend = ilo - 1
    ; carry is clear: C=0 propagated from BCS fall-through, through alloc+copies+ADC(no overflow)
    LDA zp_ilo : SBC #0 : STA POOL_XEND,Y                               ; |
    ; Continue from the span AFTER the new sibling
    STX zp_prev : LDY POOL_NEXT,X : BNE msl_y : RTS                      ; |

.ms_left_only_after_fail
    ; alloc failed → fall through and just truncate left fragment
    LDX zp_prev
.ms_left_only
    ; xend = ilo - 1 (truncate to left fragment only)
    LDA zp_ilo : SEC : SBC #1 : STA POOL_XEND,X                         ; |
    STX zp_prev : LDY POOL_NEXT,X : BNE msl_y : RTS                     ; |

}

; ======================================================================
; HAS_GAP: fast visibility check for column range [ilo, ihi]
;
; Returns A=1 if ANY active span overlaps the query range, A=0 otherwise.
; Most-called entry point (~174 calls/frame).  The inner loop is just
; 3 compares + linked-list chase, so it's very fast per iteration.
; Profile: ~14% of all clipper cycles despite trivial per-call cost,
; due to sheer call frequency.
; ======================================================================
.span_has_gap
{
    ; Range [ilo, ihi] (closed). Return 1 if any active span overlaps the
    ; range, 0 otherwise. Spans are sorted by xstart.
    ; Coherence cache: check last-matching span first (saves full walk).
    LDX zp_hg_cache : BEQ hg_no_cache
    LDA POOL_XEND,X : CMP zp_ilo : BCC hg_no_cache    ; xend < ilo → miss
    LDA zp_ihi : CMP POOL_XSTART,X : BCC hg_no_cache  ; ihi < xstart → miss
    LDA #1 : RTS                                        ; cache hit → return 1 (avoids page-cross)
.hg_no_cache
    ; Unrolled 2× ping-pong: X and Y alternate as the current span offset.
    ; Eliminates the TAX in the skip path (−2.5 cyc per skip iteration avg).
    LDX zp_head : BEQ hgn
    ; --- X iteration: current span in X ---
.hgl_x LDA POOL_XEND,X : CMP zp_ilo : BCS hg_chk_x  ; xend >= ilo → hit
    LDY POOL_NEXT,X : BEQ hgn                         ; advance via Y
    ; --- Y iteration: current span in Y ---
.hgl_y LDA POOL_XEND,Y : CMP zp_ilo : BCS hg_chk_y  ; xend >= ilo → hit
    LDX POOL_NEXT,Y : BNE hgl_x                       ; advance via X
.hgn LDA #0 : RTS
    ; --- Hit checks (one copy per register, avoids TYX which doesn't exist) ---
.hg_chk_x LDA zp_ihi : CMP POOL_XSTART,X : BCS hg_cx_yes
    LDA #0 : RTS
.hg_chk_y LDA zp_ihi : CMP POOL_XSTART,Y : BCS hg_cy_yes
    LDA #0 : RTS
.hg_cx_yes STX zp_hg_cache : LDA #1 : RTS
.hg_cy_yes STY zp_hg_cache : LDA #1 : RTS
}

; ======================================================================
; IS_FULL: check if screen is completely occluded (active list empty)
; Returns A=1 if head==0 (all columns solid), A=0 otherwise.
; ======================================================================
.span_is_full
    LDA zp_head : BEQ sif_yes : LDA #0 : RTS
.sif_yes LDA #1 : RTS

; ======================================================================
; SPAN_READ: serialize active span list to buffer at (zp_buf)
; Output: byte 0 = count, then 8 bytes per span (xstart, xend, xlo,
; xhi, tl, bl, tr, br).  Used by test harness for state comparison.
; ======================================================================
.span_read
{
    ; Output: 1 byte count, then 8 bytes per span:
    ;   xstart, xend, xlo, xhi, tl, bl, tr, br
    LDY #1 : LDA #0 : STA zp_tmp0
    LDX zp_head : BEQ srd
.srl INC zp_tmp0
    LDA POOL_XSTART,X : STA (zp_buf),Y : INY
    LDA POOL_XEND,X   : STA (zp_buf),Y : INY
    LDA POOL_XLO,X    : STA (zp_buf),Y : INY
    LDA POOL_XHI,X    : STA (zp_buf),Y : INY
    LDA POOL_TL,X     : STA (zp_buf),Y : INY
    LDA POOL_BL,X     : STA (zp_buf),Y : INY
    LDA POOL_TR,X     : STA (zp_buf),Y : INY
    LDA POOL_BR,X     : STA (zp_buf),Y : INY
    LDA POOL_NEXT,X : TAX : BNE srl
.srd LDA zp_tmp0 : LDY #0 : STA (zp_buf),Y : RTS
}

; ======================================================================
; TIGHTEN: the core visibility-narrowing operation
;
; Given a new wall segment [ilo,ihi] x [yt1..yt2, yb1..yb2], walks the
; old active list and builds a new list with narrowed apertures.
;
; Algorithm per overlapping span:
;   1. Compute overlap [ox0, ox1] = intersection of span and seg ranges
;   2. Interpolate old top/bot at overlap endpoints (fast if anchors match)
;   3. Interpolate new seg top/bot at overlap endpoints (fast if anchors match)
;   4. Detect crossovers (columns where old and new boundaries swap)
;   5. If old dominates everywhere: keep span unchanged (common fast path)
;   6. Split at crossovers, take max(top) and min(bot) per sub-interval
;   7. Emit only sub-intervals with positive aperture (top < bot)
;   8. Preserve left/right fragments outside the seg's column range
;
; This is the most complex and cycle-expensive operation.
; ======================================================================
; Extra ZP for tighten (zp_new_tail aliases zp_save2 — tighten doesn't use mark_solid scratch)
zp_new_tail = $E7     ; offset of last span in new list (0 = no tail yet)
zp_old_cur  = $E8     ; current span in old list walk
zp_ox0      = $E9     ; overlap X range
zp_ox1      = $EA
zp_ot_l     = $EB     ; old boundary at overlap endpoints (u8)
zp_ot_r     = $EC
zp_ob_l     = $ED
zp_ob_r     = $EE
zp_nt_l     = $EF     ; new boundary at overlap endpoints (s16)
zp_nt_lh    = $F0
zp_nt_r     = $F1
zp_nt_rh    = $F2
zp_nb_l     = $F3
zp_nb_lh    = $F4
zp_nb_r     = $F5
zp_nb_rh    = $F6
zp_cx_top   = $F7     ; crossover X for top boundary (0=none)
zp_cx_bot   = $F8     ; crossover X for bot boundary (0=none)
zp_final_ox1 = $F9    ; saved ox1 for multi-interval processing
; Crossover divide working set ($FA-$FF)
zp_cc_num_lo = $FA
zp_cc_num_mid = $FB
zp_cc_num_hi = $FC
zp_cc_den_lo = $FD
zp_cc_den_hi = $FE

EQUW 0  ; 2-byte alignment pad for tighten hot loop page optimization
.span_tighten
    LDA zp_ihi : CMP zp_ilo : BCS tg_go    ; ihi >= ilo: valid range    ; |
    RTS
.tg_go
    ; Save old head, then start building new list
    LDA zp_head : STA zp_old_cur                                        ; |
    LDA #0 : STA zp_new_tail : STA zp_head                                ; |
IF EMIT_LINES
    STA LINE_OUT_COUNT
ENDIF
    LDA #$FF : STA zp_cache_ox1  ; invalidate seg value cache            ; |
    STA zp_tg_cont               ; invalidate portal continuation        ; |
    ; Initialize running seg bounds (clamped to [0,159]).
    ; seg_top_max = max(clamp(yt1), clamp(yt2))
    ; seg_bot_min = min(clamp(yb1), clamp(yb2))
    ; bb_flags: $40 = all on-screen (new-dom + narrowing valid), $00 = disabled
    ; Fast path: all hi bytes zero → no clamping needed
    LDA zp_yt1h : ORA zp_yt2h : ORA zp_yb1h : ORA zp_yb2h               ; |
    BNE tg_go_slow_bounds                                                ; |
    ; All on-screen: simple max/min of lo bytes
    LDA zp_yt1 : CMP zp_yt2 : BCS tg_go_tmax1 : LDA zp_yt2              ; |
.tg_go_tmax1 STA zp_bb_yt_max                                           ; |
    LDA zp_yb1 : CMP zp_yb2 : BCC tg_go_bmin1 : LDA zp_yb2              ; |
.tg_go_bmin1 STA zp_bb_yb_min                                           ; |
    LDA #$40 : STA zp_bb_flags   ; new-dom + narrowing valid             ; |
    JMP tg_go_bb_done                                                    ; |
.tg_go_slow_bounds
    ; At least one hi byte nonzero.
    ; Sub-path: both yt negative → seg_top_max = 0, compute bot if on-screen.
    LDA zp_yt1h : AND zp_yt2h : BPL tg_go_sentinel                      ; |
    ; Both yt hi negative → seg_top_max = 0
    LDA #0 : STA zp_bb_yt_max                                           ; |
    ; Check if bot values on-screen (both hi == 0)
    LDA zp_yb1h : ORA zp_yb2h : BNE tg_go_sentinel_bot                  ; |
    ; Bot on-screen: compute min(yb1, yb2)
    LDA zp_yb1 : CMP zp_yb2 : BCC tg_go_bmin2 : LDA zp_yb2              ; |
.tg_go_bmin2 STA zp_bb_yb_min                                           ; |
    LDA #0 : STA zp_bb_flags     ; new-dom disabled, but bounds valid    ; |
    JMP tg_go_bb_done                                                    ; |
.tg_go_sentinel_bot
    ; Bot off-screen: use 0 sentinel (old-dom bot always fails)
    LDA #0 : STA zp_bb_yb_min : STA zp_bb_flags                         ; |
    JMP tg_go_bb_done                                                    ; |
.tg_go_sentinel
    ; Mixed hi bytes: use sentinels (old-dom always fails)
    LDA #$FF : STA zp_bb_yt_max                                          ; |
    LDA #0 : STA zp_bb_yb_min : STA zp_bb_flags                         ; |
.tg_go_bb_done

.tg_walk
    LDX zp_old_cur                                                      ; |
    BNE tg_process                                                      ; |
    RTS                            ; done walking                       ; |
.tg_process
    ; Store next span offset directly in old_cur (saves reload later).
    ; zp_old_cur is not modified by any subroutine during tighten processing.
    LDA POOL_NEXT,X : STA zp_old_cur                                    ; ||

    ; Check overlap of seg [ilo,ihi] against this span's ACTIVE range.
    ; Pixel-center model: endpoint-only contact is NOT overlap.
    ; Pre-seg if xend <= ilo (reversed CMP: ilo >= xend → pre-seg)
    LDA zp_ilo : CMP POOL_XEND,X : BCC tg_chk2                           ; ilo < xend → might overlap
    ; Pre-seg: fast link (skip merge check — pre-seg spans never merge)
.tg_pre_link
    LDA #0 : STA POOL_NEXT,X                                            ; ||
    LDY zp_new_tail : BEQ tg_pre_first                                  ; |
    TXA : STA POOL_NEXT,Y                                               ; ||
    STX zp_new_tail : JMP tg_walk                                       ; |
.tg_pre_first STX zp_head : STX zp_new_tail : JMP tg_walk               ; |
.tg_chk2
    ; Post-seg if xstart >= ihi (reversed CMP: xstart >= ihi → post-seg)
    LDA POOL_XSTART,X : CMP zp_ihi : BCC tg_overlaps                    ; |||
    ; Post-seg: first span goes through tg_append_x (merge check),
    ; then bulk-link the remaining chain directly.
    ; old_cur already holds POOL_NEXT,X (set at tg_process), no re-read needed.
    JSR tg_append_x                                                     ; first post-seg (with merge)
    LDX zp_old_cur : BEQ tg_post_done                                   ; any more spans?
    LDY zp_new_tail : TXA : STA POOL_NEXT,Y                             ; bulk-link rest
.tg_post_done RTS

.tg_overlaps
    ; ox0 = max(xstart, ilo).  A already holds POOL_XSTART,X from tg_chk2's
    ; CMP (which doesn't modify A). Skip the re-read.
    CMP zp_ilo : BCS tg_ox0_set                                         ; |
    LDA zp_ilo                                                          ; |
.tg_ox0_set STA zp_ox0                                                  ; |
    ; ox1 = min(xend, ihi).  BCC alone suffices: when xend == ihi, the
    ; fall-through loads ihi which equals xend — result is the same.
    LDA POOL_XEND,X : CMP zp_ihi : BCC tg_ox1_set                        ; |
    LDA zp_ihi                                                          ; |
.tg_ox1_set STA zp_ox1                                                  ; |

    ; --- Unified tiered dominance check ---
    ; Uses running narrowed seg bounds (seg_top_max / seg_bot_min) that handle
    ; all cases (neg-yt, all-on-screen, mixed) without flag dispatch.

    ; Tier 1: old-dom BB check.
    ; tl >= seg_top_max AND tr >= seg_top_max (equiv. min(tl,tr) >= seg_top_max)
    ; seg_bot_min >= bl AND seg_bot_min >= br (equiv. seg_bot_min >= max(bl,br))
    LDA POOL_TL,X : CMP zp_bb_yt_max : BCC tg_not_old_bb                ; |
    LDA POOL_TR,X : CMP zp_bb_yt_max : BCC tg_not_old_bb                ; |
    ; Top passed. Check bot: seg_bot_min >= bl AND seg_bot_min >= br.
    LDA zp_bb_yb_min                                                     ; |
    CMP POOL_BL,X : BCC tg_not_old_bb                                   ; |
    CMP POOL_BR,X : BCC tg_not_old_bb                                   ; |
    ; Old dominates — skip all interpolation.
    ; Inline fast link (skip merge check: old-dom spans rarely merge,
    ; and the merge check costs ~40 cycles per span).
    LDA #$FF : STA zp_tg_cont   ; break continuation
    LDA #0 : STA POOL_NEXT,X                                             ; |
    LDY zp_new_tail : BEQ tg_od_first                                   ; |
    TXA : STA POOL_NEXT,Y                                               ; |
    STX zp_new_tail : JMP tg_walk                                       ; |
.tg_od_first STX zp_head : STX zp_new_tail : JMP tg_walk                ; |

.tg_not_old_bb
    ; --- Portal continuation: cheap new-dom using running bounds ---
    ; If previous span was non-old-dom AND contiguous, the seg boundary
    ; is likely still inside the aperture. Check using running bounds
    ; (cheaper than the full new-dom BB which recomputes min/max).
    ; New-dom: bb_yt_max > max(tl,tr) AND min(bl,br) > bb_yb_min (strict)
    LDA zp_tg_cont : CMP #$FF : BEQ tg_no_cont
    CMP POOL_XSTART,X : BNE tg_no_cont              ; not contiguous
    LDA zp_bb_flags : AND #$40 : BEQ tg_no_cont     ; need on-screen bounds
    ; Top: max(tl,tr) < bb_yt_max
    LDA POOL_TL,X : CMP POOL_TR,X : BCS tg_cont_it : LDA POOL_TR,X
.tg_cont_it  ; A = max(tl,tr)
    CMP zp_bb_yt_max : BCS tg_no_cont               ; max(tl,tr) >= seg_top → fail
    ; Bot: min(bl,br) > bb_yb_min (strict)
    LDA POOL_BL,X : CMP POOL_BR,X : BCC tg_cont_ib : LDA POOL_BR,X
.tg_cont_ib  ; A = min(bl,br)
    CMP zp_bb_yb_min : BCC tg_no_cont               ; min(bl,br) < seg_bot → fail
    BEQ tg_no_cont                                   ; equal → old-dom at boundary
    ; Portal continuation: new dominates. Skip old interp.
    JMP tg_newdom_fast
.tg_no_cont

    ; Tier 2: new-dom BB check (full version with overlap guard).
    ; Guard: all seg hi bytes zero (bb_flags bit 6 = $40).
    LDA zp_bb_flags : AND #$40 : BEQ tg_bb_skip                         ; |
    ; Guard: overlap covers entire span (xstart >= ilo AND xend <= ihi).
    LDA zp_ilo : CMP POOL_XSTART,X : BEQ tg_nd_lo_ok : BCS tg_bb_skip  ; |
.tg_nd_lo_ok
    LDA POOL_XEND,X : CMP zp_ihi : BEQ tg_nd_hi_ok : BCS tg_bb_skip    ; |
.tg_nd_hi_ok
    ; Check: min(yt1,yt2) > max(tl,tr) (strict: new top inside aperture)
    LDA POOL_TL,X : CMP POOL_TR,X : BCS tg_nd_tmax                      ; |
    LDA POOL_TR,X                                                        ; |
.tg_nd_tmax
    STA zp_tmp0                                                          ; |
    LDA zp_yt1 : CMP zp_yt2 : BCC tg_nd_tmin : LDA zp_yt2               ; |
.tg_nd_tmin
    CMP zp_tmp0 : BCC tg_bb_skip : BEQ tg_bb_skip                       ; |
    ; Check: min(bl,br) > max(yb1,yb2) (strict: new bot inside aperture)
    LDA zp_yb1 : CMP zp_yb2 : BCS tg_nd_bmax : LDA zp_yb2               ; |
.tg_nd_bmax
    STA zp_tmp0                                                          ; |
    LDA POOL_BL,X : CMP POOL_BR,X : BCC tg_nd_bmin : LDA POOL_BR,X      ; |
.tg_nd_bmin
    CMP zp_tmp0 : BCC tg_bb_skip : BEQ tg_bb_skip                       ; |
    ; Tier 2 success: new dominates. JMP to newdom_fast (moved after bb_skip
    ; to keep tg_bb_skip in the same page as the tier 2 branches).
    JMP tg_newdom_fast
.tg_bb_skip

    ; --- Full interpolation pipeline ---
    STX zp_save1           ; save span offset early (interp calls clobber X)  ; |
    ; ---------- OLD span: fast path when (ox0,ox1) == (xlo,xhi) ----------
    ; If the overlap endpoints exactly match the span's LINE anchors, the
    ; stored tl/bl/tr/br are already the y values at those endpoints.
    LDA zp_ox0 : CMP POOL_XLO,X : BNE old_not_anchor                     ; |
    LDA zp_ox1 : CMP POOL_XHI,X : BNE old_not_anchor                    ; |
    LDA POOL_TL,X : STA zp_ot_l                                         ; |
    LDA POOL_TR,X : STA zp_ot_r                                         ; |
    LDA POOL_BL,X : STA zp_ob_l                                         ; |
    LDA POOL_BR,X : STA zp_ob_r                                         ; |
    JMP old_done                                                        ; |
.old_not_anchor
    ; --- Constant-line fast path: tl==tr AND bl==br ---
    ; Saves 4 interp_store calls when the OLD span has no slope.
    LDA POOL_TL,X : CMP POOL_TR,X : BNE old_slow                        ; |
    STA zp_ot_l : STA zp_ot_r                                           ; |
    LDA POOL_BL,X : CMP POOL_BR,X : BNE old_slow_reload                 ; |
    STA zp_ob_l : STA zp_ob_r                                           ; |
    JMP old_done                                                        ; |
.old_slow_reload
    ; BL!=BR: need full interp. Re-read TL for zp_i_y0 (rare path).
    LDA POOL_TL,X
.old_slow
    ; A holds TL on entry (from constant-line check or old_slow_reload).
    ; Hoisted den setup: den = POOL_XHI - POOL_XLO, shared by all 4 calls.
    ; (The anchor fast path above guards 1-pixel spans, so den > 0.)
    STA zp_i_y0                                                          ; |
    LDA POOL_XLO,X : STA zp_i_x0                                        ; |
    LDA POOL_XHI,X : SEC : SBC zp_i_x0 : STA zp_div_den                 ; |
    ; Top: y0 = tl (already in zp_i_y0), y1 = tr
    LDA POOL_TR,X : STA zp_i_y1                                          ; |
    LDA zp_ox0 : JSR interp_store : STA zp_ot_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_ot_r                         ; |
    ; Bot: y0 = bl, y1 = br. Reload X (udiv16_8 in interp_store clobbers X).
    LDX zp_save1                                                        ; |
    LDA POOL_BL,X : STA zp_i_y0 : LDA POOL_BR,X : STA zp_i_y1           ; ||
    LDA zp_ox0 : JSR interp_store : STA zp_ob_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_ob_r                         ; |
    JMP old_done
.tg_newdom_fast
    ; New dominates everywhere. Set dummy old values so the no-crossover
    ; path produces the new seg's boundary values in the result span.
    LDA #0 : STA zp_ot_l : STA zp_ot_r                                  ; |
    LDA #159 : STA zp_ob_l : STA zp_ob_r                                ; |
    STX zp_save1                                                         ; |
    JMP tg_pod_skip   ; skip post-old-interp check (dummy values always fail it)
.old_done
    ; --- Post-old-interp dominance check using running seg bounds ---
    ; More precise than tier-1 BB: uses actual interpolated old values.
    LDA zp_ot_l : CMP zp_bb_yt_max : BCC tg_pod_skip                    ; |
    LDA zp_ot_r : CMP zp_bb_yt_max : BCC tg_pod_skip                    ; |
    LDA zp_bb_yb_min : CMP zp_ob_l : BCC tg_pod_skip                    ; |
    CMP zp_ob_r : BCC tg_pod_skip                                       ; |
    ; Old dominates seg's bounding box — skip new seg interp entirely.
    ; Inline fast link (same as tier 1 old-dom: skip merge check).
    LDA #$FF : STA zp_tg_cont
    LDX zp_save1                                                         ; |
    LDA #0 : STA POOL_NEXT,X                                             ; |
    LDY zp_new_tail : BEQ tg_pod_first                                  ; |
    TXA : STA POOL_NEXT,Y                                               ; |
    STX zp_new_tail : JMP tg_walk                                       ; |
.tg_pod_first STX zp_head : STX zp_new_tail : JMP tg_walk               ; |
.tg_pod_skip
    ; ---------- NEW seg: cache check for left-endpoint reuse -----------
    LDA zp_ox0 : CMP zp_cache_ox1 : BNE new_no_cache
    ; Cache hit: reuse left-endpoint seg values from previous span
    LDA zp_cache_nt : STA zp_nt_l : LDA zp_cache_nt_h : STA zp_nt_lh
    LDA zp_cache_nb : STA zp_nb_l : LDA zp_cache_nb_h : STA zp_nb_lh
    JMP new_right_only
.new_no_cache
    ; ---------- NEW seg: fast path when (ox0,ox1) == (sx1,sx2) -----------
    LDA zp_ox0 : CMP zp_sx1 : BNE new_not_anchor                        ; |
    LDA zp_ox1 : CMP zp_sx2 : BNE new_not_anchor                        ; |
    ; Copy seg's s16 anchor values verbatim
    LDA zp_yt1  : STA zp_nt_l                                           ; |
    LDA zp_yt1h : STA zp_nt_lh                                          ; |
    LDA zp_yt2  : STA zp_nt_r                                           ; |
    LDA zp_yt2h : STA zp_nt_rh                                          ; |
    LDA zp_yb1  : STA zp_nb_l                                           ; |
    LDA zp_yb1h : STA zp_nb_lh                                          ; |
    LDA zp_yb2  : STA zp_nb_r                                           ; |
    LDA zp_yb2h : STA zp_nb_rh                                          ; |
    JMP new_done                                                        ; |
.new_not_anchor
    ; --- Constant-line NEW seg fast path: yt1==yt2 AND yb1==yb2 (s16) ---
    LDA zp_yt1 : CMP zp_yt2 : BNE new_slow                              ; |
    LDA zp_yt1h : CMP zp_yt2h : BNE new_slow                            ; |
    LDA zp_yb1 : CMP zp_yb2 : BNE new_slow                              ; |
    LDA zp_yb1h : CMP zp_yb2h : BNE new_slow                            ; |
    ; Constant line: both endpoints are identical s16 values.
    LDA zp_yt1  : STA zp_nt_l  : STA zp_nt_r                            ; |
    LDA zp_yt1h : STA zp_nt_lh : STA zp_nt_rh                           ; |
    LDA zp_yb1  : STA zp_nb_l  : STA zp_nb_r                            ; |
    LDA zp_yb1h : STA zp_nb_lh : STA zp_nb_rh                           ; |
    JMP new_done                                                        ; |
.new_slow
    ; Hoisted den setup: den = sx2 - sx1. Guaranteed > 0 by remap.
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den                      ; |
    ; Top: y0 = yt1 (s16), y1 = yt2 (s16)
    LDA zp_yt1 : STA zp_i_y0 : LDA zp_yt1h : STA zp_i_y0h               ; |
    LDA zp_yt2 : STA zp_i_y1 : LDA zp_yt2h : STA zp_i_y1h               ; |
    LDA zp_ox0 : JSR seg_interp_store : STA zp_nt_l : STY zp_nt_lh      ; ||
    LDA zp_ox1 : JSR seg_interp_store : STA zp_nt_r : STY zp_nt_rh      ; ||
    ; Bot: y0 = yb1 (s16), y1 = yb2 (s16)
    LDA zp_yb1 : STA zp_i_y0 : LDA zp_yb1h : STA zp_i_y0h               ; |
    LDA zp_yb2 : STA zp_i_y1 : LDA zp_yb2h : STA zp_i_y1h               ; |
    LDA zp_ox0 : JSR seg_interp_store : STA zp_nb_l : STY zp_nb_lh      ; ||
    LDA zp_ox1 : JSR seg_interp_store : STA zp_nb_r : STY zp_nb_rh      ; ||
    JMP new_done                                                         ; |
.new_right_only
    ; Cache hit: left-endpoint seg values already set. Compute right only.
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den                      ; |
    LDA zp_yt1 : STA zp_i_y0 : LDA zp_yt1h : STA zp_i_y0h               ; |
    LDA zp_yt2 : STA zp_i_y1 : LDA zp_yt2h : STA zp_i_y1h               ; |
    LDA zp_ox1 : JSR seg_interp_store : STA zp_nt_r : STY zp_nt_rh      ; ||
    LDA zp_yb1 : STA zp_i_y0 : LDA zp_yb1h : STA zp_i_y0h               ; |
    LDA zp_yb2 : STA zp_i_y1 : LDA zp_yb2h : STA zp_i_y1h               ; |
    LDA zp_ox1 : JSR seg_interp_store : STA zp_nb_r : STY zp_nb_rh      ; ||
.new_done
    ; Cache right-endpoint seg values for reuse by next contiguous span
    LDA zp_nt_r : STA zp_cache_nt : LDA zp_nt_rh : STA zp_cache_nt_h
    LDA zp_nb_r : STA zp_cache_nb : LDA zp_nb_rh : STA zp_cache_nb_h
    LDA zp_ox1 : STA zp_cache_ox1
    ; Set portal continuation: record span's xend for contiguity check
    LDX zp_save1 : LDA POOL_XEND,X : STA zp_tg_cont
    ; --- Narrow running seg bounds using cached right-edge seg values ---
    ; Only narrow when all-on-screen (bb_flags=$40); cached must be on-screen.
    LDA zp_bb_flags : BEQ tg_nd_skip                                    ; |
    ; Narrow top: seg_top_max = max(cached_nt, yt2)
    LDA zp_cache_nt_h : BNE tg_nd_top_skip                              ; |
    LDA zp_cache_nt : CMP #160 : BCS tg_nd_top_skip                     ; |
    CMP zp_yt2 : BCS tg_nd_top_ok : LDA zp_yt2                          ; |
.tg_nd_top_ok STA zp_bb_yt_max                                          ; |
.tg_nd_top_skip
    ; Narrow bot: seg_bot_min = min(cached_nb, yb2)
    LDA zp_cache_nb_h : BNE tg_nd_skip                                  ; |
    LDA zp_cache_nb : CMP #160 : BCS tg_nd_skip                         ; |
    CMP zp_yb2 : BCC tg_nd_bot_ok : LDA zp_yb2                          ; |
.tg_nd_bot_ok STA zp_bb_yb_min                                          ; |
.tg_nd_skip

    ; --- Crossover detection BEFORE clamping (needs unclamped nt/nb values) ---
    ; Top crossover: fast path when both hi bytes are 0 (common case).
    LDA zp_nt_lh : ORA zp_nt_rh : BNE tg_cc_t_slow                      ; |
    ; Both hi bytes 0: branch-based sign comparison (saves ROL/EOR chain).
    ; If both (ot >= nt) or both (ot < nt), no crossover.
    LDA zp_ot_l : CMP zp_nt_l : BCS tg_cc_t_lpos                       ; |
    ; ot_l < nt_l (carry clear)
    LDA zp_ot_r : CMP zp_nt_r : BCS tg_cc_t_check_dt                    ; signs differ → cx
    JMP tg_cc_no_top                                                    ; both < → no cx
.tg_cc_t_lpos
    ; ot_l >= nt_l (carry set)
    LDA zp_ot_r : CMP zp_nt_r : BCC tg_cc_t_check_dt                   ; signs differ → cx
    JMP tg_cc_no_top                                                    ; both >= → no cx
.tg_cc_t_slow
    ; If both nt hi bytes are negative, new top < 0 everywhere.
    ; Since old top >= 0, dt = ot - nt > 0 always → no top crossover.
    LDA zp_nt_lh : AND zp_nt_rh : BPL tg_cc_t_slowentry
    JMP tg_cc_no_top
.tg_cc_t_slowentry
    ; Slow path: per-byte sign detection (handles hi < 0 and hi > 0)
    LDA zp_nt_lh : BMI tg_cc_t0p : BNE tg_cc_t0n                        ; |
    LDA zp_ot_l : CMP zp_nt_l                                           ; |
    LDA #0 : ROL A : BCC tg_cc_t0d                                      ; |
.tg_cc_t0p LDA #1 : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cc_t0n LDA #0                   ; overflow new → negative sign
.tg_cc_t0d STA zp_tmp1                                                  ; |
    LDA zp_nt_rh : BMI tg_cc_t1p : BNE tg_cc_t1n                        ; |
    LDA zp_ot_r : CMP zp_nt_r                                           ; |
    LDA #0 : ROL A : BCC tg_cc_t1d                                      ; |
.tg_cc_t1p LDA #1 : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cc_t1n LDA #0
.tg_cc_t1d EOR zp_tmp1                                                  ; |
    BEQ tg_cc_no_top                                                    ; |
.tg_cc_t_check_dt
    ; Check dt != 0 at each endpoint (avoid calling compute_crossover for
    ; degenerate touch-at-edge cases). The previous `ORA hi,lo : CMP ot`
    ; shortcut was buggy — it gave false positives when `hi | lo` ≡ ot
    ; in u8 (e.g. hi=1, lo=0x9E, OR=0x9F=159). Correct form: if hi ≠ 0
    ; the s16 value can't equal a u8 ot; else compare low bytes.
    LDA zp_nt_lh : BNE tg_cc_t_ne_l
    LDA zp_nt_l : CMP zp_ot_l : BEQ tg_cc_no_top
.tg_cc_t_ne_l
    LDA zp_nt_rh : BNE tg_cc_t_ne_r
    LDA zp_nt_r : CMP zp_ot_r : BEQ tg_cc_no_top
.tg_cc_t_ne_r
    ; Inlined tg_cc_calc_top: compute |d0|, |d1| as u16, then JSR
    ; compute_crossover. (Formerly a standalone function with tail-call
    ; JMP compute_crossover; inlined for -3 bytes since it had 1 caller.)
    LDA zp_ot_l : SEC : SBC zp_nt_l : STA zp_tmp0
    LDA #0      : SBC zp_nt_lh      : STA zp_tmp1
    BPL ict0p
    SEC : LDA #0 : SBC zp_tmp0 : STA zp_tmp0
    LDA #0       : SBC zp_tmp1 : STA zp_tmp1
.ict0p
    LDA zp_ot_r : SEC : SBC zp_nt_r : STA zp_tmp2
    LDA #0      : SBC zp_nt_rh      : STA zp_tmp3
    BPL ict1p
    SEC : LDA #0 : SBC zp_tmp2 : STA zp_tmp2
    LDA #0       : SBC zp_tmp3 : STA zp_tmp3
.ict1p
    JSR compute_crossover                                                ; A = cx column
    EQUB $2C                                                             ; BIT abs: skip LDA #0
.tg_cc_no_top
    LDA #0                                                               ; |
    STA zp_cx_top                                                        ; shared store
.tg_cc_chk_bot
    ; Bot crossover: fast path when both hi bytes are 0 (common case).
    LDA zp_nb_lh : ORA zp_nb_rh : BNE tg_cc_b_slow                      ; |
    ; Branch-based sign comparison for bot (same as top fast path).
    LDA zp_ob_l : CMP zp_nb_l : BCS tg_cc_b_lpos                       ; |
    ; ob_l < nb_l
    LDA zp_ob_r : CMP zp_nb_r : BCC tg_cc_no_bot                       ; both < → no cx
    BCS tg_cc_b_check_dt                                                ; signs differ → cx
.tg_cc_b_lpos
    ; ob_l >= nb_l
    LDA zp_ob_r : CMP zp_nb_r : BCS tg_cc_no_bot                       ; both >= → no cx
    BCC tg_cc_b_check_dt                                                ; signs differ → cx
.tg_cc_b_slow
    LDA zp_nb_lh : BMI tg_cc_b0p : BNE tg_cc_b0n                        ; |
    LDA zp_ob_l : CMP zp_nb_l                                           ; |
    LDA #0 : ROL A : BCC tg_cc_b0d                                      ; |
.tg_cc_b0p LDA #1 : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cc_b0n LDA #0
.tg_cc_b0d STA zp_tmp1                                                  ; |
    LDA zp_nb_rh : BMI tg_cc_b1p : BNE tg_cc_b1n                        ; |
    LDA zp_ob_r : CMP zp_nb_r                                           ; |
    LDA #0 : ROL A : BCC tg_cc_b1d                                      ; |
.tg_cc_b1p LDA #1 : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cc_b1n LDA #0
.tg_cc_b1d EOR zp_tmp1                                                  ; |
    BEQ tg_cc_no_bot                                                    ; |
.tg_cc_b_check_dt
    ; Same dt != 0 pre-check as top (see tg_cc_t_ne_l comment).
    LDA zp_nb_lh : BNE tg_cc_b_ne_l                                     ; |
    LDA zp_nb_l : CMP zp_ob_l : BEQ tg_cc_no_bot                        ; |
.tg_cc_b_ne_l
    LDA zp_nb_rh : BNE tg_cc_b_ne_r                                     ; |
    LDA zp_nb_r : CMP zp_ob_r : BEQ tg_cc_no_bot                        ; |
.tg_cc_b_ne_r
    JSR tg_cc_calc_bot                                                   ; A = cx column
    EQUB $2C                                                             ; BIT abs: skip LDA #0
.tg_cc_no_bot
    LDA #0                                                               ; |
    STA zp_cx_bot                                                        ; shared store
.tg_cc_done

    ; --- Clamp new s16 values to [0,159] u8 for dominance check ---
    ; Fast path: if all 4 hi bytes are 0 and all lo bytes < 160, no clamp needed.
    LDA zp_nt_lh : ORA zp_nt_rh : ORA zp_nb_lh : ORA zp_nb_rh           ; |
    BNE tg_clamp_slow                                                    ; |
    LDA zp_nt_l : CMP #160 : BCS tg_clamp_slow                          ; |
    LDA zp_nt_r : CMP #160 : BCS tg_clamp_slow                          ; |
    LDA zp_nb_l : CMP #160 : BCS tg_clamp_slow                          ; |
    LDA zp_nb_r : CMP #160 : BCS tg_clamp_slow                          ; |
    BCC tg_clamp_done                                                    ; | C=0 from BCS not taken
; (2-byte clamp pad removed)
.tg_clamp_slow
    ; Fast path: if both top hi bytes are negative, clamp tops to 0 and skip
    ; to clamping only the bot values.
    LDA zp_nt_lh : AND zp_nt_rh : BPL tg_clamp_full
    LDA #0 : STA zp_nt_l : STA zp_nt_r
    JMP tg_clamp_nb
.tg_clamp_full
    ; High byte: negative→0, positive overflow (hi>0)→159, 0→check low
    ; byte (in [0,255], clamp [160,255] to 159).
    LDA zp_nt_lh : BMI tg_cn1z : BNE tg_cn1f                            ; |
    LDA zp_nt_l : CMP #160 : BCC tg_cn1s                                ; |
.tg_cn1f LDA #159 : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cn1z LDA #0
.tg_cn1s STA zp_nt_l                                                    ; |
    LDA zp_nt_rh : BMI tg_cn2z : BNE tg_cn2f                            ; |
    LDA zp_nt_r : CMP #160 : BCC tg_cn2s                                ; |
.tg_cn2f LDA #159 : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cn2z LDA #0
.tg_cn2s STA zp_nt_r                                                    ; |
.tg_clamp_nb
    LDA zp_nb_lh : BMI tg_cn3z : BNE tg_cn3f                            ; |
    LDA zp_nb_l : CMP #160 : BCC tg_cn3s                                ; |
.tg_cn3f LDA #159 : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cn3z LDA #0
.tg_cn3s STA zp_nb_l                                                    ; |
    LDA zp_nb_rh : BMI tg_cn4z : BNE tg_cn4f                            ; |
    LDA zp_nb_r : CMP #160 : BCC tg_cn4s                                ; |
.tg_cn4f LDA #159 : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cn4z LDA #0
.tg_cn4s STA zp_nb_r                                                    ; |
.tg_clamp_done
    ; Unsigned dominance: new_tl <= old_tl AND new_tr <= old_tr AND ...
    ; Reversed CMP: swap operands so BCC alone catches the failure case.
    LDA zp_ot_l : CMP zp_nt_l : BCC tg_not_old_dom                       ; |
    LDA zp_ot_r : CMP zp_nt_r : BCC tg_not_old_dom                       ; |
    LDA zp_nb_l : CMP zp_ob_l : BCC tg_not_old_dom                       ; |
    LDA zp_nb_r : CMP zp_ob_r : BCC tg_not_old_dom                       ; |
    ; Old dominates: keep span unchanged
    LDA #$FF : STA zp_tg_cont
    LDX zp_save1                                                        ; |
    JSR tg_append_x                                                     ; |
    JMP tg_walk                                                         ; |

.tg_not_old_dom
    ; --- Left fragment: if xstart < ilo (active range extends left of seg) ---
    ; Allocate sibling, copy line params verbatim, set its active range to
    ; [original xstart, ilo-1]. NO interp_store calls — line is preserved.
    ; Load old span into Y (preserved across alloc_span, saves a reload).
    LDY zp_save1                                                        ; |
    LDA POOL_XSTART,Y : CMP zp_ilo : BCS tg_no_left                     ; |
    JSR alloc_span : BEQ tg_no_left                                     ; |
    LDA POOL_XLO,Y    : STA POOL_XLO,X                                  ; |
    LDA POOL_XHI,Y    : STA POOL_XHI,X                                  ; |
    LDA POOL_TL,Y     : STA POOL_TL,X                                   ; |
    LDA POOL_BL,Y     : STA POOL_BL,X                                   ; |
    LDA POOL_TR,Y     : STA POOL_TR,X                                   ; |
    LDA POOL_BR,Y     : STA POOL_BR,X                                   ; |
    LDA POOL_XSTART,Y : STA POOL_XSTART,X                               ; |
    ; Abutting model: left fragment includes ilo (shared boundary)
    LDA zp_ilo : STA POOL_XEND,X                                        ; |
    JSR tg_append_x                                                     ; |
.tg_no_left

    ; --- Process overlap with crossover splits ---
    LDA zp_cx_top : ORA zp_cx_bot : BEQ ncf_no_splits                   ; |
    JMP tg_has_splits
.ncf_no_splits
    ; --- No crossover fast path ---
    ; The dominance check already computed ot_l/ot_r/ob_l/ob_r (u8 via
    ; interp_store) and nt_l/nt_r/nb_l/nb_r (clamped u8) at (ox0, ox1).
    ;
IF EMIT_LINES
    ; --- Emit portal edges BEFORE max/min overwrites ot/ob ---
    ; Guard: skip emission for 1-column overlaps (degenerate point, not a line)
    LDA zp_ox0 : CMP zp_ox1 : BCS ncf_no_bot_edge                       ; ox0 >= ox1 → skip all emission
    ; Top edge visible where nt > ot (new ceiling more restrictive).
    ; No crossover → check left endpoint only (same sign at both).
    LDA zp_nt_l : CMP zp_ot_l : BCC ncf_no_top_edge : BEQ ncf_no_top_edge
    JSR emit_top_edge
.ncf_no_top_edge
    ; Bot edge visible where nb < ob (new floor more restrictive).
    LDA zp_nb_l : CMP zp_ob_l : BCS ncf_no_bot_edge
    JSR emit_bot_edge
.ncf_no_bot_edge
ENDIF
    ; Do max/min + aperture + store inline without re-interpolating.
    LDA zp_ot_l : CMP zp_nt_l : BCS ncf_tl_ok : LDA zp_nt_l             ; |
.ncf_tl_ok STA zp_ot_l                                                  ; |
    LDA zp_ot_r : CMP zp_nt_r : BCS ncf_tr_ok : LDA zp_nt_r             ; |
.ncf_tr_ok STA zp_ot_r                                                  ; |
    LDA zp_ob_l : CMP zp_nb_l : BCC ncf_bl_ok : LDA zp_nb_l             ; |
.ncf_bl_ok STA zp_ob_l                                                  ; |
    LDA zp_ob_r : CMP zp_nb_r : BCC ncf_br_ok : LDA zp_nb_r             ; |
.ncf_br_ok STA zp_ob_r                                                  ; |
    ; Aperture check (ox0 < ox1 guaranteed by strict overlap test)
    LDA zp_ot_l : CMP zp_ob_l : BCC ncf_has_ap                          ; |
    LDA zp_ot_r : CMP zp_ob_r : BCS ncf_no_ap
.ncf_has_ap
    JSR alloc_span : BEQ ncf_no_ap                                      ; |
    ; Dense-anchored result span (line == active range)
    LDA zp_ox0 : STA POOL_XLO,X : STA POOL_XSTART,X                     ; |
    LDA zp_ox1 : STA POOL_XHI,X : STA POOL_XEND,X                       ; |
    LDA zp_ot_l : STA POOL_TL,X : LDA zp_ob_l : STA POOL_BL,X           ; |
    LDA zp_ot_r : STA POOL_TR,X : LDA zp_ob_r : STA POOL_BR,X           ; |
    JSR tg_append_x                                                     ; |
.ncf_no_ap
    JMP tg_right_frag                                                   ; |
.tg_has_splits
    LDA zp_ox1 : STA zp_final_ox1                                       ; ||
    LDA zp_cx_top : BEQ tg_split_bot                                    ; |
    LDA zp_cx_bot : BEQ tg_split_top
    ; Both crossovers. Sort: ensure cx_top <= cx_bot.
    LDA zp_cx_top : CMP zp_cx_bot : BCC tg_2sorted : BEQ tg_split_top
    LDY zp_cx_bot : STA zp_cx_bot : STY zp_cx_top
.tg_2sorted
    ; 3 closed intervals: [ox0, cx_top-1], [cx_top, cx_bot-1], [cx_bot, final_ox1]
    LDA zp_cx_top : SEC : SBC #1 : STA zp_ox1
    JSR tg_overlap_sub
    LDA zp_cx_top : STA zp_ox0
    LDA zp_cx_bot : SEC : SBC #1 : STA zp_ox1
    JSR tg_overlap_sub
    LDA zp_cx_bot : STA zp_ox0
    LDA zp_final_ox1 : STA zp_ox1
    JSR tg_overlap_sub : JMP tg_right_frag
.tg_split_top
    LDA zp_cx_top : JMP tg_split_one
.tg_split_bot
    LDA zp_cx_bot                                                       ; |
.tg_split_one
    ; A = single crossover X. 2 closed intervals: [ox0, cx-1], [cx, final_ox1]
    STA zp_tmp3                    ; save cx (tmp3 free between tg_overlap_sub calls)  ; |
    SEC : SBC #1 : STA zp_ox1                                           ; |
    JSR tg_overlap_sub                                                  ; |
    LDA zp_tmp3 : STA zp_ox0                                            ; |
    LDA zp_final_ox1 : STA zp_ox1                                       ; |
    JSR tg_overlap_sub                                                  ; |

.tg_right_frag
    ; --- Right fragment: if xend > ihi (active range extends right of seg) ---
    ; Allocate sibling, copy line params verbatim, set its active range to
    ; [ihi+1, original xend]. NO interp_store calls.
    ; Load old span into Y (preserved across alloc_span, saves a reload).
    LDY zp_save1                                                        ; |
    LDA zp_ihi : CMP POOL_XEND,Y : BCS tg_no_right                       ; |
.tg_make_right
    JSR alloc_span : BEQ tg_no_right                                    ; |
    LDA POOL_XLO,Y  : STA POOL_XLO,X                                    ; |
    LDA POOL_XHI,Y  : STA POOL_XHI,X                                    ; |
    LDA POOL_TL,Y   : STA POOL_TL,X                                     ; |
    LDA POOL_BL,Y   : STA POOL_BL,X                                     ; |
    LDA POOL_TR,Y   : STA POOL_TR,X                                     ; |
    LDA POOL_BR,Y   : STA POOL_BR,X                                     ; |
    ; Abutting model: right fragment includes ihi (shared boundary)
    LDA zp_ihi : STA POOL_XSTART,X                                      ; |
    LDA POOL_XEND,Y : STA POOL_XEND,X                                   ; |
    JSR tg_append_x                                                     ; |
.tg_no_right
    LDX zp_save1 : JSR free_span                                        ; |
    JMP tg_walk                                                         ; |

; --- TG_APPEND_X: append span X to the new list, with merge optimization ---
;
; Tries to merge X into the tail when both are constant-line spans
; (tl==tr, bl==br) with matching Y values and contiguous X ranges.
; This prevents span-count explosion from crossover splits; ~96% of
; merge candidates are constant-line, so the 6-compare fast path
; resolves quickly.
.tg_append_x
{
    LDA zp_new_tail : BNE ta_try_merge                                  ; ||
    ; First span: set head. POOL_NEXT,X = 0 (end of list).
    ; A is already 0 from the LDA above (BNE not taken ↔ A=0).
    STA POOL_NEXT,X                                                     ; |
    STX zp_head : STX zp_new_tail : RTS                                 ; |
.ta_try_merge
    LDY zp_new_tail                                                     ; |
    ; Fail fast: tail Y must be a constant-line span (tl==tr AND bl==br).
    LDA POOL_TL,Y : CMP POOL_TR,Y : BNE ta_link                         ; |||
    LDA POOL_BL,Y : CMP POOL_BR,Y : BNE ta_link                         ; ||
    ; New X must also be a constant-line span.
    LDA POOL_TL,X : CMP POOL_TR,X : BNE ta_link                         ; ||
    LDA POOL_BL,X : CMP POOL_BR,X : BNE ta_link                         ; |
    ; Matching constants?
    LDA POOL_TL,Y : CMP POOL_TL,X : BNE ta_link                         ; |
    LDA POOL_BL,Y : CMP POOL_BL,X : BNE ta_link                         ; |
    ; Contiguous active ranges? (abutting: tail.xend == new.xstart)
    LDA POOL_XEND,Y : CMP POOL_XSTART,X : BNE ta_link                    ; |
    ; Merge: extend tail's xend to cover new, then free X.
    LDA POOL_XEND,X : STA POOL_XEND,Y
    JMP free_span   ; frees X (via tail-call), returns
.ta_link
    ; X becomes new tail — write POOL_NEXT,X = 0 (deferred from entry).
    LDA #0 : STA POOL_NEXT,X                                            ; ||
    TXA : STA POOL_NEXT,Y                                               ; ||
    STX zp_new_tail : RTS                                               ; |||
}

; ======================================================================
; TG_OVERLAP_SUB: process one sub-interval of the tighten overlap
;
; Called 1-3 times per overlapping span (once per crossover sub-interval).
; Interpolates 4 old + 4 new boundary values, clamps new to [0,159],
; checks old-dominance shortcut, then does max/min + aperture check.
; ======================================================================
.tg_overlap_sub
{
    ; --- Old span: constant-line fast path or 4 interp_store calls ---
    LDX zp_save1                                                        ; |
    LDA POOL_TL,X : CMP POOL_TR,X : BNE tos_old_slow                    ; |
    STA zp_ot_l : STA zp_ot_r                                           ; |
    LDA POOL_BL,X : CMP POOL_BR,X : BNE tos_old_slow_reload             ; |
    STA zp_ob_l : STA zp_ob_r                                           ; |
    JMP tos_old_done                                                    ; |
.tos_old_slow_reload
    ; BL!=BR but TL==TR: re-read TL for old_slow (rare path)
    LDA POOL_TL,X
.tos_old_slow
    ; A holds TL on entry from constant-line check
    STA zp_i_y0                                                          ; |
    LDA POOL_XLO,X : STA zp_i_x0                                        ; |
    LDA POOL_XHI,X : SEC : SBC zp_i_x0 : STA zp_div_den                 ; |
    LDA POOL_TR,X : STA zp_i_y1                                          ; |
    LDA zp_ox0 : JSR interp_store : STA zp_ot_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_ot_r                         ; |
    LDX zp_save1                                                        ; |
    LDA POOL_BL,X : STA zp_i_y0 : LDA POOL_BR,X : STA zp_i_y1           ; |
    LDA zp_ox0 : JSR interp_store : STA zp_ob_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_ob_r                         ; |
.tos_old_done
    ; --- New seg: constant-line fast path or 4 seg_interp_store calls ---
    LDA zp_yt1 : CMP zp_yt2 : BNE tos_new_slow                          ; |
    LDA zp_yt1h : CMP zp_yt2h : BNE tos_new_slow                        ; |
    LDA zp_yb1 : CMP zp_yb2 : BNE tos_new_slow                          ; |
    LDA zp_yb1h : CMP zp_yb2h : BNE tos_new_slow                        ; |
    LDA zp_yt1  : STA zp_nt_l  : STA zp_nt_r                            ; |
    LDA zp_yt1h : STA zp_nt_lh : STA zp_nt_rh                           ; |
    LDA zp_yb1  : STA zp_nb_l  : STA zp_nb_r                            ; |
    LDA zp_yb1h : STA zp_nb_lh : STA zp_nb_rh                           ; |
    JMP tos_new_done                                                    ; |
.tos_new_slow
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den                      ; |
    LDA zp_yt1 : STA zp_i_y0 : LDA zp_yt1h : STA zp_i_y0h               ; |
    LDA zp_yt2 : STA zp_i_y1 : LDA zp_yt2h : STA zp_i_y1h               ; |
    LDA zp_ox0 : JSR seg_interp_store : STA zp_nt_l : STY zp_nt_lh      ; |
    LDA zp_ox1 : JSR seg_interp_store : STA zp_nt_r : STY zp_nt_rh      ; |
    LDA zp_yb1 : STA zp_i_y0 : LDA zp_yb1h : STA zp_i_y0h               ; |
    LDA zp_yb2 : STA zp_i_y1 : LDA zp_yb2h : STA zp_i_y1h               ; |
    LDA zp_ox0 : JSR seg_interp_store : STA zp_nb_l : STY zp_nb_lh      ; |
    LDA zp_ox1 : JSR seg_interp_store : STA zp_nb_r : STY zp_nb_rh      ; |
.tos_new_done
    ; Clamp s16 new values to [0,159] for unsigned max/min.
    ; Fast path: if all hi bytes are 0 and all lo bytes < 160, skip.
    LDA zp_nt_lh : ORA zp_nt_rh : ORA zp_nb_lh : ORA zp_nb_rh           ; |
    BNE tos_clamp_slow                                                   ; |
    LDA zp_nt_l : CMP #160 : BCS tos_clamp_slow                         ; |
    LDA zp_nt_r : CMP #160 : BCS tos_clamp_slow                         ; |
    LDA zp_nb_l : CMP #160 : BCS tos_clamp_slow                         ; |
    LDA zp_nb_r : CMP #160 : BCS tos_clamp_slow                         ; |
    BCC tos_clamp_done                                                    ; | C=0 from BCS not taken
; (1-byte tos_clamp pad removed)
.tos_clamp_slow
    LDA zp_nt_lh : BMI cn1z : BNE cn1f                                  ; |
    LDA zp_nt_l : CMP #160 : BCC cn1s                                   ; |
.cn1f LDA #159 : EQUB $2C  ; BIT abs: skip LDA #0
.cn1z LDA #0
.cn1s STA zp_nt_l                                                       ; |
    LDA zp_nt_rh : BMI cn2z : BNE cn2f                                  ; |
    LDA zp_nt_r : CMP #160 : BCC cn2s                                   ; |
.cn2f LDA #159 : EQUB $2C  ; BIT abs: skip LDA #0
.cn2z LDA #0
.cn2s STA zp_nt_r                                                       ; |
    LDA zp_nb_lh : BMI cn3z : BNE cn3f                                  ; |
    LDA zp_nb_l : CMP #160 : BCC cn3s                                   ; |
.cn3f LDA #159 : EQUB $2C  ; BIT abs: skip LDA #0
.cn3z LDA #0
.cn3s STA zp_nb_l                                                       ; |
    LDA zp_nb_rh : BMI cn4z : BNE cn4f                                  ; |
    LDA zp_nb_r : CMP #160 : BCC cn4s                                   ; |
.cn4f LDA #159 : EQUB $2C  ; BIT abs: skip LDA #0
.cn4z LDA #0
.cn4s STA zp_nb_r                                                       ; |
.tos_clamp_done
    ; Opt 2: if OLD wins top and bot at BOTH sub-interval endpoints, we can
    ; preserve the old span's line verbatim and just set xstart/xend. This
    ; typically fires on one side of a crossover-split sub-interval where
    ; the old span dominates the new seg.
    LDA zp_ot_l : CMP zp_nt_l : BCC skip_opt2   ; ot_l < nt_l → new wins top-l  ; |
    LDA zp_ot_r : CMP zp_nt_r : BCC skip_opt2                           ; |
    LDA zp_nb_l : CMP zp_ob_l : BCC skip_opt2   ; nb_l < ob_l → new wins bot-l  ; |
    LDA zp_nb_r : CMP zp_ob_r : BCC skip_opt2                           ; |
    ; Old wins all four comparisons → copy line verbatim
    JSR alloc_span : BEQ opt2_no_ap                                     ; |
    LDY zp_save1                                                        ; |
    LDA POOL_XLO,Y    : STA POOL_XLO,X                                  ; |
    LDA POOL_XHI,Y    : STA POOL_XHI,X                                  ; |
    LDA POOL_TL,Y     : STA POOL_TL,X                                   ; |
    LDA POOL_BL,Y     : STA POOL_BL,X                                   ; |
    LDA POOL_TR,Y     : STA POOL_TR,X                                   ; |
    LDA POOL_BR,Y     : STA POOL_BR,X                                   ; |
    LDA zp_ox0 : STA POOL_XSTART,X                                      ; |
    LDA zp_ox1 : STA POOL_XEND,X                                        ; |
    JMP tg_append_x                                                     ; | tail-call (saves 3 cyc)
.opt2_no_ap
    RTS                                                                 ; |
.skip_opt2
IF EMIT_LINES
    ; --- Emit portal edges BEFORE max/min overwrites ot/ob ---
    ; Guard: skip emission for degenerate 1-column sub-intervals (ox0 >= ox1)
    LDA zp_ox0 : CMP zp_ox1 : BCS tos_no_bot_edge
    ; Top edge visible where nt > ot (new ceiling more restrictive).
    ; Within a crossover sub-interval, sign is consistent at both endpoints.
    LDA zp_nt_l : CMP zp_ot_l : BCC tos_no_top_edge : BEQ tos_no_top_edge
    JSR emit_top_edge
.tos_no_top_edge
    ; Bot edge visible where nb < ob (new floor more restrictive).
    LDA zp_nb_l : CMP zp_ob_l : BCS tos_no_bot_edge
    JSR emit_bot_edge
ENDIF
.tos_no_bot_edge
    ; max top, min bot
    LDA zp_ot_l : CMP zp_nt_l : BCS tl_ok : LDA zp_nt_l                 ; |
.tl_ok STA zp_ot_l                                                      ; |
    LDA zp_ot_r : CMP zp_nt_r : BCS tr_ok : LDA zp_nt_r                 ; |
.tr_ok STA zp_ot_r                                                      ; |
    LDA zp_ob_l : CMP zp_nb_l : BCC bl_ok : LDA zp_nb_l                 ; |
.bl_ok STA zp_ob_l                                                      ; |
    LDA zp_ob_r : CMP zp_nb_r : BCC br_ok : LDA zp_nb_r                 ; |
.br_ok STA zp_ob_r                                                      ; |
    ; Check aperture
    LDA zp_ot_l : CMP zp_ob_l : BCC has_ap                              ; |
    LDA zp_ot_r : CMP zp_ob_r : BCS no_ap
.has_ap
    JSR alloc_span : BEQ no_ap                                          ; |
    ; Result span is dense-anchored: line endpoints == active range endpoints
    LDA zp_ox0 : STA POOL_XLO,X : STA POOL_XSTART,X                     ; |
    LDA zp_ox1 : STA POOL_XHI,X : STA POOL_XEND,X                       ; |
    LDA zp_ot_l : STA POOL_TL,X : LDA zp_ob_l : STA POOL_BL,X           ; |
    LDA zp_ot_r : STA POOL_TR,X : LDA zp_ob_r : STA POOL_BR,X           ; |
    JMP tg_append_x                                                     ; | tail-call (saves 3 cyc)
.no_ap
    RTS                                                                 ; |
}

; ======================================================================
; CROSSOVER COMPUTATION SECTION
;
; tg_cc_calc_bot computes |d0|, |d1| as u16 absolute differences of
; (old_bot - new_bot) at each overlap endpoint, then falls through
; to compute_crossover.
;
; compute_crossover finds the column X where the boundary difference
; crosses zero using: cx = ox0 + |d0| * ex / (|d0| + |d1|)
;
; FAST PATH (den fits u8): 8-iter u16/u8 restoring divide (~200 cyc).
; SLOW PATH (den > 255, rare): 8-iter u24/u16 restoring divide.
; Returns 0 if crossover is at edge or outside interval.
; ======================================================================
.tg_cc_calc_bot
{
    LDA zp_ob_l : SEC : SBC zp_nb_l : STA zp_tmp0                       ; |
    LDA #0      : SBC zp_nb_lh      : STA zp_tmp1                       ; |
    BPL db0p                                                            ; |
    SEC : LDA #0 : SBC zp_tmp0 : STA zp_tmp0                            ; |
    LDA #0       : SBC zp_tmp1 : STA zp_tmp1                            ; |
.db0p
    LDA zp_ob_r : SEC : SBC zp_nb_r : STA zp_tmp2                       ; |
    LDA #0      : SBC zp_nb_rh      : STA zp_tmp3                       ; |
    BPL db1p                                                            ; |
    SEC : LDA #0 : SBC zp_tmp2 : STA zp_tmp2
    LDA #0       : SBC zp_tmp3 : STA zp_tmp3
.db1p
    ; Fall through to compute_crossover
}

.compute_crossover
{
    ; den = |d0| + |d1| (u16; sufficient since post-wrapper |d| ≤ ~32800)
    LDA zp_tmp0 : CLC : ADC zp_tmp2 : STA zp_cc_den_lo                  ; |
    LDA zp_tmp1 :       ADC zp_tmp3 : STA zp_cc_den_hi                  ; |
    ORA zp_cc_den_lo : BEQ early_none                                   ; |
    ; ex = ox1 - ox0 (always ≥ 1 since ox0 < ox1 in tighten)
    LDA zp_ox1 : SEC : SBC zp_ox0 : BNE ex_ok                           ; |
.early_none
    LDA #0 : RTS
.ex_ok
    STA zp_mul_b                                                        ; |
    ; Low u16 of num = |d0|_lo * ex (one umul8 call).
    ; zp_prod_lo:hi aliases zp_div_lo:hi.
    LDA zp_tmp0 : JSR umul8                                             ; |
    ; Fast path: if den fits u8 (cc_den_hi == 0), then |d0|+|d1| ≤ 255
    ; so both |d0| and |d1| fit u8 → num fits u16. Quot fits u8
    ; (bounded by ex), so num_hi < den, letting us run the 8-iter
    ; restoring divide directly.
    LDA zp_cc_den_hi : BNE slow_setup                                   ; |
    LDA zp_cc_den_lo : STA zp_div_den                                   ; |
    ; Setup: rem(A) = num_hi, div_hi = num_lo, div_lo = 0 (quot accum).
    LDA zp_div_hi                ; A = rem = num_hi                      ; |
    LDX zp_div_lo : STX zp_div_hi  ; div_hi = num_lo (shift source)     ; |
    LDX #0 : STX zp_div_lo         ; div_lo = 0 (quotient accumulator)  ; |
    LDX #8                                                              ; |
.fast_loop
    ASL zp_div_lo : ROL zp_div_hi : ROL A                               ; |
    BCS fast_over                                                       ; |
    CMP zp_div_den : BCC fast_next                                      ; |
    SBC zp_div_den                                                      ; |
.fast_commit
    INC zp_div_lo                                                       ; |
.fast_next
    DEX : BNE fast_loop                                                 ; |
    LDA zp_div_lo                ; A = quot                             ; |
    JMP cx_from_quot                                                    ; |
.fast_over
    SBC zp_div_den          ; carry already set from BCS fast_over
    JMP fast_commit
; (1-byte cx fast pad removed)

.slow_setup
    ; Slow path: build the u24 num and run the u24/u16 restoring divide.
    ; The first umul8 result gets copied to cc_num_lo:mid (needed because
    ; the second umul8 below clobbers zp_prod_*).
    LDA zp_prod_lo : STA zp_cc_num_lo
    LDA zp_prod_hi : STA zp_cc_num_mid
    LDA #0 : STA zp_cc_num_hi
    LDA zp_tmp1 : BEQ num_done    ; |d0|_hi == 0 → num is already u16
    ; Add |d0|_hi * ex, shifted up one byte into mid:hi.
    JSR umul8
    LDA zp_prod_lo : CLC : ADC zp_cc_num_mid : STA zp_cc_num_mid
    LDA zp_prod_hi : ADC zp_cc_num_hi : STA zp_cc_num_hi
.num_done
    ; 8-iter restoring u24/u16 divide. Uses the same INC-the-shift-source
    ; trick: quot bits accumulate in cc_num_lo as the original bits get
    ; ASL'd out, so cc_num_lo == quot after 8 iterations.
    LDY #8
.slow_loop
    ASL zp_cc_num_lo
    ROL zp_cc_num_mid
    ROL zp_cc_num_hi
    BCS slow_force_commit        ; rem overflowed u16 → must subtract
    ; Compare rem (num_hi:num_mid) with den (cc_den_hi:cc_den_lo).
    LDA zp_cc_num_hi : CMP zp_cc_den_hi : BCC slow_skip
    BNE slow_do_commit
    LDA zp_cc_num_mid : CMP zp_cc_den_lo : BCC slow_skip
.slow_do_commit
.slow_force_commit
    LDA zp_cc_num_mid : SEC : SBC zp_cc_den_lo : STA zp_cc_num_mid
    LDA zp_cc_num_hi :       SBC zp_cc_den_hi : STA zp_cc_num_hi
    INC zp_cc_num_lo             ; set current quot bit (bit 0 after ASL)
.slow_skip
    DEY : BNE slow_loop
    LDA zp_cc_num_lo             ; A = quot

.cx_from_quot
    CLC : ADC zp_ox0                                                    ; |
    BEQ none                                                            ; |
    CMP zp_ox0 : BEQ none        ; cx at left edge: not strictly inside ; |
    CMP zp_ox1 : BCS none        ; cx >= ox1: not strictly inside       ; |
    RTS                                                                 ; |
.none LDA #0 : RTS
}

; ======================================================================
; MS_EMIT_LINES: wall edge line emission for mark_solid
;
; Pre-pass over span list (read-only). For each span overlapping [ilo,ihi],
; evaluates the seg's top/bot lines and the span's top/bot boundaries at the
; overlap endpoints. Emits the seg line segment where it falls within the
; span's aperture.
;
; Uses same ZP seg params as tighten (sx1/sx2/yt1/yt2/yb1/yb2).
; Uses zp_save0 for current span offset, zp_save1 for ox0, zp_save2 for ox1.
; ======================================================================
IF EMIT_LINES
.ms_emit_lines
{
    LDA #0 : STA LINE_OUT_COUNT
    LDX zp_head : BNE mel_loop
    RTS
.mel_loop
    ; Skip if span is entirely before [ilo, ihi]
    LDA POOL_XEND,X : CMP zp_ilo : BCS mel_chk_start
    JMP mel_next
.mel_chk_start
    ; Skip if span starts after [ilo, ihi]
    LDA zp_ihi : CMP POOL_XSTART,X : BCS mel_has_overlap
    RTS                                ; all subsequent spans are post-seg
.mel_has_overlap
    STX zp_save0
    ; ox0 = max(xstart, ilo)
    LDA POOL_XSTART,X : CMP zp_ilo : BCS mel_ox0_ok : LDA zp_ilo
.mel_ox0_ok STA zp_save1              ; ox0
    ; ox1 = min(xend, ihi)
    LDA POOL_XEND,X : CMP zp_ihi : BCC mel_ox1_ok : LDA zp_ihi
.mel_ox1_ok STA zp_save2              ; ox1

    ; --- Evaluate span boundaries at ox0 and ox1 ---
    ; Constant-line fast path: tl==tr AND bl==br
    LDA POOL_TL,X : CMP POOL_TR,X : BNE mel_span_not_const
    STA zp_ot_l : STA zp_ot_r
    LDA POOL_BL,X : CMP POOL_BR,X : BNE mel_span_not_const
    STA zp_ob_l : STA zp_ob_r
    JMP mel_span_done
.mel_span_not_const
    ; Anchor fast path: if ox0==xlo and ox1==xhi, use stored values
    LDA zp_save1 : CMP POOL_XLO,X : BNE mel_span_interp
    LDA zp_save2 : CMP POOL_XHI,X : BNE mel_span_interp
    LDA POOL_TL,X : STA zp_ot_l : LDA POOL_TR,X : STA zp_ot_r
    LDA POOL_BL,X : STA zp_ob_l : LDA POOL_BR,X : STA zp_ob_r
    JMP mel_span_done
.mel_span_interp
    ; Full interp: den = xhi - xlo
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_XHI,X : SEC : SBC zp_i_x0 : STA zp_div_den
    LDA POOL_TL,X : STA zp_i_y0 : LDA POOL_TR,X : STA zp_i_y1
    LDA zp_save1 : JSR interp_store : STA zp_ot_l
    LDA zp_save2 : JSR interp_store : STA zp_ot_r
    LDX zp_save0
    LDA POOL_BL,X : STA zp_i_y0 : LDA POOL_BR,X : STA zp_i_y1
    LDA zp_save1 : JSR interp_store : STA zp_ob_l
    LDA zp_save2 : JSR interp_store : STA zp_ob_r
.mel_span_done

    ; --- Evaluate seg top/bot at ox0 and ox1 ---
    ; Constant-line fast path: yt1==yt2 AND yb1==yb2 (s16)
    LDA zp_yt1 : CMP zp_yt2 : BNE mel_seg_slow
    LDA zp_yt1h : CMP zp_yt2h : BNE mel_seg_slow
    LDA zp_yb1 : CMP zp_yb2 : BNE mel_seg_slow
    LDA zp_yb1h : CMP zp_yb2h : BNE mel_seg_slow
    LDA zp_yt1  : STA zp_nt_l  : STA zp_nt_r
    LDA zp_yt1h : STA zp_nt_lh : STA zp_nt_rh
    LDA zp_yb1  : STA zp_nb_l  : STA zp_nb_r
    LDA zp_yb1h : STA zp_nb_lh : STA zp_nb_rh
    JMP mel_seg_done
.mel_seg_slow
    ; Anchor fast path: if ox0==sx1 and ox1==sx2
    LDA zp_save1 : CMP zp_sx1 : BNE mel_seg_interp
    LDA zp_save2 : CMP zp_sx2 : BNE mel_seg_interp
    LDA zp_yt1  : STA zp_nt_l  : LDA zp_yt2  : STA zp_nt_r
    LDA zp_yt1h : STA zp_nt_lh : LDA zp_yt2h : STA zp_nt_rh
    LDA zp_yb1  : STA zp_nb_l  : LDA zp_yb2  : STA zp_nb_r
    LDA zp_yb1h : STA zp_nb_lh : LDA zp_yb2h : STA zp_nb_rh
    JMP mel_seg_done
.mel_seg_interp
    ; Full seg interp
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den
    LDA zp_yt1 : STA zp_i_y0 : LDA zp_yt1h : STA zp_i_y0h
    LDA zp_yt2 : STA zp_i_y1 : LDA zp_yt2h : STA zp_i_y1h
    LDA zp_save1 : JSR seg_interp_store : STA zp_nt_l : STY zp_nt_lh
    LDA zp_save2 : JSR seg_interp_store : STA zp_nt_r : STY zp_nt_rh
    LDA zp_yb1 : STA zp_i_y0 : LDA zp_yb1h : STA zp_i_y0h
    LDA zp_yb2 : STA zp_i_y1 : LDA zp_yb2h : STA zp_i_y1h
    LDA zp_save1 : JSR seg_interp_store : STA zp_nb_l : STY zp_nb_lh
    LDA zp_save2 : JSR seg_interp_store : STA zp_nb_r : STY zp_nb_rh
.mel_seg_done

    ; --- Clamp seg values to [0,159] ---
    LDA zp_nt_lh : ORA zp_nt_rh : ORA zp_nb_lh : ORA zp_nb_rh
    BNE mel_clamp_slow
    LDA zp_nt_l : CMP #160 : BCS mel_clamp_slow
    LDA zp_nt_r : CMP #160 : BCS mel_clamp_slow
    LDA zp_nb_l : CMP #160 : BCS mel_clamp_slow
    LDA zp_nb_r : CMP #160 : BCS mel_clamp_slow
    BCC mel_clamp_ok
.mel_clamp_slow
    LDA zp_nt_lh : BMI mel_cz1 : BNE mel_cf1
    LDA zp_nt_l : CMP #160 : BCC mel_cs1
.mel_cf1 LDA #159 : EQUB $2C
.mel_cz1 LDA #0
.mel_cs1 STA zp_nt_l
    LDA zp_nt_rh : BMI mel_cz2 : BNE mel_cf2
    LDA zp_nt_r : CMP #160 : BCC mel_cs2
.mel_cf2 LDA #159 : EQUB $2C
.mel_cz2 LDA #0
.mel_cs2 STA zp_nt_r
    LDA zp_nb_lh : BMI mel_cz3 : BNE mel_cf3
    LDA zp_nb_l : CMP #160 : BCC mel_cs3
.mel_cf3 LDA #159 : EQUB $2C
.mel_cz3 LDA #0
.mel_cs3 STA zp_nb_l
    LDA zp_nb_rh : BMI mel_cz4 : BNE mel_cf4
    LDA zp_nb_r : CMP #160 : BCC mel_cs4
.mel_cf4 LDA #159 : EQUB $2C
.mel_cz4 LDA #0
.mel_cs4 STA zp_nb_r
.mel_clamp_ok

    ; --- Emit visible edges ---
    ; Top edge: visible where seg top > span top
    LDA zp_nt_l : CMP zp_ot_l : BEQ mel_chk_top_r : BCS mel_emit_top
.mel_chk_top_r
    LDA zp_nt_r : CMP zp_ot_r : BCC mel_no_top : BEQ mel_no_top
.mel_emit_top
    ; Set up rasteriser + buffer: ox0 in save1, ox1 in save2
    LDY LINE_OUT_COUNT
    LDA zp_save1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nt_l  : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_save2 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nt_r  : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JSR RASTER_ENTRY
.mel_no_top
    ; Bot edge: visible where seg bot < span bot
    LDA zp_nb_l : CMP zp_ob_l : BEQ mel_chk_bot_r : BCC mel_emit_bot
.mel_chk_bot_r
    LDA zp_nb_r : CMP zp_ob_r : BCS mel_no_bot
.mel_emit_bot
    LDY LINE_OUT_COUNT
    LDA zp_save1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nb_l  : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_save2 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nb_r  : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JSR RASTER_ENTRY
.mel_no_bot
    ; --- Advance to next span ---
    LDX zp_save0
.mel_next
    LDA POOL_NEXT,X : TAX : BEQ mel_rts
    JMP mel_loop
.mel_rts
    RTS
}
ENDIF

; ======================================================================
; EMIT_LINE: write line to buffer AND call NJ rasteriser
;
; Call with: zp_ox0/zp_ox1 = X endpoints, A = y1, X = y2
; (caller sets up which edge: top uses nt_l/nt_r, bot uses nb_l/nb_r)
; Preserves: zp_ox0/ox1/ot_l/ot_r/ob_l/ob_r/nt_l/nt_r/nb_l/nb_r
; ======================================================================
IF EMIT_LINES
.emit_top_edge
{
    LDY LINE_OUT_COUNT
    LDA zp_ox0 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nt_l : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nt_r : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY   ; tail-call rasteriser (returns via RTS)
}

.emit_bot_edge
{
    LDY LINE_OUT_COUNT
    LDA zp_ox0 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nb_l : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nb_r : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY   ; tail-call rasteriser (returns via RTS)
}
ENDIF

; ======================================================================
; DRAW_CLIPPED_LINE: clip a single line against the span list, emit
; visible portions to LINE_OUT_BUF and call the NJ rasteriser.
;
; Phase 1: basic walk with outer bbox reject / inner bbox accept.
; No CB clip (ambiguous cases skipped), no portal continuation
; (each span is considered independently).
;
; Inputs (ZP): zp_line_xl, zp_line_yl, zp_line_xr, zp_line_yr
; The line MUST be oriented left-to-right (xl <= xr).
; All Y values u8 [0,159].
;
; Output: lines written to LINE_OUT_BUF, count at LINE_OUT_COUNT.
; READ-ONLY walk — never modifies the span list.
; ======================================================================
.draw_clipped_line
{
    ; --- Compute dx, dy, ylo, yhi ---
    LDA zp_line_xr : SEC : SBC zp_line_xl : STA zp_line_dx
    LDA zp_line_yr : SEC : SBC zp_line_yl : STA zp_line_dy

    ; Y bounding box: ylo = min(yl, yr), yhi = max(yl, yr)
    LDA zp_line_yl : LDX zp_line_yr
    CMP zp_line_yr : BCC dcl_yl_lo
    ; yl >= yr: yhi=yl, ylo=yr
    STA zp_line_yhi : STX zp_line_ylo : JMP dcl_bbox_done
.dcl_yl_lo
    ; yl < yr: ylo=yl, yhi=yr
    STA zp_line_ylo : STX zp_line_yhi
.dcl_bbox_done

    ; Reset output
    LDA #0 : STA LINE_OUT_COUNT

    ; seg_start = NULL
    LDA #$FF : STA zp_seg_start_x

    ; Walk span list
    LDX zp_head

.dcl_walk
    ; End of list?
    BNE dcl_walk2
    JMP dcl_flush
.dcl_walk2

    ; --- Skip spans entirely left of line ---
    ; Skip if xend <= xl (strict: pixel-center model)
    LDA zp_line_xl : CMP POOL_XEND,X : BCC dcl_not_left
    JMP dcl_advance  ; xl >= xend → skip
.dcl_not_left

    ; --- Skip spans entirely right of line ---
    ; Done if xstart >= xr (all remaining spans are further right)
    LDA POOL_XSTART,X : CMP zp_line_xr : BCC dcl_in_range
    JMP dcl_flush  ; xstart >= xr → done
.dcl_in_range

    ; --- Compute overlap ---
    ; ox0 = max(xstart, xl) — A already holds POOL_XSTART,X from skip check
    CMP zp_line_xl : BCS dcl_ox0_ok
    LDA zp_line_xl
.dcl_ox0_ok STA zp_ox0
    ; ox1 = min(xend, xr)
    LDA POOL_XEND,X : CMP zp_line_xr : BCC dcl_ox1_ok
    LDA zp_line_xr
.dcl_ox1_ok STA zp_ox1

    ; --- Entry or continuation? ---
    LDA zp_seg_start_x : CMP #$FF : BNE dcl_exit_check

    ; ========== ENTRY: seg_start is NULL ==========
    ; --- Tier 1: outer bbox reject ---
    ; ot = min(tl, tr)
    LDA POOL_TL,X : CMP POOL_TR,X : BCC dcl_ot_ok : LDA POOL_TR,X
.dcl_ot_ok STA zp_tmp0    ; ot = min(tl, tr)
    ; Reject if yhi < ot (line entirely above aperture)
    LDA zp_line_yhi : CMP zp_tmp0 : BCC dcl_outer_reject  ; yhi < ot → reject

    ; ob = max(bl, br)
    LDA POOL_BL,X : CMP POOL_BR,X : BCS dcl_ob_ok : LDA POOL_BR,X
.dcl_ob_ok STA zp_tmp1    ; ob = max(bl, br)
    ; Reject if ylo > ob (line entirely below aperture)
    LDA zp_tmp1 : CMP zp_line_ylo : BCC dcl_outer_reject  ; ob < ylo → reject

    ; --- Tier 2: inner bbox accept ---
    ; it = max(tl, tr)
    LDA POOL_TL,X : CMP POOL_TR,X : BCS dcl_it_ok : LDA POOL_TR,X
.dcl_it_ok STA zp_tmp0    ; it = max(tl, tr)
    ; ib = min(bl, br)
    LDA POOL_BL,X : CMP POOL_BR,X : BCC dcl_ib_ok : LDA POOL_BR,X
.dcl_ib_ok STA zp_tmp1    ; ib = min(bl, br)
    ; Accept if ylo >= it AND ib >= yhi
    LDA zp_line_ylo : CMP zp_tmp0 : BCC dcl_ambiguous  ; ylo < it → ambiguous → Phase 4 CB clip
    LDA zp_tmp1 : CMP zp_line_yhi : BCS dcl_accept
    ; yhi > ib → ambiguous
    JMP dcl_cb_clip

.dcl_outer_reject
    JMP dcl_advance  ; trampoline: outer reject this span
.dcl_ambiguous
    JMP dcl_cb_clip  ; trampoline: ambiguous → Phase 4 CB clip

.dcl_accept
    ; Inner bbox accept! Line guaranteed inside this span's aperture.
    ; seg_start = (ox0, line_y_at(ox0))
    LDA zp_ox0 : STA zp_seg_start_x
    CMP zp_line_xl : BNE dcl_entry_mid
    ; ox0 == xl: use yl directly
    LDA zp_line_yl : STA zp_seg_start_y
    JMP dcl_exit_check
.dcl_entry_mid
    ; ox0 != xl: need line_y_at(ox0)
    LDA zp_line_dy : BNE dcl_entry_mid_interp
    ; dy==0: flat line, Y = yl everywhere
    LDA zp_line_yl : STA zp_seg_start_y
    JMP dcl_exit_check
.dcl_entry_mid_interp
    STX zp_save0  ; save span pointer
    JSR dcl_line_y_at_ox0
    STA zp_seg_start_y
    LDX zp_save0  ; restore span pointer
    ; Fall through to exit check

.dcl_exit_check
    ; ========== EXIT CHECK ==========
    ; Does the line end within this span? (xr <= xend)
    LDA POOL_XEND,X : CMP zp_line_xr : BCC dcl_extends_past  ; xend < xr → extends past
    ; xend >= xr: line ends within this span
    JMP dcl_line_ends

.dcl_extends_past
    ; ========== Line extends past this span — Phase 2 portal check ==========
    STX zp_save0    ; save current span pointer

    ; Check if next span abuts this one
    LDY POOL_NEXT,X : BNE dcl_has_next
    JMP dcl_exit_no_portal   ; no next span → emit+reset
.dcl_has_next

    ; Abutting? POOL_XEND[current] == POOL_XSTART[next]
    LDA POOL_XEND,X : CMP POOL_XSTART,Y : BEQ dcl_is_abutting
    JMP dcl_exit_no_portal
.dcl_is_abutting

    ; --- Compute portal aperture at shared boundary ---
    ; pt = max(current.tr, next.tl) — tightest top
    LDA POOL_TR,X : CMP POOL_TL,Y : BCS dcl_pt_ok : LDA POOL_TL,Y
.dcl_pt_ok STA zp_tmp0    ; pt

    ; pb = min(current.br, next.bl) — tightest bottom
    LDA POOL_BR,X : CMP POOL_BL,Y : BCC dcl_pb_ok : LDA POOL_BL,Y
.dcl_pb_ok STA zp_tmp1    ; pb

    ; Portal open? pt < pb
    LDA zp_tmp0 : CMP zp_tmp1 : BCS dcl_exit_no_portal  ; pt >= pb → portal closed

    ; --- Tier 1 (cheap accept): pt <= ylo AND yhi <= pb ---
    ; Line's entire Y range fits in portal aperture → continue
    LDA zp_line_ylo : CMP zp_tmp0 : BCC dcl_portal_t2  ; ylo < pt → not tier 1
    LDA zp_tmp1 : CMP zp_line_yhi : BCC dcl_portal_t2  ; pb < yhi → not tier 1
    ; Tier 1 accept: continue to next span, keep seg_start
    LDX zp_save0
    JMP dcl_advance

.dcl_portal_t2
    ; --- Tier 2 (cheap reject): yhi < pt OR ylo > pb ---
    LDA zp_line_yhi : CMP zp_tmp0 : BCC dcl_exit_no_portal  ; yhi < pt → reject
    LDA zp_tmp1 : CMP zp_line_ylo : BCC dcl_exit_no_portal  ; pb < ylo → reject

    ; --- Tier 3 (exact check): compute ly = line_y_at(portal_x) ---
    ; portal_x = POOL_XEND of current span (shared boundary)
    LDX zp_save0
    LDA zp_line_dy : BEQ dcl_portal_use_yl  ; flat line: ly = yl always
    LDA POOL_XEND,X : CMP zp_line_xr : BEQ dcl_portal_use_yr
    JSR dcl_line_y_at_a  ; A = ly
    JMP dcl_portal_chk_ly
.dcl_portal_use_yl
    LDA zp_line_yl
    JMP dcl_portal_chk_ly
.dcl_portal_use_yr
    LDA zp_line_yr
.dcl_portal_chk_ly
    ; Check: pt <= ly <= pb
    CMP zp_tmp0 : BCC dcl_exit_no_portal_a  ; ly < pt → fail
    STA zp_tmp2     ; save ly
    LDA zp_tmp1 : CMP zp_tmp2 : BCC dcl_exit_no_portal_a  ; pb < ly → fail

    ; Line passes through portal. Narrow Y bbox for next span.
    ; For flat lines (dy==0), ylo=yhi=yl is already correct — skip narrowing.
    LDA zp_line_dy : BEQ dcl_portal_continue
    ; ylo = min(ly, yr), yhi = max(ly, yr)
    LDA zp_tmp2 : CMP zp_line_yr : BCC dcl_portal_ly_lo
    ; ly >= yr: yhi=ly, ylo=yr
    STA zp_line_yhi : LDA zp_line_yr : STA zp_line_ylo
    JMP dcl_portal_continue
.dcl_portal_ly_lo
    ; ly < yr: ylo=ly, yhi=yr
    STA zp_line_ylo : LDA zp_line_yr : STA zp_line_yhi
.dcl_portal_continue
    ; Continue to next span, keep seg_start
    LDX zp_save0
    JMP dcl_advance

.dcl_exit_no_portal_a
    ; Restore for emit path (ly check failed, need save0)
.dcl_exit_no_portal
    ; Portal failed or closed: emit current segment and reset.
    ; Compute exit point Y.
    LDX zp_save0
    ; Exit Y: if xr > xend, use line_y_at(xend). If xr <= xend, use yr.
    LDA POOL_XEND,X
    STA zp_ox1   ; end_x = xend of current span
    CMP zp_line_xr : BEQ dcl_exit_use_yr
    ; xend < xr: compute line_y_at(ox1)
    LDA zp_line_dy : BNE dcl_exit_interp
    LDA zp_line_yl : JMP dcl_exit_emit  ; flat line: ly = yl
.dcl_exit_interp
    LDA zp_ox1 : JSR dcl_line_y_at_a
    JMP dcl_exit_emit
.dcl_exit_use_yr
    LDA zp_line_yr
.dcl_exit_emit
    ; A = end_y, emit segment
    STA zp_tmp0  ; end_y
    JSR dcl_emit_segment
    ; Reset seg_start
    LDA #$FF : STA zp_seg_start_x
    LDX zp_save0
    ; Advance to next span
    JMP dcl_advance

.dcl_line_ends
    ; Line ends within this span. Emit seg_start → (xr, yr)
    STX zp_save0
    LDA zp_line_yr : STA zp_tmp0  ; end_y = yr
    LDA zp_line_xr : STA zp_ox1   ; end_x = xr
    JSR dcl_emit_segment
    ; Done (line fully consumed)
    RTS

.dcl_advance
    ; Move to next span
    LDA POOL_NEXT,X : TAX
    JMP dcl_walk

.dcl_flush
    ; End of walk. If seg_start is active, emit final segment.
    LDA zp_seg_start_x : CMP #$FF : BEQ dcl_done
    ; Emit to (xr, yr) since line extends past last span
    LDA zp_line_yr : STA zp_tmp0
    LDA zp_line_xr : STA zp_ox1
    JSR dcl_emit_segment
.dcl_done
    RTS

; ========== Phase 4: CB clip (clip_to_span) ==========
; Exact clip of the line against the span's trapezoid aperture.
; Entry: X = span pointer, seg_start_x == $FF (no active segment)
; Uses interp_store to evaluate span boundaries at clipped endpoints.
.dcl_cb_clip
    STX zp_save0  ; save span pointer

    ; Step 1: X-clip line to [xstart, xend] = [ox0, ox1]
    ; cx1 = ox0
    LDA zp_ox0 : STA zp_cb_cx1
    ; cx2 = ox1
    LDA zp_ox1 : STA zp_cb_cx2

    ; Step 2: Compute line Y at clipped X endpoints
    ; dy==0 fast path: flat line → cy1 = cy2 = yl
    LDA zp_line_dy : BNE dcl_cb_cy_slow
    LDA zp_line_yl : STA zp_cb_cy1 : STA zp_cb_cy2
    JMP dcl_cb_cy_done
.dcl_cb_cy_slow
    ; cy1 = line_y_at(cx1)
    LDA zp_cb_cx1 : CMP zp_line_xl : BNE dcl_cb_cy1_interp
    LDA zp_line_yl : JMP dcl_cb_cy1_done
.dcl_cb_cy1_interp
    LDA zp_cb_cx1 : JSR dcl_line_y_at_a
.dcl_cb_cy1_done
    STA zp_cb_cy1

    ; cy2 = line_y_at(cx2)
    LDA zp_cb_cx2 : CMP zp_line_xr : BNE dcl_cb_cy2_interp
    LDA zp_line_yr : JMP dcl_cb_cy2_done
.dcl_cb_cy2_interp
    LDA zp_cb_cx2 : JSR dcl_line_y_at_a
.dcl_cb_cy2_done
    STA zp_cb_cy2
.dcl_cb_cy_done

    ; Step 3: Evaluate span boundaries at cx1, cx2
    LDX zp_save0
    ; Setup interp for span: x0=xlo, den=xhi-xlo
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_XHI,X : SEC : SBC zp_i_x0 : STA zp_div_den
    BNE dcl_cb_has_den
    ; den=0: single-column span, use tl/bl directly
    LDA POOL_TL,X : STA zp_cb_top1 : STA zp_cb_top2
    LDA POOL_BL,X : STA zp_cb_bot1 : STA zp_cb_bot2
    JMP dcl_cb_have_bounds
.dcl_cb_has_den
    ; --- Anchor fast path: if cx1==xlo AND cx2==xhi, use stored values ---
    LDA zp_cb_cx1 : CMP POOL_XLO,X : BNE dcl_cb_not_anchor
    LDA zp_cb_cx2 : CMP POOL_XHI,X : BNE dcl_cb_not_anchor
    LDA POOL_TL,X : STA zp_cb_top1
    LDA POOL_TR,X : STA zp_cb_top2
    LDA POOL_BL,X : STA zp_cb_bot1
    LDA POOL_BR,X : STA zp_cb_bot2
    JMP dcl_cb_have_bounds
.dcl_cb_not_anchor
    ; --- Constant-line fast path: if tl==tr AND bl==br, skip interp ---
    LDA POOL_TL,X : CMP POOL_TR,X : BNE dcl_cb_need_interp
    STA zp_cb_top1 : STA zp_cb_top2
    LDA POOL_BL,X : CMP POOL_BR,X : BNE dcl_cb_need_interp_bot
    STA zp_cb_bot1 : STA zp_cb_bot2
    JMP dcl_cb_have_bounds
.dcl_cb_need_interp_bot
    ; TL==TR (tops constant) but BL!=BR: need bot interp only
    ; i_x0 and div_den still valid from initial setup above
    STA zp_i_y0  ; A = POOL_BL,X
    LDA POOL_BR,X : STA zp_i_y1
    LDA zp_cb_cx1 : JSR interp_store : STA zp_cb_bot1
    LDA zp_cb_cx2 : JSR interp_store : STA zp_cb_bot2
    JMP dcl_cb_have_bounds
.dcl_cb_need_interp
    ; top1 = interp_store(cx1, xlo, tl, xhi, tr)
    LDA POOL_TL,X : STA zp_i_y0
    LDA POOL_TR,X : STA zp_i_y1
    LDA zp_cb_cx1 : JSR interp_store : STA zp_cb_top1
    ; top2 = interp_store(cx2, ...)
    LDA zp_cb_cx2 : JSR interp_store : STA zp_cb_top2
    ; bot1, bot2
    LDX zp_save0
    LDA POOL_BL,X : STA zp_i_y0
    LDA POOL_BR,X : STA zp_i_y1
    ; den still set from above (interp_store doesn't change div_den internally
    ; BUT it calls udiv16_8 which may clobber it... need to re-set)
    LDA POOL_XHI,X : SEC : SBC POOL_XLO,X : STA zp_div_den
    LDA POOL_XLO,X : STA zp_i_x0
    LDA zp_cb_cx1 : JSR interp_store : STA zp_cb_bot1
    LDA zp_cb_cx2 : JSR interp_store : STA zp_cb_bot2

.dcl_cb_have_bounds
    ; Step 4: Top boundary clip
    ; If cy1 < top1 AND cy2 < top2 → reject (entirely above)
    LDA zp_cb_cy1 : CMP zp_cb_top1 : BCS dcl_cb_top_p1_ok  ; cy1 >= top1
    LDA zp_cb_cy2 : CMP zp_cb_top2 : BCS dcl_cb_top_clip   ; cy2 >= top2 → one inside, clip
    JMP dcl_cb_reject  ; both above → reject
.dcl_cb_top_p1_ok
    ; cy1 >= top1; check cy2
    LDA zp_cb_cy2 : CMP zp_cb_top2 : BCS dcl_cb_top_done  ; cy2 >= top2 → both inside, no clip
    ; cy2 < top2, cy1 >= top1: clip at p2 end
    ; d1 = cy1 - top1 (positive or zero)
    LDA zp_cb_cy1 : SEC : SBC zp_cb_top1 : STA zp_tmp0  ; d1 >= 0
    ; d2 = cy2 - top2 (negative, since cy2 < top2)
    LDA zp_cb_cy2 : SEC : SBC zp_cb_top2 : STA zp_tmp1  ; d2 < 0 (signed)
    ; boundary_ix with clip_p1=0 (clip p2 end, round toward cx1)
    LDA #0 : JSR dcl_boundary_ix  ; A = ix
    STA zp_cb_cx2
    ; Recompute cy2 = line_y_at(cx2)
    LDA zp_cb_cx2 : CMP zp_line_xr : BNE dcl_cb_top_cy2_interp
    LDA zp_line_yr : JMP dcl_cb_top_cy2_done
.dcl_cb_top_cy2_interp
    LDA zp_cb_cx2 : CMP zp_line_xl : BNE dcl_cb_top_cy2_mid
    LDA zp_line_yl : JMP dcl_cb_top_cy2_done
.dcl_cb_top_cy2_mid
    LDA zp_cb_cx2 : JSR dcl_line_y_at_a
.dcl_cb_top_cy2_done
    STA zp_cb_cy2
    JMP dcl_cb_top_done

.dcl_cb_top_clip
    ; cy1 < top1, cy2 >= top2: clip at p1 end
    ; d1 = cy1 - top1 (negative)
    LDA zp_cb_cy1 : SEC : SBC zp_cb_top1 : STA zp_tmp0  ; d1 < 0
    ; d2 = cy2 - top2 (positive or zero)
    LDA zp_cb_cy2 : SEC : SBC zp_cb_top2 : STA zp_tmp1  ; d2 >= 0
    ; boundary_ix with clip_p1=1 (clip p1 end, round toward cx2)
    LDA #1 : JSR dcl_boundary_ix  ; A = ix
    STA zp_cb_cx1
    ; Recompute cy1 = line_y_at(cx1)
    LDA zp_cb_cx1 : CMP zp_line_xl : BNE dcl_cb_top_cy1_interp
    LDA zp_line_yl : JMP dcl_cb_top_cy1_done
.dcl_cb_top_cy1_interp
    LDA zp_cb_cx1 : CMP zp_line_xr : BNE dcl_cb_top_cy1_mid
    LDA zp_line_yr : JMP dcl_cb_top_cy1_done
.dcl_cb_top_cy1_mid
    LDA zp_cb_cx1 : JSR dcl_line_y_at_a
.dcl_cb_top_cy1_done
    STA zp_cb_cy1

.dcl_cb_top_done
    ; Check cx1 > cx2 after top clip → reject
    LDA zp_cb_cx2 : CMP zp_cb_cx1 : BCS dcl_cb_top_ok
    JMP dcl_cb_reject
.dcl_cb_top_ok

    ; Step 5: Bottom boundary clip
    ; Need to re-evaluate bot boundaries at (possibly new) cx1, cx2
    ; BUT: if we clipped for top, the old bot values at the original cx1/cx2
    ; may no longer be correct. We need bot at the NEW cx1/cx2.
    ; Optimization: only re-evaluate the endpoint that was clipped.
    ; For simplicity: re-evaluate both bot boundaries at current cx1, cx2.
    LDX zp_save0
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_XHI,X : SEC : SBC zp_i_x0 : STA zp_div_den
    BNE dcl_cb_bot_has_den
    ; den=0: single-column
    LDA POOL_BL,X : STA zp_cb_bot1 : STA zp_cb_bot2
    JMP dcl_cb_bot_eval_done
.dcl_cb_bot_has_den
    LDA POOL_BL,X : STA zp_i_y0
    LDA POOL_BR,X : STA zp_i_y1
    LDA zp_cb_cx1 : JSR interp_store : STA zp_cb_bot1
    LDA zp_cb_cx2 : JSR interp_store : STA zp_cb_bot2
.dcl_cb_bot_eval_done

    ; If cy1 > bot1 AND cy2 > bot2 → reject (entirely below)
    LDA zp_cb_bot1 : CMP zp_cb_cy1 : BCS dcl_cb_bot_p1_ok  ; bot1 >= cy1
    LDA zp_cb_bot2 : CMP zp_cb_cy2 : BCS dcl_cb_bot_clip   ; bot2 >= cy2 → one inside, clip
    JMP dcl_cb_reject  ; both below → reject
.dcl_cb_bot_p1_ok
    ; bot1 >= cy1; check cy2
    LDA zp_cb_bot2 : CMP zp_cb_cy2 : BCS dcl_cb_bot_done  ; bot2 >= cy2 → both inside
    ; cy2 > bot2, cy1 <= bot1: clip p2 end
    ; d1 = cy1 - bot1 (negative or zero, since cy1 <= bot1)
    LDA zp_cb_cy1 : SEC : SBC zp_cb_bot1 : STA zp_tmp0  ; d1 <= 0
    ; d2 = cy2 - bot2 (positive, since cy2 > bot2)
    LDA zp_cb_cy2 : SEC : SBC zp_cb_bot2 : STA zp_tmp1  ; d2 > 0
    ; boundary_ix with clip_p1=0 (clip p2, round toward cx1)
    LDA #0 : JSR dcl_boundary_ix
    STA zp_cb_cx2
    ; Recompute cy2
    LDA zp_cb_cx2 : CMP zp_line_xr : BNE dcl_cb_bot_cy2_interp
    LDA zp_line_yr : JMP dcl_cb_bot_cy2_done
.dcl_cb_bot_cy2_interp
    LDA zp_cb_cx2 : CMP zp_line_xl : BNE dcl_cb_bot_cy2_mid
    LDA zp_line_yl : JMP dcl_cb_bot_cy2_done
.dcl_cb_bot_cy2_mid
    LDA zp_cb_cx2 : JSR dcl_line_y_at_a
.dcl_cb_bot_cy2_done
    STA zp_cb_cy2
    JMP dcl_cb_bot_done

.dcl_cb_bot_clip
    ; bot1 < cy1, bot2 >= cy2: clip p1 end
    ; d1 = cy1 - bot1 (positive)
    LDA zp_cb_cy1 : SEC : SBC zp_cb_bot1 : STA zp_tmp0  ; d1 > 0
    ; d2 = cy2 - bot2 (negative or zero)
    LDA zp_cb_cy2 : SEC : SBC zp_cb_bot2 : STA zp_tmp1  ; d2 <= 0
    ; boundary_ix with clip_p1=1 (clip p1, round toward cx2)
    LDA #1 : JSR dcl_boundary_ix
    STA zp_cb_cx1
    ; Recompute cy1
    LDA zp_cb_cx1 : CMP zp_line_xl : BNE dcl_cb_bot_cy1_interp
    LDA zp_line_yl : JMP dcl_cb_bot_cy1_done
.dcl_cb_bot_cy1_interp
    LDA zp_cb_cx1 : CMP zp_line_xr : BNE dcl_cb_bot_cy1_mid
    LDA zp_line_yr : JMP dcl_cb_bot_cy1_done
.dcl_cb_bot_cy1_mid
    LDA zp_cb_cx1 : JSR dcl_line_y_at_a
.dcl_cb_bot_cy1_done
    STA zp_cb_cy1

.dcl_cb_bot_done
    ; Check cx1 > cx2 after bot clip → reject
    LDA zp_cb_cx2 : CMP zp_cb_cx1 : BCC dcl_cb_reject

    ; CB clip succeeded. Set seg_start to (cx1, cy1).
    LDA zp_cb_cx1 : STA zp_seg_start_x
    LDA zp_cb_cy1 : STA zp_seg_start_y
    ; Update Y bbox for portal checks
    LDA zp_cb_cy1 : CMP zp_cb_cy2 : BCC dcl_cb_ylo_ok
    ; cy1 >= cy2
    STA zp_line_yhi : LDA zp_cb_cy2 : STA zp_line_ylo
    JMP dcl_cb_bbox_done
.dcl_cb_ylo_ok
    ; cy1 < cy2
    STA zp_line_ylo : LDA zp_cb_cy2 : STA zp_line_yhi
.dcl_cb_bbox_done
    ; Restore span pointer and continue with exit check
    LDX zp_save0
    JMP dcl_exit_check

.dcl_cb_reject
    ; CB clip rejected — skip this span
    LDX zp_save0
    JMP dcl_advance

; --- dcl_boundary_ix: compute intersection X for CB clip ---
; Input: zp_tmp0 = d1 (s8), zp_tmp1 = d2 (s8), A = clip_p1 flag (0 or 1)
;        zp_cb_cx1, zp_cb_cx2 = current clipped X range
; Output: A = intersection X
; Formula: ix = cx1 + (cx2 - cx1) * d1 / (d1 - d2)
;   with directed rounding: if clip_p1, round toward cx2 (ceiling)
;                           else round toward cx1 (floor)
; d1 and d2 have opposite signs (one endpoint inside, one outside).
; denom = d1 - d2, |num| = (cx2-cx1) * |d1|
.dcl_boundary_ix
    STA zp_save1        ; save clip_p1 flag

    ; denom = d1 - d2 (s8 result, but could be s9 in theory)
    ; Since d1 and d2 have opposite signs, |denom| = |d1| + |d2|
    ; Compute |d1| and sign
    LDA zp_tmp0 : BPL dcl_bix_d1_pos
    ; d1 negative: |d1| = -d1
    EOR #$FF : CLC : ADC #1
.dcl_bix_d1_pos
    STA zp_tmp2         ; |d1|

    ; |denom| = |d1| + |d2| (since opposite signs)
    LDA zp_tmp1 : BPL dcl_bix_d2_pos
    EOR #$FF : CLC : ADC #1
.dcl_bix_d2_pos
    CLC : ADC zp_tmp2 : STA zp_div_den  ; |denom| = |d1| + |d2|
    ; Handle overflow: if carry set, denom > 255 — shouldn't happen
    ; for pixel-scale values, but guard just in case
    BCS dcl_bix_mid     ; denom overflow → use midpoint fallback

    ; Check denom == 0 (shouldn't happen if signs differ, but guard)
    BEQ dcl_bix_mid

    ; num = (cx2 - cx1) * |d1|
    LDA zp_cb_cx2 : SEC : SBC zp_cb_cx1 : STA zp_mul_b  ; dx = cx2 - cx1
    BEQ dcl_bix_cx1     ; dx=0 → return cx1

    LDA zp_tmp2          ; |d1|
    JSR umul8            ; prod = dx * |d1| → zp_prod_lo:hi

    ; Directed rounding: if clip_p1, add (denom-1) to numerator before divide
    ; (ceiling division). If !clip_p1, just floor division.
    LDA zp_save1 : BEQ dcl_bix_no_round
    ; Add (denom - 1) to product for ceiling
    LDA zp_prod_lo : CLC : ADC zp_div_den : STA zp_div_lo
    LDA zp_prod_hi : ADC #0 : STA zp_div_hi
    ; Subtract 1
    LDA zp_div_lo : SEC : SBC #1 : STA zp_div_lo
    LDA zp_div_hi : SBC #0 : STA zp_div_hi
    JMP dcl_bix_do_div
.dcl_bix_no_round
    ; prod already in div_lo:hi (aliases)
.dcl_bix_do_div
    JSR udiv16_8         ; A = quotient = num / denom

    ; ix = cx1 + quotient
    CLC : ADC zp_cb_cx1
    ; Clamp to [cx1, cx2]
    CMP zp_cb_cx1 : BCC dcl_bix_cx1
    CMP zp_cb_cx2 : BEQ dcl_bix_ok : BCS dcl_bix_cx2
.dcl_bix_ok
    RTS

.dcl_bix_cx1
    LDA zp_cb_cx1 : RTS
.dcl_bix_cx2
    LDA zp_cb_cx2 : RTS
.dcl_bix_mid
    ; Fallback: return midpoint
    LDA zp_cb_cx1 : CLC : ADC zp_cb_cx2 : ROR A : RTS

; --- dcl_emit_segment: write segment to LINE_OUT_BUF and call rasteriser ---
; Input: zp_seg_start_x, zp_seg_start_y, zp_ox1 (end_x), zp_tmp0 (end_y)
; Clobbers: A, Y
.dcl_emit_segment
    ; Skip degenerate segments (zero-length)
    LDA zp_seg_start_x : CMP zp_ox1 : BNE dcl_es_ok
    LDA zp_seg_start_y : CMP zp_tmp0 : BNE dcl_es_ok
    RTS  ; degenerate: start == end
.dcl_es_ok
    LDY LINE_OUT_COUNT
    LDA zp_seg_start_x : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_seg_start_y : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_tmp0 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY   ; tail-call rasteriser

; --- dcl_line_y_at_ox0: compute line Y at ox0 ---
; Uses interp_store with the line as the interpolation source.
; Input: zp_ox0 = X coordinate, line params in zp_line_*
; Output: A = line Y at ox0
; Clobbers: interp working set (zp_i_*, zp_mul_b, zp_prod_*, zp_div_*)
.dcl_line_y_at_ox0
    LDA zp_line_xl : STA zp_i_x0
    LDA zp_line_yl : STA zp_i_y0
    LDA zp_line_yr : STA zp_i_y1
    LDA zp_line_dx : STA zp_div_den
    LDA zp_ox0 : JMP interp_store

; --- dcl_line_y_at_a: compute line Y at column A ---
; Input: A = X coordinate, line params in zp_line_*
; Output: A = line Y at the given X
; Clobbers: interp working set
.dcl_line_y_at_a
    PHA
    LDA zp_line_xl : STA zp_i_x0
    LDA zp_line_yl : STA zp_i_y0
    LDA zp_line_yr : STA zp_i_y1
    LDA zp_line_dx : STA zp_div_den
    PLA : JMP interp_store
}

.end_code
SAVE "span_clip.bin", $2000, end_code, $2000
