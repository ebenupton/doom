
; ============================================================================
; MAIN-region tail: last data table + end-of-code marker, then the B-region
; segment switch. vc_bit_mask is the bit-mask lookup used by
; br_seg_xform_vertex (seg_xform.s) to test/set a vertex's valid bit in
; the VCACHE valid bitmap without a 0..7-iteration shift loop.
; ============================================================================
; (vc_bit_mask moved to the B region — defq.s — 2026-07-09: 8 table bytes
; that MAIN could no longer afford; abs,X reads cost the same anywhere.)

end_code:
.assert end_code <= $5800, error
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_bk.bin", $4800, end_code, $4800)
.else
; (ld65 writes this: SAVE "bsp_render.bin", $4800, end_code, $4800)
.endif

; ============================================================================
; B REGION ($0AA0-$0BFF) — deferred-op queue + helpers. This space is the
; unused tail of the old 384-byte SS_VISITED_BITMAP allocation (237
; subsectors need only 30 bytes, $0A80-$0A9D). Loaded as a separate binary
; (bsp_render_b.bin) by span_clip_6502.py.
; ============================================================================
.if ::BANKED
.segment "B_BK"                         ; above PAGE (directly *LOAD-able; avoids relocate-down)
.else
.segment "B"
.endif
