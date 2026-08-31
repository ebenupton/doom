; ============================================================================
; objects.s — static object (billboard) draw.
;
; The map THINGS that never move and stand off the floor (solid
; decorations + barrels) are drawn as flat outline rectangles at the END
; of their home subsector's seg loop.  Drawing THERE is what buys
; occlusion for free: the BSP walk is front-to-back, so everything
; nearer has already marked its spans solid and the clipper hides
; whatever sits behind a wall — no sprite sort, no depth buffer.
;
; Per object: ONE rotation, ONE reciprocal, TWO project_x, TWO
; project_y, four clipped lines.  The billboard faces the viewer, so its
; left/right edges are simply vx -/+ r in VIEW space, and project_x is
; linear in vx — no second rotation, and both edges share the depth and
; therefore the reciprocal.  The position uses the vertex planes' own
; page-decomposed encoding, so staging an object IS staging a vertex and
; rot_w_pages is reused verbatim.
;
; Table: SoA planes at ROM_OBJ_C (layout.inc), sorted by home subsector,
; plus a per-subsector "has objects" bitmap so an ordinary subsector
; costs one bit test and nothing else.
;
; BANK CONTRACT: pages BANK_SEG itself (table, recips and the VYCACHE memo
; all live there), then BANK_C for the clipper.  Exits under BANK_C,
; exactly as an emit arc does.
; ============================================================================

; scratch — main RAM in BOTH builds (the CODE region), so it is writable
; on hardware under any paging (see the scalar-state rule)

; --- scratch: $1100-$11FF, FREE IN BOTH BUILDS since 2026-08-17 (it
;     held the driver's retired cadence probe -- see dcl.s:1527).  It
;     lives here rather than as .res in CODE because CODE is full,
;     and it must be real RAM in both builds (the scalar-state rule).
; --- object scratch: DECLARED, not baked (2026-08-30) --------------------
; These were 41 literal equates in the hand-laid $0B80 arena.  They are
; reservations in the WORK data segment now, so ld65 owns the addresses
; and nothing here is a copy of a fact that can go stale.  The bug this
; class produces is documented on obj_fused below.
; ORDER IS LOAD-BEARING: obj_Y must follow obj_X by exactly 12 (obj_hex
; addresses both as obj_X,Y with Y = 0 or 12), asserted after the block.
SEG_WORK

obj_i:       .res 1
obj_cx_l:    .res 1
obj_cx_h:    .res 1
obj_yt_l:    .res 1
obj_yt_h:    .res 1
obj_yb_l:    .res 1
obj_yb_h:    .res 1
obj_h:       .res 1
obj_t:       .res 1                        ; obj_cur aliases this (dead once the vertices are built)
obj_a:       .res 1
obj_a2:      .res 1
obj_a3:      .res 1
obj_b:       .res 1
obj_b2:      .res 1
obj_b3:      .res 1
obj_dy:      .res 1
obj_X:       .res 12                       ; 6 x s16 — the art x table
obj_Y:       .res 36                       ; 18 x s16; MUST be obj_X + 12.
                                           ; 12 was the barrel's lid+base
                                           ; ellipse ladder; 18 since the
                                           ; pillar era -- the lamp/helmet
                                           ; use 13 y + 4 spilled x slots
                                           ; (doc/billboard).
obj_pu:      .res 1                       ; ladder-builder scratch: rounded
obj_pb:      .res 5                       ;   product; magnitudes; loop
obj_px:      .res 1                       ;   index across umul8
obj_pn:      .res 1                       ; obj_mirror's -side offset latch
obj_lod:     .res 1                       ; 0 = far tier, 1 = near tier
obj_n:       .res 1
obj_left:    .res 1
obj_k:       .res 1
obj_best:    .res 1
obj_fast:    .res 1                    ; 1 = every art line provably inside the aperture,
obj_asp:     .res 1                     ; live object aspect byte (bit 7 = art, 0-6 = k)
obj_sd_l:    .res 6                    ; [OBJ_MAXSLOT] staging triples
obj_sd_h:    .res 6
obj_scx_l:   .res 6
obj_scx_h:   .res 6
obj_syt_l:   .res 6
obj_syt_h:   .res 6
obj_syb_l:   .res 6
obj_syb_h:   .res 6
obj_sasp:    .res 6
obj_fused:   .res 1                   ; FUSED authority-run flag.  Its FIRST home was a
OBJ_ANYB:    .res 25                    ; [25] per-ss billboard bitmap, boot-filled by
                                        ;  baked $1158, which sat INSIDE obj_sasp
                                        ;  slot 1 — every armed stamp wrote asp=$01
                                        ;  over whichever object held that slot (the
                                        ;  2px barrel at FFC2.AE/0.AE/84).  THE
                                        ;  reason this block is declared, not baked.
obj_cur     = obj_t                     ; probe x cursor: columns covered so far
SEG_CODE

.assert obj_Y = obj_X + 12, error, "obj_hex addresses the lid as obj_X+12"

OBJ_MAXSLOT = 6                            ; most objects in one subsector
                                        ; is 5 with the pickups landed
                                        ; (wad_packed asserts <= 6)

; --- per-kind constants (2026-08-31).  ORDER IS THE KIND INDEX: hex,
; lamp, potion, helmet, box-stim, box-medikit, vest -- and the
; k row MUST mirror doom_wireframe's _KTAB (it asserts its own copy).
; In CODE, not bank C: the prologue reads obj_ktab under BANK_WALK.
obj_ktab:
   .byte 23, 15, 25, 34, 30, 47, 58        ; (the pillar's 10 died with it)
.if ::BANKED
; TWO TIERS PER KIND (2026-08-31, "all objects appear to render at lowest
; LOD"): the dispatch compares H against obj_lodh and indexes the tables
; at kind*2 + tier.  Single-tier kinds duplicate their row and use $FF --
; H clamps at 255, so a 255-vs-$FF fire is harmless by construction.
; Near tiers: barrel -> OCT (H >= 33, the old a >= 12 rule), boxes -> the
; trapezoid + cross (H >= 24: the bars are ~1.5 px there), potion -> the
; dodecagon (H >= 8: a circle is DEEP -- b = a -- so the half-pixel rule
; puts the switch far out).  The lamp's L0 wants 18 x slots against the
; arrays' 10, so it stays single-tier; helmet and vest ARE their tier.
.pushseg
.segment "VPTAB"
obj_lodh:
   .byte 33, $FF, 8, $FF, 24, 24, $FF
obj_tpl_pg2:                               ; art window high byte, lo/hi tier
   .byte >OBJ_ART,        >(OBJ_ART+$200)  ; hex / OCT
   .byte >OBJ_ART,        >OBJ_ART         ; lamp
   .byte >(OBJ_ART+$100), >(OBJ_ART+$200)  ; potion / dodecagon
   .byte >(OBJ_ART+$100), >(OBJ_ART+$100)  ; helmet
   .byte >(OBJ_ART+$100), >(OBJ_ART+$200)  ; box-stim / trapezoid+cross
   .byte >(OBJ_ART+$100), >(OBJ_ART+$200)  ; box-medikit
   .byte >(OBJ_ART+$100), >(OBJ_ART+$100)  ; vest
obj_tpl_off2:                              ; start offset within the window
   .byte OBJ_ART_HEX,    OBJ_ART_OCT
   .byte OBJ_ART_LAMP,   OBJ_ART_LAMP
   .byte OBJ_ART_POTION, OBJ_ART_POTL0
   .byte OBJ_ART_HELMET, OBJ_ART_HELMET
   .byte OBJ_ART_BOX,    OBJ_ART_BOXL0
   .byte OBJ_ART_BOX,    OBJ_ART_BOXL0
   .byte OBJ_ART_VEST,   OBJ_ART_VEST
.popseg
.endif

obj_bitmask:
   .byte $01,$02,$04,$08,$10,$20,$40,$80


; (obj_edges DELETED 2026-08-25 grind: the table-driven rectangle edge
;  loop it served died in the template-art rework — zero consumers
;  remained; 18 bytes back to the starved banked CODE region.)

; --- obj_anyb_fill: boot copy of the shipped OBJ_BITS bitmap into its
; main-RAM home (see OBJ_ANYB). Called from anim_init (bank L2/WALK
; ambient); pages SEG for the read and restores. $11xx ships nothing,
; so hardware needs this; the py65 loaders poke the copy directly. ---
SEG_OBJB
::obj_anyb_fill:
.if OBJ_DRAW = 0
   RTS
.else
   PAGE BANK_SEG
   LDX #LAY_OBJ_BITS_LEN-1
oaf_lp:
   LDA OBJ_BITS,X
   STA OBJ_ANYB,X
   DEX
   BPL oaf_lp
   PAGE BANK_WALK
   RTS
.endif
SEG_CODE                                   ; back to the main area (the next
                                           ; routine must NOT inherit OBJB)

; ============================================================================
; ::obj_subsector — draw every object whose home is subsector A.
;   in : A = subsector id.  Clobbers A/X/Y and the br scratch.
; ============================================================================
::obj_subsector:
.if OBJ_DRAW = 0
   RTS                                     ; feature off (layout.inc); the
.else                                      ; whole body is compiled out too --
                                        ; the octagonal art does not fit the
                                        ; banked CODE area (see the note at
                                        ; the head of this file)
   STA obj_ss
; GRIND (2026-08-29): the no-objects probe moved to the CALLER (the
; subsector prologue tests the OBJ_ANYB byte plane inline — LDA/BEQ —
; so this routine only runs for subsectors that HAVE objects; the old
; in-here shift/mask bitmap probe cost 37 cycles per visited subsector).
   PAGE BANK_SEG                           ; pass 1 reads the OBJ_* planes
; PASS 1 -- project every object of this subsector into a slot.  The
; table is ss-sorted, so the subsector's objects are ONE RUN; OBJ_RUN8
; (packed beside the bitmap) holds the first object index per ss-OCTET,
; so the walk starts at most seven objects early, skips forward, and
; stops the moment the run passes.  (The exhaustive LAY_N_OBJ sweep died
; 2026-08-31, Eben -- at 60 objects it was ~600 cycles per object-bearing
; subsector; this is bounded by the octet's population.)
   LDA #0
   STA obj_n
   LDA obj_ss
   LSR A
   LSR A
   LSR A
   TAX
   LDA OBJ_RUN8,X                          ; the octet is nonempty (the
   TAX                                     ; caller's bitmap probe), so
obj_scan:                                  ; this is a real index
   LDA OBJ_SS,X
   CMP obj_ss
   BEQ obj_hit
   BCS obj_run_end                         ; sorted: past the run -- done
   BCC obj_skip                            ; before the run: skip forward
obj_hit:
   JSR obj_project
   LDX obj_i                               ; obj_project clobbers X
obj_skip:
   INX
   CPX #LAY_N_OBJ
   BCC obj_scan
obj_run_end:
; PASS 2 -- draw FRONT TO BACK.  Order matters now that each billboard
; tightens behind itself: the nearest must claim its columns first, or a
; farther one would tighten them and clip the nearer one away.  n <= 3,
; so a selection scan is cheaper than any real sort.
   LDA obj_n
   STA obj_left
obj_pick:
   LDA obj_left
   BEQ obj_done
   LDX #0
   STX obj_best
   LDY #1
obj_minloop:
   CPY obj_n
   BCS obj_gotmin
   LDX obj_best                            ; depth[Y] < depth[best] ?
   LDA obj_sd_l,Y
   CMP obj_sd_l,X
   LDA obj_sd_h,Y
   SBC obj_sd_h,X
   BCS obj_minnext
   STY obj_best
obj_minnext:
   INY
   BNE obj_minloop
obj_gotmin:
   LDX obj_best
   JSR obj_draw_slot
   LDX obj_best                            ; retire it: depth = $FFFF sorts
   LDA #$FF                                ; last; obj_n stays the scan
   STA obj_sd_h,X                          ; bound, obj_left counts down
   DEC obj_left
   BNE obj_pick
obj_done:
   PAGE BANK_WALK                          ; the prologue's SS reads are WALK
   RTS


; ============================================================================
; obj_one — project and draw object X.
; ============================================================================
; ============================================================================
; obj_hex — fill six s16 slots with centre -+ a ratio triple.
;   in: obj_ctr_l/h = centre; X = triple base (0 = a, 3 = b);
;       Y = destination byte offset from obj_X (0 = the x table, 12 = the lid)
;   Both the x table and the lid ellipse are centre -+ {v, v2, v3}, so one
;   routine builds both -- which is what pays for the 12-gon's extra pair of
;   values in less code than the 8-gon's straight-line blocks took.
; ============================================================================
obj_hex:
   LDA #3
   STA obj_hcnt
oh_minus:
   SEC
   LDA obj_ctr_l
   SBC obj_a,X
   STA obj_X+0,Y
   LDA obj_ctr_h
   SBC #0
   STA obj_X+1,Y
   INY
   INY
   INX
   DEC obj_hcnt
   BNE oh_minus
   LDA #3                                  ; mirror back: X walks the triple
   STA obj_hcnt                            ; in reverse for the + side
oh_plus:
   DEX
   CLC
   LDA obj_ctr_l
   ADC obj_a,X
   STA obj_X+0,Y
   LDA obj_ctr_h
   ADC #0
   STA obj_X+1,Y
   INY
   INY
   DEC obj_hcnt
   BNE oh_plus
   RTS

; early-out target, placed BEFORE the body so the near-clip and far-recip
; branches reach it backwards (the four edge macros put the tail far out
; of branch range)
obj_ret:
   RTS
obj_project:
   STX obj_i
   LDA obj_n                               ; slot array is fixed-size
   CMP #OBJ_MAXSLOT
   BCS obj_ret
; --- stage the position exactly as the vertex pipeline stages a vertex ---
   LDA OBJ_OX,X
   STA zp_ri_d_l
   LDA OBJ_OY,X
   STA zp_br_dy_l
   LDA OBJ_PG,X
   STA zp_ri_d_h
; The rotate body is SMC-DISPATCHED: rot_select patches six call sites
; per frame to pick the general rot_w_pages or a CARDINAL twin when the
; view angle is axis-aligned (and the twins depend on operands only that
; path maintains).  A fixed JSR here is right for a general angle and
; WRONG for every cardinal one, which is why the billboards jumped as
; the view swung through 0/90/180/270.  Copy whatever the seg pipeline
; is using -- one of its patched sites is the live selection.
   LDA sxv0_rwpa+1
   STA obj_rwp+1
   LDA sxv0_rwpa+2
   STA obj_rwp+2
obj_rwp:
   JSR rot_w_pages                         ; operand SMC-copied above
; --- + the frame's translation ref (vertex pipeline's own ref add) ---
   CLC
   LDA zp_br_vx_l
   ADC vxcache_ref_x+0
   STA zp_br_vx_l
   LDA zp_br_vx_h
   ADC vxcache_ref_x+1
   STA zp_br_vx_h
   CLC
   LDA zp_br_vy_l
   ADC vxcache_ref_y+0
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ADC vxcache_ref_y+1
   STA zp_br_vy_h
; --- near clip: behind iff vy < 16 counts (the seg pipeline's test) ---
   BMI obj_ret
   BNE obj_nc_ok
   LDA zp_br_vy_l
   CMP #16
   BCC obj_ret
obj_nc_ok:
; --- reciprocal.  For SEG endpoints idx >= 256 is rare, so seg_xform
;     puts the far ladder on an island; for billboards it is the COMMON
;     case -- a floor lamp 1300 world units away is idx 336 -- so both
;     arms are inline here.  Dropping the far arm (the first cut did)
;     silently discarded every object on the map.
   LDA zp_br_vy_h
   CMP #16
   BCC obj_near
   LDA zp_br_vy_l                          ; idx = counts>>4, split by
   LSR A                                   ; nibble: vy_l is dead scratch
   LSR A                                   ; for the lo half, vy_h stays
   LSR A                                   ; whole for the hi
   LSR A
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ASL A
   ASL A
   ASL A
   ASL A
   ORA zp_br_vy_l
   TAY                                     ; Y = idx lo
   LDA zp_br_vy_h
   LSR A
   LSR A
   LSR A
   LSR A                                   ; A = idx hi
   JSR recip_hi
   JMP obj_recip_done
obj_near:
   LDA zp_br_vy_l
   AND #$F0
   ORA zp_br_vy_h
   TAY
   LDA RECIP_M8,Y
   STA zp_br_r_m8
   LDA RECIP_S,Y
   STA zp_br_r_s
obj_recip_done:
; --- screen x of the billboard's CENTRE.  A billboard is a 2D scaled
;     stamp, not a 3D object: one base point and one scale factor is the
;     whole of it, so the edges are NOT projected -- OBJ_RC is not even
;     read here any more.  The width falls out of the scale below.
   JSR project_x_c
   LDA zp_br_res_l
   CLC
   ADC #128                                ; sx = 128 + rns(b123)
   STA obj_cx_l
   LDA zp_br_res_h
   ADC #0
   STA obj_cx_h
; --- screen y of top and bottom.  project_y wants the height DELTA and
;     the rns kernel selected for this reciprocal (both heights share it).
   LDX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   LDX obj_i
   SEC
   LDA OBJ_ZT,X
   SBC zp_br_vz
   JSR project_y                           ; Y = sy lo, A = sy hi
   STY obj_yt_l
   STA obj_yt_h
   LDX obj_i
   SEC
   LDA OBJ_ZB,X
   SBC zp_br_vz
   JSR project_y
   STY obj_yb_l
   STA obj_yb_h
; --- park the projected rectangle in a slot; the draw happens later,
;     nearest-first, because each billboard tightens behind itself ---
   LDX obj_i                               ; project_y clobbered X
   LDA OBJ_ASP,X                           ; art template + width ratio
   LDY obj_n
   STA obj_sasp,Y
   LDA zp_br_vy_l
   STA obj_sd_l,Y
   LDA zp_br_vy_h
   STA obj_sd_h,Y
   LDA obj_cx_l
   STA obj_scx_l,Y
   LDA obj_cx_h
   STA obj_scx_h,Y
   LDA obj_yt_l
   STA obj_syt_l,Y
   LDA obj_yt_h
   STA obj_syt_h,Y
   LDA obj_yb_l
   STA obj_syb_l,Y
   LDA obj_yb_h
   STA obj_syb_h,Y
   INC obj_n
   RTS

; ============================================================================
; obj_draw_slot — draw slot X's rectangle, then TIGHTEN behind it.
;
; The TOP edge is drawn with BOT_RECORDS ARMED, so the same call both
; draws it and records it; tighten_from_records then makes that line the
; new aperture BOTTOM across the billboard's columns.  Nothing drawn
; later in the walk can appear below it -- which is exactly what a solid
; object standing on the floor should do to the geometry behind it.  The
; other three edges are pure outline and are drawn DISARMED, after the
; top, so they are not themselves clipped by the tighten they cause.
;
; This is also why pass 2 runs nearest-first: a far billboard that
; tightened first would close the columns a nearer one still needs.
; ============================================================================
; obj_draw_slot — stamp slot X's billboard, then TIGHTEN behind it.
;
; A billboard is a 2D SCALED SPRITE, not a 3D object: everything follows
; from the base point and ONE scale factor, with no projection at all.
;     H  = syb - syt                                  the scale, screen px
;     a  = 23H/64 = H>>2 + H>>4 + H>>5 + H>>6          half width
;     b  = H/16                                        lid semi-axis
;     a7 = 45a/64 = a>>1 + a>>3 + a>>4 + a>>6          a * 0.7071, to 0.4%
;     b7 = 45b/64
;     dy = 7H/8   = H - H>>3                lid centre -> base centre
; 23/64 and 45/64 are exact sums of powers of two, so there is not one
; multiply here.  An octagon's vertices are only ever +-a, +-0.7071a,
; which is why five x values and five y values cover all eight.
;
; The lid's TOP arc (art lines 0-3) is drawn with BOT_RECORDS ARMED, so
; it both draws and records; tighten_from_records then makes that arc the
; new aperture BOTTOM and nothing later in the walk can draw below it.
; ============================================================================
obj_draw_slot:
   JMP obj_ds_go
obj_dsr:                                   ; near early-out: the tail is ~490
   RTS                                     ; bytes away, out of branch range
obj_ds_go:
   LDA obj_scx_l,X
   STA obj_cx_l
   LDA obj_scx_h,X
   STA obj_cx_h
   LDA obj_syt_l,X
   STA obj_yt_l
   LDA obj_syt_h,X
   STA obj_yt_h
   LDA obj_syb_l,X
   STA obj_yb_l
   LDA obj_syb_h,X
   STA obj_yb_h
   LDA obj_sasp,X                          ; X stops being the slot below
   STA obj_asp                             ; (the a7/b7 loop takes it)
   SEC                                     ; H = syb - syt
   LDA obj_yb_l
   SBC obj_yt_l
   STA obj_h
   LDA obj_yb_h
   SBC obj_yt_h
   BEQ obj_hok
   BMI obj_dsr                             ; inverted: degenerate
   LDA #255                                ; very near: clamp the scale
   STA obj_h
obj_hok:
; a = H * k / 64, k = the object's width ratio in 64ths.  A billboard's
; half width and its height both scale by the same 1/depth, so k is just
; 64*radius/height and no projection of the radius is needed.  The old
; code hardwired the BARREL's 23/64 as a four-term shift chain; one
; quarter-square mul is both general and ~21 bytes SHORTER.  k <= 63 and
; H <= 255 are asserted in the baker, so the product cannot exceed
; 251 -- a stays u8 with no clamp.
; (No minimum-height cull: below a few px every offset rounds to zero,
;  the stamp collapses to a point, and the clipper rejects each
;  zero-length line.)
   LDA obj_h
   STA zp_mul_b
   LDY obj_asp                             ; the aspect byte IS the kind
   LDA obj_ktab,Y                          ; index; k is a per-kind constant
   JSR umul8                               ; (mirrors doom_wireframe _KTAB)
   LDA zp_prod_l                           ; (H*k + 32) >> 6, ROUNDED:
   ASL A                                   ; << 2, then +128 into the hi byte
   ROL zp_prod_h
   ASL A
   ROL zp_prod_h
   CLC
   ADC #128
   LDA zp_prod_h
   ADC #0
   STA obj_a
   JSR obj_occluded                        ; every column already solid?
   BCC obj_dsr                             ; then this slot draws NOTHING
; b = (H + 8) / 16 ROUNDED (2026-08-25 rounding audit: the LSR chain
; truncated — a 1px-flatter lid on ~half of all sizes). The ADC's
; carry-out is bit 8 of H+8; ROR folds it back so the u9 sum shifts
; correctly even at the H=255 clamp.
   LDA obj_h
   CLC
   ADC #8
   ROR A
   LSR A
   LSR A
   LSR A
   STA obj_b
; dy = H - 2b (was the truncating 7H/8 = H - H>>3). This is a CONTRACT,
; not an approximation: the rect art's bottom edge is Y[11] = lid
; centre + b + dy = syt + 2b + dy, and with dy = H - 2b that is
; EXACTLY syb for every H (the old form drifted +-1px). For barrels it
; puts the base ellipse's centre exactly b above the bottom — the
; mirror of the lid's centre b below the top — and 2b ~ H/8, so the
; proportions are the intended 7/8 to within the same rounding.
   LDA obj_b
   ASL A
   STA obj_t
   LDA obj_h
   SEC
   SBC obj_t
   STA obj_dy
; a2,b2 = 47/64 of a,b (the dodecagon's sqrt3-1, to 0.32%); a3,b3 = the
; EXACT complement, since (sqrt3-1) + (2-sqrt3) = 1.
;
; THE RATIO MUST BE ROUNDED, NOT TRUNCATED, and this is not a quality nicety
; -- it is an ordering invariant.  The six slots come out monotonic in y iff
; v >= v2 >= v3, i.e. iff v2 >= v/2.  The obvious shift chain
; (v>>1 + v>>3 + v>>4 + v>>5 + v>>6) truncates every term and returns v2 < v3
; for v = 1,3,5,7 -- and b is H/16, so a barrel of any sane size lands
; squarely in that range (H=48 -> b=3 -> b2=1, b3=2).  Y[1] and Y[2] then
; SWAP, the lid's arc edges cross, and the barrel draws as two full-width
; horizontal bands.  Rounding fixes it for all 256 inputs; verified
; exhaustively.  One mul is also ~20 bytes shorter than the chain was.
   LDX #0
obj_s7:
   STX obj_t                               ; umul8 eats X
   LDA obj_a,X
   STA zp_mul_b
   LDA #47
   JSR umul8
   LDA zp_prod_l                           ; (v*47 + 32) >> 6
   ASL A
   ROL zp_prod_h
   ASL A
   ROL zp_prod_h
   CLC
   ADC #128
   LDA zp_prod_h
   ADC #0
   LDX obj_t
   STA obj_a2,X
   SEC
   LDA obj_a,X
   SBC obj_a2,X
   STA obj_a3,X
   INX
   INX
   INX
   CPX #6
   BCC obj_s7
; --- X[0..5] = cx -+ {a,a2,a3};  Y[0..5] = lid centre -+ {b,b2,b3} -------
; Both tables are the SAME shape, which is what obj_hex exists for.  The lid
; centre is syt + b, so Y[0] comes out syt and Y[5] syt + 2b exactly as the
; art expects.
   LDA obj_cx_l
   STA obj_ctr_l
   LDA obj_cx_h
   STA obj_ctr_h
   LDX #0                                  ; the a triple
   LDY #0                                  ; -> obj_X
   JSR obj_hex
   CLC
   LDA obj_yt_l
   ADC obj_b
   STA obj_ctr_l
   LDA obj_yt_h
   ADC #0
   STA obj_ctr_h
   LDX #3                                  ; the b triple
   LDY #12                                 ; -> obj_Y (= obj_X + 12)
   JSR obj_hex
; --- Y[9..11] = the base arc: only the NEAR half is ever drawn ------------
   LDX #6
obj_ycp:
   CLC
   LDA obj_Y+0,X
   ADC obj_dy
   STA obj_Y+12,X
   LDA obj_Y+1,X
   ADC #0
   STA obj_Y+13,X
   INX
   INX
   CPX #12
   BCC obj_ycp
; --- stamp the 14 art lines ----------------------------------------------
; FUSED (2026-08-25): the outline runs lead DISARMED; the $FE control
; entry arms the fused walker and the trailing AUTHORITY arc lines each
; draw + apply in one walk (obj_fused routes the dispatch below).
   PAGE BANK_C
   ZERO FW_TOUCH                           ; per-object zero-touch state
                                        ; (fused_begin inlined 2026-08-29:
                                        ;  the JSR/RTS was 12 of its 16
                                        ;  cycles; the routine survives as
                                        ;  the harness entry)
   ZERO obj_fused                          ; leading run: plain draws
; Start at this object's template.  THE ASPECT BYTE IS A KIND INDEX
; (2026-08-31, the pickup landing): eight billboard kinds, dispatched by a
; compare ladder, each selecting its ladder builder and its art template.
; A template is (window page, start offset): obj_e stayed a byte by
; becoming an offset WITHIN a 256-byte window, and the stamp walker's four
; abs,X reads get the window HIGH byte SMC'd here (oa_rd0..3 -- page
; alignment keeps the +0..+3 displacements carry-free).
; FLAT (Eben: "ignore flat") never gets here: its planes re-homed to
; $A600 (the $B700 run was 256 B, the planes are 459) and it draws every
; object -- pickups included -- as the hex barrel; all paths below are
; ::BANKED.
.if ::BANKED
   LDX obj_asp
   LDA #0
   STA obj_lod
   LDA obj_h
   CMP obj_lodh,X                          ; C = 1 iff H >= the near switch
   TXA
   ROL A                                   ; kind*2 + tier
   TAY
   LDA obj_tpl_pg2,Y                       ; the window (SMC: 4 sites)
   STA oa_rd0+2
   STA oa_rd1+2
   STA oa_rd2+2
   STA oa_rd3+2
   LDA obj_tpl_off2,Y
   STA obj_e
   TYA
   LSR A                                   ; tier back to C, kind to A
   TAX
   ROL obj_lod                             ; obj_lod = the tier bit
   CPX #OBJ_K_LAMP
   BCC obj_sel_hex                         ; 0 = barrel
   BNE onot_lamp
; THE FLOOR LAMP (thing 2028, and the candelabras that borrow it): 10 x +
; 13 y slots via obj_lamp_xy.  BANK C IS ALREADY PAGED here (the prologue
; does it for OBJ_ART), which the bank-C ladder tables rely on.
   JSR obj_lamp_xy
   JMP obj_art_go
onot_lamp:
   CPX #OBJ_K_HELMET
   BCC obj_sel_potion                      ; 2
   BEQ obj_sel_helmet                      ; 3
   CPX #OBJ_K_VEST
   BCC obj_sel_box                         ; 4, 5
   JSR obj_vest_xy                         ; 6
   JMP obj_art_go
obj_sel_potion:
   JSR obj_potion_xy
   JMP obj_art_go
obj_sel_helmet:
   JSR obj_helmet_xy
   JMP obj_art_go
obj_sel_box:
   JSR obj_box_y                           ; (reads obj_asp for the lid)
   JMP obj_art_go
.endif
obj_sel_hex:
   LDA obj_a                               ; w = 9a/16 = a>>1 + a>>4
   LSR A
   STA obj_t
   LSR A
   LSR A
   LSR A
   CLC
   ADC obj_t
   STA obj_t
   SEC
   LDA obj_cx_l
   SBC obj_t
   STA obj_Y+12                            ; "x index 12" = cx - w
   LDA obj_cx_h
   SBC #0
   STA obj_Y+13
   CLC
   LDA obj_cx_l
   ADC obj_t
   STA obj_Y+14                            ; "x index 13" = cx + w
   LDA obj_cx_h
   ADC #0
   STA obj_Y+15
.if .not ::BANKED
   LDA #OBJ_ART_HEX
   STA obj_e                               ; flat: template A0, always
.endif
obj_art_go:
   JSR obj_probe                           ; can this billboard skip the
                                           ; clipper entirely?
obj_stamp:
; NO PAGE (2026-08-29): the art templates moved into BANK C, so this loop
; reads them and draws them under the one PAGE BANK_C the object prologue
; already did.  It used to page BANK_SEG here and BANK_C again below, twice
; per template line -- 22.4 ROMSEL stores/frame across the suite.
   LDX obj_e
oa_rd0:
   LDY OBJ_ART+0,X
   CPY #OBJ_ART_ARM                        ; control entry? ($FE/$FF)
   BCS obj_ctl
   LDA obj_X+0,Y
   STA zp_line_xl_l
   LDA obj_X+1,Y
   STA zp_line_xl_h
oa_rd1:
   LDY OBJ_ART+1,X
   LDA obj_Y+0,Y
   STA zp_line_yl_l
   LDA obj_Y+1,Y
   STA zp_line_yl_h
oa_rd2:
   LDY OBJ_ART+2,X
   LDA obj_X+0,Y
   STA zp_line_xr_l
   LDA obj_X+1,Y
   STA zp_line_xr_h
oa_rd3:
   LDY OBJ_ART+3,X
   LDA obj_Y+0,Y
   STA zp_line_yr_l
   LDA obj_Y+1,Y
   STA zp_line_yr_h
   LDA obj_fused                           ; (bank C held since the prologue)
   BEQ obj_plain
   JSR fused_below_raw                     ; authority line: clip + plot +
   JMP obj_st_next                         ; apply in one walk
obj_plain:
   LDA obj_fast                            ; provably unclipped? then the
   BEQ obj_slow                            ; span walk has nothing to do
   JMP obj_emit_direct                     ; (OBJX; it rejoins obj_st_next)
obj_slow:
   JSR draw_clipped_line_s16
obj_st_next:
   LDA obj_e
   CLC
   ADC #4
   STA obj_e
   JMP obj_stamp
; Control entries end the template ($FF) or stop recording ($FE), so the
; two art blocks need no per-template length and the RECORDED lines are
; always the block's leading run.  PAGE eats A but not Y, so the second
; test costs one CPY rather than a saved flag.
obj_ctl:
   CPY #OBJ_ART_END                        ; (bank C held; Y survives)
   BEQ obj_art_done
   LDA #1                                  ; $FE: ARM the fused authority run
   STA obj_fused
   JMP obj_st_next
obj_art_done:
; --- merge pass over the object's columns (applies happened per line) ----
   LDA FW_TOUCH
   BEQ obj_dsx
   LDX #0                                  ; ilo = clamp(X[0])
   LDA obj_X+1
   BMI obj_ds_lo
   BEQ obj_ds_lol
   LDX #255
   BNE obj_ds_lo
obj_ds_lol:
   LDX obj_X+0
obj_ds_lo:
   STX zp_i_l
   LDX #255                                ; ihi = clamp(X[5]) + 1
   LDA obj_X+11
   BMI obj_ds_hz
   BNE obj_ds_hi
   LDX obj_X+10
   INX
   BNE obj_ds_hi
obj_ds_hz:
   LDX #0
obj_ds_hi:
   STX zp_i_h
   CPX zp_i_l
   BCC obj_dsx
   BEQ obj_dsx
   JSR fused_merge_range
obj_dsx:
   RTS

SEG_OBJG
; ============================================================================
; obj_occluded — C=1 if any column of the billboard is still open, C=0 if
; the walk has already closed every one of them.
;
; A billboard spans [cx-a, cx+a] — X[0]/X[5] are exactly those — so this
; needs only cx and the half width, which is why it sits at the TOP of
; obj_draw_slot: before the vertex build, the art walk and the tighten.
; C=0 means invisible: every line would be clipped away, and tightening
; columns that are already solid is a no-op, so the whole slot is skipped.
;
; Measured: 17 of 37 billboards stamped over the 19-pose suite are fully
; occluded, and they were burning 53,816 cycles drawing nothing.
;
; span_has_gap wants NATIVE [lo, hi): zp_i_l = lo, A = hi EXCLUSIVE. The
; +1 for the exclusive edge rides the SEC into the ADC. It preserves V
; and lives in main RAM, so this is a plain JSR from either build.
; A box wholly off screen is left to the clipper (rare, and the test
; would cost more bytes than it saves).
; ============================================================================
obj_occluded:
   LDX obj_cx_l
   SEC                                     ; hi = cx + a + 1 (EXCLUSIVE)
   TXA
   ADC obj_a
   TAY
   LDA obj_cx_h
   ADC #0
   BEQ obj_oc_hs
   LDY #255                                ; past the right edge: clamp
obj_oc_hs:
   STY zp_i_h                              ; (objects own zp_i_l/h — the
   SEC                                     ;  merge pass uses them too)
   TXA                                     ; lo = cx - a
   SBC obj_a
   TAY
   LDA obj_cx_h
   SBC #0
   BEQ obj_oc_ls
   BPL obj_oc_none                         ; wholly right of the screen
   LDY #0                                  ; negative: clamp to column 0
obj_oc_ls:
   STY zp_i_l
   LDA zp_i_h
   JMP span_has_gap                        ; C = the verdict, straight out
obj_oc_none:
   CLC
   RTS

SEG_OBJX
; ============================================================================
; obj_probe — may this billboard skip the clipper?  obj_fast = 1 iff
; every one of its art lines is provably inside the visible aperture.
;
; Two conditions, both cheap and both once per billboard (not per line):
;   1. FULLY ON SCREEN. The box is [X0,X5] x [yt,yb]: X0/X5 are the
;      sorted extremes of the six x values and the lid top / base bottom
;      bound y, so the box contains every art vertex by construction
;      (verified over the suite: 0 violations). All four HI bytes must be
;      zero and y must sit inside the visible band.
;   2. FULLY UNCLIPPED. Walk the active span list (sorted by XSTART) and
;      require the spans to COVER [X0,X5] with no gap — a gap is a column
;      the walk already closed as solid — and each covering span's INNER
;      aperture [IT,IB] to contain [yt,yb]. IT/IB are the per-span
;      extremes, so that is exactly dcl's Tier-2 inner accept, hoisted
;      out of the per-line walk and asked once for the whole box.
;
; Measured on the 19-pose suite: 24% of stamped billboards qualify, and
; they are the EXPENSIVE ones (5,437 cyc each, 38% of all stamp time).
; Clobbers A,X,Y.
; ============================================================================
obj_probe:
   LDY #0
   STY obj_fast                            ; assume the clipper is needed
   LDA obj_X+1                             ; all four HI bytes must be 0:
   ORA obj_X+11                            ;  on screen and non-negative.
   ORA obj_yt_h                            ;  ORA-fold — one branch, and 6
   ORA obj_yb_h                            ;  bytes shorter than four tests
   BNE obj_pno
   LDA obj_yt_l
   CMP #Y_BIAS                             ; above the visible band?
   BCC obj_pno
   LDA #VIS_YMAX
   CMP obj_yb_l                            ; below it?
   BCC obj_pno
   LDA obj_X+0
   STA obj_cur                             ; cursor: covered up to here
   LDX zp_head
   BEQ obj_pno                             ; no spans at all: nothing open
obj_ploop:
   LDA POOL_XEND,X                         ; XEND is EXCLUSIVE
   CMP obj_cur
   BCC obj_pnext                           ; span wholly left of the cursor
   BEQ obj_pnext
   LDA POOL_XSTART,X
   CMP obj_cur
   BEQ obj_pin
   BCS obj_pno                             ; starts past the cursor: GAP
obj_pin:
   LDA obj_yt_l
   CMP POOL_IT,X
   BCC obj_pno                             ; top pokes above the aperture
   LDA POOL_IB,X
   CMP obj_yb_l
   BCC obj_pno                             ; bottom pokes below it
   LDA POOL_XEND,X
   STA obj_cur
   CMP obj_X+10                            ; covered past the last column?
   BEQ obj_pnext                           ; (XEND exclusive: need > x1)
   BCS obj_pyes
obj_pnext:
   LDA POOL_NEXT,X
   TAX
   BNE obj_ploop
obj_pno:
   RTS
obj_pyes:
   LDA #1
   STA obj_fast
   RTS

obj_emit_direct:
; Every art vertex is inside [X0,X5] x [yt,yb] BY CONSTRUCTION (X0/X5 are
; the sorted extremes of the six x values and the lid/base bound y), and
; obj_probe proved that box is covered by spans whose [IT,IB] contains
; it. So the whole line is visible: hand the segment straight to the
; emitter. The HI bytes are all zero — obj_probe rejected anything not
; fully on screen — so the s16 pre-clip has nothing to do either.
   LDA zp_line_xl_l
   STA zp_seg_start_x
   LDA zp_line_yl_l
   STA zp_seg_start_y
   LDA zp_line_xr_l
   STA zp_ox1
   LDA zp_line_yr_l
   STA zp_tmp0
   JSR dcl_emit_segment
   JMP obj_st_next

SEG_CODE                                   ; RESTORE the segment: the next
                                           ; included file (seg_xform.s)
                                           ; opens with no SEG_ macro and
                                           ; would inherit OBJX — the
                                           ; fall-through-across-.segment
                                           ; landmine, caught by a 660-byte
                                           ; CODE shrink in the map

.endif

; ===========================================================================
; LADDER BUILDERS LIVE AT THE END, ON PURPOSE.  The techno pillar's builder
; (retired 2026-08-31 with the pillar itself -- Eben: "it just doesn't
; work") first landed between the obj_ycp loop and the stamp loop, which
; the object builder FALLS THROUGH -- so every object ran it over its own
; obj_Y ladder and hit the RTS, and billboards stopped drawing entirely.
; MEAN fell 1.8% and the suite stayed green, which is the more useful half
; of that lesson (test_object_draws exists because of it).  Nothing falls
; into these blocks; the dispatch JSRs.
; ===========================================================================
SEG_BANKC
.if ::BANKED
; THE FLOOR LAMP'S LADDERS -- doc/billboard's lamp L1, VERBATIM (three
; bands r 11.5 z 0-5 / r 7.5 z 5-14 / r 5.5 z 14-48, design D = 256,
; eye = 41).  x is 5 magnitudes; y is 13 values, expressed as 256ths of
; the projected height below syt.  y_0 = syt and y_12 = syb exactly, so
; the extent invariant holds by construction.
obj_lgx:  .byte 167, 166, 122, 109        ; x magnitudes /256 of a (the
                                          ; 5th is a itself)
obj_lpo:  .byte 10, 44, 42, 40, 38        ; +side byte offset per magnitude:
                                          ; +-a keep obj_X+0/+10 (obj_probe
                                          ; hardwires those as the
                                          ; silhouette edges); the inner
                                          ; +side values spill to
                                          ; obj_Y[13..16]
obj_lgy:  .byte 174, 176, 177, 178, 180   ; y_1..y_11 /256 of H below syt
          .byte 218, 221, 224, 226, 229
          .byte 252
.endif
SEG_CODE
; ============================================================================
; obj_lamp_xy -- the floor lamp's 10-x / 13-y ladder.
; ============================================================================
; IN SEG_BANKC: this is the clipper's own bank -- the dispatch JSRs here
; under the prologue's PAGE BANK_C, and umul8 lives at $14B9 in the
; always-mapped bottom.  Being out of the object builder's fall-through
; path comes free.
; BANKED ONLY (Eben, 2026-08-31: "ignore flat").  Flat has no room for it
; anywhere: CODE is 107 B over with it there, and flat's SEG_BANKC is
; CLIPF, whose true wall is ROM_DBOUND_C at $7000 -- 153 B free, and this
; is ~160.  So flat draws EVERY object as the hex barrel until the
; tube-parasite re-cut (task #20) frees space.
;
; Unlike the barrel and the pillar, the lamp shows all three of its bands'
; rims, and its radii are off the dodecagon vertex ladder, so its occlusion
; cuts land on values the {a, a2, a3} triple cannot express: 5 x magnitudes
; where they need 3, and the whole x table is rebuilt here.  Everything is
; linear in a / H -- the shape is RIGID, per the pillar's lesson above.
.if ::BANKED
SEG_BANKC
; ---- obj_ends: syt -> obj_Y+0/1, syb -> obj_Y+Y (2026-08-31 de-lard:
; every builder ended with these copies inline) -------------------------
obj_ends:
   LDA obj_yt_l
   STA obj_Y+0
   LDA obj_yt_h
   STA obj_Y+1
   LDA obj_yb_l
   STA obj_Y+0,Y
   LDA obj_yb_h
   STA obj_Y+1,Y
   RTS

obj_lamp_xy:
   LDA obj_a
   STA obj_pb                              ; the 5th magnitude is a itself
   STA zp_mul_b                            ; umul8 only READS this, so it
   LDX #3                                  ; survives all four calls
olx_m:
   STX obj_px                              ; umul8 eats X
   LDA obj_lgx,X
   JSR umul8                               ; a * frac
   LDX obj_px
   LDA zp_prod_l                           ; C = 1 iff the dropped low byte
   CMP #128                                ;     rounds up
   LDA zp_prod_h
   ADC #0
   STA obj_pb+1,X
   DEX
   BPL olx_m
; the 5 mirror pairs: -side ascends obj_X[0..4], +side per obj_lpo
   LDX #4
olx_s:
   TXA
   ASL A
   TAY
   SEC
   LDA obj_cx_l
   SBC obj_pb,X
   STA obj_X+0,Y
   LDA obj_cx_h
   SBC #0
   STA obj_X+1,Y
   LDY obj_lpo,X
   CLC
   LDA obj_cx_l
   ADC obj_pb,X
   STA obj_X+0,Y
   LDA obj_cx_h
   ADC #0
   STA obj_X+1,Y
   DEX
   BPL olx_s
; y_1..y_11 = syt + (H * frac + 128 >> 8); y_0/y_12 = syt/syb EXACTLY
   LDA obj_h
   STA zp_mul_b
   LDX #10
oly_m:
   STX obj_px
   LDA obj_lgy,X
   JSR umul8
   LDX obj_px
   LDA zp_prod_l
   CMP #128
   LDA zp_prod_h
   ADC #0
   STA obj_pu                              ; (builder scratch)
   TXA
   ASL A
   TAY
   CLC
   LDA obj_yt_l
   ADC obj_pu
   STA obj_Y+2,Y                           ; slot X+1
   LDA obj_yt_h
   ADC #0
   STA obj_Y+3,Y
   DEX
   BPL oly_m
   LDA obj_yt_l
   STA obj_Y+0
   LDA obj_yt_h
   STA obj_Y+1
   LDA obj_yb_l                            ; the drawn figure spans exactly
   STA obj_Y+24                            ; the projected height -- the
   LDA obj_yb_h                            ; extent invariant
   STA obj_Y+25
   RTS
SEG_CODE
.endif

; ============================================================================
; THE PICKUP LADDER BUILDERS (2026-08-31) -- banked only; flat carries no
; pickup planes at all.  All AT THE END OF THE FILE, out of the object
; builder's fall-through path (the obj_pillar_y lesson).  Everything is
; LINEAR in a / H -- the shapes are RIGID billboards, per the pillar's
; static-billboard rule; the fractions are doc/billboard's L1 geometry
; verbatim (test_pickup_ladders gates them against integer mirrors).
; All run under the prologue's PAGE BANK_C; tables live HERE in CODE
; because bank C is nearly full and these are banked-only anyway.
; ============================================================================
.if ::BANKED
; ---- obj_mirror: mag = round(a * A / 256); store cx - mag at obj_X+Y,
; cx + mag at obj_X + obj_px.  zp_mul_b holds a; the spill slots are just
; obj_X offsets 38..44, so ONE helper serves every builder's pairs. ------
obj_mirror:
   STY obj_pn                              ; umul8 EATS Y as well as X (the
   JSR umul8                               ; quarter-square index pair)
   LDA zp_prod_l                           ; C = 1 iff the dropped low byte
   CMP #128                                ;     rounds up
   LDA zp_prod_h
   ADC #0
   STA obj_pu
   LDY obj_pn
   SEC
   LDA obj_cx_l
   SBC obj_pu
   STA obj_X+0,Y
   LDA obj_cx_h
   SBC #0
   STA obj_X+1,Y
   LDY obj_px
   CLC
   LDA obj_cx_l
   ADC obj_pu
   STA obj_X+0,Y
   LDA obj_cx_h
   ADC #0
   STA obj_X+1,Y
   RTS

; ---- obj_ymirror: mag = round(H * A / 256); store cy - mag at obj_Y+Y,
; cy + mag at obj_Y + obj_px.  zp_mul_b holds H, obj_pb+0/1 hold cy. ------
obj_ymirror:
   STY obj_pn                              ; umul8 eats Y (see obj_mirror)
   JSR umul8
   LDA zp_prod_l
   CMP #128
   LDA zp_prod_h
   ADC #0
   STA obj_pu
   LDY obj_pn
   SEC
   LDA obj_pb+0
   SBC obj_pu
   STA obj_Y+0,Y
   LDA obj_pb+1
   SBC #0
   STA obj_Y+1,Y
   LDY obj_px
   CLC
   LDA obj_pb+0
   ADC obj_pu
   STA obj_Y+0,Y
   LDA obj_pb+1
   ADC #0
   STA obj_Y+1,Y
   RTS

SEG_BANKC
obj_lidf:  .byte 51, 54                   ; box lid /256 of H: 3/15, 4/19
; box L0 constants, /256 (stim, medikit): rear edge (D-d)/(D+d) of a;
; cross half-width, bar half-thickness (of a); cross half-height, bar
; half-thickness (of H) -- doc/billboard's lid-implied viewpoints
obj_brf:   .byte 183, 201                 ; rear-edge ratio
obj_bcw:   .byte 110, 55                  ; cross half-width /256 of a
obj_btx:   .byte 37, 18                   ; cross bar half-thickness (x)
obj_bch:   .byte 51, 40                   ; cross half-height /256 of H
obj_btz:   .byte 17, 13                   ; cross bar half-thickness (y)
SEG_CODE

SEG_BANKC
obj_hgx:   .byte 192, 128, 96, 64         ; helmet x mags /256 of a
obj_hnx:   .byte 2, 4, 6, 8               ; their -side obj_X byte offs
obj_hpx:   .byte 44, 42, 40, 38           ; +side offs (obj_Y[13..16] spill,
                                          ; the lamp's convention; +-a keep
                                          ; obj_X+0/+10 for obj_probe)
SEG_CODE
obj_vgy:   .byte 20, 89, 75, 52           ; vest y /256 of H: front shoulder,
                                          ; armpit, scoop front, scoop rear

; ---- the boxes: y = {syt, syt + lid, syb}; x is the prologue's +-a.
; NEAR TIER (obj_lod = 1) adds the trapezoid's rear pair (obj_Y[13..14],
; the spill convention: x byte offs 38/40) and the cross outline's 4 x
; (offs 2/4/6/8) + 4 y (offs 6..12) values. ------------------------------
obj_box_y:
   LDA obj_h
   STA zp_mul_b
   LDY obj_asp                             ; 4 = stim, 5 = medikit: every
   LDA obj_lidf-OBJ_K_BOXS,Y               ; fraction row is per-kind
   JSR umul8
   LDA zp_prod_l                           ; C = 1 iff the dropped low byte
   CMP #128                                ;     rounds up
   LDA zp_prod_h
   ADC #0
   STA obj_pb+3                            ; lid px, kept for the L0 centre
   CLC
   ADC obj_yt_l
   STA obj_Y+2
   LDA obj_yt_h
   ADC #0
   STA obj_Y+3
   LDY #4
   JSR obj_ends                            ; syt -> Y0, syb -> Y2 (off 4)
   LDA obj_lod
   BNE obj_box_l0
   RTS
obj_box_l0:
   LDA obj_a
   STA zp_mul_b
   LDA #40                                 ; rear pair -> the spill slots
   STA obj_px
   LDY #38
   LDX obj_asp
   LDA obj_brf-OBJ_K_BOXS,X
   JSR obj_mirror
   LDA #8                                  ; cross half-width -> obj_X 1/4
   STA obj_px
   LDY #2
   LDX obj_asp
   LDA obj_bcw-OBJ_K_BOXS,X
   JSR obj_mirror
   LDA #6                                  ; bar half-thickness -> obj_X 2/3
   STA obj_px
   LDY #4
   LDX obj_asp
   LDA obj_btx-OBJ_K_BOXS,X
   JSR obj_mirror
; the cross centre: yc = syt + (lid + H)/2 -- the 9-bit sum rides the
; ADC carry through ROR
   LDA obj_pb+3
   CLC
   ADC obj_h
   ROR A
   CLC
   ADC obj_yt_l
   STA obj_pb+0                            ; cy lo (s16)
   LDA obj_yt_h
   ADC #0
   STA obj_pb+1                            ; cy hi
   LDA obj_h
   STA zp_mul_b
   LDA #12                                 ; cross half-height -> y offs 3/6
   STA obj_px
   LDY obj_asp
   LDA obj_bch-OBJ_K_BOXS,Y
   LDY #6
   JSR obj_ymirror
   LDA #10                                 ; bar half-thickness -> y offs 4/5
   STA obj_px
   LDY obj_asp
   LDA obj_btz-OBJ_K_BOXS,Y
   LDY #8
   JSR obj_ymirror
   RTS
   RTS

; ---- the potion: circle + wide stem ------------------------------------
; x: cx -+ {a, qa} always (a from the prologue); slots 2/3 are the stem
; sides, which are wn at the far tier and SNAP to the a3 vertices at the
; near one (the 12-gon corners: exact joins, no split arithmetic).  y from
; syb upward -- the bulb is GROUNDED: far tier centre qa above the floor
; line, near tier a above it.
; IN SEG_BANKC (with obj_lamp_xy): banked CODE ran 270 B over with all
; four builders there, and these two run under the prologue's PAGE BANK_C
; anyway.  umul8 is in the always-mapped bottom.
SEG_BANKC
obj_potion_xy:
   LDA obj_a
   STA zp_mul_b
   LDA #187                                ; q = a2 = 0.7321
   JSR umul8
   LDA zp_prod_l
   CMP #128
   LDA zp_prod_h
   ADC #0
   STA obj_pb                              ; qa (the y ladder needs it)
   LDA #69                                 ; a3 = 0.2679
   JSR umul8
   LDA zp_prod_l
   CMP #128
   LDA zp_prod_h
   ADC #0
   STA obj_pb+2                            ; a3*a (ditto)
   LDA #8                                  ; cx -+ qa -> obj_X 1/4
   STA obj_px
   LDY #2
   LDA #187
   JSR obj_mirror
   LDA #6                                  ; the stem sides -> obj_X 2/3:
   STA obj_px                              ; wn far, a3 near (the vertex
   LDY #4                                  ; snap -- exact joins)
   LDX obj_lod
   BEQ opt_wn
   LDA #69
   JSR obj_mirror
   JMP opt_shared
opt_wn:
   LDA #73                                 ; wn = 2/7 (the 4-px neck)
   JSR obj_mirror
opt_shared:
   LDA obj_lod
   BEQ opt_far
   JMP opt_near
opt_far:
   LDY #8                                  ; syt -> y0, syb -> y4 (off 8)
   JSR obj_ends
   LDA obj_pb                              ; y1 = syb - 2qa (arc mid)
   ASL A                                   ; qa <= 72, no carry out
   STA obj_pu
   SEC
   LDA obj_yb_l
   SBC obj_pu
   STA obj_Y+2
   LDA obj_yb_h
   SBC #0
   STA obj_Y+3
   CLC
   LDA obj_pb                              ; y2 = syb - (qa + a3a)
   ADC obj_pb+2
   STA obj_pu
   SEC
   LDA obj_yb_l
   SBC obj_pu
   STA obj_Y+4
   LDA obj_yb_h
   SBC #0
   STA obj_Y+5
   SEC
   LDA obj_pb                              ; y3 = syb - (qa - a3a)
   SBC obj_pb+2
   STA obj_pu
   SEC
   LDA obj_yb_l
   SBC obj_pu
   STA obj_Y+6
   LDA obj_yb_h
   SBC #0
   STA obj_Y+7
   RTS
opt_near:
; the dodecagon's y ladder: cy -+ {a, qa, a3a} with cy = syb - a, all
; expressed as syb minus a byte (the stem sides were mirrored above)
   LDY #12                                 ; syt -> y0, syb -> y6 (off 12)
   JSR obj_ends
   LDA obj_a                               ; y1 (off 2) = syb - 2a
   ASL A                                   ; a <= 99: no carry out
   STA obj_pu
   SEC
   LDA obj_yb_l
   SBC obj_pu
   STA obj_Y+2
   LDA obj_yb_h
   SBC #0
   STA obj_Y+3
   CLC
   LDA obj_a                               ; y2 (off 4) = syb - (a + qa)
   ADC obj_pb
   STA obj_pu
   SEC
   LDA obj_yb_l
   SBC obj_pu
   STA obj_Y+4
   LDA obj_yb_h
   SBC #0
   STA obj_Y+5
   CLC
   LDA obj_a                               ; y3 (off 6) = syb - (a + a3a)
   ADC obj_pb+2
   STA obj_pu
   SEC
   LDA obj_yb_l
   SBC obj_pu
   STA obj_Y+6
   LDA obj_yb_h
   SBC #0
   STA obj_Y+7
   SEC
   LDA obj_a                               ; y4 (off 8) = syb - (a - a3a)
   SBC obj_pb+2
   STA obj_pu
   SEC
   LDA obj_yb_l
   SBC obj_pu
   STA obj_Y+8
   LDA obj_yb_h
   SBC #0
   STA obj_Y+9
   SEC
   LDA obj_a                               ; y5 (off 10) = syb - (a - qa)
   SBC obj_pb
   STA obj_pu
   SEC
   LDA obj_yb_l
   SBC obj_pu
   STA obj_Y+10
   LDA obj_yb_h
   SBC #0
   STA obj_Y+11
   RTS

; ---- the helmet: the 2D outline's 10-x / 5-y ladder (bank C, with
; the lamp/potion/vest builders: the 2026-08-31 trig restore needed
; the CODE bytes back) ----------------------------------------------------
obj_helmet_xy:
   LDA obj_a
   STA zp_mul_b
   LDX #3
ohx_m:
   STX obj_px                              ; umul8 eats X
   LDA obj_hgx,X
   JSR umul8
   LDX obj_px
   LDA zp_prod_l
   CMP #128
   LDA zp_prod_h
   ADC #0
   STA obj_pb,X
   DEX
   BPL ohx_m
   LDX #3
ohx_s:
   LDY obj_hnx,X
   SEC
   LDA obj_cx_l
   SBC obj_pb,X
   STA obj_X+0,Y
   LDA obj_cx_h
   SBC #0
   STA obj_X+1,Y
   LDY obj_hpx,X
   CLC
   LDA obj_cx_l
   ADC obj_pb,X
   STA obj_X+0,Y
   LDA obj_cx_h
   ADC #0
   STA obj_X+1,Y
   DEX
   BPL ohx_s
   LDA obj_h                               ; y1..y3 = syt + H*{34,85,222}/256
   STA zp_mul_b
   LDX #2
ohy_m:
   STX obj_px
   LDA obj_hgy,X
   JSR umul8
   LDX obj_px
   LDA zp_prod_l
   CMP #128
   LDA zp_prod_h
   ADC #0
   STA obj_pu
   TXA
   ASL A
   TAY
   CLC
   LDA obj_yt_l
   ADC obj_pu
   STA obj_Y+2,Y
   LDA obj_yt_h
   ADC #0
   STA obj_Y+3,Y
   DEX
   BPL ohy_m
   LDY #8
   JMP obj_ends                            ; syt -> y0, syb -> y4 (off 8)
SEG_BANKC
obj_hgy:   .byte 34, 85, 222              ; y /256 of H: dome z13, side top
                                          ; z10, notch roof z2
SEG_CODE

; ---- the vest: 6-x / 6-y (bank C: the near tiers filled CODE) ----------
SEG_BANKC
obj_vest_xy:
   LDA obj_a
   STA zp_mul_b
   LDA #8                                  ; waist = 5.5/15.5 -> obj_X 1/4
   STA obj_px
   LDY #2
   LDA #91
   JSR obj_mirror
   LDA #6                                  ; scoop = 3/15.5 -> obj_X 2/3
   STA obj_px
   LDY #4
   LDA #50
   JSR obj_mirror
   LDA obj_h                               ; y1..y4 = syt + H*{20,89,75,52}
   STA zp_mul_b
   LDX #3
ovy_m:
   STX obj_px
   LDA obj_vgy,X
   JSR umul8
   LDX obj_px
   LDA zp_prod_l
   CMP #128
   LDA zp_prod_h
   ADC #0
   STA obj_pu
   TXA
   ASL A
   TAY
   CLC
   LDA obj_yt_l
   ADC obj_pu
   STA obj_Y+2,Y
   LDA obj_yt_h
   ADC #0
   STA obj_Y+3,Y
   DEX
   BPL ovy_m
   LDY #10                                 ; syt -> y0 (rear shoulders),
   JMP obj_ends                            ; syb -> y5 (the ground line)
SEG_CODE
.endif
