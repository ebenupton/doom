
; ============================================================================
; clip/mark_solid.s — clipper fragment 5 of 13 (module map: clip/header.s).
; Contents: span_mark_solid only. Carries the pool push/pop INLINE
; (the alloc_span/free_span subroutines were retired 2026-08-21 — see
; clip/pool.s); POOL_* field equates from clip/arith.s.
; ============================================================================

; (interp_span removed — mark_solid no longer interpolates)

; (interp_span removed — padding removed to preserve page alignment of later code)

; 0-byte pad: optimal alignment for narrowed-BB layout

; ======================================================================
; MARK_SOLID: punch out the HALF-OPEN range [lo, hi) (solid wall)
;
; NATIVE half-open throughout (the 2026-08-20 decree; arms completed
; 2026-08-21): every boundary write is a PURE COPY of lo or hi — no
; +-1 arithmetic anywhere.
;
; LAZY operation: only adjusts XSTART/XEND on affected spans.
; Line params (XLO/DEN/TL/BL/TR/BR) are NEVER modified -- zero interp
; calls needed.  When a solid range splits a span in the middle, a
; sibling slot is allocated and the 10 field bytes are copied verbatim.
;
; Three cases per overlapped span [xs, xe):
;   1. No left frag (xs >= lo): free entirely (xe <= hi) or xs := hi
;   2. Left only    (xe <= hi): xe := lo
;   3. Middle split: sibling gets [hi, xe), original keeps [xs, lo)
;
; Input:  zp_i_l, zp_i_h = solid range [lo, hi), pre-clamped to
;         [0, 255] by the caller; hi <= lo = empty = no-op.
;         zp_head = active span list (sorted by XSTART, disjoint).
; Output: every open column in [lo, hi) removed; freed slots pushed
;         on the free list; zp_head updated; zp_hg_cache invalidated.
;         Clobbers A,X,Y, zp_prev, zp_tmp0.
;
; Callers: bsp/seg_emit.s (solid-seg arm) + bsp/tfr consumers via
; direct JSR — bank C must be paged in the banked build — and the
; harness's mark_solid.
;
; Python mirror: EndpointClipSpans.mark_solid (lazy, line-preserving).
; pseudocode (per span s = [xs, xe), walked left to right):
;   if xe <= lo: skip (fast ping-pong scan below)
;   if xs >= hi: done (list is sorted)
;   if xs >= lo:                           # no left fragment
;       if xe <= hi: unlink + free s       # fully covered
;       else:        s.xs = hi             # shrink in place, TERMINAL
;   else:                                  # keep left fragment
;       if xe <= hi: s.xe = lo             # right part swallowed
;       else:                              # middle split, TERMINAL
;           sib = alloc(); sib.line = s.line (copied verbatim)
;           sib.range = [hi, xe); link after s; s.xe = lo
; The two fragments of a split ABUT the removed range exactly (share
; its boundary edges lo and hi) — no gap columns, no overlap: the
; half-open tiling has no seam arithmetic at all.
; ======================================================================
span_mark_solid:
.scope
; mark_solid is now LAZY: it only updates the active range (XSTART/XEND)
; on existing spans. The line params (XLO/XHI/TL/BL/TR/BR) never change,
; so no interp_store calls happen here. Splitting a span in the middle
; just allocates a sibling and copies the 6 line bytes verbatim.
; Invalidate the has_gap coherence cache: this entry frees/merges
; slots, and a stale cached slot's leftover XSTART/XEND can overlap
; any later query (observed: freed slot (60,69) made has_gap(60,73)
; return 1 against a pool whose only live span was (121,132)).
   ZERO zp_hg_cache
; Degenerate range (hi <= lo = EMPTY half-open) → no-op. REVERSED
; (Eben, 2026-08-21): comparing FROM lo makes "empty" a single carry
; test — C = (lo >= hi) — instead of the BEQ/BCS pair the hi-first
; form needed to catch equality separately. 8 cycles on the live
; path, was 11, and 2 bytes shorter. (A = lo here is dead: the
; sentinel store below overwrites it.)
   LDA zp_i_l
   CMP zp_i_h                              ; C = lo >= hi -> empty
   BCS ms_rts0
; Empty active list? REVERSED (Eben, 2026-08-21): exit on Z and FALL
; INTO the scan below, instead of BNE-ing into it — the live path
; loses a taken branch and the RTS folds into the shared exit.
   LDX zp_head
   BEQ ms_rts0
; PREDECESSOR RIDES A REGISTER (Eben, 2026-08-21). The ping-pong
; already holds it: at msl_x the previous span is in Y, at msl_y it is
; in X. So zp_prev is written ONCE, at the classification landing,
; instead of on every skip iteration — and the $FF "current is the
; head" sentinel just seeds Y here, so the entry store dies too.
; ($FF is never used as an index before the landing stores it.)
   LDY #$FF                                ; sentinel predecessor
   LDA zp_i_l                              ; HOISTED: lo is loop-invariant
                                        ; and NOTHING in the scan body
                                        ; touches A (the ping-pong
                                        ; advances via LDX/LDY), so it
                                        ; rides the whole walk

; --- Skip-ahead scan: chase NEXT while xe <= lo (span wholly left of
;     the solid range — strict half-open: xe == lo is edge-touch, not
;     overlap). Unrolled 2x ping-pong: the current slot alternates
;     X/Y so the skip path needs no TAX/TAY transfer. zp_prev tracks
;     the predecessor for the unlink in ms_free. ---
msl:                                    ; X = current span — entered by
msl_x:                                  ; FALL-THROUGH from the prologue,
                                        ; branch target from free/shrink
   CMP POOL_XEND,X                         ; A = lo (hoisted): C=(lo>=xe)
   BCC ms_chk_after                        ; = wholly-left skip; X = cur,
                                        ; Y = predecessor
   LDY POOL_NEXT,X                         ; advance: X becomes the pred
   BEQ ms_rts_x
; ||
msl_y:
   CMP POOL_XEND,Y                         ; (mirror: Y = cur, X = pred)
   BCC ms_chk_after_y
; ||||
   LDX POOL_NEXT,Y                         ; advance: Y becomes the pred
   BNE msl_x
; ||
ms_rts_x:
ms_rts0:                                   ; shared RTS (empty-range +
   RTS                                     ; empty-list entries)

; --- Overlap classification (entered from the scan loop when
;     xend >= ilo, i.e. the span is not entirely left of the range) ---
ms_chk_after_y:                            ; Y = current, X = predecessor
   STX zp_prev                             ; save pred BEFORE TAX eats it
   TYA
   TAX                                     ; Y→X for the overlap code
   BNE ms_chk_body                         ; always taken (a live slot is
                                        ; never 0) — skips the X arm's
                                        ; own store
ms_chk_after:                              ; X = current, Y = predecessor
   STY zp_prev                             ; ($FF on the first span)
ms_chk_body:
; Done if xstart > ihi (span starts after solid range).
; Load xstart once and reuse for both ihi and ilo comparisons.
   LDA POOL_XSTART,X                       ; NATIVE: done iff xs >= hi
   CMP zp_i_h                              ; (xs == hi is wholly-right —
   BCS ms_rts_x                            ; the legacy BEQ overlap died)
; |||
ms_overlap:
; A = xstart (from ms_chk_after). Check left fragment.
; xs < lo  → keep a left fragment   (xe may need truncating too)
; xs >= lo → no left fragment       (span starts inside [lo, hi))
   CMP zp_i_l
   BCC ms_has_left
; ||
; --- No left fragment ---
; xe > hi  → shrink in place (BCC past ms_free)
; xe <= hi → fully covered → fall through to ms_free
   LDA zp_i_h
   CMP POOL_XEND,X
   BCC ms_shrink
; |

; --- Fully covered: free this span (fall-through, no JMP) ---
; Save NEXT before freeing (free_span overwrites POOL_NEXT,X), then
; unlink: through zp_head when prev==$FF sentinel, else prev's NEXT.
ms_free:
   LDA POOL_NEXT,X
   STA zp_tmp0
; |
; free_span INLINED (2026-08-21): its 3-instruction body costs 7 bytes
; against the JSR's 3, and kills a 12-cycle JSR/RTS on a path taken
; ~6x per frame. X is preserved by the body, exactly as the sub did.
; (free_span itself stays — clip/tfr.s tail-calls it.)
   LDA zp_free
   STA POOL_NEXT,X
   STX zp_free
   LDY zp_prev
   BPL ms_unlink_span
; |
   LDX zp_tmp0                             ; (LDX/STX: A is not needed
   STX zp_head                             ; here and LDX sets Z)
   BEQ ms_rts_x
   LDY #$FF                                ; new current IS the head: re-seed
                                        ; the sentinel predecessor
   LDA zp_i_l                              ; restore the hoisted invariant
   JMP msl
; |
ms_unlink_span:
   LDA zp_tmp0
   STA POOL_NEXT,Y                         ; (STX has no abs,Y form)
   TAX
   BEQ ms_rts_x
   LDA zp_i_l                              ; restore the hoisted invariant
   JMP msl
; |

ms_shrink:
; Shrink in place: xstart := hi — a PURE COPY under half-open (the
; span keeps its line + its part [hi, xend)). The closed-era ADC #1
; here over-removed one open column (found in the 2026-08-21 comment
; re-derivation; the shadowing gates compare 6502-vs-6502 and the
; pure-python lockstep drift was tolerated, so only verify-vs-float
; saw it).
; A holds hi (from the CMP above).
; TERMINAL: this span extends past hi and the list is x-sorted &
; disjoint — nothing after can intersect [lo, hi).
   STA POOL_XSTART,X
   RTS


ms_has_left:
; xs < lo. Right fragment too? (xe > hi → middle split)
   LDA zp_i_h
   CMP POOL_XEND,X
   BCS ms_left_only
; |
; --- Middle split: allocate sibling for the right fragment ---
; Original span becomes the left fragment [xs, lo); the sibling
; inherits the SAME line definition (10 field bytes copied verbatim,
; including the precomputed OT/OB/IT/IB bbox) and takes [hi, xe).
; On pool exhaustion the right fragment is sacrificed (left-only) —
; conservative: drops open columns, never leaks solid ones as open.
   STX zp_prev                             ; |
   LDX zp_free                             ; alloc_span INLINED 2026-08-21:
   BEQ ms_left_only_after_fail          ; pool empty -> caller's fail arm
   LDA POOL_NEXT,X                         ; (the sub's TXA and the caller's
   STA zp_free                             ; BEQ existed only to carry Z
                                        ; across the JSR — both die)
; |
   LDY zp_prev                             ; Y = original span (the left fragment)               ; |
; Copy line params from Y to X (sibling shares the same line)
   LDA POOL_XLO,Y
   STA POOL_XLO,X
; |
   LDA POOL_DEN,Y
   STA POOL_DEN,X
; |
   LDA POOL_TL,Y
   STA POOL_TL,X
; |
   LDA POOL_BL,Y
   STA POOL_BL,X
; |
   LDA POOL_TR,Y
   STA POOL_TR,X
; |
   LDA POOL_BR,Y
   STA POOL_BR,X
; |
   LDA POOL_OT,Y
   STA POOL_OT,X
; |
   LDA POOL_OB,Y
   STA POOL_OB,X
; |
   LDA POOL_IT,Y
   STA POOL_IT,X
; |
   LDA POOL_IB,Y
   STA POOL_IB,X
; |
; Sibling's active range = [hi, original xend) — pure copies under
; half-open (the closed +1/-1 pair died with the 2026-08-21 fix).
   LDA zp_i_h
   STA POOL_XSTART,X
; |
   LDA POOL_XEND,Y
   STA POOL_XEND,X
; |
; Insert sibling after original
   LDA POOL_NEXT,Y
   STA POOL_NEXT,X
; |
   TXA
   STA POOL_NEXT,Y
; |
; Original (Y) now becomes the left fragment [xstart, lo).
   LDA zp_i_l
   STA POOL_XEND,Y
; |
; TERMINAL: the sibling covers [hi, old xend) and the list is x-sorted
; & disjoint — nothing after can intersect [lo, hi).
   RTS

ms_left_only_after_fail:
; alloc failed → fall through and just truncate left fragment
   LDX zp_prev
ms_left_only:
; xend = lo (NATIVE: truncate to the left fragment [xs, lo) — the
; SEC/SBC carry dance died with the half-open decree)
   LDA zp_i_l
   STA POOL_XEND,X
; |
   LDY POOL_NEXT,X                         ; re-enter the Y arm with X = the
   BEQ ms_rts_ml                           ; truncated fragment = the next
   JMP msl_y                               ; span's predecessor (store dies)
; |
ms_rts_ml:
   RTS

.endscope
