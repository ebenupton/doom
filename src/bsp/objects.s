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
obj_i:    .res 1
obj_vx_l: .res 1
obj_vx_h: .res 1
obj_xl_l: .res 1
obj_xl_h: .res 1
obj_xr_l: .res 1
obj_xr_h: .res 1
obj_yt_l: .res 1
obj_yt_h: .res 1
obj_yb_l: .res 1
obj_yb_h: .res 1

OBJ_MAXSLOT = 4                            ; most objects in one subsector
                                        ; is 3 (wad_packed asserts it)
obj_n:     .res 1                          ; slots filled this subsector
obj_left:  .res 1                          ; slots still to draw
obj_k:     .res 1                          ; edge-table cursor across the JSR
obj_best:  .res 1
obj_sd_l:  .res OBJ_MAXSLOT                ; depth (vy counts) -- sort key
obj_sd_h:  .res OBJ_MAXSLOT
obj_sxl_l: .res OBJ_MAXSLOT
obj_sxl_h: .res OBJ_MAXSLOT
obj_sxr_l: .res OBJ_MAXSLOT
obj_sxr_h: .res OBJ_MAXSLOT
obj_syt_l: .res OBJ_MAXSLOT
obj_syt_h: .res OBJ_MAXSLOT
obj_syb_l: .res OBJ_MAXSLOT
obj_syb_h: .res OBJ_MAXSLOT

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
   RTS                                     ; feature off (layout.inc)
.endif
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

obj_ss:   .res 1
obj_mask: .res 1

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
; --- screen x of the two edges.  project_x is LINEAR in vx, so the
;     billboard's edges are just vx -/+ r; no second rotation.
   LDA zp_br_vx_l
   STA obj_vx_l
   LDA zp_br_vx_h
   STA obj_vx_h
   LDX obj_i
   SEC
   LDA obj_vx_l
   SBC OBJ_RC,X
   STA zp_br_vx_l
   LDA obj_vx_h
   SBC #0
   STA zp_br_vx_h
   JSR project_x_c
   LDA zp_br_res_l
   CLC
   ADC #128                                ; sx = 128 + rns(b123)
   STA obj_xl_l
   LDA zp_br_res_h
   ADC #0
   STA obj_xl_h
   LDX obj_i
   CLC
   LDA obj_vx_l
   ADC OBJ_RC,X
   STA zp_br_vx_l
   LDA obj_vx_h
   ADC #0
   STA zp_br_vx_h
   JSR project_x_c
   LDA zp_br_res_l
   CLC
   ADC #128
   STA obj_xr_l
   LDA zp_br_res_h
   ADC #0
   STA obj_xr_h
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
   LDA obj_xl_l
   STA obj_sxl_l,Y
   LDA obj_xl_h
   STA obj_sxl_h,Y
   LDA obj_xr_l
   STA obj_sxr_l,Y
   LDA obj_xr_h
   STA obj_sxr_h,Y
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
obj_draw_slot:
   LDA obj_sxl_l,X
   STA obj_xl_l
   LDA obj_sxl_h,X
   STA obj_xl_h
   LDA obj_sxr_l,X
   STA obj_xr_l
   LDA obj_sxr_h,X
   STA obj_xr_h
   LDA obj_syt_l,X
   STA obj_yt_l
   LDA obj_syt_h,X
   STA obj_yt_h
   LDA obj_syb_l,X
   STA obj_yb_l
   LDA obj_syb_h,X
   STA obj_yb_h
   PAGE BANK_C
; hg_pass zeroes the record counts per seg; we run in the PROLOGUE,
; ahead of the seg loop, so zero them ourselves.  TOP stays empty: a
; billboard closes the aperture from below only.
   ZERO TOP_RECORDS
   ZERO BOT_RECORDS
   LDA #1
   STA zp_dcl_rec_off
   LDA #>BOT_RECORDS
   STA zp_dcl_rec_buf_h                    ; armed for the TOP edge only
   LDX #0
obj_ea:
   LDY obj_edges,X
   LDA obj_xl_l,Y
   STA zp_line_xl_l
   LDA obj_xl_h,Y
   STA zp_line_xl_h
   LDY obj_edges+1,X
   LDA obj_xl_l,Y
   STA zp_line_yl_l
   LDA obj_xl_h,Y
   STA zp_line_yl_h
   LDY obj_edges+2,X
   LDA obj_xl_l,Y
   STA zp_line_xr_l
   LDA obj_xl_h,Y
   STA zp_line_xr_h
   LDY obj_edges+3,X
   LDA obj_xl_l,Y
   STA zp_line_yr_l
   LDA obj_xl_h,Y
   STA zp_line_yr_h
   STX obj_k
   JSR draw_clipped_line_s16
   ZERO zp_dcl_rec_buf_h                   ; only the first edge records
   LDA obj_k
   CLC
   ADC #4
   TAX
   CPX #16
   BNE obj_ea
; --- close the columns, if the top edge survived the clip.  Zero
;     records means it was clipped away entirely; tighten_from_records
;     must not be called then (its own contract says so).
   LDA BOT_RECORDS
   BEQ obj_ds_done
   LDX #0                                  ; ilo = clamp(xl, 0..255)
   LDA obj_xl_h
   BMI obj_ds_lo
   BEQ obj_ds_lol
   LDX #255
   BNE obj_ds_lo
obj_ds_lol:
   LDX obj_xl_l
obj_ds_lo:
   STX zp_i_l
   LDX #255                                ; ihi = clamp(xr)+1, HALF-OPEN
   LDA obj_xr_h
   BMI obj_ds_hz
   BNE obj_ds_hi
   LDX obj_xr_l
   INX
   BNE obj_ds_hi
obj_ds_hz:
   LDX #0
obj_ds_hi:
   STX zp_i_h
   CPX zp_i_l
   BCC obj_ds_done                         ; empty or inverted range
   BEQ obj_ds_done
   JSR tighten_from_records
obj_ds_done:
   RTS
