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

ROM_SEG_HDR_C = BANKA_ORG               ; bank SEG window head: headers+DIRs
ROM_VERTS_C   = BANKA_ORG + $2B00       ; bank SEG (2026-08-13 two-bank
ROM_BBOX_C    = BANKB_ORG + $1600       ; re-cut: bbox lives in bank WALK)
NODE_SOA_C    = BANKB_ORG               ; bank WALK window head
ROM_OBJ_C     = BANKA_ORG + $2900       ; static-object (billboard) table,
                                        ; between RECIP_S's page and the
                                        ; vertex planes
ROM_DIRS_C    = BANKA_ORG + $3700       ; DIR planes ship in BOTH banks
                                        ; (union consumer: node classify
                                        ; under bank WALK, seg backface
                                        ; under bank SEG — one shared
                                        ; CROSS_MAG_DECIDE reads them; the
                                        ; flat map resolves to bank A's copy)
.assert ROM_DIRS_C + 3*LAY_MAX_DIRS <= BANKA_ORG + $3A00, error, "DIR tables reach TABL0"
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
LAY_N_OBJ   = 52                   ; static objects (wad_packed):
                                   ; 2026-09-01 the armour-room strip
                                   ; took 58 -> 52; ONE value since the
                                   ; parasite re-cut — the flat legacy
                                   ; 14-object gather is DEAD, both
                                   ; builds ship the full planes
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
OBJ_RUN8 = OBJ_BITS + LAY_OBJ_BITS_LEN  ; per-ss-OCTET first object index
                                        ; ($FF when the octet is empty) --
                                        ; the run-start table that killed
                                        ; the exhaustive scan (2026-08-31)
; THE ART IS THREE 256-BYTE WINDOWS (2026-08-31: A+B after the pillar
; died; C returned the same day carrying the CLOSE-RANGE TIERS).  obj_e stayed a byte by becoming an offset WITHIN a
; window: the stamp walker's four abs,X reads get their window HIGH byte
; SMC'd per object (oa_rd0..3), and page alignment keeps them carry-free.
; Window A is byte-identical to the old whole table, so FLAT -- which
; still draws its legacy subset as hex barrels -- copies its 140 B
; exactly as before.
;   A: HEX 0, LAMP 52        B: BOX 0, POTION 28, HELMET 88, VEST 160
;   C: OCT 0, BOXL0 76, POTL0 160  (the near tiers; obj_lodh picks)
LAY_N_OBJ_ART = 185                ; 740 B / 4 -- all three windows, both builds
; kind indices (the OBJ_ASP plane byte; k lives in obj_ktab -- the two
; tables MUST stay in step with doom_wireframe's _KTAB/_OBJ_KINDS)
OBJ_K_HEX    = 0
OBJ_K_LAMP   = 1
OBJ_K_POTION = 2
OBJ_K_HELMET = 3
OBJ_K_BOXS   = 4
OBJ_K_BOXM   = 5
OBJ_K_VEST   = 6
; per-template (window, start offset within it)
OBJ_ART_HEX    = 0                 ; window A
OBJ_ART_LAMP   = 52                ; window A
OBJ_ART_BOX    = 0                 ; window B
OBJ_ART_POTION = 28                ; window B
OBJ_ART_HELMET = 88                ; window B
OBJ_ART_VEST   = 160               ; window B
OBJ_ART_OCT    = 0                 ; window C -- barrel, close range
OBJ_ART_BOXL0  = 76                ; window C -- trapezoid + cross
OBJ_ART_POTL0  = 160               ; window C -- dodecagon + wide stem
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
; and clear of the HUD at $A400: the whole stamp loop runs under the one
; PAGE BANK_C the object prologue already does.  SEEDED BY PYTHON
; (banked_bsp) — the asserts are the only guard.
OBJ_ART  = $9B00
.assert OBJ_ART + 4*LAY_N_OBJ_ART <= $9E00, error, "banked art templates reach VDESC at $9E00"
.else
; FLAT: the CBITS data block (parasite map): three page-aligned windows
; at the top of the bank-C-bits run, below VEXPL/VDESC.  Python-seeded,
; like the banked home.
OBJ_ART  = $F100                   ; linear ($9B00 banked - $8000 + $D600)
.assert OBJ_ART + 4*LAY_N_OBJ_ART <= $F400, error, "flat art templates reach VDESC"
.endif
; (vertex block $800 -> $600 2026-08-11: the 4th plane slot died with
;  page decomposition — flat frees $B700-$B7FF, banked frees
;  $A800-$A9FF in L2; the flat object table lives in that freed run)
ROM_BKTLO_C = BANKA_ORG + $3900         ; bank A free page (SS planes left
ROM_BKTHI_C = BANKA_ORG + $3980         ; for bank B 2026-08-19)
ROM_DBOUND_C = BANKA_ORG + $3880        ; the gap after the 3 DIR planes
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
; SS_FH/SS_CH: planes 3+4 of the FIVE adjacent SS planes in BANK B
; (+$0900 PC, +$0A00 SI, +$0B00 FH, +$0C00 CH, +$0D00 VZ) — read in the
; prologue UNDER BANK_WALK, before the PAGE to SEG.  SS_CH MUST stay
; exactly one page above SS_FH (the anim worker bumps the hi byte).
ROM_SS_FH_C = BANKB_ORG + $0B00
ROM_SS_CH_C = ROM_SS_FH_C + $100
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
ROM_SS_CNT_C = BANKB_ORG + $3500
.assert ROM_SS_CNT_C + $100 <= BANKB_ORG + $3700, error, "SS_CNT runs into the DIR planes"
.assert (ROM_SS_CNT_C & $FF) = 0, error, "SS_CNT plane must be page-aligned"
; Diagonal back-face reference points (2026-08-17): 4 planes, 2 per page at
; +$00/+$80, indexed by the u8 record id the header carries at +SH_DIAG. The
; 128-slot spacing keeps every indexed read inside one page.
LV1_BASE = BANKA_ORG + $3B00            ; top of bank A
ROM_LV1X_LO_C = LV1_BASE + $000
ROM_LV1X_HI_C = LV1_BASE + $080
ROM_LV1Y_LO_C = LV1_BASE + $100
ROM_LV1Y_HI_C = LV1_BASE + $180
.assert (ROM_LV1X_LO_C & $FF) = 0, error, "LV1 planes must be page-aligned"
; Back-pair palette (2026-08-17): the seg header carries a u8 id here instead
; of two height bytes. 96 entries — 56 shared plus one private per
; mover-touching seg, so an anim patch cannot bleed into a neighbour.
BPAL_BASE = BANKA_ORG + $3D00           ; top of bank A
ROM_BPAL_BFH_C = BPAL_BASE + $00
ROM_BPAL_BCH_C = BPAL_BASE + $80
.assert ROM_BPAL_BCH_C + 128 <= BANKA_ORG + $3E00, error, "BPAL runs into the free bank-A top ($BE00+)"
; Driver tables in BANK C (2026-08-17): read only by walk_drv, which pages this
; bank for them. They were in bank A until its bottom was wanted for the
; main-RAM caches. Banked only — the flat harness runs no driver.
.if ::BANKED
ROM_DRV_SINCOS_C = $9900                ; bank C (walk_drv pages for it)
ROM_DRV_USEVEC_C = $96FC                ; EVICTED to bank A 2026-09-02: the
                                        ; SPACE use-trace vectors are read
                                        ; right before ENG_PMOVE_USE (which
                                        ; pages SEG for USETAB), so bank A is
                                        ; zero-cost -- one ROMSEL instead of
                                        ; C-then-SEG.  Fills the 260 B gap
                                        ; above the seg headers ($96FB).
.else
ROM_DRV_SINCOS_C = $EF00                ; linear ($9900 banked - $8000 +
                                        ; $D600); senior page rides $F000
                                        ; (past the CBITS region edge --
                                        ; python-seeded, ld65 never sees it)
ROM_DRV_USEVEC_C = BANKA_ORG + $16FC    ; BY CONSTRUCTION: the banked bank-A
                                        ; home ($96FC) laid flat = $6EFC
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
