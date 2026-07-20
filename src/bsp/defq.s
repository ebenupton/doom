; EXPLICIT segment (2026-07-19): this file inherited whatever segment
; main_tail.s left active — which is ZZTAIL, the true-end marker. The
; 8 vc_bit_mask bytes rode PAST code_true_end, invisible to the tail
; assert, and the day the code end crossed CPM_BASE-8 the corner-memo
; stores shredded them (vertex-cache valid tests went garbage). The
; fall-through-across-.segment landmine, again.
SEG_CODE
bsp_b_start:

; (the DEFERRED OP QUEUE lived here until 2026-07-16 — clip ops now
; apply immediately at seg end; the queue, its snapshots and the drain
; are deleted, and the $0600 page is FREE.)

; ============================================================================
; (entry split 2026-07-12, spectrack find: 88% of calls were complete
; no-ops — the hi==0/evy-positive common case is INLINED at the single
; call site in seg_xform.s; only hi != 0 calls in here now, A = hi.)
; (ev_clamp_hi_nz is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)

; (X-projector family moved to project.s 2026-07-12 — the whole X
; projection family lives in one file now.)



.export vc_bit_mask                     ; shared with the rcache probe
vc_bit_mask:
   .byte 1, 2, 4, 8, 16, 32, 64, 128       ; 1 << (idx & 7) for the vertex cache
                                        ; (from main_tail.s; MAIN at ceiling)
bsp_b_end:
; (B-region ceiling retired 2026-07-12: B floats in the one CODE region.)

; ============================================================================
; D REGION ($0978-$09FF) — near-plane edge-crossing math for bbox
; visibility. Free space after span_clip's LC_* scratch ($0958) and the
; BBOX_CORNERS/DEFQ vars ($0960-$0976). Loaded as bsp_render_d.bin.
; ============================================================================
SEG_CODE
