; ============================================================================
; layout.inc — GENERATED ROM-layout constants (tools/gen_layout_inc.py).
; The packed layout is STATIC (single anim variant, 2026-07-10): these are
; assembly-time truths. doom_wireframe asserts packed_layout against these
; values on import — drift fails loud there, never silently here.
; ============================================================================
LAY_N_SEGS   = 644
LAY_N_NODES   = 195
LAY_ROOT   = 194                      ; n_nodes - 1
LAY_OFF_VERTS   = $0B00
LAY_OFF_SS   = $0900
LAY_OFF_SEG_HDR   = $1100

LAY_HDR_STRIDE   = 9                    ; +10 bfh, +11 bch
LAY_HDR_BYTES   = $16FC                 ; footprint of the page-slotted
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
LAY_SS_CNT_OFF   = $1E00                 ; generated: per-ss seg-count plane
                                        ; (cnt-1; PG/CNT split 2026-08-29),
                                        ; relative to the seg-header base
; (2026-07-11: FHCH stream gone; back-face C-form replaced lv1/ld —
; +4 form/dir_id, +5..7 C24, +8 flags, +9 L(pad), +10/+11 back heights;
;  2026-08-17: fh/ch left for the per-subsector pages below)
LAY_N_DIRS   = 120                   ; distinct diagonal primitives
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
                                        ; (18-object subset -- see
                                        ; LAY_N_OBJ)
ROM_DIRS_C    = ROM_SEG_HDR_C + LAY_HDR_BYTES
.assert ROM_DIRS_C + 3*LAY_MAX_DIRS <= ROM_VERTS_C, error, "DIR tables reach the vertex planes"
.assert ROM_VERTS_C + $600 <= NODE_SOA_C, error, "flat vertex planes reach the node SoA"
.endif
; --- static object (billboard) planes: SoA, one X indexes every field ---
; Positions use the SAME page-decomposed encoding as the vertex planes
; (u8 offset + page nibble), so an object stages exactly like a vertex.
; --- TRIPWIRE: first-writer-wins corruption catcher (debug) ------------
; Hunting the tube's player-X corruption: the middle byte of the player X
; position is $EE while standing at the spawn column, and something moves
; it. TW sites latch the FIRST checkpoint id to observe the change, so the
; id that comes back names the phase the corruption happened in.
; Set TRIPWIRE = 0 to compile every call site out.
TRIPWIRE = 0
TW_ADDR  = DV_PXL                       ; watched byte
TW_WANT  = $EE                          ; its value while standing still

OBJ_DRAW = 1                            ; static-object billboards.  ON
                                        ; since 2026-08-23: the octagonal
                                        ; barrel art fits banked CODE now
                                        ; that the CODE head took the
                                        ; PMOVE region's dead page
                                        ; ($2600 -> $2500), leaving 68 B.
                                        ; KNOWN GATE STATE: the PYTHON
                                        ; references still do not draw
                                        ; objects, so compare_subsector /
                                        ; walkseq_check / anim6502_check /
                                        ; verify-vs-float all report the
                                        ; billboards as over-draw (miss is
                                        ; unchanged everywhere -- nothing
                                        ; STOPS being drawn).  Closing that
                                        ; needs packed_render_subsector to
                                        ; mirror obj_subsector, including
                                        ; the 4-segment records tighten,
                                        ; which the python shadow model
                                        ; cannot yet express (it speaks
                                        ; single-line tightens only).
                                        ; Set 0 to get a green gate back.
.if ::BANKED
LAY_N_OBJ   = 62                   ; static objects (wad_packed):
                                   ; 2026-08-31 the five pickups added
                                   ; 44 (13 potions, 25 helmets, 3
                                   ; medikits, stim, 2 vests)
.else
LAY_N_OBJ   = 18                   ; FLAT KEEPS THE ORIGINAL 18 (barrels,
                                   ; lamps, pillars): 62 planes are 459 B
                                   ; and no honest flat hole exists (the
                                   ; probes found $A600 = VXCACHE_XLO and
                                   ; $D700 live).  Its loader GATHERS the
                                   ; kind<=2 subset into this stride.
.endif
LAY_OBJ_BITS_LEN   = 25            ; generated: (n_ss+7)//8 — the per-ss
                                   ; "has objects" bitmap length; the
                                   ; OBJ_ART home abuts it (a hardcoded
                                   ; 28 here skewed the banked art base
                                   ; when the polish tree cut n_ss)
OBJ_OX   = ROM_OBJ_C + 0*LAY_N_OBJ      ; x offset lo
OBJ_OY   = ROM_OBJ_C + 1*LAY_N_OBJ      ; y offset lo
OBJ_PG   = ROM_OBJ_C + 2*LAY_N_OBJ      ; page nibble (x b0-1, y b2-3)
OBJ_SS   = ROM_OBJ_C + 3*LAY_N_OBJ      ; home subsector id (u8)
OBJ_ASP  = ROM_OBJ_C + 4*LAY_N_OBJ      ; bit 7 = art template select,
                                        ; bits 0-6 = width ratio k in
                                        ; 64ths (half_width = H*k/64).
                                        ; Was the radius in counts, dead
                                        ; since the billboard became a
                                        ; scaled stamp.
OBJ_ZT   = ROM_OBJ_C + 5*LAY_N_OBJ      ; prescaled top height (s8)
OBJ_ZB   = ROM_OBJ_C + 6*LAY_N_OBJ      ; prescaled floor height (s8)
OBJ_BITS = ROM_OBJ_C + 7*LAY_N_OBJ      ; per-subsector "has objects" bitmap
; THE ART IS THREE 256-BYTE WINDOWS (2026-08-31, the pickup landing).
; obj_e stayed a byte by becoming an offset WITHIN a window: the stamp
; walker's four abs,X reads get their window HIGH byte SMC'd per object
; (oa_rd0..3), and page alignment keeps them carry-free.  Window A is
; byte-identical to the old whole table, so FLAT -- which still draws
; every object as the hex barrel and carries no pickup planes (its $B700
; home died; see ROM_OBJ_C) -- copies its 140 B exactly as before.
;   A: HEX 0, LAMP 52        B: PILLAR 0, BOX 96, POTION 124
;   C: HELMET 0, VEST 72
.if ::BANKED
LAY_N_OBJ_ART = 163                ; 652 B / 4 -- all three windows
.else
LAY_N_OBJ_ART = 35                 ; hex + lamp only (window A's real 140)
.endif
; kind indices (the OBJ_ASP plane byte; k lives in obj_ktab -- the two
; tables MUST stay in step with doom_wireframe's _KTAB/_OBJ_KINDS)
OBJ_K_HEX    = 0
OBJ_K_LAMP   = 1
OBJ_K_PILLAR = 2
OBJ_K_POTION = 3
OBJ_K_HELMET = 4
OBJ_K_BOXS   = 5
OBJ_K_BOXM   = 6
OBJ_K_VEST   = 7
; per-template (window page offset from OBJ_ART, start offset within it)
OBJ_ART_HEX    = 0                 ; window A
OBJ_ART_LAMP   = 52                ; window A
OBJ_ART_PILLAR = 0                 ; window B
OBJ_ART_BOX    = 96                ; window B
OBJ_ART_POTION = 124               ; window B
OBJ_ART_HELMET = 0                 ; window C
OBJ_ART_VEST   = 72                ; window C
OBJ_ART_ARM = $FE                  ; entry: arm the FUSED authority run
OBJ_ART_END     = $FF              ; entry: template finished
; The templates: 38 x (x1,y1,x2,y2) pre-doubled indices. They live in
; DATA, not CODE -- CODE is full, and the stamp loop pages BANK_SEG to
; read them and BANK_C to draw (flat: PAGE is a no-op).
; PER-BUILD HOME (2026-08-27): the flat object hole is only 256 bytes --
; colmap's USEVEC owns $B800 -- and the LOD hex template pushed the blob
; past it (the old 25-entry blob ended at $B7FE by luck). Banked keeps
; the abutting home in the true 512-byte $A900-$AAFF hole.
.if ::BANKED
; BANKED HOME IS IN BANK C (2026-08-29), abutting the driver's use vectors
; ($9B00 + 256 = $9C00) and well clear of the HUD at $A400.  It used to sit
; with the level data in BANK_SEG, which made obj_stamp thrash: PAGE
; BANK_SEG to read four art bytes, PAGE BANK_C to draw, every template
; line.  tools/pagecensus.py measured 22.4 ROMSEL stores/frame in that loop
; -- ~134 cycles, since a store costs 6 whether or not the bank changes.
; With the art in bank C the whole stamp loop runs under the one PAGE
; BANK_C the object prologue already does, and the clipper never pages
; (there is not a single PAGE in src/clip).
; NOTE: this home is SEEDED BY PYTHON (banked_bsp.build_banked), so ld65
; cannot see it -- the asserts here and there are the only guard.
OBJ_ART  = $9C00
.assert OBJ_ART + 4*LAY_N_OBJ_ART <= $A400, error, "banked art templates reach the bank-C HUD at $A400"
.else
OBJ_ART  = $E830                        ; colmap gap: ss_vz ends $E82C,
                                        ; minpass at $E910 (inside DATA)
.assert OBJ_ART + 4*LAY_N_OBJ_ART <= $E8C8, error, "flat art templates reach the PMMU area (pmf_mul24s home, $E8C8)"
.assert ROM_OBJ_C + 7*LAY_N_OBJ + LAY_OBJ_BITS_LEN <= $B800, error, "flat object planes reach colmap USEVEC"
.endif
; (vertex block $800 -> $600 2026-08-11: the 4th plane slot died with
;  page decomposition — flat frees $B700-$B7FF, banked frees
;  $A800-$A9FF in L2; the flat object table lives in that freed run)
.if ::BANKED
ROM_BKTLO_C = $B900                     ; bank A free page (SS planes left
ROM_BKTHI_C = $B980                     ; for bank B 2026-08-19)
ROM_DBOUND_C = $B880                    ; the gap after the 3 DIR planes
.else
ROM_BKTLO_C = $7080                     ; REHOMED 2026-08-31: $0C10 put this
                                        ; 128-byte plane at $0C10-$0C8F, straight
                                        ; through the WORK segment ($0C20-$0CFF)
                                        ; -- a 112-byte overlap no gate saw until
                                        ; a ZP rotation reordered WORK and moved
                                        ; which variable landed on the region-
                                        ; reload canary.  $7080 is the CLIPF tail
                                        ; below DBOUND at $7000. (was: the shared
                                        ; $0C10 gap (scratch
ROM_BKTHI_C = $D680                     ; ends $0C0E, COLPORT at $0D00);
ROM_DBOUND_C = $7000                    ; REHOMED 2026-08-30 into the CLIPF tail
                                        ; freed by dropping plot_axis (was $4D00,
                                        ; page; the page the flat CODE
                                        ; region SHRANK to wall off.
                                        ; (All three left $7080-$71FF
                                        ; 2026-08-27 so CLIPF could take
                                        ; the armed-pair entries.)
.endif
; LV1 BKT planes (2026-08-26 second cut — the per-axis K planes lasted
; a day): the record's WHOLE K-residue term, s16 LE split-plane,
; BKT = -32*(cdy*kx - cdx*ky) against the record's CANONICAL dir
; (cdy > 0). bf_band folds it with one s16 add — SUBTRACT when the
; seg's DIR sign plane b7 says dy' < 0 (the twin runs the negated dir).
; DBOUND: per-DIR u8 exactness bound sum + sum>>1 + 1 — bfx_bound's
; one-load form, shared with the node point-on-side band gate.
; Loaders place all three from the blob tail (off_bktlo/bkthi/dbound);
; flat sits just above the right-sized CLIPF region (overgrowth is a
; link error BELOW these — wall chain: planes $7080/$7100/$7180, then
; RCACHE_STATE $7268).
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
; Per-subsector seg-count plane (cnt-1, $FF = empty; the PG/CNT split
; 2026-08-29 — SS_PG went back to a plain page byte, killing the
; prologue's AND/AND/LSRx3 unpack and the +1 sentinel bias). The plane
; rides the END of rom_main (off_ss_cnt) but is NOT part of the header
; blob copy: both flat installers place it at this OWN home. The three
; rejected homes, for the record: banked $A500 stomped BBP_R_HI side 1
; (the bbox is a PAGE-SPLIT SoA spanning the full $9600-$A5FF, not
; n_nodes*16 bytes); growing the flat header blob slid BPAL onto the
; rcache plane RC_PH_0 at $A400 (flat blob end has ZERO slack); banked
; $A900 sees bank-C raster state at $A9xx in the same window (warm
; vxcache reads caught it). Banked home: $B500 (free pair below the DIR
; planes), read under WALK with the other SS planes. Flat home: the free
; page between the node SoA end and the bbox planes.
.if ::BANKED
ROM_SS_CNT_C = $B500
.assert ROM_SS_CNT_C + $100 <= $B700, error, "SS_CNT runs into the DIR planes"
.else
ROM_SS_CNT_C = $C400
.assert NODE_SOA_C + $B00 <= ROM_SS_CNT_C, error, "node SoA reaches SS_CNT"
.assert ROM_SS_CNT_C + $100 <= ROM_BBOX_C, error, "SS_CNT runs into the bbox planes"
.endif
.assert (ROM_SS_CNT_C & $FF) = 0, error, "SS_CNT plane must be page-aligned"
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
