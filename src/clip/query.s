
; ============================================================================
; clip/query.s — clipper fragment 6 of 10 (module map: clip/header.s).
; Contents: span_has_gap (jt_has_gap), span_is_full (jt_is_full),
; span_read (jt_read, harness serializer), plus the retirement note for
; the old per-span tighten whose site this was.
; ============================================================================

; ======================================================================
; HAS_GAP: fast visibility check for column range [ilo, ihi]
;
; Returns A=1 if ANY active span overlaps the query range, A=0 otherwise.
; Most-called entry point (~174 calls/frame).  The inner loop is just
; 3 compares + linked-list chase, so it's very fast per iteration.
; Profile: ~14% of all clipper cycles despite trivial per-call cost,
; due to sheer call frequency.
;
; Input:  zp_ilo, zp_ihi (closed range; caller pre-clamps to [0,255]).
; Output: A = 1/0 (Z reflects result).  Clobbers X,Y; may update
;         zp_hg_cache (slot of the hit span, for the next call).
; Callers: bsp/bbox.s (bbox visibility probe) and bsp/subsector.s (seg
; prelude) via jt_has_gap (bank C paged in the banked build); harness.
;
; Python mirror: EndpointClipSpans.has_gap — a pure X-overlap test:
; every live span is treated as having aperture (no top/bot check).
; pseudocode:
;   for s in spans (sorted by xstart):
;     if s.xend < ilo:  continue          # wholly left — keep scanning
;     return 1 if s.xstart <= ihi else 0  # first candidate decides
;   return 0
; ======================================================================
span_has_gap:
.scope
; Range [ilo, ihi] (closed). Return 1 if any active span overlaps the
; range, 0 otherwise. Spans are sorted by xstart.
; Coherence cache: check last-matching span first (saves full walk).
; Cache probe: if the cached slot still overlaps [ilo,ihi], answer 1
; without walking. Only a positive answer is cacheable — cache misses
; fall through to the full walk. (mark_solid / tighten zero the cache,
; so a live cached slot always holds current XSTART/XEND.)
   LDX zp_hg_cache
   BEQ hg_no_cache
   LDA POOL_XEND,X
   CMP zp_ilo
   BCC hg_no_cache
; xend < ilo → miss
   LDA zp_ihi
   CMP POOL_XSTART,X
   BCC hg_no_cache
; ihi < xstart → miss
   LDA #1
   RTS
; cache hit → return 1 (avoids page-cross)
hg_no_cache:
; Unrolled 2× ping-pong: X and Y alternate as the current span offset.
; Eliminates the TAX in the skip path (−2.5 cyc per skip iteration avg).
   LDX zp_head
   BEQ hgn
; --- X iteration: current span in X ---
hgl_x:
   LDA POOL_XEND,X
   CMP zp_ilo
   BCS hg_chk_x
; xend >= ilo → hit
   LDY POOL_NEXT,X
   BEQ hgn
; advance via Y
; --- Y iteration: current span in Y ---
hgl_y:
   LDA POOL_XEND,Y
   CMP zp_ilo
   BCS hg_chk_y
; xend >= ilo → hit
   LDX POOL_NEXT,Y
   BNE hgl_x
; advance via X
hgn:
   LDA #0
   RTS
; --- Hit checks (one copy per register, avoids TYX which doesn't exist) ---
hg_chk_x:
   LDA zp_ihi
   CMP POOL_XSTART,X
   BCS hg_cx_yes
   LDA #0
   RTS
hg_chk_y:
   LDA zp_ihi
   CMP POOL_XSTART,Y
   BCS hg_cy_yes
   LDA #0
   RTS
hg_cx_yes:
   STX zp_hg_cache
   LDA #1
   RTS
hg_cy_yes:
   STY zp_hg_cache
   LDA #1
   RTS
.endscope

; ======================================================================
; IS_FULL: check if screen is completely occluded (active list empty)
; Returns A=1 if head==0 (all columns solid), A=0 otherwise.
; Input: zp_head only.  No clobbers besides A (X,Y preserved).
; Callers: bsp/walk.s (per stack pop) and bsp/defq.s (after each
; deferred op) via jt_is_full; harness.
; Python mirror: EndpointClipSpans.is_full (== not self.spans).
; ======================================================================
span_is_full:
   LDA zp_head
   BEQ sif_yes
   LDA #0
   RTS
sif_yes:
   LDA #1
   RTS

; ======================================================================
; SPAN_READ: serialize active span list to buffer at (zp_buf)
; Output: byte 0 = count, then 8 bytes per span (xstart, xend, xlo,
; xhi, tl, bl, tr, br).  Used by test harness for state comparison.
;
; Input:  zp_buf = u16 pointer to output buffer (harness sets $0300);
;         zp_head = active list.
; Output: buffer filled as above; xhi is RECONSTRUCTED as xlo + den
;         (the pool stores DEN, not XHI); count written last at offset
;         0.  Clobbers A,X,Y, zp_tmp0 (running count).
; Consumed by SpanClip6502.read_spans (span_clip_6502.py), which
; returns the same 8-tuples as EndpointClipSpans.spans.
; NB: no overflow guard — 31 spans max * 8 + 1 = 249 bytes, fits a page.
; ======================================================================
span_read:
.scope
; Output: 1 byte count, then 8 bytes per span:
;   xstart, xend, xlo, xhi, tl, bl, tr, br
   LDY #1
   LDA #0
   STA zp_tmp0
   LDX zp_head
   BEQ srd
srl:
   INC zp_tmp0
   LDA POOL_XSTART,X
   STA (zp_buf),Y
   INY
   LDA POOL_XEND,X
   STA (zp_buf),Y
   INY
   LDA POOL_XLO,X
   STA (zp_buf),Y
   INY
   CLC
   ADC POOL_DEN,X
   STA (zp_buf),Y
   INY
; xhi = xlo + den
   LDA POOL_TL,X
   STA (zp_buf),Y
   INY
   LDA POOL_BL,X
   STA (zp_buf),Y
   INY
   LDA POOL_TR,X
   STA (zp_buf),Y
   INY
   LDA POOL_BR,X
   STA (zp_buf),Y
   INY
   LDA POOL_NEXT,X
   TAX
   BNE srl
srd:
   LDA zp_tmp0
   LDY #0
   STA (zp_buf),Y
   RTS
.endscope

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
; NOTE (2026-07): the banner above describes the RETIRED per-span
; tighten that lived at this site. Narrowing is now records-driven:
; DCL writes 4-byte segment records while clipping the portal edge
; lines, and tighten_from_records (clip/tfr.s) consumes them with a
; 3-cursor event walk — no per-span seg interpolation here any more.
; The banner is kept as an algorithm reference for what the records
; walk must be state-equivalent to; only the alignment pad remains.
; Extra ZP for tighten (zp_new_tail aliases zp_save2 — tighten doesn't use mark_solid scratch)
; Crossover divide working set ($FA-$FF)

.word 0                                 ; 2-byte alignment pad for tighten hot loop page optimization
