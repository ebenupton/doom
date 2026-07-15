.segment "LO"
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
   JSR cross_compute
; Project cx with frac=0 (Python passes fvx_c=0 for clipped endpoints).
; cx is s16; br_project_x dispatches narrow/wide on its hi byte.
   LDA zp_clip_cx
   STA zp_v_x_h
   LDA zp_clip_cx_hi
   STA zp_v_x_x
   LDA #0
   STA zp_v_x_l
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
cross_compute:
.scope
; Compute cx = v1_evx + (t * (v2_evx - v1_evx)) >> 8 where
;   t = ((NEAR - v1_evy) << 8) / (v2_evy - v1_evy)
; matching Python's fp_near_clip path. Both num and den always share
; sign in our cases (one vertex clipped, one not), so t is non-negative.
; Use unsigned division on magnitudes; sign of the t*dvx term comes
; from dvx alone.

; Special case: v2_evy = NEAR. Then |num| = |den|, t would be 256 and
; wrap to 0 in u8. Crossing point is v2 itself.
   LDA zp_seg_v2_evy
   CMP #1
   BNE c_normal
   LDA zp_seg_v2_evx
   STA zp_clip_cx
   ZERO zp_clip_cx_hi
   LDA zp_seg_v2_evx
   BPL c_sc_done
   LDA #$FF
   STA zp_clip_cx_hi
c_sc_done:
   JMP c_set_recip
c_normal:

; |num| = |1 - v1_evy| via signed abs of (1 - v1_evy).
   LDA #1
   SEC
   SBC zp_seg_v1_evy
   BPL c_num_ok
   EOR #$FF
   BUMP
c_num_ok:
   STA zp_div_h
   ZERO zp_div_l

; |den| = |v2_evy - v1_evy|
   LDA zp_seg_v2_evy
   SEC
   SBC zp_seg_v1_evy
   BPL c_den_ok
   EOR #$FF
   BUMP
c_den_ok:
   STA zp_div_den

   JSR SC_UDIV16_8                         ; A = t (u8)
   STA zp_br_a

; dvx = v2_evx - v1_evx as s16 (sign-extend then subtract).
   LDA zp_seg_v2_evx
   STA zp_br_dx_l
   ZERO zp_br_dx_h
   LDA zp_seg_v2_evx
   BPL c_v2_pos
   LDA #$FF
   STA zp_br_dx_h
c_v2_pos:
   LDA zp_seg_v1_evx
   BPL c_v1_pos
   LDA zp_br_dx_l
   SEC
   SBC zp_seg_v1_evx
   STA zp_br_dx_l
   LDA zp_br_dx_h
   SBC #$FF
   STA zp_br_dx_h
   JMP c_have_dvx
c_v1_pos:
   LDA zp_br_dx_l
   SEC
   SBC zp_seg_v1_evx
   STA zp_br_dx_l
   BCS c_dvx_nb                            ; BCS/DEC borrow bump (-2 bytes)
   DEC zp_br_dx_h
c_dvx_nb:
c_have_dvx:

   JSR cross_umul_u8_s16
; cx (s16) = sext(v1_evx) + sext(resh). With both endpoint evx in s8
; and t in [0,256], cx lies between them so s16 always holds it; cx
; itself can still fall outside s8 (sum of two s8) — the caller
; dispatches narrow/wide projection on the hi byte.
   ZERO zp_br_t2
   LDA zp_seg_v1_evx
   BPL c_cx_v1p
   LDA #$FF
   STA zp_br_t2
c_cx_v1p:
   ZERO zp_br_t3
   LDA zp_br_res_h
   BPL c_cx_rp
   LDA #$FF
   STA zp_br_t3
c_cx_rp:
   LDA zp_seg_v1_evx
   CLC
   ADC zp_br_res_h
   STA zp_clip_cx
   LDA zp_br_t2
   ADC zp_br_t3
   STA zp_clip_cx_hi

c_set_recip:
   LDA #2
   STA zp_br_t0
   LDA #0
   STA zp_br_t1
   JMP br_recip
.endscope

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
cross_umul_u8_s16:
.scope
; dx = v2_evx - v1_evx with both endpoints s8 => |dx| <= 255: dx_h is
; pure sign ($00/$FF) and |dx| fits the LO byte. The old second
; multiply (t x |dx|_hi) was t x 0 — a whole SC_UMUL8 of dead work
; (deleted 2026-07-14). |dx|_lo = -dx_l is exact: dx = -256 can't occur.
   ZERO zp_br_sign
   LDA zp_br_dx_h
   BPL c2_dxp
   LDA #0
   SEC
   SBC zp_br_dx_l
   STA zp_br_dx_l
   INC zp_br_sign
c2_dxp:
; t * |dx| (u8 × u8 → u16 → resl:resh)
   LDA zp_br_dx_l
   STA zp_mul_b
   LDA zp_br_a
   JSR SC_UMUL8
   STA zp_br_res_h                          ; A = prod_hi (umul8 contract)
   LDA zp_prod_l
   STA zp_br_res_l
; sign-flip if dx was negative
   LDA zp_br_sign
   BEQ c2_pos
   LDA #0
   SEC
   SBC zp_br_res_l
   STA zp_br_res_l
   LDA #0
   SBC zp_br_res_h
   STA zp_br_res_h
c2_pos:
   RTS
.endscope

; ============================================================================
; br_node_setup — read node from ROM, compute the player's side. Once
; per internal node visit; the walk follows children (id + leaf flag)
; straight from the SoA pages, so side is the whole contract.
;
;   Inputs:  zp_node_ch_l = node id (u8 — n_nodes <= 256, pack-time assert)
;            zp_br_pxraw_l/hi, zp_br_pyraw_l/hi = player position, RAW
;              map units relative to map_center (s16, NOT prescaled — the
;              side test must not lose a weak axis to /8 truncation).
;   Outputs: zp_side = 0 (right of partition) / 1 (left/on).
;   Scratch: zp_seg_dxraw/dyraw (player - node origin), zp_node_dx/dy,
;            $0A50-$0A52 (s24 cross-product accumulator), zp_br_dx/dy*.
;
; Node data comes from the SoA pages built by wad_packed.build_packed:
; one 256-byte page per field byte (NODE_NXLO..NODE_DYHI, child ids
; NODE_CRLO/NODE_CLLO, and NODE_TYPE), indexed with constant-base
; LDA abs,X — no pointer arithmetic. The partition TYPE is baked at pack
; time (bits 0-1: NT_GENERAL=0, NT_DX0=1 vertical, NT_DY0=2 horizontal;
; bits 7/6 are the child leaf flags, masked off here) so the 73%
; of E1M1 nodes that are axis-aligned skip the classification AND load
; only the one delta they need.
;
; Python mirror (doom_wireframe.point_on_side, raw s16 values):
;   dx, dy = x - node.nx, y - node.ny
;   side = 0 if (node.dy*dx - node.dx*dy) > 0 else 1
;
; Pseudocode (D = dxraw*ndy - dyraw*ndx, side0 iff D > 0):
;   type NT_DY0 (ndy==0): D = -dyraw*ndx → side0 iff dyraw!=0 and
;                          sign(dyraw) != sign(ndx)         (no multiply)
;   type NT_DX0 (ndx==0): D =  dxraw*ndy → side0 iff dxraw!=0 and
;                          sign(dxraw) == sign(ndy)         (no multiply)
;   general: DOOM R_PointOnSide sign shortcuts (see block comment below);
;            only same-sign nonzero products fall through to the two
;            s16×s16→s32 multiplies and the full 24-bit compare.
; ============================================================================
br_node_setup:
.scope
   PAGE BANK_L0                            ; node SoA pages live in bank L0
; Node index is u8 (n_nodes <= 256, asserted at pack time); the partition
; type is baked (page NODE_TYPE), so axis-aligned nodes — 73% on E1M1 —
; skip the classification and load only the two fields they need.
   LDX zp_node_ch_l
   LDA NODE_TYPE,X
   AND #NT_MASK                            ; bits 7/6 are the child leaf flags
   BEQ ns_t_general
   CMP #1
   BEQ ns_t_dx0
; --- type 2: ndy==0 -> side from sign(dyraw) vs sign(ndx) ---
   LDA zp_br_pyraw_l
   SEC
   SBC NODE_NYLO,X
   STA zp_seg_dyraw_l
   LDA zp_br_pyraw_h
   SBC NODE_NYHI,X
   STA zp_seg_dyraw_h
   ORA zp_seg_dyraw_l
   BEQ ns_jmp_side1
   LDA NODE_DXHI,X
   EOR zp_seg_dyraw_h
   BPL ns_jmp_side1
   JMP ns_side0
ns_t_dx0:
; --- type 1: ndx==0 -> side from sign(dxraw) vs sign(ndy) ---
   LDA zp_br_pxraw_l
   SEC
   SBC NODE_NXLO,X
   STA zp_seg_dxraw_l
   LDA zp_br_pxraw_h
   SBC NODE_NXHI,X
   STA zp_seg_dxraw_h
   ORA zp_seg_dxraw_l
   BEQ ns_jmp_side1
   LDA NODE_DYHI,X
   EOR zp_seg_dxraw_h
   BMI ns_jmp_side1
   JMP ns_side0
ns_jmp_side1:
   JMP ns_side1
ns_t_general:
; --- general partition: both deltas + the dx/dy fields for the
;     sign-shortcut / multiply cascade below ---
   LDA NODE_DXLO,X
   STA zp_node_dx_l
   LDA NODE_DXHI,X
   STA zp_node_dx_h
   LDA NODE_DYLO,X
   STA zp_node_dy_l
   LDA NODE_DYHI,X
   STA zp_node_dy_h
   LDA zp_br_pxraw_l
   SEC
   SBC NODE_NXLO,X
   STA zp_seg_dxraw_l
   LDA zp_br_pxraw_h
   SBC NODE_NXHI,X
   STA zp_seg_dxraw_h
   LDA zp_br_pyraw_l
   SEC
   SBC NODE_NYLO,X
   STA zp_seg_dyraw_l
   LDA zp_br_pyraw_h
   SBC NODE_NYHI,X
   STA zp_seg_dyraw_h
ns_general:
; DOOM R_PointOnSide sign shortcut (EXACT — ndx and ndy are both nonzero
; on this path, so P1 = dxraw*ndy is zero iff dxraw==0, P2 = dyraw*ndx
; is zero iff dyraw==0, and sign(product) = XOR of the operand signs).
; side0 iff D = P1 - P2 > 0. Only same-sign nonzero products need the
; two s16*s16 multiplies below.
   LDA zp_seg_dxraw_l
   ORA zp_seg_dxraw_h
   BNE ns_dx_nz
; dxraw==0 -> P1=0 -> D=-P2 (dyraw==0 too -> D=0 -> side1)
   LDA zp_seg_dyraw_l
   ORA zp_seg_dyraw_h
   BEQ ns_sh_side1
   LDA zp_seg_dyraw_h
   EOR zp_node_dx_h
   BMI ns_sh_side0                         ; P2<0 -> D>0 -> side0
ns_sh_side1:
   JMP ns_side1
ns_sh_side0:
   JMP ns_side0
ns_dx_nz:
   LDA zp_seg_dyraw_l
   ORA zp_seg_dyraw_h
   BNE ns_dy_nz
; dyraw==0 -> D=P1 -> side by sign(dxraw)^sign(ndy)
   LDA zp_seg_dxraw_h
   EOR zp_node_dy_h
   BMI ns_sh_side1
   JMP ns_side0
ns_dy_nz:
; both products nonzero: opposite signs decide without multiplying
   LDA zp_seg_dxraw_h
   EOR zp_node_dy_h                        ; sign(P1)
   STA zp_br_t3
   EOR zp_seg_dyraw_h
   EOR zp_node_dx_h                        ; sign(P1) ^ sign(P2)
   BPL ns_mul                              ; same sign -> full compare
   LDA zp_br_t3
   BMI ns_sh_side1                         ; P1<0<P2 -> D<0 -> side1
   JMP ns_side0
ns_mul:
; --- Full evaluation: P1 = dxraw*ndy → $0A50-52 (low 3 bytes of the s32
; product), then P2 = dyraw*ndx subtracted in place; sign/zero test on
; the 24-bit difference: D<0 or D==0 → side1, else side0. ---
   LDA zp_seg_dxraw_l
   STA zp_br_dx_l
   LDA zp_seg_dxraw_h
   STA zp_br_dx_h
   LDA zp_node_dy_l
   STA zp_br_dy_l
   LDA zp_node_dy_h
   STA zp_br_dy_h
   JSR br_smul_s16_s16_s32
   LDA zp_br_t0
   STA $0A50
   LDA zp_br_t1
   STA $0A51
   LDA zp_br_t2
   STA $0A52
   LDA zp_seg_dyraw_l
   STA zp_br_dx_l
   LDA zp_seg_dyraw_h
   STA zp_br_dx_h
   LDA zp_node_dx_l
   STA zp_br_dy_l
   LDA zp_node_dx_h
   STA zp_br_dy_h
   JSR br_smul_s16_s16_s32
   LDA $0A50
   SEC
   SBC zp_br_t0
   STA $0A50
   LDA $0A51
   SBC zp_br_t1
   STA $0A51
   LDA $0A52
   SBC zp_br_t2                            ; N from the SBC; the byte is
   BMI ns_side1                            ; dead in memory (no reader
   ORA $0A51                               ; past this test)
   ORA $0A50
   BEQ ns_side1
; (2026-07-15: the BSP_NEAR/FAR staging is gone — the walk follows
; children straight from the SoA pages at dispatch time, near and far
; alike, so setup's whole output is zp_side.)
ns_side0:
   LDA #0
   STA zp_side
   RTS
ns_side1:
   LDA #1
   STA zp_side
   RTS
.endscope

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
ap_edges:
.scope
   BIT zp_seg_flags                        ; V = bit 6 = APEDGE1
   BVC ap_chk2
   LDX #0                                  ; v1 struct
   JSR ap_edge_one
ap_chk2:
   LDA zp_seg_flags
   LSR A                                   ; C = bit 0 = SF_APEDGE2
   BCC ap_done
   LDX #VX_STRIDE                          ; v2 struct
   JMP ap_edge_one                         ; tail call
ap_done:
   RTS
.endscope

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
   PAGE BANK_C
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
apv_stage:
.scope
   BIT zp_seg_flags                        ; V = bit 6 = APEDGE1
   BVC as_chk2
   LDX #0
   LDY #13                                 ; header +13 = apv1_fh (+12 ch)
   JSR as_one
as_chk2:
   LDA zp_seg_flags
   LSR A                                   ; C = bit 0 = APEDGE2
   BCC as_done
   LDX #VX_STRIDE
   LDY #15                                 ; header +15 = apv2_fh (+14 ch)
   JMP as_one                              ; tail call
as_done:
   RTS
; as_one: X = struct offset, Y = header offset of the FH byte (CH = Y-1)
as_one:
   LDA VX1+4,X                             ; sx_hi: off-screen endpoint →
   BEQ as_on                               ; ap_edge_one skips its vertical,
   RTS                                     ; so DON'T project the pair
                                        ; (spectrack 2026-07-12: every
                                        ; wasted apv_stage call was this)
as_on:
   STX as_x
   LDA VX1+13,X                            ; endpoint recip
   STA zp_br_r_m8
   LDA VX1+14,X
   STA zp_br_r_s
   JSR rns_select                          ; (LDX/LDA/STA: Y survives)
   PAGE BANK_L0
   DEY
   LDA (zp_seg_hdr_p),Y                    ; APV ch FIRST (staged for the
   SEC                                     ; second projection)
   SBC zp_br_vz
   STA zp_ap2_dlt
   INY
   LDA (zp_seg_hdr_p),Y                    ; APV fh
   SEC
   SBC zp_br_vz
   TAX                                     ; fh delta RIDES X across the
   PAGE BANK_L2                            ; A-clobbering PAGE (projections
   TXA                                     ; run under L2)
   JSR br_project_y                        ; h in A -> Y = lo, A = hi
   LDX as_x
   STA VX1+10,X                            ; FH projection hi (from A)
   TYA
   STA VX1+9,X                             ; FH projection lo
   LDA zp_ap2_dlt                          ; h in A
   JSR br_project_y
   LDX as_x
   STA VX1+12,X                            ; CH projection hi (from A)
   TYA
   STA VX1+11,X                            ; CH projection lo
   RTS
; (as_x promoted to ZP — zp.inc $A1 — 3 accesses per as_one)
.endscope




; ============================================================================
; chain_reuse_v1 — the seg loop's vertex-chain hit path (2026-07-10).
; This seg's v1 == the previous transform's v2 (same subsector): copy
; VX2 -> VX1 wholesale — evy/evx/clip always; sx + front sy pair (same
; subsector => same fh/ch) + rhi/rlo when unclipped — then project just
; the flag-gated back pair with the vertex's recip restored. ep = 0 set
; by the caller. Replaces the whole VCACHE hit path + 2 VWHC lookups.
; ============================================================================
chain_reuse_v1:
.scope
   LDA zp_seg_v2_evy
   STA zp_seg_v1_evy
   LDA zp_seg_v2_evx
   STA zp_seg_v1_evx
   LDA zp_seg_v2_clipped
   STA zp_seg_v1_clipped
   BNE ch_rts                               ; clipped: rest undefined
   LDA zp_seg_sx2_l
   STA zp_seg_sx1_l
   LDA zp_seg_sx2_h
   STA zp_seg_sx1_h
; recip carried UNCONDITIONALLY (2026-07-11): the post-has_gap y stage
; projects from the struct-banked recips.
   LDA zp_seg_v2_r_m8
   STA zp_seg_v1_r_m8
   LDA zp_seg_v2_r_s
   STA zp_seg_v1_r_s
; CHAIN SY RECOVERY (2026-07-11): if the PREVIOUS seg ran its y stage
; (zp_ys_done — cleared by any culled/back-facing seg in between), VX2
; still holds its v2's projected FRONT pair, and this seg's v1 is that
; same vertex under the same subsector heights: copy the pair and let
; the y stage skip v1's front projection (zp_ys_v1ok).
   LDA zp_ys_done
   BEQ ch_rts
   LDA zp_seg_sy2_top_l
   STA zp_seg_sy1_top_l
   LDA zp_seg_sy2_top_h
   STA zp_seg_sy1_top_h
   LDA zp_seg_sy2_bot_l
   STA zp_seg_sy1_bot_l
   LDA zp_seg_sy2_bot_h
   STA zp_seg_sy1_bot_h
   LDA #1
   STA zp_ys_v1ok
ch_rts:
   RTS
.endscope

bsp_lo_end:
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_lo_bk.bin", $1B40, bsp_lo_end, $1B40)
.else
; (ld65 writes this: SAVE "bsp_render_lo.bin", $1B40, bsp_lo_end, $1B40)
.endif
