
; ============================================================================
vc_bit_mask:
.byte 1, 2, 4, 8, 16, 32, 64, 128       ; 1 << (idx & 7) for the vertex cache

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
