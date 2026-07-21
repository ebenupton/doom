SEG_CODE
bsp_lo_start:

; ============================================================================
; reproject_at_crossing — call cross_compute, then project sx at the
; NEAR reciprocal, writing straight into the clipped endpoint's STRUCT
; slots (VX1/VX2, zp.inc — stride 15; zp_seg_ep = 0 for v1, 15 for v2,
; set by the caller). Y projection is NOT done here: it is deferred to
; the post-has_gap y stage like every other endpoint (2026-07-11); this
; routine banks recip(NEAR) into the struct's +13/+14 so that stage and
; apv_stage read the right reciprocal.
;
; Called by the seg loop (subsector.s) when EXACTLY ONE endpoint of a
; front-facing seg is behind the near plane: that endpoint is replaced by
; the seg's crossing point with vy = NEAR, mirroring Python's fp_near_clip
; branch in packed_render_seg (idxK = eyK << 1 = 2 → recip at NEAR;
; fvxK_c = 0 for clipped endpoints).
;
;   Inputs:  VX1+0/+1 and VX2+0/+1 (both endpoints' s8 evy/evx — always
;              populated by br_seg_xform_vertex, even when clipped),
;            zp_seg_ep = the CLIPPED endpoint's struct offset (0 | 15).
;   Outputs: struct +3/+4 = sx of the crossing point (s16),
;            struct +13/+14 and zp_br_r_m8/rlo = recip(NEAR) = (M8=0, S=1);
;            chain key killed by the caller (VX2 no longer holds a vertex).
;
;   Pseudocode:
;     cx = cross_compute()             # view-x where the seg meets vy=NEAR
;     sx = project_x(cx, frac=0)       # narrow/wide auto-dispatch
;     do_project_y()                   # 4 heights at the NEAR reciprocal
; ============================================================================
reproject_at_crossing:
.scope
   cross_compute
; Project cx with frac=0 (Python passes fvx_c=0 for clipped endpoints).
; cx is s16; br_project_x dispatches narrow/wide on its hi byte.
   LDA zp_clip_cx
   STA zp_br_vx_h
   LDA zp_clip_cx_hi
   STA zp_br_vx_x
   LDA #0
   STA zp_br_vx_l
   JSR br_project_x                        ; -> Y = sx lo, A = sx hi
   LDX zp_seg_ep                           ; struct offset (0/15)
   STA VX1+4,X                             ; sx → the clipped endpoint's
   TYA                                     ; struct slots, in place
   STA VX1+3,X
   LDA zp_br_r_m8                           ; bank recip(NEAR) = (M8=0, S=1)
   STA VX1+13,X                            ; into the struct: the deferred
   LDA zp_br_r_s                           ; y stage (and apv_stage) project
   STA VX1+14,X                            ; the crossing with THIS recip
   RTS
.endscope

; ============================================================================
; cross_compute — near-plane crossing point for a seg with one clipped vertex.
;   Inputs:  zp_clip_C_evy, zp_clip_C_evx (clipped, evy ≤ 0)
;            zp_clip_U_evy, zp_clip_U_evx (unclipped, evy ≥ 1)
;   Outputs: zp_clip_cx (s8 crossing view-x), zp_br_r_m8/rlo = (M8, S) at NEAR
;
;   Mirrors fp_near_clip exactly:
;     t   = ((NEAR - vy_C) << 8) / (vy_U - vy_C)    (u8 truncated)
;     dvx = vx_U - vx_C                              (s9: -255..255)
;     cx  = vx_C + (t * dvx) >> 8                    (s8 wraparound)
;
; CURRENT interface (the C/U slot names above are historical): the seg
; loop copies both endpoints into zp_seg_v{1,2}_{evy,evx}; this routine
; always parametrises from v1 — t = ((1 - v1_evy) << 8) / (v2_evy -
; v1_evy), cx = v1_evx + (t * (v2_evx - v1_evx)) >> 8 — exactly as
; fp_near_clip does regardless of WHICH endpoint is the clipped one.
; Output is now s16: zp_clip_cx (lo) : zp_clip_cx_hi (hi); the tail JMPs
; to br_recip with vy_idx = 2 (9.1 for vy = NEAR), so (M8, S) = (0, 1).
; Clobbers zp_div_l/hi/den, zp_br_a, zp_br_dx_l/dxhi, zp_br_t2/t3,
; zp_br_sign, plus SC_UDIV16_8 / SC_UMUL8 scratch.
; ============================================================================
; (cross_compute is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)

; ============================================================================
; cross_umul_u8_s16 — t (u8 in zp_br_a) × dx (s16 in zp_br_dx_l:dxhi) → s16
; in zp_br_res_l:resh. Caller takes resh as the (>>8) result.
;
; Sign-magnitude: |dx| via 16-bit negate (sign in zp_br_sign), then
;   res = t*|dx|.lo  +  (t*|dx|.hi << 8)      (two u8×u8 muls; only the
;                                              low byte of the second
;                                              product fits — dx is s9
;                                              here so it never carries)
; and negate the s16 result if dx was negative. Clobbers zp_br_dx_l/dxhi
; (replaced by |dx|), zp_br_sign, zp_mul_b, zp_prod_l/hi.
; ============================================================================
; (cross_umul_u8_s16 is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)

; (br_node_setup moved to walk.s as the NODE_SETUP_DISPATCH macro,
; 2026-07-16 — single caller, inlined; exits JMP straight to the side
; bodies, no A/RTS round trip.)


; (br_project_x_wide moved to project.s 2026-07-12; rns32 — its
; round-to-nearest shifter — stays below.)


; (rns32 followed br_project_x_wide to project.s 2026-07-12 — its only
; caller; the projection family is complete in one file.)

; (ev_clamp_evy16 moved to the B region.)



; (flat LO ceiling retired 2026-07-12: LO floats in the one CODE region
; in BOTH builds now.)


; ============================================================================
; ap_edges — NOVT aperture-edge verticals (SF_APEDGE1=$40 / SF_APEDGE2=$01).
; Mirrors the Python reference:
;   SOLID seg, APEDGE_K: draw (sxK, apvK_ch', sxK, apvK_fh') where the
;     apv heights are the colinear portal's aperture, projected with
;     endpoint K's reciprocal by apv_stage (post-has_gap, this file).
;     The packer bakes them into the 16-byte header: K=1 overlays the
;     bfh/bch slots (+12/+13), K=2 owns +14/+15; apv_stage writes the
;     projections into the endpoint structs' btop/bbot sy pairs.
;   PORTAL seg (has steps), APEDGE_K: draw (sxK, bt|ft, sxK, bb|fb) — all
;     four projections already in the endpoint struct's sy slots (the
;     y stage filled them; SEG_PROJ_BUF is long retired).
; Off-screen endpoints (sx hi != 0) are skipped like the other verticals:
; Python computes then AP-skips or DCL-clips them; pixel output matches.
; X = endpoint STRUCT offset (0 = v1, 15 = v2) for ap_edge_one.
; ============================================================================
; (ap_edges is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)

; ap_edge_one — emit ONE aperture-edge vertical at endpoint K.
;   X = vertex struct offset (0 = v1, VX_STRIDE = v2); everything (sx,
;   sy pairs) reads from the packed ZP struct VX1+ofs,X.
;   Dispatch: portal → y-range from the struct sy slots selected by
;   NEEDBT/NEEDBB; solid v1 → APV1 projections already sit in the
;   btop/bbot slots (do_project_y projected the overlaid APV heights);
;   solid (either endpoint) → APV projections staged by apv_stage.
;   Line emitted through SC_DRAW_S16 (bank C) at x = sxK.
ap_edge_one:
.scope
   LDA VX1+4,X                             ; sx_hi
   BNE ap_rts
; sx off-screen → skip
   LDA zp_seg_flags
   AND #$02
   BNE ap_solid
; portal: top edge = bt if NEEDBT else ft; bot = bb if NEEDBB else fb
   LDA zp_seg_flags
   AND #$04
   BEQ ap_top_ft
   LDA VX1+9,X                             ; sy_btop
   STA zp_line_yl_l
   LDA VX1+10,X
   STA zp_line_yl_h
   JMP ap_bot
ap_top_ft:
   LDA VX1+5,X                             ; sy_top
   STA zp_line_yl_l
   LDA VX1+6,X
   STA zp_line_yl_h
ap_bot:
   LDA zp_seg_flags
   AND #$08
   BEQ ap_bot_fb
   LDA VX1+11,X                            ; sy_bbot
   STA zp_line_yr_l
   LDA VX1+12,X
   STA zp_line_yr_h
   JMP ap_emit_y
ap_bot_fb:
   LDA VX1+7,X                             ; sy_bot
   STA zp_line_yr_l
   LDA VX1+8,X
   STA zp_line_yr_h
   JMP ap_emit_y
ap_solid:
; APV projections sit in the struct for BOTH endpoints now (apv_stage
; runs post-visibility, pre-swap — the ap2_solid_proj special case is
; dead): line from CH proj (+11/12) to FH proj (+9/10).
   LDA VX1+11,X
   STA zp_line_yl_l
   LDA VX1+12,X
   STA zp_line_yl_h
   LDA VX1+9,X
   STA zp_line_yr_l
   LDA VX1+10,X
   STA zp_line_yr_h
ap_emit_y:
; vertical at the endpoint's sx (struct slots)
   LDA VX1+3,X
   STA zp_line_xl_l
   STA zp_line_xr_l
   LDA VX1+4,X
   STA zp_line_xl_h
   STA zp_line_xr_h
   LDA #0
   STA zp_dcl_rec_buf_h
; (no PAGE: ap_edges expands in the verticals section of the seg loop,
;  strictly after hgp_fwd's emit-cascade PAGE C; every in-ladder L0
;  excursion re-pages C — bank C is the ladder invariant here. dfscan
;  11/11 same-bank; caller audit 2026-07-21.)
   JMP SC_DRAW_S16
ap_rts:
   RTS
.endscope

; (ap2_solid_proj DELETED 2026-07-11: apv_stage projects BOTH endpoints'
; aperture pairs into the structs post-visibility — one uniform solid
; path in ap_edge_one, no emit-time special case.)

; ============================================================================
; apv_stage — post-visibility APV aperture projections (2026-07-11).
; Called once per VISIBLE solid seg carrying APEDGE1/2, from the seg
; loop right after has_gap passes and BEFORE any canonicalizing endpoint
; swap — seg-endpoint identity still equals struct identity here, so the
; header offsets are unambiguous (+12/13 = APV1 ch/fh, +14/15 = APV2).
; Projects with the endpoint's OWN recip (VXk+13/14 — for a near-clipped
; endpoint that is the crossing recip the reprojection banked), filling
; VXk+9/10 (FH projection) and +11/12 (CH projection): the same slots
; and orientation the old dpy(APEDGE1)/ap2_solid_proj paths produced.
; Replaces TRANSFORM-TIME speculation: has_gap-culled segs pay nothing.
; Arrives under BANK_C; pages L0 for the header reads; br_project_y
; pages L2 itself; the emits re-page C per draw as always.
; ============================================================================
; (apv_stage is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)




; ============================================================================
; chain_reuse_v1 — the seg loop's vertex-chain hit path (2026-07-10).
; This seg's v1 == the previous transform's v2 (same subsector): copy
; VX2 -> VX1 wholesale — evy/evx/clip always; sx + front sy pair (same
; subsector => same fh/ch) + rhi/rlo when unclipped — then project just
; the flag-gated back pair with the vertex's recip restored. ep = 0 set
; by the caller. Replaces the whole VCACHE hit path + 2 VWHC lookups.
; ============================================================================
; (chain_reuse_v1 is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)

bsp_lo_end:
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_lo_bk.bin", $1B40, bsp_lo_end, $1B40)
.else
; (ld65 writes this: SAVE "bsp_render_lo.bin", $1B40, bsp_lo_end, $1B40)
.endif
