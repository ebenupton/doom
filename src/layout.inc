; ============================================================================
; layout.inc — GENERATED ROM-layout constants (tools/gen_layout_inc.py).
; The packed layout is STATIC (single anim variant, 2026-07-10): these are
; assembly-time truths. doom_wireframe asserts packed_layout against these
; values on import — drift fails loud there, never silently here.
; ============================================================================
LAY_N_SEGS   = 649
LAY_N_NODES   = 220
LAY_ROOT   = 219                      ; n_nodes - 1
LAY_OFF_VERTS   = $0C00
LAY_OFF_SS   = $0900
LAY_OFF_SEG_HDR   = $1200

LAY_HDR_STRIDE   = 14                    ; heights INLINED at +10..13
LAY_HDR_BYTES   = $240E                 ; footprint of the page-slotted
                                        ; header array (generated: 18
                                        ; slots of 14 per 256B page, so
                                        ; it is NOT n_segs*stride)
; (2026-07-11: FHCH stream gone; back-face C-form replaced lv1/ld —
; +4 form/dir_id, +5..7 C24, +8 flags, +9 L(pad), +10..15 heights)
LAY_N_DIRS   = 118                   ; distinct diagonal primitives
LAY_MAX_DIRS   = 160                   ; DIR table stride (3 arrays)

.if ::BANKED
ROM_SEG_HDR_C = $8000                   ; bank SEG window head: headers+DIRs
ROM_VERTS_C   = $AB00                   ; bank SEG (2026-08-13 two-bank
ROM_BBOX_C    = $9600                   ; re-cut: bbox lives in bank WALK)
NODE_SOA_C    = $8000                   ; bank WALK window head
ROM_DIRS_C    = $B700                   ; DIR planes ship in BOTH banks
                                        ; (union consumer: node classify
                                        ; under bank WALK, seg backface
                                        ; under bank SEG — one shared
                                        ; CROSS_MAG_DECIDE reads them)
.assert ROM_DIRS_C + 3*LAY_MAX_DIRS <= $BE90, error, "DIR tables reach TABL0"
.else
ROM_SEG_HDR_C = $8600                   ; flat LEVEL block (2026-07-21 map):
ROM_VERTS_C   = $B100                   ; hdrs+dirs, verts, SoA, bbox, recip
ROM_BBOX_C    = $C500                   ; all contiguous
NODE_SOA_C    = $B900
ROM_DIRS_C    = ROM_SEG_HDR_C + LAY_HDR_BYTES
.assert ROM_DIRS_C + 3*LAY_MAX_DIRS <= ROM_VERTS_C, error, "DIR tables reach the vertex planes"
.assert ROM_VERTS_C + $600 <= NODE_SOA_C, error, "flat vertex planes reach the node SoA"
; (vertex block $800 -> $600 2026-08-11: the 4th plane slot died with
;  page decomposition — flat frees $B700-$B8FF, banked frees
;  $A800-$A9FF in L2, both now part of the pre-existing gaps)
.endif
.assert (ROM_BBOX_C & $FF) = 0, error, "bbox base must stay page-aligned"
; Bbox corner planes (16 x 256, page-split SoA): field at f*$200, side
; (0 = right child box, 1 = left) at +$100. Node ids are u8 -> corner
; reads are abs,Y with the plane baked per side/zone arm.
BBP_T_LO = ROM_BBOX_C + $000
BBP_T_HI = ROM_BBOX_C + $200
BBP_B_LO = ROM_BBOX_C + $400
BBP_B_HI = ROM_BBOX_C + $600
BBP_L_LO = ROM_BBOX_C + $800
BBP_L_HI = ROM_BBOX_C + $A00
BBP_R_LO = ROM_BBOX_C + $C00
BBP_R_HI = ROM_BBOX_C + $E00
; Per-side aliases (2026-07-18): suffix 0 = RIGHT child box, 1 = LEFT.
; Same pages as base+$100 — these just NAME the side dimension so the
; per-side classify ladders read as intent instead of arithmetic.
; (The ZC arms reach the same pages through ZCF's `s` parameter.)
BBP_T_LO0 = BBP_T_LO
BBP_T_LO1 = BBP_T_LO + $100
BBP_T_HI0 = BBP_T_HI
BBP_T_HI1 = BBP_T_HI + $100
BBP_B_LO0 = BBP_B_LO
BBP_B_LO1 = BBP_B_LO + $100
BBP_B_HI0 = BBP_B_HI
BBP_B_HI1 = BBP_B_HI + $100
BBP_L_LO0 = BBP_L_LO
BBP_L_LO1 = BBP_L_LO + $100
BBP_L_HI0 = BBP_L_HI
BBP_L_HI1 = BBP_L_HI + $100
BBP_R_LO0 = BBP_R_LO
BBP_R_LO1 = BBP_R_LO + $100
BBP_R_HI0 = BBP_R_HI
BBP_R_HI1 = BBP_R_HI + $100
.assert (NODE_SOA_C & $FF) = 0, error, "node SoA must stay page-aligned"
