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
obj_a     = $1109
obj_a7    = $110A
obj_b     = $110B
obj_b7    = $110C
obj_dy    = $110D
obj_e     = $110E
obj_X     = $110F   ; 10 bytes
obj_sd_l  = $1133   ; [OBJ_MAXSLOT]
obj_sd_h  = $1136   ; [OBJ_MAXSLOT]
obj_scx_l = $1139   ; [OBJ_MAXSLOT]
obj_scx_h = $113C   ; [OBJ_MAXSLOT]
obj_syt_l = $113F   ; [OBJ_MAXSLOT]
obj_syt_h = $1142   ; [OBJ_MAXSLOT]
obj_syb_l = $1145   ; [OBJ_MAXSLOT]
obj_syb_h = $1148   ; [OBJ_MAXSLOT]
obj_Y     = $1119   ; 20 bytes
obj_n     = $112D
obj_left  = $112E
obj_k     = $112F
obj_best  = $1130
obj_ss    = $1131
obj_mask  = $1132

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
   LDY obj_n
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
   LDA obj_h                               ; (no minimum-height cull: below a
   LSR A                                   ; a = 23H/64   few px every offset
                                        ; rounds to zero, the whole stamp
                                        ; collapses to one point and the
                                        ; clipper rejects each zero-length
                                        ; line -- and CODE has no room for
                                        ; the test)
   LSR A
   STA obj_t
   STA obj_a
   LSR A
   LSR A
   CLC
   ADC obj_a
   STA obj_a
   LDA obj_t
   LSR A
   LSR A
   LSR A
   CLC
   ADC obj_a
   STA obj_a
   LDA obj_t
   LSR A
   LSR A
   LSR A
   LSR A
   CLC
   ADC obj_a
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
   LDX #0                                  ; a7,b7 = 45/64 of a,b
obj_s7:
   LDA obj_a,X
   LSR A
   STA obj_t
   STA obj_a7,X
   LSR A
   LSR A
   CLC
   ADC obj_a7,X
   STA obj_a7,X
   LDA obj_t
   LSR A
   LSR A
   LSR A
   CLC
   ADC obj_a7,X
   STA obj_a7,X
   LDA obj_t
   LSR A
   LSR A
   LSR A
   LSR A
   LSR A
   CLC
   ADC obj_a7,X
   STA obj_a7,X
   INX
   INX
   CPX #4
   BCC obj_s7
; --- X[] = cx + {-a, -a7, 0, +a7, +a} ------------------------------------
   LDA obj_cx_l
   STA obj_X+4
   LDA obj_cx_h
   STA obj_X+5
   CLC
   LDA obj_cx_l
   ADC obj_a
   STA obj_X+8
   LDA obj_cx_h
   ADC #0
   STA obj_X+9
   SEC
   LDA obj_cx_l
   SBC obj_a
   STA obj_X+0
   LDA obj_cx_h
   SBC #0
   STA obj_X+1
   CLC
   LDA obj_cx_l
   ADC obj_a7
   STA obj_X+6
   LDA obj_cx_h
   ADC #0
   STA obj_X+7
   SEC
   LDA obj_cx_l
   SBC obj_a7
   STA obj_X+2
   LDA obj_cx_h
   SBC #0
   STA obj_X+3
; --- Y[0..4] = lid, Y[5..9] = lid + dy -----------------------------------
   LDA obj_yt_l                            ; Y[0] = syt (the lid's top)
   STA obj_Y+0
   LDA obj_yt_h
   STA obj_Y+1
   CLC                                     ; Y[2] = syt + b
   LDA obj_yt_l
   ADC obj_b
   STA obj_Y+4
   LDA obj_yt_h
   ADC #0
   STA obj_Y+5
   CLC                                     ; Y[4] = Y[2] + b
   LDA obj_Y+4
   ADC obj_b
   STA obj_Y+8
   LDA obj_Y+5
   ADC #0
   STA obj_Y+9
   SEC                                     ; Y[1] = Y[2] - b7
   LDA obj_Y+4
   SBC obj_b7
   STA obj_Y+2
   LDA obj_Y+5
   SBC #0
   STA obj_Y+3
   CLC                                     ; Y[3] = Y[2] + b7
   LDA obj_Y+4
   ADC obj_b7
   STA obj_Y+6
   LDA obj_Y+5
   ADC #0
   STA obj_Y+7
   LDX #0
obj_ycp:
   CLC
   LDA obj_Y+0,X
   ADC obj_dy
   STA obj_Y+10,X
   LDA obj_Y+1,X
   ADC #0
   STA obj_Y+11,X
   INX
   INX
   CPX #10
   BCC obj_ycp
; --- stamp the 14 art lines ----------------------------------------------
   PAGE BANK_C
   ZERO TOP_RECORDS
   ZERO BOT_RECORDS
   LDA #1
   STA zp_dcl_rec_off
   LDA #>BOT_RECORDS
   STA zp_dcl_rec_buf_h                    ; armed for the lid's top arc
   LDA #0
   STA obj_e
obj_stamp:
   PAGE BANK_SEG                           ; the art template lives with the
   LDX obj_e                               ; object data (CODE is full)
   LDY OBJ_ART+0,X
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
   JSR draw_clipped_line_s16
   LDA obj_e
   CLC
   ADC #4
   STA obj_e
   CMP #16                                 ; lid top arc done -> stop
   BNE obj_st_on                           ; recording
   ZERO zp_dcl_rec_buf_h
obj_st_on:
   LDA obj_e
   CMP #4*LAY_N_OBJ_ART
   BCC obj_stamp
; --- close the columns behind it -----------------------------------------
   LDA BOT_RECORDS
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
   LDX #255                                ; ihi = clamp(X[4]) + 1
   LDA obj_X+9
   BMI obj_ds_hz
   BNE obj_ds_hi
   LDX obj_X+8
   INX
   BNE obj_ds_hi
obj_ds_hz:
   LDX #0
obj_ds_hi:
   STX zp_i_h
   CPX zp_i_l
   BCC obj_dsx
   BEQ obj_dsx
   JSR tighten_from_records
obj_dsx:
   RTS
.endif
