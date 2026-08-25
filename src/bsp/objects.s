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
; BANK CONTRACT: pages BANK_SEG itself (table, recips and the VWHC memo
; all live there), then BANK_C for the clipper.  Exits under BANK_C,
; exactly as an emit arc does.
; ============================================================================

; scratch — main RAM in BOTH builds (the CODE region), so it is writable
; on hardware under any paging (see the scalar-state rule)

; --- scratch: $1100-$11FF, FREE IN BOTH BUILDS since 2026-08-17 (it
;     held the driver's retired cadence probe -- see dcl.s:1527).  It
;     lives here rather than as .res in CODE because CODE is full,
;     and it must be real RAM in both builds (the scalar-state rule).
obj_i     = $1100
obj_cx_l  = $1101
obj_cx_h  = $1102
obj_yt_l  = $1103
obj_yt_h  = $1104
obj_yb_l  = $1105
obj_yb_h  = $1106
obj_h     = $1107
obj_t     = $1108
; The two ratio TRIPLES, same stride so one loop fills both and obj_hex
; walks either with X = 0 or X = 3.  v2 = (sqrt3-1)v ~ 47v/64, v3 = v - v2,
; which is EXACT: the dodecagon's two ratios sum to 1.
obj_a     = $1109
obj_a2    = $110A
obj_a3    = $110B
obj_b     = $110C
obj_b2    = $110D
obj_b3    = $110E
obj_dy    = $110F
obj_e     = $1110
obj_ctr_l = $1111   ; obj_hex centre
obj_ctr_h = $1112
obj_hcnt  = $1113
; obj_Y MUST sit exactly 12 bytes after obj_X: obj_hex addresses both as
; obj_X,Y with Y = 0 (the x table) or 12 (the lid), so one store serves both.
obj_X     = $1114   ; 6 x s16  -> $1114-$111F
obj_Y     = $1120   ; 12 x s16 -> $1120-$1137
obj_n     = $1138
obj_left  = $1139
obj_k     = $113A
obj_best  = $113B
obj_ss    = $113C
obj_mask  = $113D
obj_asp   = $113E   ; live object's aspect byte (bit 7 = art, 0-6 = k)
obj_sd_l  = $113F   ; [OBJ_MAXSLOT]
obj_sd_h  = $1142
obj_scx_l = $1145
obj_scx_h = $1148
obj_syt_l = $114B
obj_syt_h = $114E
obj_syb_l = $1151
obj_syb_h = $1154
obj_sasp  = $1157
obj_fused = $1158                        ; FUSED authority-run flag   ; [OBJ_MAXSLOT] -> $1157-$1159

.assert obj_Y = obj_X + 12, error, "obj_hex addresses the lid as obj_X+12"

OBJ_MAXSLOT = 3                            ; most objects in one subsector
                                        ; is 3 (wad_packed asserts it)

obj_bitmask:
   .byte $01,$02,$04,$08,$10,$20,$40,$80


; --- rectangle edges, table-driven ---------------------------------------
; The four edges use only four values (xl, xr, yt, yb), so each edge is
; four byte OFFSETS into the obj_xl_l block: x1, y1, x2, y2.  Four macro
; expansions of the staging cost ~200 bytes and overflowed the banked
; CODE area; this is ~40 plus a 16-byte table.
;   block: obj_xl_l/h = +0, obj_xr_l/h = +2, obj_yt_l/h = +4, obj_yb_l/h = +6
obj_edges:
   .byte 0,4, 2,4                          ; top    (xl,yt)-(xr,yt)
   .byte 0,6, 2,6                          ; bottom
   .byte 0,4, 0,6                          ; left
   .byte 2,4, 2,6                          ; right


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
   PAGE BANK_SEG                           ; NB: PAGE is LDA #n/STA $FE30 --
   LDA obj_ss                              ; it EATS A.  Flat's PAGE is a
   AND #7                                  ; no-op, so a missing reload here
                                        ; works in flat and silently
                                        ; computes the mask from the bank
                                        ; number in banked.
   TAX
   LDA obj_bitmask,X
   STA obj_mask
   LDA obj_ss
   LSR A
   LSR A
   LSR A
   TAX
   LDA OBJ_BITS,X
   AND obj_mask
   BNE obj_have
   PAGE BANK_WALK                          ; prologue contract: WALK in/out
   RTS                                     ; the common case: one bit test
obj_have:
; PASS 1 -- project every object of this subsector into a slot.  The
; table is sorted by subsector, but a linear sweep of 18 entries is
; cheaper than any search and only runs for a subsector that HAS
; objects.
   LDA #0
   STA obj_n
   LDX #LAY_N_OBJ-1
obj_scan:
   LDA OBJ_SS,X
   CMP obj_ss
   BNE obj_next
   JSR obj_project
   LDX obj_i                               ; obj_project clobbers X
obj_next:
   DEX
   BPL obj_scan
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
   ADC vxc_ref_x+0
   STA zp_br_vx_l
   LDA zp_br_vx_h
   ADC vxc_ref_x+1
   STA zp_br_vx_h
   CLC
   LDA zp_br_vy_l
   ADC vxc_ref_y+0
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ADC vxc_ref_y+1
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
   LDA obj_asp
   AND #$7F
   JSR umul8
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
   LDA obj_h                               ; b = H/16
   LSR A
   LSR A
   LSR A
   LSR A
   STA obj_b
   LDA obj_h                               ; dy = 7H/8
   LSR A
   LSR A
   LSR A
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
   JSR fused_begin                         ; per-object zero-touch state
   ZERO obj_fused                          ; leading run: plain draws
; Start at this object's template.  Bit 7 of the aspect byte IS the
; selector: barrels get the octagonal prism, everything else the plain
; outline rectangle it had before the prism existed -- a floor lamp drawn
; as a squat eight-sided drum reads as a barrel, not a lamp.
   LDA #OBJ_ART_OCT
   BIT obj_asp
   BPL obj_art_set
   LDA #OBJ_ART_RECT
obj_art_set:
   STA obj_e
obj_stamp:
   PAGE BANK_SEG                           ; the art template lives with the
   LDX obj_e                               ; object data (CODE is full)
   LDY OBJ_ART+0,X
   CPY #OBJ_ART_ARM                        ; control entry? ($FE/$FF)
   BCS obj_ctl
   LDA obj_X+0,Y
   STA zp_line_xl_l
   LDA obj_X+1,Y
   STA zp_line_xl_h
   LDY OBJ_ART+1,X
   LDA obj_Y+0,Y
   STA zp_line_yl_l
   LDA obj_Y+1,Y
   STA zp_line_yl_h
   LDY OBJ_ART+2,X
   LDA obj_X+0,Y
   STA zp_line_xr_l
   LDA obj_X+1,Y
   STA zp_line_xr_h
   LDY OBJ_ART+3,X
   LDA obj_Y+0,Y
   STA zp_line_yr_l
   LDA obj_Y+1,Y
   STA zp_line_yr_h
   PAGE BANK_C
   LDA obj_fused
   BEQ obj_plain
   JSR fused_below_raw                     ; authority line: clip + plot +
   JMP obj_st_next                         ; apply in one walk
obj_plain:
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
   PAGE BANK_C
   CPY #OBJ_ART_END
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
.endif
