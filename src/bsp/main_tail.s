
; ============================================================================
; MAIN-region tail: last data table + end-of-code marker, then the B-region
; segment switch. vc_bit_mask is the bit-mask lookup used by
; br_seg_xform_vertex (seg_xform.s) to test/set a vertex's valid bit in
; the VCACHE valid bitmap without a 0..7-iteration shift loop.
; ============================================================================
; (vc_bit_mask moved to the B region — defq.s — 2026-07-09: 8 table bytes
; that MAIN could no longer afford; abs,X reads cost the same anywhere.)

end_code:
.if ::BANKED
.assert end_code <= $5800, error        ; banked: FB at $5800
.else
.assert end_code <= $5800, error        ; flat: FB at $5800 (RCACHE carve freed 2026-07-15)
.endif
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_bk.bin", $4800, end_code, $4800)
.else
; (ld65 writes this: SAVE "bsp_render.bin", $4800, end_code, $4800)
.endif

; ============================================================================
; B SEGMENT — deferred-op queue helpers + small tables. Historically its
; own low-RAM island ($0AA0, the unused tail of the SS_VISITED_BITMAP
; allocation); since the 2026-07-12 flat merge it floats inside the one
; CODE region in both builds (no separate bin). Name = link order only.
; ============================================================================
.if ::BANKED
.segment "B_BK"                         ; above PAGE (directly *LOAD-able; avoids relocate-down)
.else
.segment "B"
.endif

; ============================================================================
; TRUE end-of-CODE marker (2026-07-13): ZZTAIL is linked LAST in the CODE
; region in BOTH cfgs, so this assert covers EVERY segment — the old
; end_code label sat mid-chain and let B/D/W/ANIML2 slide silently into
; the RCACHE carve when LO grew (rotcache corruption, found the hard way).
; ============================================================================
.segment "ZZTAIL"
code_true_end:
.if ::BANKED
.assert code_true_end <= $5800, error, "CODE overflows into the FB (banked)"
.else
.assert code_true_end <= CPM_BASE, error, "CODE overflows into the CPM carve (flat corner-phi memo, 3 pages ending at the screen — CPM_BASE in abi.inc)"
.endif
