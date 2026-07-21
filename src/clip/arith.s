; ============================================================================
; clip/arith.s — clipper fragment 2 of 10 (see clip/header.s for the module
; map and entry contracts). Contents: the pinned umul8 primitive (FIRST code
; in the CLIP segment so the flat build lands it at $2030 — ABI pin), the
; span-pool field equates (POOL_*), Y_BIAS, sqr table aliases, the records /
; LINE_OUT / rasteriser interface constants, and the ZP layout notes.
; Sibling cross-refs: pool.s (allocator + udiv16_8), interp.s (interp_store),
; dcl.s (records + LINE_OUT writers), tfr.s (records consumer).
; ============================================================================

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
; always reads sqr_l/hi.
;
; Input:  A = a (u8), zp_mul_b = b (u8)
; Output: zp_prod_l:zp_prod_h = a*b (u16).  Clobbers X,Y, zp_tmp0.
;         CONTRACT (2026-07-09): A = zp_prod_h on return AND the N/Z
;         flags reflect it — BOTH exit paths end `STA zp_prod_h`, which
;         leaves A intact. Callers may take the product's HIGH byte
;         straight from A (backface's u24 magnitude products do). Preserve
;         this if you ever restructure the tail.
;         zp_prod_l/hi alias zp_div_l/hi, so the product feeds
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
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_prod_l
; |||||
   LDA sqr_h,X
   SBC sqr_h,Y
   STA zp_prod_h
   RTS
; |||||||
uo:                                     ; sum >= 256: sqr2 tables for sum (carry already set from BCS)
; prod = sqr2[s & 255] - sqr[d]  (X already wrapped mod 256 by the ADC)
   LDA sqr2_l,X
   SBC sqr_l,Y
   STA zp_prod_l
   LDA sqr2_h,X
   SBC sqr_h,Y
   STA zp_prod_h
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
; abi.inc owns the table base (SQR_BASE; banked $1C00 low RAM — above
; BCA_WS $1B40, below the drivers at $2000; reachable from the bank-C
; clipper AND bsp_render's local umul8. Loader-seeded page).
sqr_l = SQR_LO
sqr_h = SQR_HI
sqr2_l = SQR2_LO
sqr2_h = SQR2_HI

; === RETIRED tighten ZP notes (rewritten 2026-07-12) ===
; The blocks that lived here — "seg value cache $A0-$A4", "running seg
; bounds $A5-$A7", "static seg Y bbox $A8-$AB", "tighten pre-dominance
; flags $B6", "tighten secondary seg params $B2-$B5" — all described
; the RETIRED per-span tighten (tg_go / mel / span_tighten; see the
; retirement note in clip/query.s).  None of those symbols exist in
; src/zp.inc any more, and $A0-$A7 belong to the bsp/ang modules today.
; src/zp.inc is the single source of truth for the live map.

; === Draw-clipped-line ZP ($A8-$B9) ===
; Caller sets zp_line_xl/yl/xr/yr ($A8-$AB); DCL computes dx/dy/ylo/yhi
; ($AC-$AF); seg_start $B0/$B1; CB-clip working set $B2-$B9 (overlaid
; with the s16 line HI bytes — phase-disjoint, see zp.inc).  $A8 also
; overlaid the old zp_ms_emit flag (GC'd 2026-07-12: it had no 6502 reader)
; any more (the harness pins it to 0).
; ===== DCL records hook ($BC-$BE) =====
; When zp_dcl_rec_buf_h ($BD) is non-zero, dcl_emit_segment appends ONE
; 4-byte record (xl, yl, xr, yr — biased Y) per SURVIVING segment to the
; buffer at (zp_dcl_rec_buf), bumping the count in byte 0;
; zp_dcl_rec_off ($BE) is the 1-based write offset. Callers arm with hi
; byte $07 (TOP_RECORDS) or $08 (BOT_RECORDS) and disarm with $00.
; br_init_frame grounds the pointer once per frame; every DCL call site
; arms/disarms explicitly.  (An older note here described the legacy
; 6-byte clip_line_records format and a $03/$01/$02 side mask — both
; retired; see the LEGACY note under TOP_RECORDS below.)

; === Line output buffer ($0200) ===
; Segments captured by the DCL emit paths (dcl_emit_segment and
; dcl_vertical's dv_emit in clip/dcl.s) — nothing else writes it since
; the per-span tighten retired.
; Format: byte count at $0200, then x1,y1,x2,y2 tuples at $0201+
; (Y already un-biased).  Drained by the Python wrapper after each
; draw call.
LINE_OUT_COUNT = $0200
LINE_OUT_BUF = $0201
; LINE_OUT capture is HARNESS-ONLY (2026-07-11): the native frame never
; reads the buffer — and worse, $0201-$02FC OVERLAPS the D-cache
; ($0210-$03F7), so on-disc emits were silently clobbering cache
; entries. The Python wrapper sets LINE_OUT_EN around its calls; native
; emits take the direct RASTER_ZP-only path.
LINE_OUT_EN = $0BE8                     ; (freed ROM-pointer block byte)

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
; The NJ rasteriser is NOT part of this link — the flat build loads its
; binary at $A900 (see nj_raster.py for the pixel-exact reference).
; dcl.s's emit dispatch (des_dispatch / dv_emit) tail-calls it for
; diagonal segments; axis-aligned ones (~70% of pixels) go to the local
; plot_h / plot_v in clip/plot_axis.s instead.
; ZP $82-$85 = x0,y0,x1,y1 (rasteriser inputs, no conflict with clipper ZP).
; ZP $70 = screen start hi byte, set per frame by the caller (the walk
; driver stores the back-buffer page; the Python harness sets it in
; flat tests).
.if ::BANKED
RASTER_ENTRY = $A900                    ; bank C window
.else
RASTER_ENTRY = $6200                    ; flat: right after the CODE blob —
                                        ; all code together at one end
.endif

; === Zero-page workspace ===
; src/zp.inc is the single source of truth (one registry shared by the
; whole link).  Clipper-owned highlights (2026-07-12): list head/free +
; query range $C0-$C3, has_gap cache $D0, interp workspace $D1-$D5,
; mul/div set $D9-$DD, tmps $DE-$E0, DCL line + CB clip $A8-$B9,
; records pointer $BC-$BE, save/tfr scratch $6A-$6F, prev/buf $61-$63,
; rasteriser args $70 + $82-$85.  ($E2-$FF is the bsp module's packed
; vertex structs — NOT clipper space; the old "$C0-$FF" claim predates
; that carve-out.)
; Note: prod_lo aliases div_lo -- multiply output feeds directly into
; division input, saving two loads per interp call.
; s16 line endpoints for the s16 clipper enter through zp_line_*_lo/_hi
; (hi bytes overlay the CB-clip slots); the LC_* absolute working set
; for s16 math is declared in clip/tfr.s ($0938-$0958).
