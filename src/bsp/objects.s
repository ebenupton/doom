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

obj_bitmask:
   .byte $01,$02,$04,$08,$10,$20,$40,$80

; --- stage one rectangle edge and clip it ---
.macro OBJ_EDGE x1l, x1h, y1l, y1h, x2l, x2h, y2l, y2h
   LDA x1l
   STA zp_line_xl_l
   LDA x1h
   STA zp_line_xl_h
   LDA y1l
   STA zp_line_yl_l
   LDA y1h
   STA zp_line_yl_h
   LDA x2l
   STA zp_line_xr_l
   LDA x2h
   STA zp_line_xr_h
   LDA y2l
   STA zp_line_yr_l
   LDA y2h
   STA zp_line_yr_h
   JSR draw_clipped_line_s16
.endmacro

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
   RTS                                     ; the common case: one bit test
obj_have:
; the table is sorted by subsector, but a linear sweep of 18 entries is
; cheaper than any search and only runs for a subsector that HAS objects
   LDX #LAY_N_OBJ-1
obj_scan:
   LDA OBJ_SS,X
   CMP obj_ss
   BNE obj_next
   JSR obj_one
   LDX obj_i                               ; obj_one clobbers X
obj_next:
   DEX
   BPL obj_scan
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
obj_one:
   STX obj_i
; --- stage the position exactly as the vertex pipeline stages a vertex ---
   LDA OBJ_OX,X
   STA zp_ri_d_l
   LDA OBJ_OY,X
   STA zp_br_dy_l
   LDA OBJ_PG,X
   STA zp_ri_d_h
   JSR rot_w_pages
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
; --- four clipped edges, records OFF (a billboard must never write a
;     tighten record: it is not a wall and closes no aperture) ---
   ZERO zp_dcl_rec_buf_h
   PAGE BANK_C
   OBJ_EDGE obj_xl_l, obj_xl_h, obj_yt_l, obj_yt_h, obj_xr_l, obj_xr_h, obj_yt_l, obj_yt_h
   OBJ_EDGE obj_xl_l, obj_xl_h, obj_yb_l, obj_yb_h, obj_xr_l, obj_xr_h, obj_yb_l, obj_yb_h
   OBJ_EDGE obj_xl_l, obj_xl_h, obj_yt_l, obj_yt_h, obj_xl_l, obj_xl_h, obj_yb_l, obj_yb_h
   OBJ_EDGE obj_xr_l, obj_xr_h, obj_yt_l, obj_yt_h, obj_xr_l, obj_xr_h, obj_yb_l, obj_yb_h
   PAGE BANK_SEG                           ; the scan's next OBJ_SS read
   RTS
