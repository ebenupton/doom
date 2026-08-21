
; ============================================================================
; clip/pool.s — clipper fragment 3 of 13 (module map: clip/header.s).
; Contents: span_init and the O(1) free-list allocator
; (alloc_span / free_span).
; Pool layout + field equates (POOL_*) are defined in clip/arith.s;
; ZP names come from src/zp.inc.
; ============================================================================

; ======================================================================
; SPAN_INIT: reset the clipper to one full-screen span
;
; Builds two structures:
;   FREE LIST -- singly-linked chain of unused slots 2..31
;   ACTIVE LIST -- single span (slot 1) covering columns [0, 255) —
;                  XEND = 255 is the native EXCLUSIVE edge (column 255
;                  is nonexistent by decree) — with the full visible
;                  Y band on every column
;
; Called once per frame: the walk driver pages bank C and JSRs
; span_init (address via engine_syms.inc) before the render; the
; Python harness calls it per test frame. Runtime is negligible
; (< 0.5% of total).
;
; Input:  none.
; Output: zp_free = 2 (free chain 2->3->...->31->0),
;         zp_head = 1, slot 1 = full-screen span:
;           XSTART=XLO=0, XEND=DEN=255 (XEND exclusive),
;           TL=TR=OT=IT=Y_BIAS (48), BL=BR=OB=IB=Y_BIAS+159 (207)
;           (screen-space Y is stored BIASED: visible [0,159] -> [48,207])
;         zp_hg_cache = 1 (has_gap coherence cache primed to the span).
; Clobbers A,X.  Python mirror: EndpointClipSpans.__init__.
; ======================================================================
span_init:
.scope
; Free list: slots 2..31 (indices 2,3,...,31).
   LDX #2                                  ; slot 2                                     ; |
   STX zp_free                             ; |
   CLC                                     ; loop C=0 invariant seed (the
                                           ; CMP below re-clears on every
                                           ; continue: BCS not taken)
il:
   TXA
   BUMP_CC                                 ; C=0: seeded + CMP invariant
; ||
   CMP #NUM_SLOTS                          ; reached end? (= 32)                        ; |
   BCS id                                  ; |
   STA POOL_NEXT,X
   TAX
; ||
   BNE il                                  ; always taken                               ; |
id:
   LDA #0                                  ; A = 0 RIDES into slot 1's
   STA POOL_NEXT,X                         ; NEXT/XLO/XSTART stores below —
                                        ; NOT a C02/STZ candidate
; |
; Active list: slot 1 = full screen with biased Y [Y_BIAS, Y_BIAS+159].
   LDX #1                                  ; slot 1 (index 1)                           ; |
   STX zp_head                             ; |
   STA POOL_NEXT,X
   STA POOL_XLO,X
   STA POOL_XSTART,X
; |
   LDA #Y_BIAS                             ; |
   STA POOL_TL,X
   STA POOL_TR,X
; |
   STA POOL_OT,X
   STA POOL_IT,X
; | OT=IT=Y_BIAS
   LDA #255
   STA POOL_DEN,X
   STA POOL_XEND,X
; |
   LDA #(Y_BIAS + 159)                     ; |
   STA POOL_BL,X
   STA POOL_BR,X
; |
   STA POOL_OB,X
   STA POOL_IB,X
; | OB=IB=Y_BIAS+159
   STX zp_hg_cache                         ; init cache to slot 1 (the initial span)   ; |
   RTS                                     ; |
.endscope

; ======================================================================
; ALLOC_SPAN / FREE_SPAN: O(1) pool allocator via free-list push/pop
;
; alloc_span: pops free list head into X.  Z=0 on success, Z=1 if empty.
; free_span:  pushes slot X back onto free list.  Tail-callable (JMP).
;
; alloc_span — In: none. Out: X = slot (0 + Z=1 if pool exhausted).
;              Clobbers A. All other slot fields are stale — caller fills.
; free_span  — In: X = slot to free (must be unlinked from the active
;              list first). Out: slot pushed on free chain. Clobbers A;
;              X preserved.
; ======================================================================
alloc_span:
; Returns X = new span offset.  Z=1 if failed (X=0), Z=0 if success.
; Caller is responsible for setting POOL_NEXT (tg_append_x or mark_solid linking).
   LDX zp_free
   BEQ af
; |
   LDA POOL_NEXT,X
   STA zp_free
; |
   TXA                                     ; A=X≠0, sets Z=0                           ; |
af:
   RTS
; |

free_span:
   LDA zp_free
   STA POOL_NEXT,X
   STX zp_free
   RTS
; |||

; ======================================================================
; UMUL8: unsigned 8x8 multiply via quarter-square identity
;
; Computes A * zp_mul_b using: a*b = sqr(a+b) - sqr(a-b)
; where sqr(n) = floor(n^2/4).  Two table sets handle a+b < 256 vs
; a+b >= 256.  |a-b| is always < 256 so uses sqr_l/hi in both cases.
; Result: zp_prod_l:zp_prod_h (u16).
;
; This is the hottest subroutine -- called by every interpolation.
; ======================================================================
; (umul8 moved to the fixed $2030 slot below the jump table.)
; The code + full I/O header now live in clip/arith.s (included right
; after clip/header.s so the pin lands at $2030 in the flat build).

; (the historical umul8 alignment pad byte was deleted 2026-07-19 —
; umul8 has been at the pinned $2030 slot in clip/arith.s since
; 2026-07-12 and nothing anchors to the layout below.)

; (interp_core removed — inlined into interp_store below.)

; (smul8 removed — no longer used with u8 Y_BIAS pipeline)

; (udiv16_8 moved to clip/arith.s 2026-08-09 — the arithmetic
; primitives home together: umul8's product aliases its dividend.)
