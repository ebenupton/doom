; ============================================================================
; layout.inc — GENERATED ROM-layout constants (tools/gen_layout_inc.py).
; The packed layout is STATIC (single anim variant, 2026-07-10): these are
; assembly-time truths. doom_wireframe asserts packed_layout against these
; values on import — drift fails loud there, never silently here.
; ============================================================================
LAY_N_SEGS   = 649
LAY_N_NODES   = 220
LAY_ROOT   = 219                      ; n_nodes - 1
LAY_OFF_VERTS   = $0B00
LAY_OFF_SS   = $0900
LAY_OFF_SEG_HDR   = $1100

LAY_HDR_STRIDE   = 9                    ; +10 bfh, +11 bch
LAY_HDR_BYTES   = $172D                 ; footprint of the page-slotted
                                        ; header array (generated: 256/
                                        ; stride slots per 256B page, so
                                        ; it is NOT n_segs*stride)
LAY_SH_DIAG   = 5                       ; generated header field offsets
LAY_SH_FLAGS   = 7                      ; (wad_packed SH_*: the .s files
LAY_SH_BPAL   = 8                      ;  must never carry private copies)
LAY_BPAL_OFF   = $1D00                  ; generated: back-pair palette page
                                        ; (2 planes at +$00/+$80)
LAY_LV1_OFF   = $1B00                   ; generated: diagonal LV1 records,
                                        ; relative to the seg-header base
                                        ; (2 pages, planes at +$00/+$80)
LAY_SS_FH_OFF   = $1900                 ; generated: front-height pages,
                                        ; RELATIVE to the seg-header base
                                        ; (page-aligned in both builds)
; (2026-07-11: FHCH stream gone; back-face C-form replaced lv1/ld —
; +4 form/dir_id, +5..7 C24, +8 flags, +9 L(pad), +10/+11 back heights;
;  2026-08-17: fh/ch left for the per-subsector pages below)
LAY_N_DIRS   = 118                   ; distinct diagonal primitives
LAY_MAX_DIRS   = 128                   ; DIR table stride (3 arrays)

.if ::BANKED
ROM_SEG_HDR_C = $8000                   ; bank SEG window head: headers+DIRs
ROM_VERTS_C   = $AB00                   ; bank SEG (2026-08-13 two-bank
ROM_BBOX_C    = $9600                   ; re-cut: bbox lives in bank WALK)
NODE_SOA_C    = $8000                   ; bank WALK window head
ROM_OBJ_C     = $A900                   ; static-object (billboard) table,
                                        ; between RECIP_S's page and the
                                        ; vertex planes at $AB00
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
ROM_OBJ_C     = $B700                   ; static-object table, in the run
                                        ; the retired 4th vertex plane left
ROM_DIRS_C    = ROM_SEG_HDR_C + LAY_HDR_BYTES
.assert ROM_DIRS_C + 3*LAY_MAX_DIRS <= ROM_VERTS_C, error, "DIR tables reach the vertex planes"
.assert ROM_VERTS_C + $600 <= NODE_SOA_C, error, "flat vertex planes reach the node SoA"
.endif
; --- static object (billboard) planes: SoA, one X indexes every field ---
; Positions use the SAME page-decomposed encoding as the vertex planes
; (u8 offset + page nibble), so an object stages exactly like a vertex.
OBJ_DRAW = 1                            ; static-object billboards: the
                                        ; 6502 draw is complete and works,
                                        ; but the PYTHON references do not
                                        ; draw them yet, so every
                                        ; cross-impl gate reports the
                                        ; rectangles as over-draw.  Flip to
                                        ; 1 once packed_render_subsector and
                                        ; the float render_bsp mirror it.
LAY_N_OBJ   = 18                   ; static objects (wad_packed)
OBJ_OX   = ROM_OBJ_C + 0*LAY_N_OBJ      ; x offset lo
OBJ_OY   = ROM_OBJ_C + 1*LAY_N_OBJ      ; y offset lo
OBJ_PG   = ROM_OBJ_C + 2*LAY_N_OBJ      ; page nibble (x b0-1, y b2-3)
OBJ_SS   = ROM_OBJ_C + 3*LAY_N_OBJ      ; home subsector id (u8)
OBJ_RC   = ROM_OBJ_C + 4*LAY_N_OBJ      ; half-width in s16 COUNTS
OBJ_ZT   = ROM_OBJ_C + 5*LAY_N_OBJ      ; prescaled top height (s8)
OBJ_ZB   = ROM_OBJ_C + 6*LAY_N_OBJ      ; prescaled floor height (s8)
OBJ_BITS = ROM_OBJ_C + 7*LAY_N_OBJ      ; per-subsector "has objects" bitmap
; (vertex block $800 -> $600 2026-08-11: the 4th plane slot died with
;  page decomposition — flat frees $B700-$B8FF, banked frees
;  $A800-$A9FF in L2; the flat object table lives in that freed run)
.assert ROM_OBJ_C + 8*LAY_N_OBJ + 28 <= ROM_OBJ_C + $200, error, "object table overruns its 512-byte hole"
; Per-SUBSECTOR front heights (2026-08-17): fh/ch are subsector-constant, so
; they ride two pages in the header blob instead of 2 bytes x every seg. Read
; under BANK_SEG with X = the subsector id (already live in the prologue).
.if ::BANKED
; SS_FH/SS_CH left bank A for bank B on 2026-08-19 (the SS consolidation:
; all five per-subsector planes adjacent in one bank, read under WALK).
; SS_CH MUST stay exactly one page above SS_FH — the anim worker reads ch
; by incrementing the pointer's high byte. Bank A's $B900-$BAFF came free.
ROM_SS_FH_C = $8B00                     ; 2026-08-19: planes 3+4 of the FIVE
ROM_SS_CH_C = $8C00                     ; adjacent SS planes in BANK B
                                        ; ($8900 PC, $8A00 SI, $8B00 FH,
                                        ; $8C00 CH, $8D00 VZ) — read in the
                                        ; prologue UNDER BANK_WALK, before
                                        ; the PAGE to SEG
.else
ROM_SS_FH_C = ROM_SEG_HDR_C + LAY_SS_FH_OFF
ROM_SS_CH_C = ROM_SS_FH_C + $100
.endif
; Diagonal back-face reference points (2026-08-17): 4 planes, 2 per page at
; +$00/+$80, indexed by the u8 record id the header carries at +SH_DIAG. The
; 128-slot spacing keeps every indexed read inside one page.
.if ::BANKED
LV1_BASE = $BB00                        ; top of bank A (see above)
.else
LV1_BASE = ROM_SEG_HDR_C + LAY_LV1_OFF
.endif
ROM_LV1X_LO_C = LV1_BASE + $000
ROM_LV1X_HI_C = LV1_BASE + $080
ROM_LV1Y_LO_C = LV1_BASE + $100
ROM_LV1Y_HI_C = LV1_BASE + $180
.assert (ROM_LV1X_LO_C & $FF) = 0, error, "LV1 planes must be page-aligned"
; Back-pair palette (2026-08-17): the seg header carries a u8 id here instead
; of two height bytes. 96 entries — 56 shared plus one private per
; mover-touching seg, so an anim patch cannot bleed into a neighbour.
.if ::BANKED
BPAL_BASE = $BD00                       ; top of bank A (see above)
.else
BPAL_BASE = ROM_SEG_HDR_C + LAY_BPAL_OFF
.endif
ROM_BPAL_BFH_C = BPAL_BASE + $00
ROM_BPAL_BCH_C = BPAL_BASE + $80
.assert ROM_BPAL_BCH_C + 128 <= $BE00, error, "BPAL runs into USETAB"
; Driver tables in BANK C (2026-08-17): read only by walk_drv, which pages this
; bank for them. They were in bank A until its bottom was wanted for the
; main-RAM caches. Banked only — the flat harness runs no driver.
.if ::BANKED
ROM_DRV_SINCOS_C = $9900
ROM_DRV_USEVEC_C = $9B00
.endif
.assert (ROM_BPAL_BFH_C & $FF) = 0, error, "BPAL page must be page-aligned"
.assert (ROM_SS_FH_C & $FF) = 0, error, "SS height pages must be page-aligned"
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
