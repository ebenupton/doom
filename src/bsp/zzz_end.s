; ============================================================================
; bsp/zzz_end.s — THE end-of-code marker. Included LAST in bsp_render.s
; (the last object), so code_true_end is the true end of the CODE
; segment by construction: nothing can land after it, and a file that
; forgets its segment directive lands BEFORE it, still covered by the
; region ceilings below.
; ============================================================================
SEG_CODE
code_true_end:
.if ::BANKED
.assert code_true_end <= $5800, error, "CODE overflows into the FB (banked)"
.else
.assert code_true_end <= $6400, error, "flat CODE overflows into the NJ blob at $6200"
.endif
