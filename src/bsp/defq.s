bsp_b_start:

; (the DEFERRED OP QUEUE lived here until 2026-07-16 — clip ops now
; apply immediately at seg end; the queue, its snapshots and the drain
; are deleted, and the $0600 page is FREE.)

; ============================================================================
; (entry split 2026-07-12, spectrack find: 88% of calls were complete
; no-ops — the hi==0/evy-positive common case is INLINED at the single
; call site in seg_xform.s; only hi != 0 calls in here now, A = hi.)
ev_clamp_hi_nz:
.scope
   CMP #$FF
   BEQ ev_case_ff
   ASL A
   BCS ev_clamp_neg
; carry = sign of hi byte
   LDA #$7F
   BNE ev_store
ev_clamp_neg:
   LDA #$80
   BNE ev_store
ev_case_ff:
   LDA VX1+0,X
   BMI ev_done
; $FF:%1xxxxxxx → fits s8
   LDA #$80
   BNE ev_store
; -256..-129 → clamp
ev_store:
   STA VX1+0,X
ev_done:
   RTS
.endscope

; (X-projector family moved to project.s 2026-07-12 — the whole X
; projection family lives in one file now.)



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
.if ::BANKED
.segment "D_BK"                         ; above PAGE (directly *LOAD-able)
.else
.segment "D"
.endif
