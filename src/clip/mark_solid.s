
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
;
; Input:  zp_ilo, zp_ihi = solid column range (closed, both inclusive,
;         pre-clamped to [0,255] by the caller; ihi < ilo = no-op).
;         zp_head = active span list (sorted by XSTART).
; Output: every active column in [ilo,ihi] removed; freed slots pushed
;         on the free list; zp_head updated; zp_hg_cache invalidated.
;         Clobbers A,X,Y, zp_prev, zp_tmp0.
;
; Python mirror: EndpointClipSpans.mark_solid (lazy, line-preserving).
; pseudocode (per span s, walked left to right):
;   if s.xend   <  ilo: skip (fast ping-pong scan below)
;   if s.xstart >  ihi: done (list is sorted)
;   if s.xstart >= ilo:                    # no left fragment
;       if s.xend <= ihi: unlink + free s  # fully covered
;       else:             s.xstart = ihi+1 # shrink in place, done-check
;   else:                                  # keep left fragment
;       if s.xend <= ihi: s.xend = ilo-1   # right part swallowed
;       else:                              # middle split
;           sib = alloc(); sib.line = s.line (copied verbatim)
;           sib.range = [ihi+1, s.xend]; link after s; s.xend = ilo-1
; Fragments here are NON-abutting (ilo-1 / ihi+1): solid columns are
; removed outright, unlike tighten's shared-boundary fragments.
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
; Degenerate range (ihi < ilo) → no-op.
LDA zp_ihi
CMP zp_ilo
BCS mss
; |
RTS
mss:
; zp_prev = $FF sentinel: "current span is the list head" (unlink via
; zp_head rather than a predecessor's NEXT).
LDA #$FF
STA zp_prev
; |
LDA zp_head
TAX
BNE msl
RTS
; |

; --- Overlap classification (entered from the scan loop when
;     xend >= ilo, i.e. the span is not entirely left of the range) ---
ms_chk_after_y:
TYA
TAX
; Y→X for overlap code
ms_chk_after:
; Done if xstart > ihi (span starts after solid range).
; Load xstart once and reuse for both ihi and ilo comparisons.
LDA POOL_XSTART,X                       ; |
CMP zp_ihi
BEQ ms_overlap
BCS ms_rts_x
; |||
ms_overlap:
; A = xstart (from ms_chk_after). Check left fragment.
; xstart < ilo  → keep a left fragment   (xend may need clip too)
; xstart >= ilo → no left fragment       (this span is entirely in or right of [ilo,ihi])
CMP zp_ilo
BCC ms_has_left
; ||
; --- No left fragment ---
; xend > ihi  → shrink in place (BCC past ms_free)
; xend <= ihi → fully covered → fall through to ms_free
LDA zp_ihi
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
JSR free_span                           ; |
LDA zp_prev
CMP #$FF
BNE ms_unlink_span
; |
LDA zp_tmp0
STA zp_head
TAX
BNE msl
RTS
; |
ms_unlink_span:
LDY zp_prev
LDA zp_tmp0
STA POOL_NEXT,Y
TAX
BNE msl
RTS
; |

ms_shrink:
; Shrink in place: xstart = ihi + 1 (span keeps its line + right part).
; A holds ihi; carry clear from BCC
ADC #1
STA POOL_XSTART,X
; |
STX zp_prev
LDA POOL_NEXT,X
TAX
BEQ ms_rts_x
; Fall through to msl (common: continue scanning)

; --- Skip-ahead scan: chase NEXT while xend < ilo (span wholly left of
;     the solid range). Unrolled 2x ping-pong: the current slot
;     alternates X/Y so the skip path needs no TAX/TAY transfer.
;     zp_prev tracks the predecessor for the unlink in ms_free. ---
msl:                                    ; X = current span — fall-through from shrink, branch target from free
msl_x:
LDA POOL_XEND,X
CMP zp_ilo
BCS ms_chk_after
; ||||
STX zp_prev
LDY POOL_NEXT,X
BEQ ms_rts_x
; ||
msl_y:
LDA POOL_XEND,Y
CMP zp_ilo
BCS ms_chk_after_y
; ||||
STY zp_prev
LDX POOL_NEXT,Y
BNE msl_x
; ||
ms_rts_x:
RTS

ms_has_left:
; xstart < ilo. Has right fragment? xend > ihi?
LDA zp_ihi
CMP POOL_XEND,X
BCS ms_left_only
; |
; --- Middle split: allocate sibling for the right fragment ---
; Original span becomes the left fragment; the sibling inherits the
; SAME line definition (10 field bytes copied verbatim, including the
; precomputed OT/OB/IT/IB bbox) and takes the right active range.
; On pool exhaustion the right fragment is sacrificed (left-only) —
; conservative: drops open columns, never leaks solid ones as open.
STX zp_prev                             ; |
JSR alloc_span
BEQ ms_left_only_after_fail
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
; Sibling's active range = [ihi+1, original xend]
; carry already clear: BCS ms_left_only fell through (C=0) and alloc_span/STAs don't change C
LDA zp_ihi
ADC #1
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
; Original (Y) now becomes the left fragment: xend = ilo - 1
; carry is clear: C=0 propagated from BCS fall-through, through alloc+copies+ADC(no overflow)
LDA zp_ilo
SBC #0
STA POOL_XEND,Y
; |
; Continue from the span AFTER the new sibling
STX zp_prev
LDY POOL_NEXT,X
BEQ ms_rts_ms
JMP msl_y
; |
ms_rts_ms:
RTS

ms_left_only_after_fail:
; alloc failed → fall through and just truncate left fragment
LDX zp_prev
ms_left_only:
; xend = ilo - 1 (truncate to left fragment only)
LDA zp_ilo
SEC
SBC #1
STA POOL_XEND,X
; |
STX zp_prev
LDY POOL_NEXT,X
BEQ ms_rts_ml
JMP msl_y
; |
ms_rts_ml:
RTS

.endscope
