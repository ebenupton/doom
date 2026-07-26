
; ============================================================================
; clip/query.s — clipper fragment 6 of 10 (module map: clip/header.s).
; Contents: span_has_gap, plus the retirement notes for the old
; per-span tighten whose site this was, span_is_full and span_read.
; ============================================================================

; ======================================================================
; HAS_GAP: fast visibility check for column range [ilo, ihi]
;
; Returns C=1 if ANY active span overlaps the query range, C=0 otherwise.
; Most-called entry point (~174 calls/frame).  The inner loop is just
; 3 compares + linked-list chase, so it's very fast per iteration.
; Profile: ~14% of all clipper cycles despite trivial per-call cost,
; due to sheer call frequency.
;
; Input:  A = interval hi, zp_i_l = interval lo (closed range; caller
;         pre-clamps to [0,255]).  zp_i_h is NOT touched: ihi lives in
;         A for the whole routine (Eben's 2026-07-26 rewrite).
; Output: C = verdict (C=1 gap / C=0 none) — C-ONLY since 2026-07-26;
;         A returns the caller's ihi UNTOUCHED (no exit materializes
;         a 0/1 any more); Z, N and V are UNDEFINED here. Clobbers
;         X,Y; may update zp_hg_cache (slot of the hit span).
; Callers: bsp/bbox.s (bbox visibility probe) and bsp/subsector.s (seg
; prelude) — direct JSR (bank C paged in the banked build); harness.
;
; Python mirror: EndpointClipSpans.has_gap — a pure X-overlap test:
; every live span is treated as having aperture (no top/bot check).
; pseudocode:
;   for s in spans (sorted by xstart):
;     if s.xend < ilo:  continue          # wholly left — keep scanning
;     return 1 if s.xstart <= ihi else 0  # first candidate decides
;   return 0
; ======================================================================
; MOVED TO MAIN (2026-07-15): has_gap touches ONLY main-RAM state
; (POOL_* $04xx/$05xx + zp) — hosting the code in bank C forced a
; PAGE BANK_C round-trip at every probe (~174 calls/frame, and the
; hottest cross-bank transition on the audit: bbox's angle work L2 ->
; C -> back). It lives in the B segment (CODE region, unbanked) so
; callers just JSR/JMP span_has_gap directly (linker-resolved) — the
; harness.
.export span_has_gap
SEG_CODE
span_has_gap:
.scope
; ABI (A-hi pure-register + C-ONLY RETURN, 2026-07-26; supersedes the
; same-day A-lo and entry-STA cuts, and the 2026-07-20 "A/Z with
; C == A" contract):
;
;   in:  A = interval hi, zp_i_l = interval lo (closed [lo, hi])
;   out: C = verdict. C=1 -> some active span overlaps [lo, hi]
;                     C=0 -> none does (range fully solid)
;        A = ihi, UNTOUCHED (every instruction below is a load, a
;            compare, CLC or a store — nothing writes A)
;        Z/N = undefined (last compare's leftovers)
;        V   = untouched (no instruction here affects it) — this is
;            LOAD-BEARING: the bca classify tail runs CLV before its
;            fused JMPs here, and the dcap record store reads V=0
;            (extent) vs V=1 (cull) AFTER this routine returns. Do
;            not add ADC/SBC/BIT/PLP to this routine.
;
; ihi NEVER lands in memory here — A carries it through the probe
; (xstart test first; the two probe tests are independent), the walk
; (xend compares ride Y/X via CPY/CPX zp_i_l, scratching the idle
; cursor register — safe, each advance reloads it), and the hit
; checks (CMP POOL_XSTART off A). zp_i_h is neither read nor written:
; its post-call consumers have their own writers (mark_solid/tfr get
; the emit-path clamp; the dst*_ext record store reads bca_ihi landed
; by the bca classify tail).
;
; C provenance, per exit (no exit executes a flag instruction except
; hgn0's CLC — the verdict IS the last compare's carry):
;   probe hit        CPY zp_i_l fell through BCC  -> C=1
;   hg_chk_x/y       CMP POOL_XSTART's carry, returned RAW (branch-
;                    free: the cache store precedes the compare)
;   hgn (list ran out) CPY/CPX zp_i_l, BCS not taken -> C=0
;   hgn0 (empty list) explicit CLC (C is caller junk on this entry)
;
; Consumers of C: subsector's seg gate (BCS hg_pass), the walk's six
; bbox branches (BCC skip), the dcap record stores (C rides through
; their loads/stores back to the walk), and the harness (reads P.C).
; The old A=0/1 materialization had exactly one non-redundant reader
; (the ROL A encode in the dcap stores) — that decode now reads V, so
; the four LDA #0/#1 exit loads died with it.
; Return 1 if any active span overlaps the range, 0 otherwise. Spans
; are sorted by xstart.
; Coherence cache: check last-CANDIDATE span first (saves full walk).
; Cache probe: if the cached slot overlaps [ilo,ihi], answer 1 without
; walking. The walk stores its candidate slot unconditionally (hit OR
; fail — see the hit checks); only a positive PROBE shortcuts, so a
; cached non-overlapper is harmless. (mark_solid / tighten zero the
; cache, so a live cached slot always holds current XSTART/XEND.)
   LDX zp_hg_cache
   BEQ hg_no_cache
   CMP POOL_XSTART,X                       ; A = ihi, straight off the entry
   BCC hg_no_cache
; ihi < xstart → miss
   LDY POOL_XEND,X
   CPY zp_i_l
   BCC hg_no_cache
; xend < ilo → miss
   RTS                                     ; cache hit: C=1 from the CPY
                                           ; (BCC fell); A still = ihi
hg_no_cache:
; Unrolled 2× ping-pong: X and Y alternate as the current span offset.
; Eliminates the TAX in the skip path (−2.5 cyc per skip iteration avg).
   LDX zp_head
   BEQ hgn0
; --- X iteration: current span in X ---
hgl_x:
   LDY POOL_XEND,X
   CPY zp_i_l
   BCS hg_chk_x
; xend >= ilo → hit
   LDY POOL_NEXT,X
   BEQ hgn
; advance via Y
; --- Y iteration: current span in Y ---
hgl_y:
   LDX POOL_XEND,Y
   CPX zp_i_l
   BCS hg_chk_y
; xend >= ilo → hit
   LDX POOL_NEXT,Y
   BNE hgl_x
; advance via X; chain end FALLS INTO hgn (C=0 from the CPX above —
; no CLC needed; Eben's catch: hgn0 moved out of line 2026-07-26)
hgn:
   RTS                                     ; no gap: C=0, A = ihi untouched
hgn0:
   CLC                                     ; empty active list ONLY: C is
                                           ; the caller's junk on this entry
                                           ; (the one compare-free path) —
                                           ; normalize to the C=0 no-gap
                                           ; verdict. Out of line: the hot
                                           ; chain-end exits above never
                                           ; execute it.
   RTS
; --- Hit checks (one copy per register, avoids TYX which doesn't exist) ---
; BRANCH-FREE (2026-07-26, Eben's 'always update the cache'): the
; candidate slot is stored UNCONDITIONALLY before the compare, so the
; old BCS + separate yes-exits (whose only job was to skip the store
; on a no) are gone. Caching a FAILING candidate is sound: it is
; still a live span (mark_solid/tighten zero the cache on any
; mutation), and the probe only ever shortcuts POSITIVE overlaps — a
; cached non-overlapper just falls through to the walk. A = ihi
; throughout; the CMP's carry IS the returned verdict (C=0: xstart >
; ihi — first candidate starts past the range, and the list is
; sorted, so no later span can overlap either). -3 cycles on the gap
; verdict, +1 on the no-gap one; hits dominate.
hg_chk_x:
   STX zp_hg_cache
   CMP POOL_XSTART,X
   RTS
hg_chk_y:
   STY zp_hg_cache
   CMP POOL_XSTART,Y
   RTS
.endscope
SEG_BANKC
; (span_is_full RETIRED 2026-07-26: the walk inlines SPAN_IS_NOT_FULL
; — LDA zp_head, Z = solid — and the harness reads zp_head directly.
; Python mirror: EndpointClipSpans.is_full == not self.spans.)
; (ballast stripped same day with the rest of the perf pads — free
; space now consolidates at the CODE segment end)

; (span_read RETIRED 2026-07-26: the serializer was harness-only —
; SpanClip6502.read_spans now walks zp_head/POOL_* directly in Python
; and reconstructs xhi = xlo + den itself. zp_buf ($62) died with it;
; $63 was only ever zp_bv_entry's lo byte wearing a second hat.)

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

; (2-byte tighten hot-loop page pad stripped 2026-07-26 with the rest
; of the perf padding)
