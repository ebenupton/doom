
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
LDA zp_ihi
CMP zp_ilo
BCS mss
; |
RTS
mss:
.if ::EMIT_LINES
; --- Wall edge line emission pre-pass (if seg params provided) ---
LDA zp_ms_emit
BEQ ms_no_emit
; |
JSR ms_emit_lines                       ; |
ms_no_emit:
.endif
LDA #$FF
STA zp_prev
; |
LDA zp_head
TAX
BNE msl
RTS
; |

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
; A holds ihi; carry clear from BCC
ADC #1
STA POOL_XSTART,X
; |
STX zp_prev
LDA POOL_NEXT,X
TAX
BEQ ms_rts_x
; Fall through to msl (common: continue scanning)

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
