; ======================================================================
; UMUL8: unsigned 8x8 -> 16 multiply via quarter-square identity
;
; The hottest arithmetic primitive — one call per boundary interpolation
; (see feedback: all FP arithmetic is built on this 8x8 mul).
;
; Identity:  a*b = floor((a+b)^2/4) - floor((a-b)^2/4)
; Exact because a+b and a-b have the same parity, so the two /4
; truncation errors cancel.  sqr[n] = floor(n^2/4) covers n in [0,255];
; when a+b >= 256 the sum term uses sqr2[n] = floor((n+256)^2/4),
; indexed with (a+b) & $FF.  |a-b| < 256 always, so the difference term
; always reads sqr_lo/hi.
;
; Input:  A = a (u8), zp_mul_b = b (u8)
; Output: zp_prod_lo:zp_prod_hi = a*b (u16).  Clobbers A,X,Y, zp_tmp0.
;         zp_prod_lo/hi alias zp_div_lo/hi, so the product feeds
;         directly into udiv16_8 with no extra loads.
;
; pseudocode:
;   d = |a - b|; s = a + b
;   if s < 256: prod = sqr[s]        - sqr[d]
;   else:       prod = sqr2[s & 255] - sqr[d]
; ======================================================================
umul8_fixed:
umul8:
.scope
   TAX                                     ; stash a in X (was zp_tmp0: the
; d = a - b; negate if borrow            ; round-trip cost 6, TAX/TXA 4)
   SEC
   SBC zp_mul_b
   BCS pos
   EOR #$FF
   ADC #1
; |diff| (C was 0 from SBC, so ADC adds +0+1)
pos:
   TAY
; Y = |diff|
; s = a + b (carry out selects sqr vs sqr2 table for the sum term)
   TXA
   CLC
   ADC zp_mul_b
; ||||
   TAX
   BCS uo
; X = sum; overflow if carry from ADC          ; ||
; sum < 256: sqr tables for sum
; prod = sqr[s] - sqr[d]  (16-bit table subtract)
   LDA sqr_lo,X
   SEC
   SBC sqr_lo,Y
   STA zp_prod_lo
; |||||
   LDA sqr_hi,X
   SBC sqr_hi,Y
   STA zp_prod_hi
   RTS
; |||||||
uo:                                     ; sum >= 256: sqr2 tables for sum (carry already set from BCS)
; prod = sqr2[s & 255] - sqr[d]  (X already wrapped mod 256 by the ADC)
   LDA sqr2_lo,X
   SBC sqr_lo,Y
   STA zp_prod_lo
   LDA sqr2_hi,X
   SBC sqr_hi,Y
   STA zp_prod_hi
   RTS
.endscope

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
POOL = $0400
POOL_NEXT = $0400
POOL_XLO = $0420
POOL_DEN = $0440                        ; precomputed xhi - xlo (denominator for interp)
POOL_TL = $0460
POOL_BL = $0480
POOL_TR = $04A0
POOL_BR = $04C0
POOL_XSTART = $04E0
POOL_XEND = $0500
POOL_OT = $0520
POOL_OB = $0540
POOL_IT = $0560
POOL_IB = $0580
NUM_SLOTS = 32

Y_BIAS = 48                             ; bias Y so visible [0,159] maps to [48,207] within u8
VIS_YMAX = Y_BIAS + 159                 ; = 207: maximum biased visible Y

; Quarter-square multiply tables (pre-loaded by the Python harness).
; sqr[n]  = floor(n^2/4) for n in [0,255]; sqr2[n] = floor((n+256)^2/4)
; used when a+b overflows u8.
.if ::BANKED
; low RAM, in the space the clipper vacated ($2000+); above vcache ($0C00-
; $1A97) and bsp_render_lo ($1B40-$1FB4). Reachable from the bank-C clipper
; AND from bsp_render's local umul8 (both read sqr).
sqr_lo = $2000
sqr_hi = $2100
sqr2_lo = $2200
sqr2_hi = $2300
.else
sqr_lo = $A500
sqr_hi = $A600
sqr2_lo = $A700
sqr2_hi = $A800
.endif

; === Seg value cache ($A0-$A4) — separate from crossover working set ===
; Caches the right-endpoint new-seg values from the previous overlapping span
; for reuse when the next span shares the boundary column (abutting model).
; === Running seg bounds ($A5-$A7) — progressively tighter seg extremes ===
; Initialized at tg_go with clamped max(yt1,yt2) and min(yb1,yb2); narrowed
; after each non-old-dom span. Used by the unified tiered dominance check.

; === Static seg Y bbox ($A8-$AB) — set once per mel/tg_go call ===
; Aliased onto the DCL line ZP slots: mel runs only inside mark_solid and
; tighten runs only inside span_tighten, neither overlaps DCL. mel reuses
; zp_ms_emit's slot ($A8) since that flag is consumed at mark_solid entry.
; Sentinels disable the per-span bbox check when seg values aren't u8:
;   seg_top_max=$FF, seg_top_min=$00, seg_bot_max=$FF, seg_bot_min=$00.

; === Draw-clipped-line ZP ($A8-$B9) — reuses $A8 (ms_emit) since non-overlapping ===
; Caller sets xl/yl/xr/yr; routine computes dx/dy/ylo/yhi.
; ===== DCL records hook ($BC-$BF) =====
; When zp_dcl_rec_buf+1 (high byte) is non-zero, DCL writes per-span records
; to the buffer at zp_dcl_rec_buf during its existing per-span walk. Caller
; sets to TOP_RECORDS or BOT_RECORDS to enable; sets high byte to 0 to disable.
; Buffer format matches clip_line_records: byte 0 = count, then 6-byte records
; (si, sox0, sox1, verdict, cy0, cy1). DCL initializes count=0 and offset=1
; on entry when records enabled.
;   $03 = both (default), $01 = top only, $02 = bot only, $00 = none
; CB clip working set ($B2-$B9)

; === Tighten pre-dominance flags ($B6 — reuses CB clip slot, non-overlapping) ===
; Set per-span at post-old-interp dom check. Drives gating in new interp paths
; so we skip top or bot interps when one side is dominated by the old span.
;   bit 0 = top_dom (zp_nt_l/r preset to 0 sentinels — max(ot,nt) = ot)
;   bit 1 = bot_dom (zp_nb_l/r preset to $FF sentinels — min(ob,nb) = ob)

; === Tighten secondary seg params ($B2-$B5) — reuses DCL CB slots ===
; Passed by the wrapper when emit_sec_top/emit_sec_bot flags are set.
; Secondary values are the front ceiling/floor y at sx1/sx2 (u8 post-remap).
; Used by ncf to emit the ft/fb line alongside the primary bt/bb line.

; === Line output buffer ($0200) ===
; Lines emitted during tighten (portal edges) and mark_solid (wall edges).
; Format: byte count at $0200, then x1,y1,x2,y2 tuples at $0201+.
; Drained by Python after each tighten/mark_solid call.
LINE_OUT_COUNT = $0200
LINE_OUT_BUF = $0201

; === Tighten records buffers ($0700, $0800) ===
; clip_line_records writes per-span sub-records here; tighten_from_records
; consumes them. Each buffer: byte 0 = record count, then records (6
; bytes each) at offset +1. Top buffer for yt-line, bot buffer for yb-line.
;   Record format: si (slot index), sox0, sox1, verdict, cy0, cy1
;     verdict: 0 = above, 1 = inside, 2 = below
;     cy0, cy1 only meaningful for verdict=inside (line y at sox0, sox1)
; NOTE (2026-07): the 6-byte verdict record layout above is the LEGACY
; Phase-A format and is retained as a historical reference only.  The
; shipping records path uses 4-byte segment records (xl, yl, xr, yr) —
; one per surviving DCL segment — written by dcl_emit_segment (clip/dcl.s)
; and consumed by tighten_from_records (clip/tfr.s).  Byte 0 of each
; buffer is still the record COUNT; records start at offset 1.
; REC_BYTES/REC_VERDICT_* below are unreferenced (kept: equates emit no
; bytes and record the old scheme).
TOP_RECORDS = $0700
BOT_RECORDS = $0800
REC_BYTES = 6                           ; bytes per record
REC_VERDICT_ABOVE = 0
REC_VERDICT_INSIDE = 1
REC_VERDICT_BELOW = 2

; === NJ rasteriser integration ===
; When rasteriser is loaded at $A900, emit_line calls it directly.
; ZP $82-$85 = x0,y0,x1,y1 (rasteriser inputs, no conflict with clipper ZP).
; ZP $70 = screen start hi byte (set once by Python before frame).
RASTER_ENTRY = $A900

; === Zero-page workspace ($C0-$FF) ===
; Layout: list management (head, free), input params (seg coords s16),
; interpolation temps (i_x, i_y0, mul_b, prod, div), scratch (tmp0-3),
; and tighten state (overlap bounds, crossover X, boundary values).
; Note: prod_lo aliases div_lo -- multiply output feeds directly into
; division input, saving two loads per interp call.
; Seg parameters: 16-bit (lo/hi pairs). Values can be outside [0,255].
; s16 Y for seg interp
