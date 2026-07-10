; ============================================================================
; layout.inc — GENERATED ROM-layout constants (tools/gen_layout_inc.py).
; The packed layout is STATIC (single anim variant, 2026-07-10): these are
; assembly-time truths. doom_wireframe asserts packed_layout against these
; values on import — drift fails loud there, never silently here.
; ============================================================================
LAY_N_SEGS   = 662
LAY_N_NODES  = 236
LAY_ROOT     = 235                      ; n_nodes - 1
LAY_OFF_VERTS   = $1000
LAY_OFF_SS      = $0D00
LAY_OFF_SEG_HDR = $174C

.if ::BANKED
ROM_SEG_HDR_C = $9000                   ; headers slide over the evicted verts
ROM_FHCH_C    = $9000 + 662*12          ; = $AF08, tails the headers in L0
ROM_VERTS_C   = $A200                   ; bank L2
ROM_BBOX_C    = $8E00                   ; bank L2 (page-aligned)
.else
ROM_MAIN_C    = $6C00                   ; flat rom_main base (harness)
ROM_SEG_HDR_C = ROM_MAIN_C + LAY_OFF_SEG_HDR
ROM_FHCH_C    = $B600                   ; flat FHCH stream
ROM_VERTS_C   = ROM_MAIN_C + LAY_OFF_VERTS
ROM_BBOX_C    = $C600                   ; flat bbox (page-aligned)
.endif
.assert (ROM_BBOX_C & $FF) = 0, error, "bbox base must stay page-aligned"
