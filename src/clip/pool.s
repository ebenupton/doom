
; ============================================================================
; clip/pool.s — clipper fragment 3 of 13 (module map: clip/header.s).
; Contents: span_init ONLY. The O(1) free-list allocator that lived
; here (alloc_span / free_span) was retired 2026-08-21 — both bodies
; are straight-line enough that all six call sites carry them inline;
; see the notes below for the accounting.
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
; POOL ALLOCATOR (retired as subroutines 2026-08-21) — the free list is
; a singly-linked chain through POOL_NEXT with the head in zp_free.
; The two operations are now inline at every site:
;
;   POP (was alloc_span, 3 sites: mark_solid's middle split, tfr's
;   flush_pending and emit_unchanged_subspan)
;       LDX zp_free / BEQ <caller's fail arm>
;       LDA POOL_NEXT,X / STA zp_free       ; X = fresh slot, fields stale
;
;   PUSH (was free_span, 3 sites: mark_solid's ms_free, tfr's sweep
;   tail and tg_append_x's merge). Slot must be UNLINKED first.
;       LDA zp_free / STA POOL_NEXT,X / STX zp_free   ; X preserved
;
; Both inlines are net-free: span_clip.bin is the same size as with
; the subroutines, and they bought -366 cyc/frame together (the pop
; also kills the TXA/BEQ pair that only carried Z across the JSR).
; ======================================================================
; (alloc_span RETIRED 2026-08-21, with free_span: all three call sites
; carry the 4-instruction pop inline. Inlining is a STRICT win here —
; the subroutine's TXA and each caller's BEQ existed solely to carry
; the empty-pool verdict across the JSR, and inline the pop's own BEQ
; branches straight to the caller's fail arm.)

; (free_span RETIRED 2026-08-21: all three call sites — mark_solid's
; ms_free and tfr's sweep-tail + merge tail-call — carry the
; 3-instruction body inline now. It was never exported; alloc_span
; stays, since its free-list pop is not a straight-line body.)

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
