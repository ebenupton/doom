; ============================================================================
; layout.inc — GENERATED ROM-layout constants (tools/gen_layout_inc.py).
; The packed layout is STATIC (single anim variant, 2026-07-10): these are
; assembly-time truths. doom_wireframe asserts packed_layout against these
; values on import — drift fails loud there, never silently here.
; ============================================================================
LAY_N_SEGS   = 649
LAY_N_NODES   = 220
LAY_ROOT   = 219                      ; n_nodes - 1
LAY_OFF_VERTS   = $0E00
LAY_OFF_SS   = $0B00
LAY_OFF_SEG_HDR   = $1600

LAY_HDR_STRIDE  = 16                    ; heights INLINED at +10..15
; (2026-07-11: FHCH stream gone; back-face C-form replaced lv1/ld —
; +4 form/dir_id, +5..7 C24, +8 flags, +9 L(pad), +10..15 heights)
LAY_N_DIRS   = 113                   ; distinct diagonal primitives
LAY_MAX_DIRS   = 160                   ; DIR table stride (3 arrays)

.if ::BANKED
ROM_SEG_HDR_C = $9000                   ; 662*16 = 10592 + DIR tables
ROM_VERTS_C   = $A200                   ; bank L2
ROM_BBOX_C    = $8E00                   ; bank L2 (page-aligned)
NODE_SOA_C    = $8000                   ; bank L0 window head
ROM_DIRS_C    = ROM_SEG_HDR_C + LAY_N_SEGS*LAY_HDR_STRIDE
.assert ROM_DIRS_C + 3*LAY_MAX_DIRS <= $BE90, error, "DIR tables reach TABL0"
.else
ROM_SEG_HDR_C = $6C00                   ; flat: stride-18 stream, ends $9B8B
ROM_VERTS_C   = $9C00                   ; flat verts (ends $A34B, below SEL $A400)
ROM_BBOX_C    = $C600                   ; flat bbox (page-aligned)
NODE_SOA_C    = $B600                   ; flat SoA: the old FHCH hole (16 pages)
ROM_DIRS_C    = ROM_SEG_HDR_C + LAY_N_SEGS*LAY_HDR_STRIDE
.assert ROM_DIRS_C + 3*LAY_MAX_DIRS <= $9800, error, "DIR tables reach the VXC planes at $9800 (the invisible squatter that caught the first slotting attempt)"
.assert ROM_VERTS_C + $800 <= $A400, error, "flat vertex planes reach SEL"
.endif
.assert (ROM_BBOX_C & $FF) = 0, error, "bbox base must stay page-aligned"
.assert (NODE_SOA_C & $FF) = 0, error, "node SoA must stay page-aligned"
