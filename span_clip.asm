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
; 32 slots in block layout at $0400; slot 0 is the null sentinel.
;
; Pool at POOL ($0400), 32 slots in block layout.  Slot 0 = null.
; Each field is a 32-byte block; slot N is at POOL_FIELD + N.
; Access: LDX slot_number; LDA POOL_XLO,X  (fast absolute indexed)
;
; Division by 256 (ex=0): just take high byte of multiply (shift, no loop).
; Otherwise: restoring division loop, 8 iterations.

; --- Build flags ---
EMIT_LINES = TRUE     ; set FALSE to disable line emission (pure clip benchmark)

; --- Code origin: $2000 in BBC Micro memory map ---
; (hoisted: the pinned umul8 at $2030 references these before the main
; equate block)
zp_mul_b = $D9
zp_prod_lo = $DA : zp_div_lo = $DA   ; shared: mul output = div input
zp_prod_hi = $DB : zp_div_hi = $DB
zp_tmp0  = $DE : zp_tmp1  = $DF : zp_tmp2  = $E0

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
JMP clip_line_records ; $2018
JMP tighten_from_records ; $201B
JMP draw_clipped_line_s16 ; $201E
JMP umul8                 ; $2021  (exported for bsp_render.asm)
JMP udiv16_8              ; $2024  (exported for bsp_render.asm)

; umul8 is the hottest cross-module call (every multiply) — pin it at a
; FIXED address so bsp_render can JSR it directly, skipping the table's
; extra JMP (3 cycles per multiply). The ASSERT keeps the pin honest.
ORG $2030
.umul8_fixed
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

; === Pool constants and field offsets ===
; The span pool uses block layout at $0400: each field is a contiguous
; 32-byte block, one byte per slot.  Slot N is at POOL_FIELD + N.
; X register holds the slot number directly (0-31).
; Slot 0 is the null sentinel; slot 1 is the initial active span;
; slots 2..31 start on the free list.
;
; Field blocks (32 bytes each):
;   NEXT     linked-list next (slot number, 0 = end)
;   XLO      line anchor x left  (immutable after span creation)
;   DEN      xhi - xlo (precomputed denominator for interp, immutable)
;   TL       top y at XLO
;   BL       bot y at XLO
;   TR       top y at XLO+DEN
;   BR       bot y at XLO+DEN
;   XSTART   active range start (mutable: shrunk by mark_solid / tighten fragments)
;   XEND     active range end   (mutable)
;   OT       min(TL, TR) — outer top (precomputed bbox)
;   OB       max(BL, BR) — outer bot (precomputed bbox)
;   IT       max(TL, TR) — inner top (precomputed bbox)
;   IB       min(BL, BR) — inner bot (precomputed bbox)
;
; Spans interpolate y at any column x ∈ [XSTART, XEND] using the line through
; (XLO, TL/BL) — (XLO+DEN, TR/BR). XLO/DEN need not match XSTART/XEND once
; a span has been narrowed: the line is preserved across mark_solid splits
; and left/right-fragment creation in tighten, so no interp_store is needed
; for those operations.
POOL        = $0400
POOL_NEXT   = $0400
POOL_XLO    = $0420
POOL_DEN    = $0440  ; precomputed xhi - xlo (denominator for interp)
POOL_TL     = $0460
POOL_BL     = $0480
POOL_TR     = $04A0
POOL_BR     = $04C0
POOL_XSTART = $04E0
POOL_XEND   = $0500
POOL_OT     = $0520
POOL_OB     = $0540
POOL_IT     = $0560
POOL_IB     = $0580
NUM_SLOTS   = 32

Y_BIAS = 48   ; bias Y so visible [0,159] maps to [48,207] within u8
VIS_YMAX = Y_BIAS + 159  ; = 207: maximum biased visible Y

; Quarter-square multiply tables (pre-loaded by the Python harness).
; sqr[n]  = floor(n^2/4) for n in [0,255]; sqr2[n] = floor((n+256)^2/4)
; used when a+b overflows u8.
sqr_lo  = $A500 : sqr_hi  = $A600
sqr2_lo = $A700 : sqr2_hi = $A800

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

; === Static seg Y bbox ($A8-$AB) — set once per mel/tg_go call ===
; Aliased onto the DCL line ZP slots: mel runs only inside mark_solid and
; tighten runs only inside span_tighten, neither overlaps DCL. mel reuses
; zp_ms_emit's slot ($A8) since that flag is consumed at mark_solid entry.
; Sentinels disable the per-span bbox check when seg values aren't u8:
;   seg_top_max=$FF, seg_top_min=$00, seg_bot_max=$FF, seg_bot_min=$00.
zp_seg_top_max = $A8   ; max(yt1, yt2) when all hi bytes 0; else $FF sentinel
zp_seg_top_min = $A9   ; min(yt1, yt2)                       else $00 sentinel
zp_seg_bot_max = $AA   ; max(yb1, yb2)                       else $FF sentinel
zp_seg_bot_min = $AB   ; min(yb1, yb2)                       else $00 sentinel

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
zp_tg_emit    = $BB   ; tighten emission mask: bit0=emit top, bit1=emit bot
; ===== DCL records hook ($BC-$BF) =====
; When zp_dcl_rec_buf+1 (high byte) is non-zero, DCL writes per-span records
; to the buffer at zp_dcl_rec_buf during its existing per-span walk. Caller
; sets to TOP_RECORDS or BOT_RECORDS to enable; sets high byte to 0 to disable.
; Buffer format matches clip_line_records: byte 0 = count, then 6-byte records
; (si, sox0, sox1, verdict, cy0, cy1). DCL initializes count=0 and offset=1
; on entry when records enabled.
zp_dcl_rec_buf   = $BC   ; lo byte of buffer ptr
zp_dcl_rec_buf_h = $BD   ; hi byte of buffer ptr ($00 = records disabled)
zp_dcl_rec_off   = $BE   ; current write offset (1-based) within buffer
zp_dcl_last_cy   = $BF   ; cy at previous span's ox1 (for continuation cy0 reuse)
                      ;   $03 = both (default), $01 = top only, $02 = bot only, $00 = none
; CB clip working set ($B2-$B9)
zp_cb_cx1   = $B2    ; u8, clipped left X
zp_cb_cy1   = $B3    ; u8, clipped left Y (line Y at cx1)
zp_cb_cx2   = $B4    ; u8, clipped right X
zp_cb_cy2   = $B5    ; u8, clipped right Y (line Y at cx2)
zp_cb_top1  = $B6    ; u8, span top at cx1
zp_cb_top2  = $B7    ; u8, span top at cx2
zp_cb_bot1  = $B8    ; u8, span bot at cx1
zp_cb_bot2  = $B9    ; u8, span bot at cx2

; === Tighten pre-dominance flags ($B6 — reuses CB clip slot, non-overlapping) ===
; Set per-span at post-old-interp dom check. Drives gating in new interp paths
; so we skip top or bot interps when one side is dominated by the old span.
;   bit 0 = top_dom (zp_nt_l/r preset to 0 sentinels — max(ot,nt) = ot)
;   bit 1 = bot_dom (zp_nb_l/r preset to $FF sentinels — min(ob,nb) = ob)
zp_pre_dom_flags = $B6

; === Tighten secondary seg params ($B2-$B5) — reuses DCL CB slots ===
; Passed by the wrapper when emit_sec_top/emit_sec_bot flags are set.
; Secondary values are the front ceiling/floor y at sx1/sx2 (u8 post-remap).
; Used by ncf to emit the ft/fb line alongside the primary bt/bb line.
zp_yt_sec1 = $B2     ; u8, secondary top y at sx1 (front ceiling proj)
zp_yt_sec2 = $B3     ; u8, secondary top y at sx2
zp_yb_sec1 = $B4     ; u8, secondary bot y at sx1 (front floor proj)
zp_yb_sec2 = $B5     ; u8, secondary bot y at sx2

; === Line output buffer ($0200) ===
; Lines emitted during tighten (portal edges) and mark_solid (wall edges).
; Format: byte count at $0200, then x1,y1,x2,y2 tuples at $0201+.
; Drained by Python after each tighten/mark_solid call.
LINE_OUT_COUNT = $0200
LINE_OUT_BUF   = $0201

; === Tighten records buffers ($0700, $0800) ===
; clip_line_records writes per-span sub-records here; tighten_from_records
; consumes them. Each buffer: byte 0 = record count, then records (6
; bytes each) at offset +1. Top buffer for yt-line, bot buffer for yb-line.
;   Record format: si (slot index), sox0, sox1, verdict, cy0, cy1
;     verdict: 0 = above, 1 = inside, 2 = below
;     cy0, cy1 only meaningful for verdict=inside (line y at sox0, sox1)
TOP_RECORDS = $0700
BOT_RECORDS = $0800
REC_BYTES   = 6           ; bytes per record
REC_VERDICT_ABOVE  = 0
REC_VERDICT_INSIDE = 1
REC_VERDICT_BELOW  = 2

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
zp_div_den = $DC : zp_div_rem = $DD
zp_tmp3  = $E1 : zp_prev  = $E2
zp_buf   = $E3  ; u16 pointer ($E3/$E4)
zp_save0 = $E5  ; safe scratch (not clobbered by interp)
zp_save1 = $E6  ; safe scratch #2
zp_save2 = $E7  ; safe scratch #3 (alias for tighten zp_new_tail; mark_solid only)

; ======================================================================
; SPAN_INIT: reset the clipper to one full-screen span
;
; Builds two structures:
;   FREE LIST -- singly-linked chain of unused slots 2..31
;   ACTIVE LIST -- single span (slot 1) covering [0,255] x [0,159]
;
; Called once per frame. Runtime is negligible (< 0.5% of total).
; ======================================================================
.span_init
{
    ; Free list: slots 2..31 (indices 2,3,...,31).
    LDX #2                 ; slot 2                                     ; |
    STX zp_free                                                         ; |
.il  TXA : CLC : ADC #1                                                 ; ||
    CMP #NUM_SLOTS         ; reached end? (= 32)                        ; |
    BCS id                                                              ; |
    STA POOL_NEXT,X : TAX                                               ; ||
    BNE il                 ; always taken                               ; |
.id  LDA #0 : STA POOL_NEXT,X                                           ; |
    ; Active list: slot 1 = full screen with biased Y [Y_BIAS, Y_BIAS+159].
    LDX #1                 ; slot 1 (index 1)                           ; |
    STX zp_head                                                         ; |
    STA POOL_NEXT,X : STA POOL_XLO,X : STA POOL_XSTART,X                ; |
    LDA #Y_BIAS                                                        ; |
    STA POOL_TL,X : STA POOL_TR,X                                       ; |
    STA POOL_OT,X : STA POOL_IT,X                                       ; | OT=IT=Y_BIAS
    LDA #255 : STA POOL_DEN,X : STA POOL_XEND,X                         ; |
    LDA #(Y_BIAS + 159)                                                ; |
    STA POOL_BL,X : STA POOL_BR,X                                       ; |
    STA POOL_OB,X : STA POOL_IB,X                                       ; | OB=IB=Y_BIAS+159
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
; (umul8 moved to the fixed $2030 slot below the jump table.)

EQUB 0   ; 1-byte pad: optimal alignment for umul8

; (interp_core removed — inlined into interp_store below.)

; (smul8 removed — no longer used with u8 Y_BIAS pipeline)

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

; (seg_interp_store + smul8 removed — replaced by u8 interp_store with Y_BIAS)

; ======================================================================
; INTERP_STORE: interpolate Y at column X (u8 result)
;
; Used for both old span boundaries AND new seg boundaries (with Y_BIAS,
; all Y values are u8).  Direction-split: always unsigned multiply |dy|.
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
    ; Direction check: compare y1 vs y0. Always unsigned multiply |dy|.
    LDA zp_i_y1 : CMP zp_i_y0 : BEQ is_y0 : BCC descending              ; ||||
    ; ASCENDING (y1 > y0): dy = y1 - y0 (unsigned)
    SEC : SBC zp_i_y0                                                    ; |
    JSR umul_round_div                                                   ; |
    CLC : ADC zp_i_y0 : RTS                                             ; | y0 + quot
.descending
    ; DESCENDING (y1 < y0): |dy| = y0 - y1 (unsigned)
    LDA zp_i_y0 : SEC : SBC zp_i_y1                                     ; |
    JSR umul_round_div                                                   ; |
    EOR #$FF : SEC : ADC zp_i_y0 : RTS                                  ; | y0 - quot
.is_y0
    LDA zp_i_y0 : RTS                                                   ; ||
.is_y1
    LDA zp_i_y1 : RTS                                                   ; ||
}

; Shared helper: umul8 + round-to-nearest + udiv16_8 (tail-call).
; Input: A = |dy| (u8), zp_mul_b = offset (u8), zp_div_den set.
; Output: A = quotient (u8). Product always positive.
.umul_round_div
{
    JSR umul8
    LDA zp_div_den : LSR A
    CLC : ADC zp_prod_lo : STA zp_prod_lo
    LDA zp_prod_hi : ADC #0 : STA zp_prod_hi
    JMP udiv16_8                                                        ; tail-call
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
    ; Invalidate the has_gap coherence cache: this entry frees/merges
    ; slots, and a stale cached slot's leftover XSTART/XEND can overlap
    ; any later query (observed: freed slot (60,69) made has_gap(60,73)
    ; return 1 against a pool whose only live span was (121,132)).
    LDA #0 : STA zp_hg_cache
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
    LDA POOL_DEN,Y  : STA POOL_DEN,X                                    ; |
    LDA POOL_TL,Y   : STA POOL_TL,X                                     ; |
    LDA POOL_BL,Y   : STA POOL_BL,X                                     ; |
    LDA POOL_TR,Y   : STA POOL_TR,X                                     ; |
    LDA POOL_BR,Y   : STA POOL_BR,X                                     ; |
    LDA POOL_OT,Y   : STA POOL_OT,X                                     ; |
    LDA POOL_OB,Y   : STA POOL_OB,X                                     ; |
    LDA POOL_IT,Y   : STA POOL_IT,X                                     ; |
    LDA POOL_IB,Y   : STA POOL_IB,X                                     ; |
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
    STX zp_prev : LDY POOL_NEXT,X : BEQ ms_rts_ms : JMP msl_y            ; |
.ms_rts_ms RTS

.ms_left_only_after_fail
    ; alloc failed → fall through and just truncate left fragment
    LDX zp_prev
.ms_left_only
    ; xend = ilo - 1 (truncate to left fragment only)
    LDA zp_ilo : SEC : SBC #1 : STA POOL_XEND,X                         ; |
    STX zp_prev : LDY POOL_NEXT,X : BEQ ms_rts_ml : JMP msl_y            ; |
.ms_rts_ml RTS

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
    CLC : ADC POOL_DEN,X : STA (zp_buf),Y : INY       ; xhi = xlo + den
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
    ; Invalidate the has_gap coherence cache (pool slots are about to be
    ; rebuilt/freed — see span_mark_solid note).
    LDA #0 : STA zp_hg_cache
    LDA zp_ihi : CMP zp_ilo : BCS tg_go    ; ihi >= ilo: valid range    ; |
    RTS
.tg_go
    ; Save old head, then start building new list
    LDA zp_head : STA zp_old_cur                                        ; |
    LDA #0 : STA zp_new_tail : STA zp_head                                ; |
    ; NOTE: do NOT reset LINE_OUT_COUNT here — draw_clipped_line may
    ; have already written lines to the buffer before tighten was called.
    ; The buffer is append-only; the rasteriser is called immediately
    ; for each line, so the buffer is just a log for verification.
    LDA #$FF : STA zp_cache_ox1  ; invalidate seg value cache            ; |
    STA zp_tg_cont               ; invalidate portal continuation        ; |
    LDA #0   : STA zp_pre_dom_flags  ; pre-dom flags: clear at tighten entry
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
    ; OT >= seg_top_max (equiv. min(tl,tr) >= seg_top_max)
    ; seg_bot_min >= OB (equiv. seg_bot_min >= max(bl,br))
    LDA POOL_OT,X : CMP zp_bb_yt_max : BCC tg_not_old_bb                ; |
    ; Top passed. Check bot: seg_bot_min >= OB.
    LDA zp_bb_yb_min                                                     ; |
    CMP POOL_OB,X : BCC tg_not_old_bb                                   ; |
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
    ; Top: IT < bb_yt_max
    LDA POOL_IT,X : CMP zp_bb_yt_max : BCS tg_no_cont  ; IT >= seg_top → fail
    ; Bot: IB > bb_yb_min (strict)
    LDA POOL_IB,X : CMP zp_bb_yb_min : BCC tg_no_cont  ; IB < seg_bot → fail
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
    ; Check: min(yt1,yt2) > IT (strict: new top inside aperture)
    LDA zp_yt1 : CMP zp_yt2 : BCC tg_nd_tmin : LDA zp_yt2               ; |
.tg_nd_tmin
    CMP POOL_IT,X : BCC tg_bb_skip : BEQ tg_bb_skip                     ; |
    ; Check: IB > max(yb1,yb2) (strict: new bot inside aperture)
    LDA zp_yb1 : CMP zp_yb2 : BCS tg_nd_bmax : LDA zp_yb2               ; |
.tg_nd_bmax
    STA zp_tmp0                                                          ; |
    LDA POOL_IB,X : CMP zp_tmp0 : BCC tg_bb_skip : BEQ tg_bb_skip       ; |
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
    LDA zp_ox1 : SEC : SBC zp_ox0 : CMP POOL_DEN,X : BNE old_not_anchor ; |
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
    ; Hoisted den setup: den from precomputed POOL_DEN, shared by all 4 calls.
    ; (The anchor fast path above guards 1-pixel spans, so den > 0.)
    STA zp_i_y0                                                          ; |
    LDA POOL_XLO,X : STA zp_i_x0                                        ; |
    LDA POOL_DEN,X : STA zp_div_den                 ; |
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
    ; Use Y_BIAS/VIS_YMAX as sentinels so results stay in visible range
    ; (avoids SBC #Y_BIAS underflow in edge emission rasteriser writes).
    LDA #Y_BIAS : STA zp_ot_l : STA zp_ot_r                             ; |
    LDA #VIS_YMAX : STA zp_ob_l : STA zp_ob_r                           ; |
    STX zp_save1                                                         ; |
    LDA #0 : STA zp_pre_dom_flags    ; clear so tg_pod_skip uses normal path
    JMP tg_pod_skip   ; skip post-old-interp check (dummy values always fail it)
.old_done
    ; --- Post-old-interp dominance check (extended for one-sided dom) ---
    ; Uses interpolated ot_l/r and ob_l/r at (ox0, ox1) — more precise than
    ; tier-1 BB. Three-way fork:
    ;   both top and bot dominate → full old-dom shortcut (link span unchanged)
    ;   only top dominates       → set zp_nt_l/r = 0 sentinels, skip top NEW interp
    ;   only bot dominates       → set zp_nb_l/r = $FF sentinels, skip bot NEW interp
    ;   neither dominates        → fall through to tg_pod_skip (full interp)
    LDA #0 : STA zp_pre_dom_flags
    LDA zp_ot_l : CMP zp_bb_yt_max : BCC tg_top_no_dom
    LDA zp_ot_r : CMP zp_bb_yt_max : BCC tg_top_no_dom
    ; Top dominates. Check bot.
    LDA zp_bb_yb_min : CMP zp_ob_l : BCC tg_top_only_dom
    CMP zp_ob_r : BCC tg_top_only_dom
    ; Both dominate — full old-dom shortcut (existing path).
    LDA #$FF : STA zp_tg_cont
    LDX zp_save1                                                         ; |
    LDA #0 : STA POOL_NEXT,X                                             ; |
    LDY zp_new_tail : BEQ tg_pod_first                                  ; |
    TXA : STA POOL_NEXT,Y                                               ; |
    STX zp_new_tail : JMP tg_walk                                       ; |
.tg_pod_first STX zp_head : STX zp_new_tail : JMP tg_walk               ; |
.tg_top_only_dom
    ; Top dominates, bot doesn't. Set top sentinels: nt_l/r=0 + hi=0 →
    ; max(ot,0)=ot, no top crossover (signs uniform), c_tl=clamp(0)=Y_BIAS<=ot_l.
    LDA #0 : STA zp_nt_l : STA zp_nt_r : STA zp_nt_lh : STA zp_nt_rh
    LDA #$01 : STA zp_pre_dom_flags
    JMP tg_pod_skip
.tg_top_no_dom
    ; Top doesn't dominate. Check bot dominance alone.
    LDA zp_bb_yb_min : CMP zp_ob_l : BCC tg_pod_skip                    ; |
    CMP zp_ob_r : BCC tg_pod_skip                                       ; |
    ; Bot only dom. Set bot sentinels: nb_l/r=$FF + hi=0 →
    ; min(ob,$FF)=ob, no bot crossover, c_bl=clamp($FF)=VIS_YMAX>=ob_l.
    LDA #$FF : STA zp_nb_l : STA zp_nb_r
    LDA #0 : STA zp_nb_lh : STA zp_nb_rh
    LDA #$02 : STA zp_pre_dom_flags
    ; fall through to tg_pod_skip
.tg_pod_skip
    ; If pre-dom fired, bypass cache + anchor + constant fast paths (which
    ; would overwrite our sentinels) and go directly to the gated slow path.
    ; Branch out of range — trampoline through JMP.
    LDA zp_pre_dom_flags : BEQ tg_pod_skip_normal
    JMP new_slow_gated
.tg_pod_skip_normal
    ; ---------- NEW seg: cache check for left-endpoint reuse -----------
    LDA zp_ox0 : CMP zp_cache_ox1 : BNE new_no_cache
    ; Cache hit: reuse left-endpoint seg values from previous span
    LDA zp_cache_nt : STA zp_nt_l
    LDA zp_cache_nb : STA zp_nb_l
    LDA #0 : STA zp_nt_lh : STA zp_nb_lh                                ; | hi bytes = 0
    JMP new_right_only
.new_no_cache
    ; ---------- NEW seg: fast path when (ox0,ox1) == (sx1,sx2) -----------
    LDA zp_ox0 : CMP zp_sx1 : BNE new_not_anchor                        ; |
    LDA zp_ox1 : CMP zp_sx2 : BNE new_not_anchor                        ; |
    ; Copy seg's u8 anchor values verbatim
    LDA zp_yt1  : STA zp_nt_l                                           ; |
    LDA zp_yt2  : STA zp_nt_r                                           ; |
    LDA zp_yb1  : STA zp_nb_l                                           ; |
    LDA zp_yb2  : STA zp_nb_r                                           ; |
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh : STA zp_nb_lh : STA zp_nb_rh ; | hi bytes = 0
    JMP new_done                                                        ; |
.new_not_anchor
    ; --- Constant-line NEW seg fast path: yt1==yt2 AND yb1==yb2 (u8) ---
    LDA zp_yt1 : CMP zp_yt2 : BNE new_slow                              ; |
    LDA zp_yb1 : CMP zp_yb2 : BNE new_slow                              ; |
    ; Constant line: both endpoints identical.
    LDA zp_yt1  : STA zp_nt_l  : STA zp_nt_r                            ; |
    LDA zp_yb1  : STA zp_nb_l  : STA zp_nb_r                            ; |
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh : STA zp_nb_lh : STA zp_nb_rh ; | hi bytes = 0
    JMP new_done                                                        ; |
.new_slow
    ; Hoisted den setup: den = sx2 - sx1. Guaranteed > 0 by remap.
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den                      ; |
    LDA zp_sx1 : STA zp_i_x0                                             ; |
    ; Top: y0 = yt1 (u8 with Y_BIAS), y1 = yt2
    LDA zp_yt1 : STA zp_i_y0                                             ; |
    LDA zp_yt2 : STA zp_i_y1                                             ; |
    LDA zp_ox0 : JSR interp_store : STA zp_nt_l                         ; ||
    LDA zp_ox1 : JSR interp_store : STA zp_nt_r                         ; ||
    ; Bot: y0 = yb1 (u8), y1 = yb2
    LDA zp_yb1 : STA zp_i_y0                                             ; |
    LDA zp_yb2 : STA zp_i_y1                                             ; |
    LDA zp_ox0 : JSR interp_store : STA zp_nb_l                         ; ||
    LDA zp_ox1 : JSR interp_store : STA zp_nb_r                         ; ||
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh : STA zp_nb_lh : STA zp_nb_rh ; | hi bytes = 0
    JMP new_done                                                         ; |
.new_slow_gated
    ; Pre-dom path: top OR bot interp gated on zp_pre_dom_flags. The
    ; dominated side has its nt_l/r (top) or nb_l/r (bot) preset to
    ; sentinels (0 or $FF) by the post-old-interp dom check, plus its
    ; hi bytes set to 0. Compute only the non-dominated side.
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den                      ; |
    LDA zp_sx1 : STA zp_i_x0                                             ; |
    ; Top: skip if zp_pre_dom_flags & $01 (top dominated)
    LDA zp_pre_dom_flags : AND #$01 : BNE nsg_skip_top
    LDA zp_yt1 : STA zp_i_y0                                             ; |
    LDA zp_yt2 : STA zp_i_y1                                             ; |
    LDA zp_ox0 : JSR interp_store : STA zp_nt_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_nt_r                         ; |
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh                                 ; |
.nsg_skip_top
    ; Bot: skip if zp_pre_dom_flags & $02 (bot dominated)
    LDA zp_pre_dom_flags : AND #$02 : BNE nsg_skip_bot
    LDA zp_yb1 : STA zp_i_y0                                             ; |
    LDA zp_yb2 : STA zp_i_y1                                             ; |
    LDA zp_ox0 : JSR interp_store : STA zp_nb_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_nb_r                         ; |
    LDA #0 : STA zp_nb_lh : STA zp_nb_rh                                 ; |
.nsg_skip_bot
    JMP new_done                                                         ; |
.new_right_only
    ; Cache hit: left-endpoint seg values already set. Compute right only.
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den                      ; |
    LDA zp_sx1 : STA zp_i_x0                                             ; |
    LDA zp_yt1 : STA zp_i_y0                                             ; |
    LDA zp_yt2 : STA zp_i_y1                                             ; |
    LDA zp_ox1 : JSR interp_store : STA zp_nt_r                         ; ||
    LDA zp_yb1 : STA zp_i_y0                                             ; |
    LDA zp_yb2 : STA zp_i_y1                                             ; |
    LDA zp_ox1 : JSR interp_store : STA zp_nb_r                         ; ||
    LDA #0 : STA zp_nt_rh : STA zp_nb_rh                                ; | hi bytes = 0
.new_done
    ; Cache right-endpoint seg values for reuse by next contiguous span.
    ; If pre-dom fired (one or both sides hold sentinel values that would
    ; corrupt the next span's left endpoint reuse), invalidate cache_ox1
    ; AND set cache_nt/nb to off-screen sentinel ($FF) so the running
    ; seg bound narrowing code below skips this span (its CMP #(VIS_YMAX+1)
    ; check rejects $FF as off-screen).
    LDA zp_pre_dom_flags : BNE new_done_invalidate_cache
    LDA zp_nt_r : STA zp_cache_nt
    LDA zp_nb_r : STA zp_cache_nb
    LDA zp_ox1 : STA zp_cache_ox1
    JMP new_done_cache_done
.new_done_invalidate_cache
    LDA #$FF : STA zp_cache_ox1 : STA zp_cache_nt : STA zp_cache_nb
.new_done_cache_done
    ; Set portal continuation: record span's xend for contiguity check
    LDX zp_save1 : LDA POOL_XEND,X : STA zp_tg_cont
    ; --- Narrow running seg bounds using cached right-edge seg values ---
    ; Only narrow when all-on-screen (bb_flags=$40); cached must be on-screen.
    LDA zp_bb_flags : BEQ tg_nd_skip                                    ; |
    ; Narrow top: seg_top_max = max(cached_nt, yt2)
    LDA zp_cache_nt : CMP #(VIS_YMAX + 1) : BCS tg_nd_top_skip          ; |
    CMP zp_yt2 : BCS tg_nd_top_ok : LDA zp_yt2                          ; |
.tg_nd_top_ok STA zp_bb_yt_max                                          ; |
.tg_nd_top_skip
    ; Narrow bot: seg_bot_min = min(cached_nb, yb2)
    LDA zp_cache_nb : CMP #(VIS_YMAX + 1) : BCS tg_nd_skip              ; |
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

    ; --- Clamp new s16 values for dominance check ---
    ; With Y_BIAS, all values reaching here are u8 (hi bytes = 0).
    ; Skip clamping when all hi bytes are zero.
    LDA zp_nt_lh : ORA zp_nt_rh : ORA zp_nb_lh : ORA zp_nb_rh           ; |
    BEQ tg_clamp_done                                                    ; | all u8 → no clamp
; (2-byte clamp pad removed)
.tg_clamp_slow
    ; Fast path: if both top hi bytes are negative, clamp tops to 0 and skip
    ; to clamping only the bot values.
    LDA zp_nt_lh : AND zp_nt_rh : BPL tg_clamp_full
    LDA #0 : STA zp_nt_l : STA zp_nt_r
    ; hi bytes already nonzero (negative) → no need to set them
    JMP tg_clamp_nb
.tg_clamp_full
    ; High byte: negative→0, positive overflow (hi>0)→VIS_YMAX, 0→check low
    ; byte (in [0,255], clamp [VIS_YMAX+1,255] to VIS_YMAX).
    ; When clamping occurs, set hi byte to nonzero so edge emission guard fires.
    LDA zp_nt_lh : BMI tg_cn1z : BNE tg_cn1f
    LDA zp_nt_l : CMP #(VIS_YMAX + 1) : BCC tg_cn1s
    LDA #1 : STA zp_nt_lh                                               ; mark clamped
.tg_cn1f LDA #VIS_YMAX : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cn1z LDA #0
.tg_cn1s STA zp_nt_l                                                    ; |
    LDA zp_nt_rh : BMI tg_cn2z : BNE tg_cn2f
    LDA zp_nt_r : CMP #(VIS_YMAX + 1) : BCC tg_cn2s
    LDA #1 : STA zp_nt_rh                                               ; mark clamped
.tg_cn2f LDA #VIS_YMAX : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cn2z LDA #0
.tg_cn2s STA zp_nt_r                                                    ; |
.tg_clamp_nb
    LDA zp_nb_lh : BMI tg_cn3z : BNE tg_cn3f
    LDA zp_nb_l : CMP #(VIS_YMAX + 1) : BCC tg_cn3s
    LDA #1 : STA zp_nb_lh                                               ; mark clamped
.tg_cn3f LDA #VIS_YMAX : EQUB $2C  ; BIT abs: skip LDA #0
.tg_cn3z LDA #0
.tg_cn3s STA zp_nb_l                                                    ; |
    LDA zp_nb_rh : BMI tg_cn4z : BNE tg_cn4f
    LDA zp_nb_r : CMP #(VIS_YMAX + 1) : BCC tg_cn4s
    LDA #1 : STA zp_nb_rh                                               ; mark clamped
.tg_cn4f LDA #VIS_YMAX : EQUB $2C  ; BIT abs: skip LDA #0
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
    LDA POOL_DEN,Y    : STA POOL_DEN,X                                  ; |
    LDA POOL_TL,Y     : STA POOL_TL,X                                   ; |
    LDA POOL_BL,Y     : STA POOL_BL,X                                   ; |
    LDA POOL_TR,Y     : STA POOL_TR,X                                   ; |
    LDA POOL_BR,Y     : STA POOL_BR,X                                   ; |
    LDA POOL_OT,Y     : STA POOL_OT,X                                   ; |
    LDA POOL_OB,Y     : STA POOL_OB,X                                   ; |
    LDA POOL_IT,Y     : STA POOL_IT,X                                   ; |
    LDA POOL_IB,Y     : STA POOL_IB,X                                   ; |
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
    ; Primary emission removed — DCL handles all line emission via the
    ; wrapper's draw_clipped forward.  (See 2026-05-01 attempt at
    ; combined draw-and-tighten — abandoned due to Bresenham
    ; per-segment vs whole-line rasteriser pixel mismatch.)
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
    LDA zp_ox1 : STA POOL_XEND,X                                        ; |
    SEC : SBC zp_ox0 : STA POOL_DEN,X                                   ; | den = ox1 - ox0
    LDA zp_ot_l : STA POOL_TL,X : LDA zp_ob_l : STA POOL_BL,X           ; |
    LDA zp_ot_r : STA POOL_TR,X : LDA zp_ob_r : STA POOL_BR,X           ; |
    ; OT = min(zp_ot_l, zp_ot_r)
    LDA zp_ot_l : CMP zp_ot_r : BCC ncf_ot_ok : LDA zp_ot_r
.ncf_ot_ok STA POOL_OT,X
    ; OB = max(zp_ob_l, zp_ob_r)
    LDA zp_ob_l : CMP zp_ob_r : BCS ncf_ob_ok : LDA zp_ob_r
.ncf_ob_ok STA POOL_OB,X
    ; IT = max(zp_ot_l, zp_ot_r)
    LDA zp_ot_l : CMP zp_ot_r : BCS ncf_it_ok : LDA zp_ot_r
.ncf_it_ok STA POOL_IT,X
    ; IB = min(zp_ob_l, zp_ob_r)
    LDA zp_ob_l : CMP zp_ob_r : BCC ncf_ib_ok : LDA zp_ob_r
.ncf_ib_ok STA POOL_IB,X
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
    ; 3 sharing intervals: [ox0, cx_top], [cx_top, cx_bot], [cx_bot, final_ox1]
    LDA zp_cx_top : STA zp_ox1
    JSR tg_overlap_sub
    LDA zp_cx_top : STA zp_ox0
    LDA zp_cx_bot : STA zp_ox1
    JSR tg_overlap_sub
    LDA zp_cx_bot : STA zp_ox0
    LDA zp_final_ox1 : STA zp_ox1
    JSR tg_overlap_sub : JMP tg_right_frag
.tg_split_top
    LDA zp_cx_top : JMP tg_split_one
.tg_split_bot
    LDA zp_cx_bot                                                       ; |
.tg_split_one
    ; A = single crossover X. 2 sharing intervals: [ox0, cx], [cx, final_ox1]
    STA zp_tmp3                    ; save cx                             ; |
    STA zp_ox1                     ; left sub-interval ends AT cx (shared)  ; |
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
    LDA POOL_DEN,Y  : STA POOL_DEN,X                                    ; |
    LDA POOL_TL,Y   : STA POOL_TL,X                                     ; |
    LDA POOL_BL,Y   : STA POOL_BL,X                                     ; |
    LDA POOL_TR,Y   : STA POOL_TR,X                                     ; |
    LDA POOL_BR,Y   : STA POOL_BR,X                                     ; |
    LDA POOL_OT,Y   : STA POOL_OT,X                                     ; |
    LDA POOL_OB,Y   : STA POOL_OB,X                                     ; |
    LDA POOL_IT,Y   : STA POOL_IT,X                                     ; |
    LDA POOL_IB,Y   : STA POOL_IB,X                                     ; |
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
    LDA POOL_DEN,X : STA zp_div_den                 ; |
    LDA POOL_TR,X : STA zp_i_y1                                          ; |
    LDA zp_ox0 : JSR interp_store : STA zp_ot_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_ot_r                         ; |
    LDX zp_save1                                                        ; |
    LDA POOL_BL,X : STA zp_i_y0 : LDA POOL_BR,X : STA zp_i_y1           ; |
    LDA zp_ox0 : JSR interp_store : STA zp_ob_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_ob_r                         ; |
.tos_old_done
    ; --- New seg: constant-line fast path or 4 interp_store calls (u8) ---
    LDA zp_yt1 : CMP zp_yt2 : BNE tos_new_slow                          ; |
    LDA zp_yb1 : CMP zp_yb2 : BNE tos_new_slow                          ; |
    ; Constant line: both endpoints identical.
    LDA zp_yt1  : STA zp_nt_l  : STA zp_nt_r                            ; |
    LDA zp_yb1  : STA zp_nb_l  : STA zp_nb_r                            ; |
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh : STA zp_nb_lh : STA zp_nb_rh ; | hi bytes = 0
    JMP tos_new_done                                                    ; |
.tos_new_slow
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den                      ; |
    LDA zp_sx1 : STA zp_i_x0                                             ; |
    LDA zp_yt1 : STA zp_i_y0                                             ; |
    LDA zp_yt2 : STA zp_i_y1                                             ; |
    LDA zp_ox0 : JSR interp_store : STA zp_nt_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_nt_r                         ; |
    LDA zp_yb1 : STA zp_i_y0                                             ; |
    LDA zp_yb2 : STA zp_i_y1                                             ; |
    LDA zp_ox0 : JSR interp_store : STA zp_nb_l                         ; |
    LDA zp_ox1 : JSR interp_store : STA zp_nb_r                         ; |
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh : STA zp_nb_lh : STA zp_nb_rh ; | hi bytes = 0
.tos_new_done
    ; Clamp s16 new values for dominance check.
    ; With Y_BIAS, all values are u8 (hi bytes = 0). Skip clamping.
    LDA zp_nt_lh : ORA zp_nt_rh : ORA zp_nb_lh : ORA zp_nb_rh           ; |
    BEQ tos_clamp_done                                                   ; | all u8 → no clamp
.tos_clamp_slow
    LDA zp_nt_lh : BMI cn1z : BNE cn1f
    LDA zp_nt_l : CMP #(VIS_YMAX + 1) : BCC cn1s
    LDA #1 : STA zp_nt_lh                                               ; mark clamped
.cn1f LDA #VIS_YMAX : EQUB $2C  ; BIT abs: skip LDA #0
.cn1z LDA #0
.cn1s STA zp_nt_l                                                       ; |
    LDA zp_nt_rh : BMI cn2z : BNE cn2f
    LDA zp_nt_r : CMP #(VIS_YMAX + 1) : BCC cn2s
    LDA #1 : STA zp_nt_rh                                               ; mark clamped
.cn2f LDA #VIS_YMAX : EQUB $2C  ; BIT abs: skip LDA #0
.cn2z LDA #0
.cn2s STA zp_nt_r                                                       ; |
    LDA zp_nb_lh : BMI cn3z : BNE cn3f
    LDA zp_nb_l : CMP #(VIS_YMAX + 1) : BCC cn3s
    LDA #1 : STA zp_nb_lh                                               ; mark clamped
.cn3f LDA #VIS_YMAX : EQUB $2C  ; BIT abs: skip LDA #0
.cn3z LDA #0
.cn3s STA zp_nb_l                                                       ; |
    LDA zp_nb_rh : BMI cn4z : BNE cn4f
    LDA zp_nb_r : CMP #(VIS_YMAX + 1) : BCC cn4s
    LDA #1 : STA zp_nb_rh                                               ; mark clamped
.cn4f LDA #VIS_YMAX : EQUB $2C  ; BIT abs: skip LDA #0
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
    LDA POOL_DEN,Y    : STA POOL_DEN,X                                  ; |
    LDA POOL_TL,Y     : STA POOL_TL,X                                   ; |
    LDA POOL_BL,Y     : STA POOL_BL,X                                   ; |
    LDA POOL_TR,Y     : STA POOL_TR,X                                   ; |
    LDA POOL_BR,Y     : STA POOL_BR,X                                   ; |
    LDA POOL_OT,Y     : STA POOL_OT,X                                   ; |
    LDA POOL_OB,Y     : STA POOL_OB,X                                   ; |
    LDA POOL_IT,Y     : STA POOL_IT,X                                   ; |
    LDA POOL_IB,Y     : STA POOL_IB,X                                   ; |
    LDA zp_ox0 : STA POOL_XSTART,X                                      ; |
    LDA zp_ox1 : STA POOL_XEND,X                                        ; |
    JMP tg_append_x                                                     ; | tail-call (saves 3 cyc)
.opt2_no_ap
    RTS                                                                 ; |
.skip_opt2
IF EMIT_LINES
    ; Primary emission removed — DCL handles all line emission.
ENDIF
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
    LDA zp_ox1 : STA POOL_XEND,X                                        ; |
    SEC : SBC zp_ox0 : STA POOL_DEN,X                                   ; | den = ox1 - ox0
    LDA zp_ot_l : STA POOL_TL,X : LDA zp_ob_l : STA POOL_BL,X           ; |
    LDA zp_ot_r : STA POOL_TR,X : LDA zp_ob_r : STA POOL_BR,X           ; |
    ; OT = min(zp_ot_l, zp_ot_r)
    LDA zp_ot_l : CMP zp_ot_r : BCC tos_ot_ok : LDA zp_ot_r
.tos_ot_ok STA POOL_OT,X
    ; OB = max(zp_ob_l, zp_ob_r)
    LDA zp_ob_l : CMP zp_ob_r : BCS tos_ob_ok : LDA zp_ob_r
.tos_ob_ok STA POOL_OB,X
    ; IT = max(zp_ot_l, zp_ot_r)
    LDA zp_ot_l : CMP zp_ot_r : BCS tos_it_ok : LDA zp_ot_r
.tos_it_ok STA POOL_IT,X
    ; IB = min(zp_ob_l, zp_ob_r)
    LDA zp_ob_l : CMP zp_ob_r : BCC tos_ib_ok : LDA zp_ob_r
.tos_ib_ok STA POOL_IB,X
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
    ; NOTE: do NOT reset LINE_OUT_COUNT — draw_clipped_line may have
    ; already written lines before mark_solid was called.

    ; --- DCL-style seg Y bbox setup (one-time per mel call) ---
    ; Compute static seg bbox (max/min of yt1/yt2 and yb1/yb2) for the
    ; per-span "neither edge can emit" reject below.  Sentinels disable
    ; the check when:
    ;   - any yt/yb hi byte is non-zero (seg extends off-screen in u8)
    ;   - [sx1,sx2] doesn't cover [ilo,ihi] (overlap extrapolation
    ;     would invalidate the bbox bounds derived from yt1/yt2)
    LDA zp_yt1h : ORA zp_yt2h : ORA zp_yb1h : ORA zp_yb2h
    BNE mel_bbox_disable
    ; sx1 must be <= ilo (no left extrapolation).  sx1 negative covers
    ; this trivially; sx1 with hi=0 needs sx1 <= ilo.
    LDA zp_sx1h : BMI mel_bbox_sx1_ok
    BNE mel_bbox_disable                               ; sx1 > 255 → impossible
    LDA zp_ilo : CMP zp_sx1 : BCC mel_bbox_disable     ; ilo < sx1 → extrap
.mel_bbox_sx1_ok
    ; sx2 must be >= ihi (no right extrapolation).
    LDA zp_sx2h : BMI mel_bbox_disable                 ; sx2 < 0 → impossible
    BNE mel_bbox_valid                                  ; sx2 > 255 ≥ ihi → ok
    LDA zp_sx2 : CMP zp_ihi : BCC mel_bbox_disable     ; sx2 < ihi → extrap
.mel_bbox_valid
    ; All hi bytes zero AND seg covers overlap — compute real bbox.
    LDA zp_yt1 : CMP zp_yt2 : BCC mel_bbox_t_swap
    STA zp_seg_top_max : LDX zp_yt2 : STX zp_seg_top_min
    BCS mel_bbox_t_done                              ; always taken
.mel_bbox_t_swap
    STA zp_seg_top_min : LDX zp_yt2 : STX zp_seg_top_max
.mel_bbox_t_done
    LDA zp_yb1 : CMP zp_yb2 : BCC mel_bbox_b_swap
    STA zp_seg_bot_max : LDX zp_yb2 : STX zp_seg_bot_min
    BCS mel_bbox_done                                ; always taken
.mel_bbox_b_swap
    STA zp_seg_bot_min : LDX zp_yb2 : STX zp_seg_bot_max
    BCC mel_bbox_done                                ; always taken
.mel_bbox_disable
    LDA #$FF : STA zp_seg_top_max : STA zp_seg_bot_max
    LDA #$00 : STA zp_seg_top_min : STA zp_seg_bot_min
.mel_bbox_done

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

    ; --- DCL-style per-span bbox reject ---
    ; Skip span entirely if neither top nor bot edge can emit anywhere
    ; in this span.  Saves all 8 interp_store calls + emission tree.
    ;   no top emit: seg_top_max <= POOL_OT  OR  seg_top_min >= POOL_OB
    ;   no bot emit: seg_bot_max <= POOL_OT  OR  seg_bot_min >= POOL_OB
    ; "Skip span" requires BOTH no-top AND no-bot.
    LDA POOL_OT,X : CMP zp_seg_top_max : BCS mel_top_no_emit  ; OT >= top_max
    LDA zp_seg_top_min : CMP POOL_OB,X : BCS mel_top_no_emit  ; top_min >= OB
    JMP mel_span_check_done                                   ; top can emit
.mel_top_no_emit
    LDA POOL_OT,X : CMP zp_seg_bot_max : BCS mel_skip_span    ; OT >= bot_max
    LDA zp_seg_bot_min : CMP POOL_OB,X : BCS mel_skip_span    ; bot_min >= OB
    JMP mel_span_check_done                                   ; bot can emit
.mel_skip_span
    JMP mel_next
.mel_span_check_done

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
    LDA zp_save2 : SEC : SBC zp_save1 : CMP POOL_DEN,X : BNE mel_span_interp
    LDA POOL_TL,X : STA zp_ot_l : LDA POOL_TR,X : STA zp_ot_r
    LDA POOL_BL,X : STA zp_ob_l : LDA POOL_BR,X : STA zp_ob_r
    JMP mel_span_done
.mel_span_interp
    ; Full interp: den = xhi - xlo
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_DEN,X : STA zp_div_den
    LDA POOL_TL,X : STA zp_i_y0 : LDA POOL_TR,X : STA zp_i_y1
    LDA zp_save1 : JSR interp_store : STA zp_ot_l
    LDA zp_save2 : JSR interp_store : STA zp_ot_r
    LDX zp_save0
    LDA POOL_BL,X : STA zp_i_y0 : LDA POOL_BR,X : STA zp_i_y1
    LDA zp_save1 : JSR interp_store : STA zp_ob_l
    LDA zp_save2 : JSR interp_store : STA zp_ob_r
.mel_span_done

    ; --- Evaluate seg top/bot at ox0 and ox1 (u8 with Y_BIAS) ---
    ; Constant-line fast path: yt1==yt2 AND yb1==yb2
    LDA zp_yt1 : CMP zp_yt2 : BNE mel_seg_slow
    LDA zp_yb1 : CMP zp_yb2 : BNE mel_seg_slow
    LDA zp_yt1  : STA zp_nt_l  : STA zp_nt_r
    LDA zp_yb1  : STA zp_nb_l  : STA zp_nb_r
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh : STA zp_nb_lh : STA zp_nb_rh ; | hi = 0
    JMP mel_seg_done
.mel_seg_slow
    ; Anchor fast path: if ox0==sx1 and ox1==sx2
    LDA zp_save1 : CMP zp_sx1 : BNE mel_seg_interp
    LDA zp_save2 : CMP zp_sx2 : BNE mel_seg_interp
    LDA zp_yt1  : STA zp_nt_l  : LDA zp_yt2  : STA zp_nt_r
    LDA zp_yb1  : STA zp_nb_l  : LDA zp_yb2  : STA zp_nb_r
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh : STA zp_nb_lh : STA zp_nb_rh ; | hi = 0
    JMP mel_seg_done
.mel_seg_interp
    ; Full interp (u8 via interp_store)
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den
    LDA zp_sx1 : STA zp_i_x0
    LDA zp_yt1 : STA zp_i_y0
    LDA zp_yt2 : STA zp_i_y1
    LDA zp_save1 : JSR interp_store : STA zp_nt_l
    LDA zp_save2 : JSR interp_store : STA zp_nt_r
    LDA zp_yb1 : STA zp_i_y0
    LDA zp_yb2 : STA zp_i_y1
    LDA zp_save1 : JSR interp_store : STA zp_nb_l
    LDA zp_save2 : JSR interp_store : STA zp_nb_r
    LDA #0 : STA zp_nt_lh : STA zp_nt_rh : STA zp_nb_lh : STA zp_nb_rh ; | hi = 0
.mel_seg_done

    ; --- Clamp seg values for dominance ---
    ; With Y_BIAS, all values are u8 (hi bytes = 0). Skip clamping.
    LDA zp_nt_lh : ORA zp_nt_rh : ORA zp_nb_lh : ORA zp_nb_rh
    BEQ mel_clamp_ok
.mel_clamp_slow
    LDA zp_nt_lh : BMI mel_cz1 : BNE mel_cf1
    LDA zp_nt_l : CMP #(VIS_YMAX + 1) : BCC mel_cs1
    LDA #1 : STA zp_nt_lh                                               ; mark clamped
.mel_cf1 LDA #VIS_YMAX : EQUB $2C
.mel_cz1 LDA #0
.mel_cs1 STA zp_nt_l
    LDA zp_nt_rh : BMI mel_cz2 : BNE mel_cf2
    LDA zp_nt_r : CMP #(VIS_YMAX + 1) : BCC mel_cs2
    LDA #1 : STA zp_nt_rh                                               ; mark clamped
.mel_cf2 LDA #VIS_YMAX : EQUB $2C
.mel_cz2 LDA #0
.mel_cs2 STA zp_nt_r
    LDA zp_nb_lh : BMI mel_cz3 : BNE mel_cf3
    LDA zp_nb_l : CMP #(VIS_YMAX + 1) : BCC mel_cs3
    LDA #1 : STA zp_nb_lh                                               ; mark clamped
.mel_cf3 LDA #VIS_YMAX : EQUB $2C
.mel_cz3 LDA #0
.mel_cs3 STA zp_nb_l
    LDA zp_nb_rh : BMI mel_cz4 : BNE mel_cf4
    LDA zp_nb_r : CMP #(VIS_YMAX + 1) : BCC mel_cs4
    LDA #1 : STA zp_nb_rh                                               ; mark clamped
.mel_cf4 LDA #VIS_YMAX : EQUB $2C
.mel_cz4 LDA #0
.mel_cs4 STA zp_nb_r
.mel_clamp_ok

    ; --- Emit visible edges ---
    ; The wall's top/bot edge must be INSIDE the span's aperture [ot, ob]
    ; to be visible. We handle four cases at each edge:
    ;   both endpoints inside aperture → emit full line
    ;   left inside, right outside       → clip right at crossover
    ;   left outside, right inside       → clip left at crossover
    ;   both outside                     → skip
    ; "Outside" for top edge means nt < ot (line above span top) or
    ; nt > ob (line below span bot). For bot: nb < ot or nb > ob.
    ; At present we only check the "primary" boundary (nt vs ot for top,
    ; nb vs ob for bot) — the "line outside on the other side" case is
    ; rare and not yet handled; it would require a second crossover.
    ; Guard: skip emission for single-column overlaps (degenerate point)
    LDA zp_save1 : CMP zp_save2 : BCC mel_emit_any
    JMP mel_no_bot
.mel_emit_any
    ; Top edge: visible where ot < nt (new top below span top, new
    ; covers more of aperture).
    ; Guard: skip if either top endpoint was clamped (hi byte nonzero)
    LDA zp_nt_lh : ORA zp_nt_rh : BEQ mel_top_clamp_ok
    JMP mel_no_top
.mel_top_clamp_ok
    ; Also skip if seg top is below span bot at BOTH endpoints
    ; (entirely below aperture — line can't be visible).
    LDA zp_nt_l : CMP zp_ob_l : BCC mel_top_lok
    LDA zp_nt_r : CMP zp_ob_r : BCC mel_top_lok
    JMP mel_no_top                                     ; both below aperture
.mel_top_lok
    ; Decision tree on left endpoint (nt_l vs ot_l).
    ; For TOP emission, "inside aperture from top" means nt > ot.
    LDA zp_nt_l : CMP zp_ot_l
    BCC mel_top_l_above                              ; nt_l < ot_l (above aperture)
    BEQ mel_top_l_eq                                 ; nt_l == ot_l (at boundary)
    ; nt_l > ot_l: strict inside. Check right.
    LDA zp_nt_r : CMP zp_ot_r
    BCS mel_emit_top_full                            ; nt_r >= ot_r → both in → emit full
    ; nt_r < ot_r → clip right at crossover
    LDA zp_nt_l : SEC : SBC zp_ot_l : STA zp_tmp0    ; |d0| = nt_l - ot_l
    LDA #0                         : STA zp_tmp1
    LDA zp_ot_r : SEC : SBC zp_nt_r : STA zp_tmp2    ; |d1| = ot_r - nt_r
    LDA #0                         : STA zp_tmp3
    JSR mel_emit_top_cross_right
    JMP mel_no_top
.mel_top_l_eq
    ; Left at boundary. Emit only if right strict inside (matches original).
    LDA zp_nt_r : CMP zp_ot_r
    BEQ mel_no_top
    BCC mel_no_top
    JMP mel_emit_top_full
.mel_top_l_above
    ; Left strict outside (above aperture). Check right.
    LDA zp_nt_r : CMP zp_ot_r
    BCC mel_no_top
    BEQ mel_no_top
    ; Left above, right strict inside → clip left at crossover
    LDA zp_ot_l : SEC : SBC zp_nt_l : STA zp_tmp0    ; |d0| = ot_l - nt_l
    LDA #0                         : STA zp_tmp1
    LDA zp_nt_r : SEC : SBC zp_ot_r : STA zp_tmp2    ; |d1| = nt_r - ot_r
    LDA #0                         : STA zp_tmp3
    JSR mel_emit_top_cross_left
    JMP mel_no_top
.mel_emit_top_full
    LDY LINE_OUT_COUNT
    LDA zp_save1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nt_l  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_save2 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nt_r  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JSR RASTER_ENTRY
.mel_no_top
    ; Bot edge: visible where nb < ob.
    ; Guard: skip if either bot endpoint was clamped (hi byte nonzero)
    LDA zp_nb_lh : ORA zp_nb_rh : BEQ mel_bot_clamp_ok
    JMP mel_no_bot
.mel_bot_clamp_ok
    ; Skip if seg bot is above span top at BOTH endpoints (entirely above).
    LDA zp_nb_l : CMP zp_ot_l : BCS mel_bot_lok
    LDA zp_nb_r : CMP zp_ot_r : BCS mel_bot_lok
    JMP mel_no_bot                                     ; both above aperture
.mel_bot_lok
    ; Decision tree on left endpoint (nb_l vs ob_l).
    ; For BOT emission, "inside aperture from bot" means nb < ob.
    LDA zp_nb_l : CMP zp_ob_l
    BCC mel_bot_l_in                                 ; nb_l < ob_l (strict in)
    BEQ mel_bot_l_eq                                 ; nb_l == ob_l (boundary)
    ; nb_l > ob_l: strict outside (below aperture). Check right.
    LDA zp_nb_r : CMP zp_ob_r
    BCS mel_no_bot                                   ; nb_r >= ob_r → both out
    ; nb_r < ob_r → clip left at crossover
    LDA zp_nb_l : SEC : SBC zp_ob_l : STA zp_tmp0    ; |d0| = nb_l - ob_l
    LDA #0                         : STA zp_tmp1
    LDA zp_ob_r : SEC : SBC zp_nb_r : STA zp_tmp2    ; |d1| = ob_r - nb_r
    LDA #0                         : STA zp_tmp3
    JSR mel_emit_bot_cross_left
    JMP mel_no_bot
.mel_bot_l_eq
    ; Left at boundary. Emit only if right strict inside.
    LDA zp_nb_r : CMP zp_ob_r
    BEQ mel_no_bot
    BCS mel_no_bot
    JMP mel_emit_bot_full
.mel_bot_l_in
    ; Left strict inside. Check right.
    LDA zp_nb_r : CMP zp_ob_r
    BCC mel_emit_bot_full                            ; both strict in → emit full
    BEQ mel_emit_bot_full                            ; boundary at right → emit full
    ; nb_r > ob_r → clip right
    LDA zp_ob_l : SEC : SBC zp_nb_l : STA zp_tmp0    ; |d0| = ob_l - nb_l
    LDA #0                         : STA zp_tmp1
    LDA zp_nb_r : SEC : SBC zp_ob_r : STA zp_tmp2    ; |d1| = nb_r - ob_r
    LDA #0                         : STA zp_tmp3
    JSR mel_emit_bot_cross_right
    JMP mel_no_bot
.mel_emit_bot_full
    LDY LINE_OUT_COUNT
    LDA zp_save1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nb_l  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_save2 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nb_r  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
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

; === mel crossover-clip helpers ===
; Each takes |d0| in zp_tmp0:tmp1, |d1| in zp_tmp2:tmp3. Computes the
; crossover X via compute_crossover, then the line Y at that X, then
; emits the clipped line fragment. Uses zp_tmp0/tmp1 as scratch for
; saved cx/cy after compute_crossover returns.

.mel_emit_top_cross_left
    ; Emit (cx, cy) → (save2, nt_r). Line Y uses nt_l→nt_r interp.
    LDA zp_save1 : STA zp_ox0
    LDA zp_save2 : STA zp_ox1
    JSR compute_crossover                ; A = cx
    BNE mel_emit_cx_ok
    RTS                                  ; degenerate (boundary) → skip
.mel_emit_cx_ok
    STA zp_ox0                           ; save cx in ox0 (interp_store preserves it)
    LDA zp_save1 : STA zp_i_x0
    LDA zp_save2 : SEC : SBC zp_save1 : STA zp_div_den
    LDA zp_nt_l : STA zp_i_y0
    LDA zp_nt_r : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store        ; A = cy (clobbers tmp0 via umul8)
    STA zp_ox1                           ; save cy in ox1
    LDY LINE_OUT_COUNT
    LDA zp_ox0   : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_ox1   : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_save2 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nt_r  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY

.mel_emit_top_cross_right
    ; Emit (save1, nt_l) → (cx, cy).
    LDA zp_save1 : STA zp_ox0
    LDA zp_save2 : STA zp_ox1
    JSR compute_crossover
    CMP #0 : BNE mel_ecx_ok_1
    RTS                                  ; degenerate → skip
.mel_ecx_ok_1
    STA zp_ox0                           ; save cx
    LDA zp_save1 : STA zp_i_x0
    LDA zp_save2 : SEC : SBC zp_save1 : STA zp_div_den
    LDA zp_nt_l : STA zp_i_y0
    LDA zp_nt_r : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store
    STA zp_ox1                           ; save cy
    LDY LINE_OUT_COUNT
    LDA zp_save1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nt_l  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox0   : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_ox1   : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY

.mel_emit_bot_cross_left
    ; Emit (cx, cy) → (save2, nb_r).
    LDA zp_save1 : STA zp_ox0
    LDA zp_save2 : STA zp_ox1
    JSR compute_crossover
    CMP #0 : BNE mel_ecx_ok_2
    RTS                                  ; degenerate → skip
.mel_ecx_ok_2
    STA zp_ox0
    LDA zp_save1 : STA zp_i_x0
    LDA zp_save2 : SEC : SBC zp_save1 : STA zp_div_den
    LDA zp_nb_l : STA zp_i_y0
    LDA zp_nb_r : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store
    STA zp_ox1
    LDY LINE_OUT_COUNT
    LDA zp_ox0   : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_ox1   : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_save2 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nb_r  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY

.mel_emit_bot_cross_right
    ; Emit (save1, nb_l) → (cx, cy).
    LDA zp_save1 : STA zp_ox0
    LDA zp_save2 : STA zp_ox1
    JSR compute_crossover
    CMP #0 : BNE mel_ecx_ok_3
    RTS                                  ; degenerate → skip
.mel_ecx_ok_3
    STA zp_ox0
    LDA zp_save1 : STA zp_i_x0
    LDA zp_save2 : SEC : SBC zp_save1 : STA zp_div_den
    LDA zp_nb_l : STA zp_i_y0
    LDA zp_nb_r : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store
    STA zp_ox1
    LDY LINE_OUT_COUNT
    LDA zp_save1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nb_l  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox0   : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_ox1   : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY
.mel_emit_skip
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
    LDA zp_nt_l : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nt_r : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY   ; tail-call rasteriser (returns via RTS)
}

.emit_bot_edge
{
    LDY LINE_OUT_COUNT
    LDA zp_ox0 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_nb_l : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_nb_r : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY   ; tail-call rasteriser (returns via RTS)
}

; Secondary edge emitters: emit the front ceiling/floor line (ft/fb)
; passed via zp_yt_sec1/2 or zp_yb_sec1/2.  Used for step cases
; (need_bt / need_bb) where Python draws BOTH the step edge (at bt/bb,
; primary) AND the front ceiling/floor edge (at ft/fb, secondary).
; The values are u8 after the wrapper's remap.  We interp at (ox0, ox1)
; using the seg anchors (sx1, sx2), reusing zp_tmp2/tmp3 for the
; computed u8 y values.
.emit_sec_top_edge
{
    ; Fast path: constant line (yt_sec1 == yt_sec2) → skip interp
    LDA zp_yt_sec1 : CMP zp_yt_sec2 : BNE es_top_interp
    STA zp_tmp2 : STA zp_tmp3
    JMP es_top_emit
.es_top_interp
    ; interp at ox0
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den
    LDA zp_sx1 : STA zp_i_x0
    LDA zp_yt_sec1 : STA zp_i_y0
    LDA zp_yt_sec2 : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store : STA zp_tmp2
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den
    LDA zp_sx1 : STA zp_i_x0
    LDA zp_yt_sec1 : STA zp_i_y0
    LDA zp_yt_sec2 : STA zp_i_y1
    LDA zp_ox1 : JSR interp_store : STA zp_tmp3
.es_top_emit
    LDY LINE_OUT_COUNT
    LDA zp_ox0 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_tmp2 : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_tmp3 : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY
}

.emit_sec_bot_edge
{
    ; Fast path: constant line (yb_sec1 == yb_sec2) → skip interp
    LDA zp_yb_sec1 : CMP zp_yb_sec2 : BNE es_bot_interp
    STA zp_tmp2 : STA zp_tmp3
    JMP es_bot_emit
.es_bot_interp
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den
    LDA zp_sx1 : STA zp_i_x0
    LDA zp_yb_sec1 : STA zp_i_y0
    LDA zp_yb_sec2 : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store : STA zp_tmp2
    LDA zp_sx2 : SEC : SBC zp_sx1 : STA zp_div_den
    LDA zp_sx1 : STA zp_i_x0
    LDA zp_yb_sec1 : STA zp_i_y0
    LDA zp_yb_sec2 : STA zp_i_y1
    LDA zp_ox1 : JSR interp_store : STA zp_tmp3
.es_bot_emit
    LDY LINE_OUT_COUNT
    LDA zp_ox0 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_tmp2 : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_tmp3 : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY
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
    ; --- Vertical fast path: xl == xr (trampoline — dcl_vertical out of BEQ range) ---
    LDA zp_line_xl : CMP zp_line_xr : BNE dcl_not_vert
    JMP dcl_vertical
.dcl_not_vert
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

    ; --- Records-mode init (if enabled) ---
    LDA zp_dcl_rec_buf_h : BEQ dcl_records_off
    LDA #0 : LDY #0 : STA (zp_dcl_rec_buf),Y    ; count = 0
    LDA #1 : STA zp_dcl_rec_off                  ; first record at offset 1
.dcl_records_off

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
    ; xl >= xend → skip this span (inline advance)
    LDA POOL_NEXT,X : TAX : BNE dcl_walk2
    JMP dcl_flush
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
    LDA zp_seg_start_x : CMP #$FF : BEQ dcl_entry_path
    ; Continuation: line still in aperture across this span. Records are
    ; written once at dcl_emit_segment, not per-span.
    JMP dcl_exit_check
.dcl_entry_path

    ; ========== ENTRY: seg_start is NULL ==========
    ; --- Tier 1: outer bbox reject ---
    LDA zp_line_yhi : CMP POOL_OT,X : BCC dcl_reject_above  ; yhi < OT → line above aperture
    LDA POOL_OB,X : CMP zp_line_ylo : BCC dcl_reject_below  ; OB < ylo → line below aperture

    ; --- Tier 2: inner bbox accept ---
    LDA zp_line_ylo : CMP POOL_IT,X : BCC dcl_ambiguous     ; ylo < max(tl,tr) → CB clip
    LDA POOL_IB,X : CMP zp_line_yhi : BCS dcl_accept        ; min(bl,br) >= yhi → accept
    ; yhi > ib → ambiguous
    JMP dcl_cb_clip

.dcl_reject_above
.dcl_reject_below
.dcl_outer_reject
    ; Outer reject → advance to next span (inline)
    LDA POOL_NEXT,X : TAX : BNE dcl_walk2
    JMP dcl_flush
.dcl_ambiguous
    JMP dcl_cb_clip  ; trampoline → Phase 4 CB clip

    ; ── dcl_accept: record seg_start for an inner-bbox-accepted entry ──
    ; Sets seg_start = (ox0, line_y_at(ox0)).
    ; Three cases converge at STA zp_seg_start_y:
    ;   ox0 == xl  → A = yl      (common: line starts at/before span)
    ;   dy == 0    → A = yl      (flat line, y constant everywhere)
    ;   else       → A = interp  (rare: line enters span mid-way)
    ; The rare interp path uses BIT abs to skip the LDA zp_line_yl.
.dcl_accept
    LDA zp_ox0 : STA zp_seg_start_x
    CMP zp_line_xl : BEQ dcl_accept_yl                                 ; ox0 == xl → yl
    LDA zp_line_dy : BEQ dcl_accept_yl                                 ; dy == 0 → yl
    ; ox0 > xl, dy != 0: interp (rare path)
    STX zp_save0
    JSR dcl_line_y_at_ox0                                              ; A = line_y_at(ox0)
    LDX zp_save0
    EQUB $2C                                                           ; BIT abs: skip LDA
.dcl_accept_yl
    LDA zp_line_yl
    STA zp_seg_start_y
    ; (Records hook moved to dcl_emit_segment — one record per surviving
    ;  segment, not per-span.)
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

    ; Abutting? POOL_XEND[current] == POOL_XSTART[next] (shared pixel center)
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
    LDA POOL_NEXT,X : TAX
    JMP dcl_walk

.dcl_portal_t2
    ; --- Tier 2 (cheap reject): yhi < pt OR ylo > pb ---
    LDA zp_line_yhi : CMP zp_tmp0 : BCC dcl_exit_no_portal  ; yhi < pt → reject
    LDA zp_tmp1 : CMP zp_line_ylo : BCC dcl_exit_no_portal  ; pb < ylo → reject

    ; --- Tier 3 (exact check): compute ly = line_y_at(portal_x) ---
    ; portal_x = POOL_XEND of current span (shared boundary)
    LDX zp_save0
    LDA zp_line_dy : BEQ dcl_portal_use_yr  ; flat → yr (== yl)
    LDA POOL_XEND,X : CMP zp_line_xr : BEQ dcl_portal_use_yr
    JSR dcl_line_y_at_a  ; A = ly
    EQUB $2C                             ; BIT abs: skip LDA yr
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
    LDA POOL_NEXT,X : TAX
    JMP dcl_walk

.dcl_exit_no_portal_a
    ; Restore for emit path (ly check failed, need save0)
.dcl_exit_no_portal
    ; Portal failed or closed: emit current segment and reset.
    ; Compute exit point Y — three cases converge at dcl_exit_emit via
    ; chained BIT abs tricks (interp skips yl, yl skips yr):
    ;   xend == xr → A = yr
    ;   dy == 0    → A = yl
    ;   else       → A = line_y_at(xend)
    LDX zp_save0
    LDA POOL_XEND,X
    STA zp_ox1   ; end_x = xend of current span
    CMP zp_line_xr : BEQ dcl_exit_use_yr
    LDA zp_line_dy : BEQ dcl_exit_use_yr      ; dy==0 → yr (== yl for flat lines)
    ; xend < xr, sloped: interp
    LDA zp_ox1 : JSR dcl_line_y_at_a
    EQUB $2C                                   ; BIT abs: skip LDA yr
.dcl_exit_use_yr
    LDA zp_line_yr
.dcl_exit_emit
    ; A = end_y
    STA zp_tmp0
    JSR dcl_emit_segment
    ; Reset seg_start
    LDA #$FF : STA zp_seg_start_x
    LDX zp_save0
    ; Advance to next span (inline)
    LDA POOL_NEXT,X : TAX
    JMP dcl_walk

.dcl_line_ends
    ; Line ends within this span. Emit seg_start → (xr, yr)
    STX zp_save0
    LDA zp_line_yr : STA zp_tmp0  ; end_y = yr
    LDA zp_line_xr : STA zp_ox1   ; end_x = xr
    JSR dcl_emit_segment
    ; Done (line fully consumed)
    RTS

.dcl_flush
    ; End of walk.  If seg_start is still active (last iteration was a
    ; portal-continue into a span past xr, or list exhausted), emit the
    ; final segment to (xr, yr).
    LDA zp_seg_start_x : CMP #$FF : BEQ dcl_done
    LDA zp_line_yr : STA zp_tmp0
    LDA zp_line_xr : STA zp_ox1
    JSR dcl_emit_segment
.dcl_done
    RTS

; ========== Vertical line handler ==========
; For xl == xr: find the first span containing column xl, compute
; aperture [top_y, bot_y] at that column, clip [ylo, yhi] to aperture,
; emit single vertical line segment.  Matches Python's draw_clipped
; vertical path (break on first span containing ix).
.dcl_vertical
    ; Compute ylo/yhi (dx/dy not needed for verticals)
    LDA zp_line_yl : LDX zp_line_yr
    CMP zp_line_yr : BCC dv_yl_lo
    STA zp_line_yhi : STX zp_line_ylo : JMP dv_bbox_done
.dv_yl_lo
    STA zp_line_ylo : STX zp_line_yhi
.dv_bbox_done
    LDA #0 : STA LINE_OUT_COUNT
    LDX zp_head
.dv_walk
    BNE dv_check
    RTS                ; span list exhausted
.dv_check
    ; Skip if xend < xl (span entirely left of column — strict)
    LDA POOL_XEND,X : CMP zp_line_xl : BCC dv_next
    ; Done if xstart > xl (span entirely right of column; list sorted)
    LDA POOL_XSTART,X : CMP zp_line_xl : BEQ dv_in : BCC dv_in
    RTS
.dv_next
    LDA POOL_NEXT,X : TAX : JMP dv_walk
.dv_in
    ; Span contains column xl. Compute top_y and bot_y at xl.
    STX zp_save0
    ; Top: constant-line fast path or interp
    LDA POOL_TL,X : CMP POOL_TR,X : BNE dv_top_interp
    STA zp_cb_top1
    JMP dv_top_done
.dv_top_interp
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_DEN,X : STA zp_div_den
    LDA POOL_TL,X : STA zp_i_y0
    LDA POOL_TR,X : STA zp_i_y1
    LDA zp_line_xl : JSR interp_store : STA zp_cb_top1
.dv_top_done
    ; Bot: constant-line fast path or interp
    LDX zp_save0
    LDA POOL_BL,X : CMP POOL_BR,X : BNE dv_bot_interp
    STA zp_cb_bot1
    JMP dv_bot_done
.dv_bot_interp
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_DEN,X : STA zp_div_den
    LDA POOL_BL,X : STA zp_i_y0
    LDA POOL_BR,X : STA zp_i_y1
    LDA zp_line_xl : JSR interp_store : STA zp_cb_bot1
.dv_bot_done
    ; Clip [ylo, yhi] to [top_y, bot_y]
    ; cy1 = max(ylo, top_y)
    LDA zp_line_ylo : CMP zp_cb_top1 : BCS dv_cy1_ok : LDA zp_cb_top1
.dv_cy1_ok STA zp_cb_cy1
    ; cy2 = min(yhi, bot_y)
    LDA zp_line_yhi : CMP zp_cb_bot1 : BCC dv_cy2_ok : LDA zp_cb_bot1
.dv_cy2_ok STA zp_cb_cy2
    ; Emit if cy1 <= cy2
    LDA zp_cb_cy1 : CMP zp_cb_cy2 : BEQ dv_emit
    BCC dv_emit
    RTS   ; line clipped away
.dv_emit
    LDY LINE_OUT_COUNT
    LDA zp_line_xl : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_cb_cy1  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_line_xl : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_cb_cy2  : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY

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

    ; Pre-set interp workspace to line-mode so all line_y_at calls
    ; within CB clip can call interp_store directly (no shuffle).
    ; Span eval (top/bot) clobbers the workspace; dcl_cb_line_mode
    ; restores it afterward.
    LDA zp_line_xl : STA zp_i_x0
    LDA zp_line_yl : STA zp_i_y0
    LDA zp_line_yr : STA zp_i_y1
    LDA zp_line_dx : STA zp_div_den

    ; Step 2: Compute line Y at clipped X endpoints
    ; dy==0 fast path: flat line → cy1 = cy2 = yl
    LDA zp_line_dy : BNE dcl_cb_cy_slow
    LDA zp_line_yl : STA zp_cb_cy1 : STA zp_cb_cy2
    JMP dcl_cb_cy_done
.dcl_cb_cy_slow
    ; cy1 = line_y_at(cx1). CMP preserves A, so interp reuses it.
    ; Interp workspace already in line-mode — call interp_store directly.
    LDA zp_cb_cx1 : CMP zp_line_xl : BEQ dcl_cb_cy1_yl
    JSR interp_store : EQUB $2C                            ; BIT abs: skip LDA
.dcl_cb_cy1_yl
    LDA zp_line_yl
    STA zp_cb_cy1

    ; cy2 = line_y_at(cx2)
    LDA zp_cb_cx2 : CMP zp_line_xr : BEQ dcl_cb_cy2_yr
    JSR interp_store : EQUB $2C                            ; BIT abs: skip LDA
.dcl_cb_cy2_yr
    LDA zp_line_yr
    STA zp_cb_cy2
.dcl_cb_cy_done

    ; ── Step 3: Top boundary ──────────────────────────────────────────
    ; Bbox filter: if both cy values are below the span's tightest top
    ; (cy >= IT = max(tl,tr) for both endpoints), the line can't cross
    ; the top boundary anywhere.  Skip top eval + clip entirely.
    LDX zp_save0
    LDA zp_cb_cy1 : CMP POOL_IT,X : BCC dcl_cb_top_eval
    LDA zp_cb_cy2 : CMP POOL_IT,X : BCC dcl_cb_top_eval
    JMP dcl_cb_top_done                                    ; both >= IT → skip top

.dcl_cb_top_eval
    ; Evaluate top1, top2 at cx1, cx2 (fast paths first)
    ; Constant top? TL==TR (also covers den=0 since that implies TL==TR)
    LDA POOL_TL,X : CMP POOL_TR,X : BNE dcl_cb_top_interp
    STA zp_cb_top1 : STA zp_cb_top2
    JMP dcl_cb_top_evaled
.dcl_cb_top_interp
    ; Setup interp and evaluate
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_DEN,X : STA zp_div_den
    LDA POOL_TL,X : STA zp_i_y0
    LDA POOL_TR,X : STA zp_i_y1
    LDA zp_cb_cx1 : JSR interp_store : STA zp_cb_top1
    LDA zp_cb_cx2 : JSR interp_store : STA zp_cb_top2
.dcl_cb_top_evaled

    ; Top clip: test cy vs top at each endpoint
    LDA zp_cb_cy1 : CMP zp_cb_top1 : BCS dcl_cb_top_p1_ok  ; cy1 >= top1
    LDA zp_cb_cy2 : CMP zp_cb_top2 : BCS dcl_cb_top_clip   ; cy2 >= top2 → one inside, clip
    JMP dcl_cb_reject_above  ; both above → reject
.dcl_cb_top_p1_ok
    ; cy1 >= top1; check cy2
    LDA zp_cb_cy2 : CMP zp_cb_top2 : BCS dcl_cb_top_done  ; cy2 >= top2 → both inside, no clip
    ; cy2 < top2, cy1 >= top1: clip at p2 end
    LDA zp_cb_cy1 : SEC : SBC zp_cb_top1 : STA zp_tmp0  ; d1 = cy1 - top1 >= 0
    LDA zp_cb_cy2 : SEC : SBC zp_cb_top2 : STA zp_tmp1  ; d2 = cy2 - top2 < 0
    LDA #0 : JSR dcl_boundary_ix  ; A = ix (clip p2, round toward cx1)
    STA zp_cb_cx2
    ; cy at crossing = boundary_y(ix). Interp workspace still has the
    ; span's top line (i_x0=XLO, i_y0=TL, i_y1=TR); boundary_ix only
    ; clobbered div_den. Constant spans: cy = top1 directly.
    LDA zp_cb_top1 : CMP zp_cb_top2 : BEQ dcl_cb_top_cy2_const
    LDX zp_save0 : LDA POOL_DEN,X : STA zp_div_den
    LDA zp_cb_cx2 : JSR interp_store : EQUB $2C
.dcl_cb_top_cy2_const
    LDA zp_cb_top1
    STA zp_cb_cy2
    JMP dcl_cb_top_done

.dcl_cb_top_clip
    ; cy1 < top1, cy2 >= top2: clip at p1 end
    LDA zp_cb_cy1 : SEC : SBC zp_cb_top1 : STA zp_tmp0  ; d1 < 0
    LDA zp_cb_cy2 : SEC : SBC zp_cb_top2 : STA zp_tmp1  ; d2 >= 0
    LDA #1 : JSR dcl_boundary_ix  ; A = ix (clip p1, round toward cx2)
    STA zp_cb_cx1
    LDA zp_cb_top1 : CMP zp_cb_top2 : BEQ dcl_cb_top_cy1_const
    LDX zp_save0 : LDA POOL_DEN,X : STA zp_div_den
    LDA zp_cb_cx1 : JSR interp_store : EQUB $2C
.dcl_cb_top_cy1_const
    LDA zp_cb_top1
    STA zp_cb_cy1

.dcl_cb_top_done
    ; Check cx1 > cx2 after top clip → reject
    LDA zp_cb_cx2 : CMP zp_cb_cx1 : BCS dcl_cb_top_ok
    JMP dcl_cb_reject_above
.dcl_cb_top_ok

    ; ── Step 4: Bot boundary ──────────────────────────────────────────
    ; Bbox filter: if both cy values are above the span's tightest bot
    ; (cy <= IB = min(bl,br) for both endpoints), the line can't cross
    ; the bot boundary anywhere.  Skip bot eval + clip entirely.
    LDX zp_save0
    LDA POOL_IB,X : CMP zp_cb_cy1 : BCC dcl_cb_bot_eval
    LDA POOL_IB,X : CMP zp_cb_cy2 : BCC dcl_cb_bot_eval
    JMP dcl_cb_bot_done                                    ; both <= IB → skip bot

.dcl_cb_bot_eval
    ; Evaluate bot1, bot2 at (possibly top-clipped) cx1, cx2
    ; Constant bot? BL==BR (also covers den=0 since that implies BL==BR)
    LDA POOL_BL,X : CMP POOL_BR,X : BNE dcl_cb_bot_interp
    STA zp_cb_bot1 : STA zp_cb_bot2
    JMP dcl_cb_bot_eval_done
.dcl_cb_bot_interp
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_DEN,X : STA zp_div_den
    LDA POOL_BL,X : STA zp_i_y0
    LDA POOL_BR,X : STA zp_i_y1
    LDA zp_cb_cx1 : JSR interp_store : STA zp_cb_bot1
    LDA zp_cb_cx2 : JSR interp_store : STA zp_cb_bot2
.dcl_cb_bot_eval_done

    ; Bot clip: test cy vs bot at each endpoint
    LDA zp_cb_bot1 : CMP zp_cb_cy1 : BCS dcl_cb_bot_p1_ok  ; bot1 >= cy1
    LDA zp_cb_bot2 : CMP zp_cb_cy2 : BCS dcl_cb_bot_clip   ; bot2 >= cy2 → one inside, clip
    JMP dcl_cb_reject_below  ; both below → reject
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
    ; cy at crossing = boundary_y(ix). Bot interp workspace still valid.
    LDA zp_cb_bot1 : CMP zp_cb_bot2 : BEQ dcl_cb_bot_cy2_const
    LDX zp_save0 : LDA POOL_DEN,X : STA zp_div_den
    LDA zp_cb_cx2 : JSR interp_store : EQUB $2C
.dcl_cb_bot_cy2_const
    LDA zp_cb_bot1
    STA zp_cb_cy2
    JMP dcl_cb_bot_done

.dcl_cb_bot_clip
    ; bot1 < cy1, bot2 >= cy2: clip p1 end
    LDA zp_cb_cy1 : SEC : SBC zp_cb_bot1 : STA zp_tmp0  ; d1 > 0
    LDA zp_cb_cy2 : SEC : SBC zp_cb_bot2 : STA zp_tmp1  ; d2 <= 0
    LDA #1 : JSR dcl_boundary_ix
    STA zp_cb_cx1
    LDA zp_cb_bot1 : CMP zp_cb_bot2 : BEQ dcl_cb_bot_cy1_const
    LDX zp_save0 : LDA POOL_DEN,X : STA zp_div_den
    LDA zp_cb_cx1 : JSR interp_store : EQUB $2C
.dcl_cb_bot_cy1_const
    LDA zp_cb_bot1
    STA zp_cb_cy1

.dcl_cb_bot_done
    ; Check cx1 > cx2 after bot clip → reject
    LDA zp_cb_cx2 : CMP zp_cb_cx1 : BCC dcl_cb_reject_below

    ; CB clip succeeded. If cx2 < ox1 the line exits the aperture INSIDE
    ; the span (not at a span boundary). Emit (cx1,cy1)→(cx2,cy2) directly
    ; and reset seg_start — no portal continuation possible since the line
    ; left the aperture mid-span. dcl_line_ends / dcl_exit_no_portal both
    ; use xr/yr or line_y_at(xend) for the exit, which would be wrong here.
    LDA zp_cb_cx2 : CMP zp_ox1 : BCS dcl_cb_no_exit_clip
    ; cx2 < ox1 → emit clipped fragment (segment record written by emit).
    LDX zp_save0
    LDA zp_cb_cx1 : STA zp_seg_start_x
    LDA zp_cb_cy1 : STA zp_seg_start_y
    LDA zp_cb_cx2 : STA zp_ox1
    LDA zp_cb_cy2 : STA zp_tmp0
    JSR dcl_emit_segment
    LDA #$FF : STA zp_seg_start_x
    LDX zp_save0
    LDA POOL_NEXT,X : TAX
    JMP dcl_walk

.dcl_cb_no_exit_clip
    ; cx2 == ox1: CB did not clip the exit. Set seg_start = (cx1, cy1)
    ; and fall through to the normal exit check (portal or line_ends).
    ; Segment record written by dcl_emit_segment when the segment closes.
    LDX zp_save0
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

.dcl_cb_reject_above
.dcl_cb_reject_below
.dcl_cb_reject
    ; CB clip rejected — skip this span
    LDX zp_save0
    LDA POOL_NEXT,X : TAX
    JMP dcl_walk

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
.dcl_bix_no_round
    ; prod already in div_lo:hi (aliases — fall through to divide)
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
    ; Skip degenerate segments (zero-length).
    LDA zp_seg_start_x : CMP zp_ox1 : BNE dcl_es_ok
    LDA zp_seg_start_y : CMP zp_tmp0 : BNE dcl_es_ok
    RTS  ; degenerate
.dcl_es_ok
    ; --- Records hook: ONE record per surviving segment ---
    ; Segment record format: 4 bytes (xl, yl, xr, yr).
    ; Triggers exactly when DCL emits a visible segment, regardless of how
    ; many pool spans the segment crossed. Tighten consumer derives
    ; everything from these 4 endpoint values via interp.
    LDA zp_dcl_rec_buf_h : BEQ dcl_es_no_record
    LDY zp_dcl_rec_off
    LDA zp_seg_start_x : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_seg_start_y : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_ox1         : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_tmp0        : STA (zp_dcl_rec_buf),Y : INY
    STY zp_dcl_rec_off
    LDY #0 : LDA (zp_dcl_rec_buf),Y : CLC : ADC #1 : STA (zp_dcl_rec_buf),Y
.dcl_es_no_record
    LDY LINE_OUT_COUNT
    LDA zp_seg_start_x : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X0 : INY
    LDA zp_seg_start_y : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y0 : INY
    LDA zp_ox1 : STA LINE_OUT_BUF,Y : STA RASTER_ZP_X1 : INY
    LDA zp_tmp0 : SEC : SBC #Y_BIAS : STA LINE_OUT_BUF,Y : STA RASTER_ZP_Y1 : INY
    STY LINE_OUT_COUNT
    JMP RASTER_ENTRY   ; tail-call rasteriser

}

; --- line_interp_store: compute line Y at column A ---
; Reads directly from zp_line_xl/yl/yr/dx — no shuffle into the
; interp workspace needed.  Defers div_den setup past offset-zero
; and offset-max shortcuts.
; Input: A = x column.  Output: A = line Y.
; Clobbers: Y, mul_b, prod_*, div_*.
.dcl_line_y_at_ox0
    LDA $E9                      ; zp_ox0 (forward ref)
.dcl_line_y_at_a
.line_interp_store
{
    SEC : SBC zp_line_xl : BEQ lis_yl                                    ; offset=0 → yl
    CMP zp_line_dx : BEQ lis_yr                                         ; offset=dx → yr
    STA zp_mul_b
    LDY zp_line_dx : STY zp_div_den
    ; Direction check
    LDA zp_line_yr : CMP zp_line_yl : BEQ lis_yl : BCC lis_desc         ; |||
    ; ASCENDING: dy = yr - yl (unsigned)
    SEC : SBC zp_line_yl
    JSR umul_round_div
    CLC : ADC zp_line_yl : RTS
.lis_desc
    ; DESCENDING: |dy| = yl - yr (unsigned)
    LDA zp_line_yl : SEC : SBC zp_line_yr
    JSR umul_round_div
    EOR #$FF : SEC : ADC zp_line_yl : RTS
.lis_yl
    LDA zp_line_yl : RTS
.lis_yr
    LDA zp_line_yr : RTS
}

; ======================================================================
; CLIP_LINE_RECORDS / TIGHTEN_FROM_RECORDS — Phase B records-driven tighten
;
; Records-driven tighten architecture: clip_line_records walks the active
; span list and writes per-span sub-records describing the line vs span
; aperture relationship; tighten_from_records consumes the top+bot records
; and applies the narrowing. Replaces the existing draw_clipped+tighten
; pair for portal segs in records mode.
;
; Inputs (caller writes ZP):
;   zp_line_xl, zp_line_yl, zp_line_xr, zp_line_yr  — line endpoints (u8)
;   zp_ilo, zp_ihi                                  — clamp range (u8)
; Output: records buffer pointed to by zp_buf is populated.
; ======================================================================

; ===== Records mode ZP aliases =====
; Reuse tighten ZP slots since the two modes never run concurrently.
zp_clr_cy0     = $EF   ; (alias zp_nt_l)   line y at ox0
zp_clr_cy1     = $F1   ; (alias zp_nt_r)   line y at ox1
zp_clr_otl     = $EB   ; (alias zp_ot_l)   span_top at ox0
zp_clr_otr     = $EC   ; (alias zp_ot_r)   span_top at ox1
zp_clr_obl     = $ED   ; (alias zp_ob_l)   span_bot at ox0
zp_clr_obr     = $EE   ; (alias zp_ob_r)   span_bot at ox1
zp_clr_cx_t    = $F7   ; (alias zp_cx_top) top crossover x  ($00 = none)
zp_clr_cx_b    = $F8   ; (alias zp_cx_bot) bot crossover x  ($00 = none)
zp_clr_offset  = $F0   ; (alias zp_nt_lh)  next-record write offset in buffer
zp_clr_count   = $F2   ; (alias zp_nt_rh)  count of records written
zp_clr_save_x  = $F4   ; (alias zp_nb_lh)  save X across interp_store calls
; Per-sub-range scratch (overlap with tighten temps):
zp_clr_slo     = $D7   ; sub-range low x
zp_clr_shi     = $D8   ; sub-range high x

; --- DCL records hook helpers ---

; Write CB-clip records. Inputs: X = span slot,
;   zp_ox0, zp_ox1 = span overlap range
;   zp_cb_cx1, zp_cb_cy1 = visible portion left endpoint
;   zp_cb_cx2, zp_cb_cy2 = visible portion right endpoint
;   zp_cb_top1, zp_cb_bot1 = span aperture at cx1
;   zp_cb_top2, zp_cb_bot2 = span aperture at cx2
; Writes 1-3 records: optional 'above'/'below' for [ox0, cb_cx1],
; mandatory 'inside' for [cb_cx1, cb_cx2], optional 'above'/'below'
; for [cb_cx2, ox1]. Determines above/below by comparing cb_cy{1,2}
; with cb_top{1,2} / cb_bot{1,2} — no interp needed (already computed).
.dcl_record_cb_clip
{
    LDY zp_dcl_rec_buf_h : BEQ cb_done_tramp
    JMP cb_continue
.cb_done_tramp
    RTS
.cb_continue
    ; --- Outer left fragment [ox0, cb_cx1] (if cb_cx1 > ox0) ---
    LDA zp_ox0 : CMP zp_cb_cx1 : BCS no_outer_left
    ; Determine 'above' (cb_cy1 == cb_top1) or 'below' (cb_cy1 == cb_bot1).
    LDA #REC_VERDICT_ABOVE
    LDY zp_cb_cy1 : CPY zp_cb_top1 : BEQ ol_have_v
    LDA #REC_VERDICT_BELOW
.ol_have_v
    LDY zp_dcl_rec_off
    PHA                                       ; save verdict
    TXA : STA (zp_dcl_rec_buf),Y : INY        ; si
    LDA zp_ox0 : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_cb_cx1 : STA (zp_dcl_rec_buf),Y : INY
    PLA : STA (zp_dcl_rec_buf),Y : INY        ; verdict
    LDA #0 : STA (zp_dcl_rec_buf),Y : INY
              STA (zp_dcl_rec_buf),Y : INY
    STY zp_dcl_rec_off
    LDY #0 : LDA (zp_dcl_rec_buf),Y : CLC : ADC #1 : STA (zp_dcl_rec_buf),Y
.no_outer_left
    ; --- Inside fragment [cb_cx1, cb_cx2] ---
    LDY zp_dcl_rec_off
    TXA : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_cb_cx1 : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_cb_cx2 : STA (zp_dcl_rec_buf),Y : INY
    LDA #REC_VERDICT_INSIDE : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_cb_cy1 : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_cb_cy2 : STA (zp_dcl_rec_buf),Y : INY
    STY zp_dcl_rec_off
    LDY #0 : LDA (zp_dcl_rec_buf),Y : CLC : ADC #1 : STA (zp_dcl_rec_buf),Y
    ; --- Outer right fragment [cb_cx2, ox1] (if cb_cx2 < ox1) ---
    LDA zp_cb_cx2 : CMP zp_ox1 : BCS no_outer_right
    LDA #REC_VERDICT_ABOVE
    LDY zp_cb_cy2 : CPY zp_cb_top2 : BEQ or_have_v
    LDA #REC_VERDICT_BELOW
.or_have_v
    LDY zp_dcl_rec_off
    PHA
    TXA : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_cb_cx2 : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_ox1 : STA (zp_dcl_rec_buf),Y : INY
    PLA : STA (zp_dcl_rec_buf),Y : INY
    LDA #0 : STA (zp_dcl_rec_buf),Y : INY
              STA (zp_dcl_rec_buf),Y : INY
    STY zp_dcl_rec_off
    LDY #0 : LDA (zp_dcl_rec_buf),Y : CLC : ADC #1 : STA (zp_dcl_rec_buf),Y
.no_outer_right
.done
    RTS
}

; Write 'above'/'below' record. Caller already checked records enabled.
; Inputs: A = verdict (ABOVE or BELOW), X = span slot, zp_ox0/zp_ox1 set.
.dcl_record_outside
{
    LDY zp_dcl_rec_buf_h : BEQ done
    PHA                                      ; save verdict
    LDY zp_dcl_rec_off
    TXA : STA (zp_dcl_rec_buf),Y : INY       ; si
    LDA zp_ox0 : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_ox1 : STA (zp_dcl_rec_buf),Y : INY
    PLA : STA (zp_dcl_rec_buf),Y : INY        ; verdict
    LDA #0 : STA (zp_dcl_rec_buf),Y : INY    ; cy0 (unused)
              STA (zp_dcl_rec_buf),Y : INY    ; cy1 (unused)
    STY zp_dcl_rec_off
    LDY #0 : LDA (zp_dcl_rec_buf),Y : CLC : ADC #1 : STA (zp_dcl_rec_buf),Y
.done
    RTS
}

; Write 'inside' record at continuation. cy0 = line_y at ox0, cy1 = line_y at ox1.
; Both interps required — DCL doesn't track cy at span seams in continuation.
; Optimization: ox0 == line_xl is rare in continuation (continuation means
; line started before this span). ox1 == line_xr is common when line ends
; in this span (line_ends path).
; Inputs: X = span slot, zp_ox0/zp_ox1 set.
.dcl_record_inside_continuation
{
    STX zp_save0                              ; save span slot
    ; cy at ox0
    LDA zp_ox0 : CMP zp_line_xl : BEQ cont_use_yl_lo
    JSR dcl_line_y_at_a
    JMP cont_have_cy0
.cont_use_yl_lo
    LDA zp_line_yl
.cont_have_cy0
    PHA                                       ; save cy0
    ; cy at ox1
    LDX zp_save0
    LDA zp_ox1 : CMP zp_line_xr : BEQ cont_use_yr_hi
    JSR dcl_line_y_at_a
    JMP cont_have_cy1
.cont_use_yr_hi
    LDA zp_line_yr
.cont_have_cy1
    PHA                                       ; save cy1
    ; Write record
    LDX zp_save0
    LDY zp_dcl_rec_off
    TXA : STA (zp_dcl_rec_buf),Y : INY        ; si
    LDA zp_ox0 : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_ox1 : STA (zp_dcl_rec_buf),Y : INY
    LDA #REC_VERDICT_INSIDE : STA (zp_dcl_rec_buf),Y : INY
    PLA : TAX : PLA                           ; X=cy1, A=cy0
    STA (zp_dcl_rec_buf),Y : INY              ; cy0
    TXA : STA (zp_dcl_rec_buf),Y : INY        ; cy1
    STY zp_dcl_rec_off
    LDY #0 : LDA (zp_dcl_rec_buf),Y : CLC : ADC #1 : STA (zp_dcl_rec_buf),Y
    LDX zp_save0
    RTS
}

; Write 'inside' record at dcl_accept. cy0 = zp_seg_start_y (= line_y at ox0,
; just set by accept logic). cy1 = line_y at ox1 (1 interp; OR zp_line_yr if
; ox1 == line_xr to avoid the interp).
; Inputs: X = span slot, zp_ox0/zp_ox1 set, zp_seg_start_y set.
.dcl_record_inside_at_accept
{
    STX zp_save0                              ; save span slot
    ; Compute cy at ox1: if ox1 == line_xr, cy = line_yr (no interp); else interp.
    LDA zp_ox1 : CMP zp_line_xr : BEQ use_yr
    JSR dcl_line_y_at_a                       ; A = line_y_at(ox1)
    JMP write_record
.use_yr
    LDA zp_line_yr
.write_record
    PHA                                       ; save cy1
    LDX zp_save0                              ; restore span slot
    LDY zp_dcl_rec_off
    TXA : STA (zp_dcl_rec_buf),Y : INY        ; si
    LDA zp_ox0 : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_ox1 : STA (zp_dcl_rec_buf),Y : INY
    LDA #REC_VERDICT_INSIDE : STA (zp_dcl_rec_buf),Y : INY
    LDA zp_seg_start_y : STA (zp_dcl_rec_buf),Y : INY  ; cy0
    PLA : STA (zp_dcl_rec_buf),Y : INY        ; cy1
    STY zp_dcl_rec_off
    LDY #0 : LDA (zp_dcl_rec_buf),Y : CLC : ADC #1 : STA (zp_dcl_rec_buf),Y
    LDX zp_save0
    RTS
}

.clip_line_records
{
    ; --- Initialise records buffer: count=0, write offset=1 ---
    LDY #0 : LDA #0
    STA (zp_buf),Y
    STA zp_clr_count
    LDA #1 : STA zp_clr_offset

    ; Caller is responsible for line endpoint ordering. We don't swap here:
    ; sx2 may legitimately be > 255 (u8 wraps to look smaller than sx1) when
    ; the seg extends off-screen. interp_store handles via u8 SBC which wraps
    ; correctly to give the right den = (sx2 - sx1) mod 256.

    ; --- Walk active span list ---
    LDX zp_head
.clr_walk
    BNE clr_process
    JMP clr_done       ; X=0 → end of list
.clr_process
    STX zp_clr_save_x   ; save X early so clr_next can reload it
    ; Skip span if no overlap with [ilo, ihi].
    ; pixel-center: xe <= ilo or xs >= ihi → no overlap.
    LDA POOL_XEND,X : CMP zp_ilo : BCC clr_skip_tramp
    BEQ clr_skip_tramp
    LDA POOL_XSTART,X : CMP zp_ihi : BCC clr_in_range
.clr_skip_tramp
    JMP clr_next
.clr_in_range

    ; --- Compute ox0 = max(POOL_XSTART,X, ilo) ---
    LDA POOL_XSTART,X : CMP zp_ilo : BCS clr_ox0_ok
    LDA zp_ilo
.clr_ox0_ok
    STA zp_ox0

    ; --- Compute ox1 = min(POOL_XEND,X, ihi) ---
    LDA POOL_XEND,X : CMP zp_ihi : BCC clr_ox1_ok
    LDA zp_ihi
.clr_ox1_ok
    STA zp_ox1

    ; --- Compute line y at ox0 / ox1 (cy0, cy1) ---
    ; Setup interp params for line: x0=line_xl, den=line_xr-line_xl, y0=line_yl, y1=line_yr.
    LDA zp_line_xl : STA zp_i_x0
    LDA zp_line_xr : SEC : SBC zp_line_xl : STA zp_div_den
    LDA zp_line_yl : STA zp_i_y0
    LDA zp_line_yr : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store : STA zp_clr_cy0
    LDA zp_ox1 : JSR interp_store : STA zp_clr_cy1

    ; --- Compute span_top at ox0 / ox1 (otl, otr) ---
    LDX zp_clr_save_x
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_DEN,X : STA zp_div_den
    LDA POOL_TL,X : STA zp_i_y0
    LDA POOL_TR,X : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store : STA zp_clr_otl
    LDA zp_ox1 : JSR interp_store : STA zp_clr_otr

    ; --- Compute span_bot at ox0 / ox1 (obl, obr) ---
    LDX zp_clr_save_x
    LDA POOL_BL,X : STA zp_i_y0
    LDA POOL_BR,X : STA zp_i_y1
    LDA zp_ox0 : JSR interp_store : STA zp_clr_obl
    LDA zp_ox1 : JSR interp_store : STA zp_clr_obr

    ; --- Detect top crossing: dt = cy - top, sign change ⇒ crossing ---
    ; Compute |dt0|, |dt1| as u16 in zp_tmp0/1 and zp_tmp2/3 (compute_crossover args).
    ; dt0 = cy0 - otl. dt1 = cy1 - otr.
    LDA zp_clr_cy0 : SEC : SBC zp_clr_otl : STA zp_tmp0
    LDA #0 : SBC #0 : STA zp_tmp1   ; sign-extend (carry from SBC gives s8→s16)
    BPL clr_dt0_pos                  ; dt0 >= 0: keep
    SEC : LDA #0 : SBC zp_tmp0 : STA zp_tmp0
    LDA #0 : SBC zp_tmp1 : STA zp_tmp1
.clr_dt0_pos
    LDA zp_clr_cy1 : SEC : SBC zp_clr_otr : STA zp_tmp2
    LDA #0 : SBC #0 : STA zp_tmp3
    BPL clr_dt1_pos
    SEC : LDA #0 : SBC zp_tmp2 : STA zp_tmp2
    LDA #0 : SBC zp_tmp3 : STA zp_tmp3
.clr_dt1_pos
    ; Sign change check: was original dt0 sign != dt1 sign?
    ; Re-derive from raw bytes: high bit of (cy-top) before abs.
    ; Simpler: redo the sign check via direct compare.
    LDA #0 : STA zp_clr_cx_t
    LDA zp_clr_cy0 : CMP zp_clr_otl
    PHP                              ; save N flag (cy0 < otl)
    LDA zp_clr_cy1 : CMP zp_clr_otr
    BCS clr_t_signs_known            ; cy1 >= otr: dt1 >= 0
    ; cy1 < otr: dt1 < 0
    PLP : BCS clr_top_cross          ; cy0 >= otl, cy1 < otr → cross
    BCC clr_no_top_cross             ; both < (above)
.clr_t_signs_known
    PLP : BCC clr_top_cross          ; cy0 < otl, cy1 >= otr → cross
.clr_no_top_cross
    JMP clr_check_bot
.clr_top_cross
    ; |dt0|, |dt1| already in tmp0/1 and tmp2/3. compute_crossover.
    JSR compute_crossover
    STA zp_clr_cx_t

.clr_check_bot
    ; Same logic for bot: db = cy - bot, sign change ⇒ crossing.
    LDA zp_clr_cy0 : SEC : SBC zp_clr_obl : STA zp_tmp0
    LDA #0 : SBC #0 : STA zp_tmp1
    BPL clr_db0_pos
    SEC : LDA #0 : SBC zp_tmp0 : STA zp_tmp0
    LDA #0 : SBC zp_tmp1 : STA zp_tmp1
.clr_db0_pos
    LDA zp_clr_cy1 : SEC : SBC zp_clr_obr : STA zp_tmp2
    LDA #0 : SBC #0 : STA zp_tmp3
    BPL clr_db1_pos
    SEC : LDA #0 : SBC zp_tmp2 : STA zp_tmp2
    LDA #0 : SBC zp_tmp3 : STA zp_tmp3
.clr_db1_pos
    LDA #0 : STA zp_clr_cx_b
    LDA zp_clr_cy0 : CMP zp_clr_obl
    PHP
    LDA zp_clr_cy1 : CMP zp_clr_obr
    BCS clr_b_signs_known
    PLP : BCS clr_bot_cross
    BCC clr_no_bot_cross
.clr_b_signs_known
    PLP : BCC clr_bot_cross
.clr_no_bot_cross
    JMP clr_emit_subranges
.clr_bot_cross
    JSR compute_crossover
    STA zp_clr_cx_b

.clr_emit_subranges
    ; --- Emit sub-records for sub-ranges ---
    ; Up to 3 sub-ranges based on (cx_t, cx_b) crossings.
    ; Case 0 (no crossings): [ox0, ox1] only.
    ; Case T (top only):     [ox0, cx_t], [cx_t, ox1].
    ; Case B (bot only):     [ox0, cx_b], [cx_b, ox1].
    ; Case TB (both):        sorted at min(cx_t, cx_b), max(cx_t, cx_b).
    LDA zp_clr_cx_t : BNE clr_has_cx_t
    LDA zp_clr_cx_b : BNE clr_only_cx_b
    ; Case 0: no crossings. Single sub-range.
    LDA zp_ox0 : STA zp_clr_slo
    LDA zp_ox1 : STA zp_clr_shi
    JSR clr_emit_one_subrange
    JMP clr_next
.clr_only_cx_b
    ; Case B: bot only.
    LDA zp_ox0 : STA zp_clr_slo
    LDA zp_clr_cx_b : STA zp_clr_shi
    JSR clr_emit_one_subrange
    LDA zp_clr_cx_b : STA zp_clr_slo
    LDA zp_ox1 : STA zp_clr_shi
    JSR clr_emit_one_subrange
    JMP clr_next
.clr_has_cx_t
    LDA zp_clr_cx_b : BNE clr_both_cx
    ; Case T: top only.
    LDA zp_ox0 : STA zp_clr_slo
    LDA zp_clr_cx_t : STA zp_clr_shi
    JSR clr_emit_one_subrange
    LDA zp_clr_cx_t : STA zp_clr_slo
    LDA zp_ox1 : STA zp_clr_shi
    JSR clr_emit_one_subrange
    JMP clr_next
.clr_both_cx
    ; Case TB: both crossings. Sort cx_t, cx_b → 3 sub-ranges.
    LDA zp_clr_cx_t : CMP zp_clr_cx_b : BCC clr_t_first
    ; cx_t >= cx_b: order [ox0, cx_b], [cx_b, cx_t], [cx_t, ox1].
    LDA zp_ox0 : STA zp_clr_slo
    LDA zp_clr_cx_b : STA zp_clr_shi
    JSR clr_emit_one_subrange
    LDA zp_clr_cx_b : STA zp_clr_slo
    LDA zp_clr_cx_t : STA zp_clr_shi
    JSR clr_emit_one_subrange
    LDA zp_clr_cx_t : STA zp_clr_slo
    LDA zp_ox1 : STA zp_clr_shi
    JSR clr_emit_one_subrange
    JMP clr_next
.clr_t_first
    ; cx_t < cx_b: order [ox0, cx_t], [cx_t, cx_b], [cx_b, ox1].
    LDA zp_ox0 : STA zp_clr_slo
    LDA zp_clr_cx_t : STA zp_clr_shi
    JSR clr_emit_one_subrange
    LDA zp_clr_cx_t : STA zp_clr_slo
    LDA zp_clr_cx_b : STA zp_clr_shi
    JSR clr_emit_one_subrange
    LDA zp_clr_cx_b : STA zp_clr_slo
    LDA zp_ox1 : STA zp_clr_shi
    JSR clr_emit_one_subrange

.clr_next
    ; Move to next span
    LDX zp_clr_save_x
    LDA POOL_NEXT,X : TAX
    JMP clr_walk

.clr_done
    ; Write final count to buffer[0]
    LDA zp_clr_count : LDY #0
    STA (zp_buf),Y
    RTS
}

; --- Helper: emit one sub-record for [zp_clr_slo, zp_clr_shi] ---
; Determines verdict based on cy_lo/cy_hi vs t_lo/t_hi/b_lo/b_hi.
; Writes record to buffer at offset zp_clr_offset, increments offset and count.
; ===== emit_one_subrange ZP =====
; Avoid zp_tmp0..3 ($DE-$E1) — umul8 clobbers zp_tmp0; other helpers use $DE-E1.
; Use $B6-$B9 (CB clip slots, free during records mode) and $E5-$E7 (safe scratch).
zp_eos_cy_lo = $B6
zp_eos_cy_hi = $B7
zp_eos_t_lo  = $B8
zp_eos_t_hi  = $B9
zp_eos_b_lo  = $E5
zp_eos_b_hi  = $E6
zp_eos_verdict = $E7

.clr_emit_one_subrange
{
    ; Compute cy_lo, cy_hi, t_lo, t_hi, b_lo, b_hi at slo/shi.
    ; Setup line interp params.
    LDA zp_line_xl : STA zp_i_x0
    LDA zp_line_xr : SEC : SBC zp_line_xl : STA zp_div_den
    LDA zp_line_yl : STA zp_i_y0
    LDA zp_line_yr : STA zp_i_y1
    LDA zp_clr_slo : JSR interp_store : STA zp_eos_cy_lo
    LDA zp_clr_shi : JSR interp_store : STA zp_eos_cy_hi

    ; Span top at slo/shi.
    LDX zp_clr_save_x
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_DEN,X : STA zp_div_den
    LDA POOL_TL,X : STA zp_i_y0
    LDA POOL_TR,X : STA zp_i_y1
    LDA zp_clr_slo : JSR interp_store : STA zp_eos_t_lo
    LDA zp_clr_shi : JSR interp_store : STA zp_eos_t_hi

    ; Span bot at slo/shi.
    LDX zp_clr_save_x
    LDA POOL_BL,X : STA zp_i_y0
    LDA POOL_BR,X : STA zp_i_y1
    LDA zp_clr_slo : JSR interp_store : STA zp_eos_b_lo
    LDA zp_clr_shi : JSR interp_store : STA zp_eos_b_hi

    ; Verdict determination:
    ;   cy_lo <= t_lo AND cy_hi <= t_hi  → 'above'
    ;   cy_lo >= b_lo AND cy_hi >= b_hi  → 'below'
    ;   else                              → 'inside' (store cy_lo, cy_hi)
    LDA zp_eos_cy_lo : CMP zp_eos_t_lo : BEQ chk_top_eq_l : BCS chk_below
.chk_top_eq_l
    LDA zp_eos_cy_hi : CMP zp_eos_t_hi : BEQ above_v : BCC above_v
.chk_below
    LDA zp_eos_cy_lo : CMP zp_eos_b_lo : BCC inside_v : BEQ chk_bot_eq_l
    LDA zp_eos_cy_hi : CMP zp_eos_b_hi : BCS below_v : BEQ below_v
    JMP inside_v
.chk_bot_eq_l
    LDA zp_eos_cy_hi : CMP zp_eos_b_hi : BCS below_v : BEQ below_v
.inside_v
    LDA #REC_VERDICT_INSIDE : STA zp_eos_verdict
    JMP write_record
.above_v
    LDA #REC_VERDICT_ABOVE : STA zp_eos_verdict
    JMP write_record
.below_v
    LDA #REC_VERDICT_BELOW : STA zp_eos_verdict

.write_record
    ; Append 6-byte record at zp_clr_offset.
    LDY zp_clr_offset
    LDA zp_clr_save_x : STA (zp_buf),Y : INY    ; si
    LDA zp_clr_slo    : STA (zp_buf),Y : INY    ; sox0
    LDA zp_clr_shi    : STA (zp_buf),Y : INY    ; sox1
    LDA zp_eos_verdict : STA (zp_buf),Y : INY   ; verdict
    LDA zp_eos_cy_lo  : STA (zp_buf),Y : INY    ; cy0
    LDA zp_eos_cy_hi  : STA (zp_buf),Y : INY    ; cy1
    STY zp_clr_offset
    INC zp_clr_count
    RTS
}

; ===== tighten_from_records ZP aliases =====
; Records-mode-only — reuse tighten ZP slots that aren't active concurrently.
zp_tfr_top_off = $D7   ; offset of top record (0 = none)
zp_tfr_bot_off = $D8   ; offset of bot record (0 = none)
zp_tfr_top_v   = $B6   ; top verdict (0/1/2) for current fragment
zp_tfr_top_cy0 = $B7   ; top line y at fragment lo
zp_tfr_top_cy1 = $B8   ; top line y at fragment hi
zp_tfr_bot_v   = $B9   ; bot verdict for current fragment
zp_tfr_bot_cy0 = $E5   ; bot line y at fragment lo
zp_tfr_bot_cy1 = $E6   ; bot line y at fragment hi
zp_tfr_old_tl  = $EB   ; old span top at fragment lo (alias zp_ot_l)
zp_tfr_old_tr  = $EC   ; old span top at fragment hi
zp_tfr_old_bl  = $ED   ; old span bot at fragment lo
zp_tfr_old_br  = $EE   ; old span bot at fragment hi
zp_tfr_rt_l    = $EF   ; result top at fragment lo (after max)
zp_tfr_rt_r    = $F1   ; result top at fragment hi
zp_tfr_rb_l    = $F3   ; result bot at fragment lo (after min)
zp_tfr_rb_r    = $F5   ; result bot at fragment hi

; ===== Segment-records tighten scratch (RAM at $0900-$0921) =====
; Records are now ONE per surviving DCL segment (4 bytes: xl, yl, xr, yr).
; Tighten consumer is a 3-cursor walk: top recs, bot recs, pool spans.
TFS_CUR_X       = $0900   ; current x in inner loop
TFS_X_HI        = $0901   ; right edge of in-range processing
TFS_NEXT_X      = $0902   ; next event x
TFS_TOP_DOM     = $0903   ; 1 if top dominated by record at cur_x, else 0
TFS_BOT_DOM     = $0904   ; same for bot
TFS_TOP_L       = $0905   ; top value at cur_x
TFS_TOP_R       = $0906   ; top value at next_x
TFS_BOT_L       = $0907
TFS_BOT_R       = $0908
TFS_TOP_KIND    = $0909   ; 0 = pool, 1 = top record
TFS_TOP_ID      = $090A   ; pool slot or record offset
TFS_BOT_KIND    = $090B   ; 0 = pool, 1 = bot record
TFS_BOT_ID      = $090C
TFS_TOP_BUFEND  = $090D   ; 1 + top_count*4 (first invalid offset)
TFS_BOT_BUFEND  = $090E
TFS_T_CUR       = $090F   ; top record cursor offset (0 = exhausted)
TFS_B_CUR       = $0910   ; bot record cursor offset (0 = exhausted)
TFS_PEND_ACT    = $0911   ; 1 if a pending output span is buffered
TFS_PEND_XL     = $0912
TFS_PEND_XR     = $0913
TFS_PEND_TL     = $0914
TFS_PEND_TR     = $0915
TFS_PEND_BL     = $0916
TFS_PEND_BR     = $0917
TFS_PEND_TKIND  = $0918
TFS_PEND_TID    = $0919
TFS_PEND_BKIND  = $091A
TFS_PEND_BID    = $091B

; ===================================================================
; tighten_from_records — segment-record consumer (3-cursor walk).
;
; Records (4 bytes each: xl, yl, xr, yr) are one-per-surviving-segment
; written by dcl_emit_segment. This routine walks the pool together
; with monotonic top + bot record cursors, building a brand-new pool
; list span-by-span:
;
;   both top and bot dom  → span = (T_rec.top, B_rec.bot), no pool needed
;   only top dom           → span = (T_rec.top, pool.bot)
;   only bot dom           → span = (pool.top,  B_rec.bot)
;   neither dom            → span = pool unchanged (one fragment)
;
; Adjacent emitted spans are merged when their TOP and BOT sources
; (kind + id) match — this is the lossless-merge condition because
; same-source guarantees same line equation and hence same slope.
; ===================================================================
.tighten_from_records
{
    ; Invalidate the has_gap coherence cache (see span_mark_solid note).
    LDA #0 : STA zp_hg_cache
    LDA zp_head : STA zp_old_cur
    LDA #0 : STA zp_new_tail : STA zp_head
    LDA #$FF : STA zp_tg_cont

    ; Init top/bot cursors and buffer-end offsets.
    LDA TOP_RECORDS : BEQ tfs_no_top
    LDA #1 : STA TFS_T_CUR : JMP tfs_top_be
.tfs_no_top
    LDA #0 : STA TFS_T_CUR
.tfs_top_be
    LDA TOP_RECORDS : ASL A : ASL A : CLC : ADC #1 : STA TFS_TOP_BUFEND
    LDA BOT_RECORDS : BEQ tfs_no_bot
    LDA #1 : STA TFS_B_CUR : JMP tfs_bot_be
.tfs_no_bot
    LDA #0 : STA TFS_B_CUR
.tfs_bot_be
    LDA BOT_RECORDS : ASL A : ASL A : CLC : ADC #1 : STA TFS_BOT_BUFEND

    ; No pending output span yet.
    LDA #0 : STA TFS_PEND_ACT

    LDX zp_old_cur
.tfs_walk
    BNE tfs_proc
    JMP tfs_finish
.tfs_proc
    LDA POOL_NEXT,X : STA zp_old_cur
    STX zp_clr_save_x

    ; Out-of-range check.
    LDA POOL_XEND,X : CMP zp_ilo : BCC tfs_oor
    BEQ tfs_oor
    LDA POOL_XSTART,X : CMP zp_ihi : BCC tfs_in_range
.tfs_oor
    JSR tfs_flush_pending
    LDX zp_clr_save_x
    JSR tg_append_x
    JMP tfs_continue
.tfs_in_range

    ; Pre-fragment [span.xstart, ilo] if span.xstart < ilo.
    LDA POOL_XSTART,X : CMP zp_ilo : BCS tfs_no_pre
    JSR tfs_flush_pending
    LDX zp_clr_save_x
    LDA POOL_XSTART,X : STA zp_ox0
    LDA zp_ilo : STA zp_ox1
    JSR emit_unchanged_subspan
    LDA zp_ilo : STA TFS_CUR_X
    JMP tfs_xhi_done
.tfs_no_pre
    LDX zp_clr_save_x
    LDA POOL_XSTART,X : STA TFS_CUR_X
.tfs_xhi_done

    ; x_hi = min(span.xend, ihi).
    LDX zp_clr_save_x
    LDA POOL_XEND,X : CMP zp_ihi : BCC tfs_xhi_xend
    LDA zp_ihi : STA TFS_X_HI : JMP tfs_xhi_set
.tfs_xhi_xend
    STA TFS_X_HI
.tfs_xhi_set

    ; Fast path: if NEITHER top nor bot record overlaps [cur_x, x_hi],
    ; emit the pool span unchanged and skip the interp inner loop.
    ; A record at the cursor doesn't overlap if its xl >= x_hi (segment
    ; starts past us). T_CUR == 0 also means no overlap.
    LDA TFS_T_CUR : BEQ tfs_fp_chk_bot
    TAY : LDA TOP_RECORDS,Y : CMP TFS_X_HI : BCC tfs_inner    ; T.xl < x_hi → overlap
.tfs_fp_chk_bot
    LDA TFS_B_CUR : BEQ tfs_fp_emit
    TAY : LDA BOT_RECORDS,Y : CMP TFS_X_HI : BCC tfs_inner
.tfs_fp_emit
    JSR tfs_flush_pending
    LDX zp_clr_save_x
    LDA TFS_CUR_X : STA zp_ox0
    LDA TFS_X_HI  : STA zp_ox1
    JSR emit_unchanged_subspan
    JMP tfs_inner_done

.tfs_inner
    LDA TFS_CUR_X : CMP TFS_X_HI : BCC tfs_inner_go
    JMP tfs_inner_done
.tfs_inner_go

    ; ---- Determine top_dom (T.xl <= cur_x < T.xr) ----
    LDA #0 : STA TFS_TOP_DOM
    LDA TFS_T_CUR : BEQ tfs_top_dom_done
    TAY : LDA TOP_RECORDS,Y                ; T.xl
    CMP TFS_CUR_X : BEQ tfs_top_chk_xr : BCS tfs_top_dom_done
.tfs_top_chk_xr
    INY : INY : LDA TOP_RECORDS,Y          ; T.xr
    CMP TFS_CUR_X : BCC tfs_top_dom_done : BEQ tfs_top_dom_done
    LDA #1 : STA TFS_TOP_DOM
.tfs_top_dom_done

    ; ---- Determine bot_dom ----
    LDA #0 : STA TFS_BOT_DOM
    LDA TFS_B_CUR : BEQ tfs_bot_dom_done
    TAY : LDA BOT_RECORDS,Y
    CMP TFS_CUR_X : BEQ tfs_bot_chk_xr : BCS tfs_bot_dom_done
.tfs_bot_chk_xr
    INY : INY : LDA BOT_RECORDS,Y
    CMP TFS_CUR_X : BCC tfs_bot_dom_done : BEQ tfs_bot_dom_done
    LDA #1 : STA TFS_BOT_DOM
.tfs_bot_dom_done

    ; ---- next_x = min(x_hi, top event, bot event) ----
    LDA TFS_X_HI : STA TFS_NEXT_X
    LDA TFS_T_CUR : BEQ tfs_skip_top_evt
    LDA TFS_TOP_DOM : BNE tfs_top_evt_xr
    LDY TFS_T_CUR : LDA TOP_RECORDS,Y     ; not yet dom: candidate = T.xl
    JMP tfs_top_evt_check
.tfs_top_evt_xr
    LDA TFS_T_CUR : CLC : ADC #2 : TAY    ; dom: candidate = T.xr
    LDA TOP_RECORDS,Y
.tfs_top_evt_check
    CMP TFS_NEXT_X : BCS tfs_skip_top_evt
    STA TFS_NEXT_X
.tfs_skip_top_evt
    LDA TFS_B_CUR : BEQ tfs_skip_bot_evt
    LDA TFS_BOT_DOM : BNE tfs_bot_evt_xr
    LDY TFS_B_CUR : LDA BOT_RECORDS,Y
    JMP tfs_bot_evt_check
.tfs_bot_evt_xr
    LDA TFS_B_CUR : CLC : ADC #2 : TAY
    LDA BOT_RECORDS,Y
.tfs_bot_evt_check
    CMP TFS_NEXT_X : BCS tfs_skip_bot_evt
    STA TFS_NEXT_X
.tfs_skip_bot_evt

    ; ---- Per-interval fast path: both sides from pool → emit unchanged.
    ; Saves the 4 interps the normal path would do for a pool/pool sub-
    ; fragment (the parts of a pool span that records don't dominate).
    LDA TFS_TOP_DOM : ORA TFS_BOT_DOM : BNE tfs_compute_vals
    JSR tfs_flush_pending
    LDX zp_clr_save_x
    LDA TFS_CUR_X  : STA zp_ox0
    LDA TFS_NEXT_X : STA zp_ox1
    JSR emit_unchanged_subspan
    JMP tfs_advance_curs
.tfs_compute_vals

    ; ---- Compute top values for [cur_x, next_x] ----
    LDA TFS_TOP_DOM : BEQ tfs_top_pool
    ; top from record T_CUR: read (xl, yl, xr, yr) and interp.
    ; Segment endpoints are on the original yt-line (DCL computes them with
    ; the same interp_store used here), so interp between them recovers the
    ; line's geometry. Small u8-rounding aliasing at sub-segment fragments
    ; can shift a pixel; this is inherent to integer interp.
    LDY TFS_T_CUR
    LDA TOP_RECORDS,Y : STA zp_i_x0
    INY : LDA TOP_RECORDS,Y : STA zp_i_y0
    INY : LDA TOP_RECORDS,Y : STA zp_tmp0
    INY : LDA TOP_RECORDS,Y : STA zp_i_y1
    LDA zp_tmp0 : SEC : SBC zp_i_x0 : STA zp_div_den
    LDA TFS_CUR_X : JSR interp_store : STA TFS_TOP_L
    LDA TFS_NEXT_X : JSR interp_store : STA TFS_TOP_R
    LDA #1 : STA TFS_TOP_KIND
    LDA TFS_T_CUR : STA TFS_TOP_ID
    JMP tfs_top_vals_done
.tfs_top_pool
    LDX zp_clr_save_x
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_TL,X : STA zp_i_y0
    LDA POOL_TR,X : STA zp_i_y1
    LDA POOL_DEN,X : STA zp_div_den
    LDA TFS_CUR_X : JSR interp_store : STA TFS_TOP_L
    LDA TFS_NEXT_X : JSR interp_store : STA TFS_TOP_R
    LDA #0 : STA TFS_TOP_KIND
    LDA zp_clr_save_x : STA TFS_TOP_ID
.tfs_top_vals_done

    ; ---- Compute bot values for [cur_x, next_x] ----
    LDA TFS_BOT_DOM : BEQ tfs_bot_pool
    LDY TFS_B_CUR
    LDA BOT_RECORDS,Y : STA zp_i_x0
    INY : LDA BOT_RECORDS,Y : STA zp_i_y0
    INY : LDA BOT_RECORDS,Y : STA zp_tmp0
    INY : LDA BOT_RECORDS,Y : STA zp_i_y1
    LDA zp_tmp0 : SEC : SBC zp_i_x0 : STA zp_div_den
    LDA TFS_CUR_X : JSR interp_store : STA TFS_BOT_L
    LDA TFS_NEXT_X : JSR interp_store : STA TFS_BOT_R
    LDA #1 : STA TFS_BOT_KIND
    LDA TFS_B_CUR : STA TFS_BOT_ID
    JMP tfs_bot_vals_done
.tfs_bot_pool
    LDX zp_clr_save_x
    LDA POOL_XLO,X : STA zp_i_x0
    LDA POOL_BL,X : STA zp_i_y0
    LDA POOL_BR,X : STA zp_i_y1
    LDA POOL_DEN,X : STA zp_div_den
    LDA TFS_CUR_X : JSR interp_store : STA TFS_BOT_L
    LDA TFS_NEXT_X : JSR interp_store : STA TFS_BOT_R
    LDA #0 : STA TFS_BOT_KIND
    LDA zp_clr_save_x : STA TFS_BOT_ID
.tfs_bot_vals_done

    ; ---- Try to merge with pending ----
    LDA TFS_PEND_ACT : BEQ tfs_start_pend
    LDA TFS_PEND_XR : CMP TFS_CUR_X : BNE tfs_no_merge
    LDA TFS_PEND_TKIND : CMP TFS_TOP_KIND : BNE tfs_no_merge
    LDA TFS_PEND_TID : CMP TFS_TOP_ID : BNE tfs_no_merge
    LDA TFS_PEND_BKIND : CMP TFS_BOT_KIND : BNE tfs_no_merge
    LDA TFS_PEND_BID : CMP TFS_BOT_ID : BNE tfs_no_merge
    ; Merge: extend pending right edge.
    LDA TFS_NEXT_X : STA TFS_PEND_XR
    LDA TFS_TOP_R : STA TFS_PEND_TR
    LDA TFS_BOT_R : STA TFS_PEND_BR
    JMP tfs_advance_curs
.tfs_no_merge
    JSR tfs_flush_pending
.tfs_start_pend
    LDA #1 : STA TFS_PEND_ACT
    LDA TFS_CUR_X : STA TFS_PEND_XL
    LDA TFS_NEXT_X : STA TFS_PEND_XR
    LDA TFS_TOP_L : STA TFS_PEND_TL
    LDA TFS_TOP_R : STA TFS_PEND_TR
    LDA TFS_BOT_L : STA TFS_PEND_BL
    LDA TFS_BOT_R : STA TFS_PEND_BR
    LDA TFS_TOP_KIND : STA TFS_PEND_TKIND
    LDA TFS_TOP_ID   : STA TFS_PEND_TID
    LDA TFS_BOT_KIND : STA TFS_PEND_BKIND
    LDA TFS_BOT_ID   : STA TFS_PEND_BID

.tfs_advance_curs
    ; Advance T_CUR if next_x crossed T.xr.
    LDA TFS_T_CUR : BEQ tfs_skip_t_adv
    LDA TFS_TOP_DOM : BEQ tfs_skip_t_adv
    LDA TFS_T_CUR : CLC : ADC #2 : TAY
    LDA TOP_RECORDS,Y : CMP TFS_NEXT_X : BNE tfs_skip_t_adv
    LDA TFS_T_CUR : CLC : ADC #4
    CMP TFS_TOP_BUFEND : BCC tfs_t_adv_ok
    LDA #0
.tfs_t_adv_ok
    STA TFS_T_CUR
.tfs_skip_t_adv
    LDA TFS_B_CUR : BEQ tfs_skip_b_adv
    LDA TFS_BOT_DOM : BEQ tfs_skip_b_adv
    LDA TFS_B_CUR : CLC : ADC #2 : TAY
    LDA BOT_RECORDS,Y : CMP TFS_NEXT_X : BNE tfs_skip_b_adv
    LDA TFS_B_CUR : CLC : ADC #4
    CMP TFS_BOT_BUFEND : BCC tfs_b_adv_ok
    LDA #0
.tfs_b_adv_ok
    STA TFS_B_CUR
.tfs_skip_b_adv

    LDA TFS_NEXT_X : STA TFS_CUR_X
    JMP tfs_inner

.tfs_inner_done

    ; Post-fragment [ihi, span.xend] if span.xend > ihi.
    LDX zp_clr_save_x
    LDA POOL_XEND,X : CMP zp_ihi : BCC tfs_no_post : BEQ tfs_no_post
    JSR tfs_flush_pending
    LDX zp_clr_save_x
    LDA zp_ihi : STA zp_ox0
    LDA POOL_XEND,X : STA zp_ox1
    JSR emit_unchanged_subspan
.tfs_no_post

    ; Free original pool span (its replacements are now in the new list).
    LDX zp_clr_save_x
    JSR free_span

.tfs_continue
    LDA zp_old_cur : TAX
    JMP tfs_walk

.tfs_finish
    JSR tfs_flush_pending
    RTS
}

; ---- Flush pending output span: alloc, populate fields, append. ----
.tfs_flush_pending
{
    LDA TFS_PEND_ACT : BNE flush_do
    RTS
.flush_do
    LDA #0 : STA TFS_PEND_ACT
    JSR alloc_span : BEQ flush_fail
    LDA TFS_PEND_XL : STA POOL_XSTART,X : STA POOL_XLO,X
    LDA TFS_PEND_XR : STA POOL_XEND,X
    SEC : SBC TFS_PEND_XL : STA POOL_DEN,X
    LDA TFS_PEND_TL : STA POOL_TL,X
    LDA TFS_PEND_TR : STA POOL_TR,X
    LDA TFS_PEND_BL : STA POOL_BL,X
    LDA TFS_PEND_BR : STA POOL_BR,X
    ; OT = min(TL,TR), IT = max(TL,TR), OB = max(BL,BR), IB = min(BL,BR).
    LDA TFS_PEND_TL : CMP TFS_PEND_TR : BCC fp_ot : LDA TFS_PEND_TR
.fp_ot STA POOL_OT,X
    LDA TFS_PEND_TL : CMP TFS_PEND_TR : BCS fp_it : LDA TFS_PEND_TR
.fp_it STA POOL_IT,X
    LDA TFS_PEND_BL : CMP TFS_PEND_BR : BCS fp_ob : LDA TFS_PEND_BR
.fp_ob STA POOL_OB,X
    LDA TFS_PEND_BL : CMP TFS_PEND_BR : BCC fp_ib : LDA TFS_PEND_BR
.fp_ib STA POOL_IB,X
    JSR tg_append_x
.flush_fail
    RTS
}

; Emit unchanged sub-span [zp_ox0, zp_ox1] with old span's line def.
.emit_unchanged_subspan
    JSR alloc_span : BEQ ues_fail
    LDY zp_clr_save_x
    LDA POOL_XLO,Y    : STA POOL_XLO,X
    LDA POOL_DEN,Y    : STA POOL_DEN,X
    LDA POOL_TL,Y     : STA POOL_TL,X
    LDA POOL_BL,Y     : STA POOL_BL,X
    LDA POOL_TR,Y     : STA POOL_TR,X
    LDA POOL_BR,Y     : STA POOL_BR,X
    LDA POOL_OT,Y     : STA POOL_OT,X
    LDA POOL_OB,Y     : STA POOL_OB,X
    LDA POOL_IT,Y     : STA POOL_IT,X
    LDA POOL_IB,Y     : STA POOL_IB,X
    LDA zp_ox0        : STA POOL_XSTART,X
    LDA zp_ox1        : STA POOL_XEND,X
    JSR tg_append_x
.ues_fail
    RTS


; ===================================================================
; s16 line clipper — generic first cut
;
; Wrapper writes 8 bytes of s16 input (4 endpoints × 2 bytes) to
; LC_X1_LO..LC_Y2_HI in scratch RAM, then JSRs $201E. Routine clips
; line to u8 [0,255]×[0,255], writes u8 result to zp_line_xl/yl/xr/yr,
; then falls through to draw_clipped_line (existing DCL pipeline).
;
; The math is the slow generic version: u16×u16 = u32, u32÷u16 = u16.
; A `project_clip_arithmetic_fastpath` memo notes the obvious fast
; paths to add later (u8-fits-operand, trivial offset==0/den cases,
; early-exit divide when leading zeros guarantee u8 quotient).
; ===================================================================

; ---- s16 line input (wrapper writes these) ----
; Lo bytes alias zp_line_* (the same u8 slots DCL reads). Hi bytes
; alias the CB-clip / tighten-secondary ZP block ($B2-$B5) — those
; slots are used DOWNSTREAM of the s16 clipper (DCL clobbers them
; during emission), but the wrapper rewrites them before each call,
; so there's no conflict. ZP access shaves ~7 cycles off the in-range
; fast-path detect (4 ORAs of zp vs absolute).
LC_X1_LO    = zp_line_xl
LC_X1_HI    = $B2
LC_Y1_LO    = zp_line_yl
LC_Y1_HI    = $B3
LC_X2_LO    = zp_line_xr
LC_X2_HI    = $B4
LC_Y2_LO    = zp_line_yr
LC_Y2_HI    = $B5
; ---- saved originals for interp (snapped at start of x-clip / y-clip) ----
LC_OX1_LO   = $0938
LC_OX1_HI   = $0939
LC_OY1_LO   = $093A
LC_OY1_HI   = $093B
LC_OX2_LO   = $093C
LC_OX2_HI   = $093D
LC_OY2_LO   = $093E
LC_OY2_HI   = $093F
; ---- math working ----
LC_OFF_LO   = $0940
LC_OFF_HI   = $0941
LC_DEN_LO   = $0942
LC_DEN_HI   = $0943
LC_DY_LO    = $0944
LC_DY_HI    = $0945
LC_DY_NEG   = $0946
LC_M_A_LO   = $0947
LC_M_A_HI   = $0948
LC_M_B_LO   = $0949
LC_M_B_HI   = $094A
LC_M_R0     = $094B
LC_M_R1     = $094C
LC_M_R2     = $094D
LC_M_R3     = $094E
LC_QUOT_LO  = $094F
LC_QUOT_HI  = $0950
LC_REM_LO   = $0951
LC_REM_HI   = $0952
LC_TMP_LO   = $0953
LC_TMP_HI   = $0954
LC_RES_LO   = $0955
LC_RES_HI   = $0956
LC_TGT_LO   = $0957     ; clip target value (s16)
LC_TGT_HI   = $0958

; ===================================================================
; umul16x16 — u16 × u16 = u32
; Inputs:  LC_M_A_LO/HI, LC_M_B_LO/HI
; Output:  LC_M_R0..LC_M_R3 (LSB first)
; Clobbers: A, X, Y, zp_mul_b, zp_prod_lo, zp_prod_hi
.umul16x16
{
    ; Always need p1 = a_lo * b_lo.
    LDA LC_M_B_LO : STA zp_mul_b
    LDA LC_M_A_LO : JSR umul8
    LDA zp_prod_lo : STA LC_M_R0
    LDA zp_prod_hi : STA LC_M_R1
    LDA #0 : STA LC_M_R2 : STA LC_M_R3

    ; Fast paths: skip multiplies whose factor is zero.
    LDA LC_M_B_HI : BEQ skip_p2

    LDA LC_M_B_HI : STA zp_mul_b
    LDA LC_M_A_LO : JSR umul8           ; p2 = a_lo * b_hi
    LDA zp_prod_lo : CLC : ADC LC_M_R1 : STA LC_M_R1
    LDA zp_prod_hi : ADC LC_M_R2 : STA LC_M_R2
    LDA #0          : ADC LC_M_R3 : STA LC_M_R3
.skip_p2

    LDA LC_M_A_HI : BEQ skip_p3_p4

    LDA LC_M_B_LO : STA zp_mul_b
    LDA LC_M_A_HI : JSR umul8           ; p3 = a_hi * b_lo
    LDA zp_prod_lo : CLC : ADC LC_M_R1 : STA LC_M_R1
    LDA zp_prod_hi : ADC LC_M_R2 : STA LC_M_R2
    LDA #0          : ADC LC_M_R3 : STA LC_M_R3

    LDA LC_M_B_HI : BEQ skip_p3_p4      ; if b fits u8, p4 = a_hi * 0 = 0
    LDA LC_M_B_HI : STA zp_mul_b
    LDA LC_M_A_HI : JSR umul8           ; p4 = a_hi * b_hi
    LDA zp_prod_lo : CLC : ADC LC_M_R2 : STA LC_M_R2
    LDA zp_prod_hi : ADC LC_M_R3 : STA LC_M_R3
.skip_p3_p4
    RTS
}

; ===================================================================
; udiv32_16 — u32 ÷ u16 = u16 quotient (low 16 bits, with rounding
; pre-applied by caller)
; Inputs:  LC_M_R0..R3 (dividend, modified); LC_DEN_LO/HI (divisor)
; Output:  LC_QUOT_LO/HI, LC_REM_LO/HI
; Clobbers: A, X, dividend bytes
;
; Fast path (per project_clip_arithmetic_fastpath): byte-level skip of
; leading-zero dividend bytes. Each skipped byte saves 8 iterations
; (~240 cycles). Typical s16 clipper inputs produce a u20-u22 product
; from umul16x16, so R3 is always 0 and we always save ≥8 iterations.
.udiv32_16
{
    LDA #0 : STA LC_QUOT_LO : STA LC_QUOT_HI

    ; ---- Fast path: quotient fits u16 ----
    ; True iff top 16 bits of dividend < den. Pre-load rem = R3:R2 and
    ; run 16 iterations on the low 16 bits (skip the first 16 no-op
    ; iterations the standard loop would do). For typical s16 clipper
    ; inputs (product u20-u22, den u12) this is always true.
    LDA LC_M_R3 : CMP LC_DEN_HI : BCC u16_quot
    BNE no_u16_quot
    LDA LC_M_R2 : CMP LC_DEN_LO : BCS no_u16_quot
.u16_quot
    LDA LC_M_R3 : STA LC_REM_HI
    LDA LC_M_R2 : STA LC_REM_LO
    LDX #16
.u16_loop
    ASL LC_M_R0 : ROL LC_M_R1 : ROL LC_REM_LO : ROL LC_REM_HI
    LDA LC_REM_LO : SEC : SBC LC_DEN_LO : STA LC_TMP_LO
    LDA LC_REM_HI : SBC LC_DEN_HI
    BCC u16_no_sub
    STA LC_REM_HI
    LDA LC_TMP_LO : STA LC_REM_LO
    SEC
    JMP u16_set
.u16_no_sub
    CLC
.u16_set
    ROL LC_QUOT_LO : ROL LC_QUOT_HI
    DEX : BNE u16_loop
    RTS

.no_u16_quot
    ; ---- Slow path: u32 ÷ u16 → up to u17 quotient ----
    ; (Rare for s16 clipper; kept for correctness.) Use byte-level skip
    ; + bit-level skip to trim no-op iterations.
    LDA #0 : STA LC_REM_LO : STA LC_REM_HI
    LDX #32
    LDA LC_M_R3 : BNE bit_skip
    LDA LC_M_R2 : STA LC_M_R3
    LDA LC_M_R1 : STA LC_M_R2
    LDA LC_M_R0 : STA LC_M_R1
    LDA #0 : STA LC_M_R0
    LDX #24
    LDA LC_M_R3 : BNE bit_skip
    LDA LC_M_R2 : STA LC_M_R3
    LDA LC_M_R1 : STA LC_M_R2
    LDA #0 : STA LC_M_R0 : STA LC_M_R1
    LDX #16
    LDA LC_M_R3 : BNE bit_skip
    LDA LC_M_R2 : STA LC_M_R3
    LDA #0 : STA LC_M_R0 : STA LC_M_R1 : STA LC_M_R2
    LDX #8
    LDA LC_M_R3 : BNE bit_skip
    RTS
.bit_skip
    BMI div_loop
.bs_loop
    ASL LC_M_R0 : ROL LC_M_R1 : ROL LC_M_R2 : ROL LC_M_R3
    DEX
    LDA LC_M_R3 : BPL bs_loop
.div_loop
    ASL LC_M_R0 : ROL LC_M_R1 : ROL LC_M_R2 : ROL LC_M_R3
    ROL LC_REM_LO : ROL LC_REM_HI
    LDA LC_REM_LO : SEC : SBC LC_DEN_LO : STA LC_TMP_LO
    LDA LC_REM_HI : SBC LC_DEN_HI
    BCC div_no_sub
    STA LC_REM_HI
    LDA LC_TMP_LO : STA LC_REM_LO
    SEC
    JMP div_setbit
.div_no_sub
    CLC
.div_setbit
    ROL LC_QUOT_LO : ROL LC_QUOT_HI
    DEX : BNE div_loop
    RTS
}

; ===================================================================
; s16_interp — find target axis at given free-axis value
; The "free" axis is the one whose value we know (the clip target);
; the "target" axis is the one we want to compute. Caller sets:
;   LC_TGT_LO/HI       = target free-axis value (s16)
;   LC_OX1_LO/HI etc.  = anchor 1 (free, target)
;   LC_OX2_LO/HI etc.  = anchor 2 (free, target)
; To clip x at boundary: free=x, target=y, OX*=x, OY*=y.
; To clip y at boundary: free=y, target=x, OX*=y, OY*=x.
; Output: A = clamped u8 result, LC_RES_LO/HI = unclamped s16 result.
; Clobbers: many.
.s16_interp
{
    ; offset = target - x0
    LDA LC_TGT_LO : SEC : SBC LC_OX1_LO : STA LC_OFF_LO
    LDA LC_TGT_HI : SBC LC_OX1_HI : STA LC_OFF_HI
    ; den = x1 - x0
    LDA LC_OX2_LO : SEC : SBC LC_OX1_LO : STA LC_DEN_LO
    LDA LC_OX2_HI : SBC LC_OX1_HI : STA LC_DEN_HI
    ; If den < 0, negate both offset and den.
    LDA LC_DEN_HI : BPL si_den_pos
    LDA #0 : SEC : SBC LC_OFF_LO : STA LC_OFF_LO
    LDA #0 : SBC LC_OFF_HI : STA LC_OFF_HI
    LDA #0 : SEC : SBC LC_DEN_LO : STA LC_DEN_LO
    LDA #0 : SBC LC_DEN_HI : STA LC_DEN_HI
.si_den_pos
    ; Trivial: den == 0 (degenerate line) → return y0
    LDA LC_DEN_LO : ORA LC_DEN_HI : BNE si_den_nz
    JMP si_return_y0
.si_den_nz
    ; Trivial: offset == 0 (target == x0) → return y0
    LDA LC_OFF_LO : ORA LC_OFF_HI : BNE si_off_nz
    JMP si_return_y0
.si_off_nz
    ; Trivial: offset == den (target == x1) → return y1
    LDA LC_OFF_LO : CMP LC_DEN_LO : BNE si_off_lt_den
    LDA LC_OFF_HI : CMP LC_DEN_HI : BNE si_off_lt_den
    JMP si_return_y1
.si_off_lt_den
    ; dy = y1 - y0 (s16)
    LDA LC_OY2_LO : SEC : SBC LC_OY1_LO : STA LC_DY_LO
    LDA LC_OY2_HI : SBC LC_OY1_HI : STA LC_DY_HI
    ; Trivial: dy == 0 (horizontal line) → return y0
    LDA LC_DY_LO : ORA LC_DY_HI : BNE si_dy_nz
    JMP si_return_y0
.si_dy_nz
    ; |dy|, sign tracked in LC_DY_NEG
    LDA LC_DY_HI : BPL si_dy_pos
    LDA #1 : STA LC_DY_NEG
    LDA #0 : SEC : SBC LC_DY_LO : STA LC_DY_LO
    LDA #0 : SBC LC_DY_HI : STA LC_DY_HI
    JMP si_dy_done
.si_dy_pos
    LDA #0 : STA LC_DY_NEG
.si_dy_done
    ; Fast path: |offset|, |den|, |dy| all fit u8 → use existing
    ; umul8 + udiv16_8 (one multiply, one divide-with-skip-zeros).
    LDA LC_OFF_HI : ORA LC_DEN_HI : ORA LC_DY_HI : BNE si_general
    LDA LC_DY_LO : STA zp_mul_b
    LDA LC_OFF_LO : JSR umul8
    ; round: prod += (den / 2)
    LDA LC_DEN_LO : LSR A
    CLC : ADC zp_prod_lo : STA zp_div_lo
    LDA #0 : ADC zp_prod_hi : STA zp_div_hi
    LDA LC_DEN_LO : STA zp_div_den
    JSR udiv16_8                  ; A = u8 quotient
    LDX LC_DY_NEG : BNE si_u8_sub
    CLC : ADC LC_OY1_LO : STA LC_RES_LO
    LDA LC_OY1_HI : ADC #0 : STA LC_RES_HI
    JMP si_clamp
.si_u8_sub
    STA LC_TMP_LO
    LDA LC_OY1_LO : SEC : SBC LC_TMP_LO : STA LC_RES_LO
    LDA LC_OY1_HI : SBC #0 : STA LC_RES_HI
    JMP si_clamp
.si_general
    ; multiply: |offset| × |dy| → u32 (umul16x16 also has a_hi=0/b_hi=0
    ; fast paths internally).
    LDA LC_OFF_LO : STA LC_M_A_LO
    LDA LC_OFF_HI : STA LC_M_A_HI
    LDA LC_DY_LO  : STA LC_M_B_LO
    LDA LC_DY_HI  : STA LC_M_B_HI
    JSR umul16x16
    ; round-to-nearest: add (den / 2) before divide
    LDA LC_DEN_HI : LSR A : STA LC_TMP_HI
    LDA LC_DEN_LO : ROR A : STA LC_TMP_LO
    LDA LC_M_R0 : CLC : ADC LC_TMP_LO : STA LC_M_R0
    LDA LC_M_R1 :       ADC LC_TMP_HI : STA LC_M_R1
    LDA LC_M_R2 :       ADC #0        : STA LC_M_R2
    LDA LC_M_R3 :       ADC #0        : STA LC_M_R3
    JSR udiv32_16
    ; result = y0 ± quot
    LDA LC_DY_NEG : BNE si_sub
    LDA LC_OY1_LO : CLC : ADC LC_QUOT_LO : STA LC_RES_LO
    LDA LC_OY1_HI :       ADC LC_QUOT_HI : STA LC_RES_HI
    JMP si_clamp
.si_sub
    LDA LC_OY1_LO : SEC : SBC LC_QUOT_LO : STA LC_RES_LO
    LDA LC_OY1_HI :       SBC LC_QUOT_HI : STA LC_RES_HI
.si_clamp
    LDA LC_RES_HI : BMI si_clamp_zero
                    BNE si_clamp_max
    LDA LC_RES_LO : RTS
.si_clamp_zero
    LDA #0 : RTS
.si_clamp_max
    LDA #$FF : RTS
.si_return_y0
    LDA LC_OY1_LO : STA LC_RES_LO
    LDA LC_OY1_HI : STA LC_RES_HI
    JMP si_clamp
.si_return_y1
    LDA LC_OY2_LO : STA LC_RES_LO
    LDA LC_OY2_HI : STA LC_RES_HI
    JMP si_clamp
}

; ===================================================================
; draw_clipped_line_s16 — clip s16 line to u8 then dispatch to DCL.
; Reads LC_X1_LO..LC_Y2_HI (8 bytes of s16 input).
; Writes u8 to zp_line_xl, zp_line_yl, zp_line_xr, zp_line_yr and
; falls through to draw_clipped_line. If line fully off-screen,
; degenerate, or otherwise rejected, RTS without invoking DCL.
.draw_clipped_line_s16
{
    ; ---- Fast path: all 4 endpoints already in u8 range ----
    ; HI bytes all zero ⇔ all coords in [0, 255]. Wrapper has already
    ; written zp_line_xl/yl/xr/yr (= LC_X*_LO via alias), ordered the
    ; endpoints, and rejected degenerate input. Tail-call DCL directly.
    LDA LC_X1_HI : ORA LC_Y1_HI : ORA LC_X2_HI : ORA LC_Y2_HI
    BNE main_clip
    JMP draw_clipped_line
.main_clip
    ; ---- Quick reject: both endpoints on the same side of any edge ----
    ; Both x < 0?  hi byte negative for both means both < 0 (s16).
    LDA LC_X1_HI : BPL x1_in_or_big
    LDA LC_X2_HI : BPL not_both_xneg
    JMP rejected
.x1_in_or_big
    ; LC_X1_HI ≥ 0. Check if LC_X1_LO/HI > 255 (i.e. HI != 0).
    BEQ not_both_xbig                ; HI = 0 → in [0, 255] (low byte)
    ; HI > 0 → x1 > 255. Is x2 also > 255?
    LDA LC_X2_HI : BMI not_both_xbig ; x2 < 0 → not both > 255
    BEQ not_both_xbig                ; x2 in [0, 255] → not both > 255
    ; both > 255
    JMP rejected
.not_both_xneg
.not_both_xbig
    ; same for y
    LDA LC_Y1_HI : BPL y1_in_or_big
    LDA LC_Y2_HI : BPL not_both_yneg
    JMP rejected
.y1_in_or_big
    BEQ not_both_ybig
    LDA LC_Y2_HI : BMI not_both_ybig
    BEQ not_both_ybig
    JMP rejected
.not_both_yneg
.not_both_ybig

    ; ---- Skip x-clip path entirely if both x already in u8 ----
    ; (We got here because at least one HI byte is non-zero; might be y.)
    LDA LC_X1_HI : ORA LC_X2_HI : BNE need_xclip
    JMP skip_xclip
.need_xclip

    ; ---- Save originals for x-clip interp (only when needed) ----
    LDA LC_X1_LO : STA LC_OX1_LO
    LDA LC_X1_HI : STA LC_OX1_HI
    LDA LC_Y1_LO : STA LC_OY1_LO
    LDA LC_Y1_HI : STA LC_OY1_HI
    LDA LC_X2_LO : STA LC_OX2_LO
    LDA LC_X2_HI : STA LC_OX2_HI
    LDA LC_Y2_LO : STA LC_OY2_LO
    LDA LC_Y2_HI : STA LC_OY2_HI

    ; ---- X clip ----
    ; If x1 < 0, replace y1 with y at x=0; x1 = 0.
    ; Else if x1 > 255, replace y1 with y at x=255; x1 = 255.
    LDA LC_X1_HI : BPL x1_not_neg
    LDA #0 : STA LC_TGT_LO : STA LC_TGT_HI
    JSR s16_interp
    STA LC_Y1_LO : LDA #0 : STA LC_Y1_HI
    LDA #0 : STA LC_X1_LO : STA LC_X1_HI
    JMP x1_done
.x1_not_neg
    BEQ x1_done                      ; HI=0 → in u8 range, no clip
    LDA #$FF : STA LC_TGT_LO
    LDA #0   : STA LC_TGT_HI
    JSR s16_interp
    STA LC_Y1_LO : LDA #0 : STA LC_Y1_HI
    LDA #$FF : STA LC_X1_LO : LDA #0 : STA LC_X1_HI
.x1_done
    ; same for x2
    LDA LC_X2_HI : BPL x2_not_neg
    LDA #0 : STA LC_TGT_LO : STA LC_TGT_HI
    JSR s16_interp
    STA LC_Y2_LO : LDA #0 : STA LC_Y2_HI
    LDA #0 : STA LC_X2_LO : STA LC_X2_HI
    JMP x2_done
.x2_not_neg
    BEQ x2_done
    LDA #$FF : STA LC_TGT_LO
    LDA #0   : STA LC_TGT_HI
    JSR s16_interp
    STA LC_Y2_LO : LDA #0 : STA LC_Y2_HI
    LDA #$FF : STA LC_X2_LO : LDA #0 : STA LC_X2_HI
.x2_done
.skip_xclip

    ; ---- Quick reject after x-clip (y might still be out same side) ----
    LDA LC_Y1_HI : BPL y1_after_in_or_big
    LDA LC_Y2_HI : BPL not_both_yneg2
    JMP rejected
.y1_after_in_or_big
    BEQ not_both_ybig2
    LDA LC_Y2_HI : BMI not_both_ybig2
    BEQ not_both_ybig2
    JMP rejected
.not_both_yneg2
.not_both_ybig2

    ; ---- If both y already in u8, skip y-clip ----
    LDA LC_Y1_HI : BNE need_yclip
    LDA LC_Y2_HI : BNE need_yclip
    JMP y_in_range
.need_yclip
    ; Re-snap originals to post-x-clip values; for y-clip, axes swap:
    ; OX* now holds the FREE axis (y), OY* the TARGET (x).
    LDA LC_Y1_LO : STA LC_OX1_LO
    LDA LC_Y1_HI : STA LC_OX1_HI
    LDA LC_X1_LO : STA LC_OY1_LO
    LDA LC_X1_HI : STA LC_OY1_HI
    LDA LC_Y2_LO : STA LC_OX2_LO
    LDA LC_Y2_HI : STA LC_OX2_HI
    LDA LC_X2_LO : STA LC_OY2_LO
    LDA LC_X2_HI : STA LC_OY2_HI

    ; y1 clip
    LDA LC_Y1_HI : BPL y1c_not_neg
    LDA #0 : STA LC_TGT_LO : STA LC_TGT_HI
    JSR s16_interp
    STA LC_X1_LO : LDA #0 : STA LC_X1_HI
    LDA #0 : STA LC_Y1_LO : STA LC_Y1_HI
    JMP y1c_done
.y1c_not_neg
    BEQ y1c_done
    LDA #$FF : STA LC_TGT_LO
    LDA #0   : STA LC_TGT_HI
    JSR s16_interp
    STA LC_X1_LO : LDA #0 : STA LC_X1_HI
    LDA #$FF : STA LC_Y1_LO : LDA #0 : STA LC_Y1_HI
.y1c_done
    ; y2 clip
    LDA LC_Y2_HI : BPL y2c_not_neg
    LDA #0 : STA LC_TGT_LO : STA LC_TGT_HI
    JSR s16_interp
    STA LC_X2_LO : LDA #0 : STA LC_X2_HI
    LDA #0 : STA LC_Y2_LO : STA LC_Y2_HI
    JMP y2c_done
.y2c_not_neg
    BEQ y2c_done
    LDA #$FF : STA LC_TGT_LO
    LDA #0   : STA LC_TGT_HI
    JSR s16_interp
    STA LC_X2_LO : LDA #0 : STA LC_X2_HI
    LDA #$FF : STA LC_Y2_LO : LDA #0 : STA LC_Y2_HI
.y2c_done
.y_in_range

    ; ---- Order/copy/degen handled by wrapper for input; clipping in
    ; this slow path could shrink the line to a point, so check that
    ; one case before dispatching. zp_line_* already holds the clipped
    ; values via the LC_X*_LO aliases.
    LDA zp_line_xl : CMP zp_line_xr : BCC dispatch_dcl
    BNE rejected_swap_after_clip   ; clipping reordered: bail (rare)
    LDA zp_line_yl : CMP zp_line_yr : BEQ rejected
.dispatch_dcl
    JMP draw_clipped_line
.rejected_swap_after_clip
    ; Post-clip x1 > x2 — would require swap; just emit reordered.
    LDA zp_line_xl : LDX zp_line_xr : STX zp_line_xl : STA zp_line_xr
    LDA zp_line_yl : LDX zp_line_yr : STX zp_line_yl : STA zp_line_yr
    JMP draw_clipped_line
.rejected
    RTS
}

.end_code
SAVE "span_clip.bin", $2000, end_code, $2000
