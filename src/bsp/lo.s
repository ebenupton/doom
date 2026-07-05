bsp_lo_start:

; reproject_at_crossing — call cross_compute, then project sx + 4 sy values
; using the reciprocal at NEAR. Output → zp_seg_sx_lo/hi, zp_seg_sy_*.
reproject_at_crossing:
.scope
JSR cross_compute
; Project cx with frac=0 (Python passes fvx_c=0 for clipped endpoints).
; cx is s16; br_project_x_auto dispatches narrow/wide on its hi byte.
LDA zp_clip_cx
STA zp_v_xint
LDA zp_clip_cx_hi
STA zp_v_xext
LDA #0
STA zp_v_xfrac
JSR br_project_x_auto
LDA zp_br_resl
STA zp_seg_sx_lo
LDA zp_br_resh
STA zp_seg_sx_hi
JMP do_project_y
.endscope

; copy_seg_to_v1 / copy_seg_to_v2 — copy zp_seg_sx_*/sy_*_* into vN slots,
; biasing sy by Y_BIAS (= 48). Used after both br_seg_xform_vertex and
; reproject_at_crossing fill the "current vertex" slots.
copy_seg_to_v1:
LDX #0
LDY #0
BEQ copy_seg_to_vx
copy_seg_to_v2:
LDX #4
LDY #2
; copy_seg_to_vx — X = sy-slot offset (0=v1, 4=v2), Y = sx-slot offset
; (0=v1, 2=v2). SEG_PROJ_BUF pairs: vK_top at +0/+4, btop at +8/+12,
; bbot at +10/+14; sx slots at $61/$63. Y values biased by Y_BIAS (48).
copy_seg_to_vx:
; Y values arrive pre-biased from br_project_y (HALF_H + Y_BIAS).
LDA zp_seg_sx_lo
STA $0061,Y
LDA zp_seg_sx_hi
STA $0062,Y
LDA zp_seg_sy_top_lo
STA SEG_PROJ_BUF+0,X
LDA zp_seg_sy_top_hi
STA SEG_PROJ_BUF+1,X
LDA zp_seg_sy_bot_lo
STA SEG_PROJ_BUF+2,X
LDA zp_seg_sy_bot_hi
STA SEG_PROJ_BUF+3,X
LDA zp_seg_sy_btop_lo
STA SEG_PROJ_BUF+8,X
LDA zp_seg_sy_btop_hi
STA SEG_PROJ_BUF+9,X
LDA zp_seg_sy_bbot_lo
STA SEG_PROJ_BUF+10,X
LDA zp_seg_sy_bbot_hi
STA SEG_PROJ_BUF+11,X
RTS

; cross_compute — near-plane crossing point for a seg with one clipped vertex.
;   Inputs:  zp_clip_C_evy, zp_clip_C_evx (clipped, evy ≤ 0)
;            zp_clip_U_evy, zp_clip_U_evx (unclipped, evy ≥ 1)
;   Outputs: zp_clip_cx (s8 crossing view-x), zp_br_rhi/rlo (recip at NEAR)
;
;   Mirrors fp_near_clip exactly:
;     t   = ((NEAR - vy_C) << 8) / (vy_U - vy_C)    (u8 truncated)
;     dvx = vx_U - vx_C                              (s9: -255..255)
;     cx  = vx_C + (t * dvx) >> 8                    (s8 wraparound)
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
STA zp_div_hi
ZERO zp_div_lo

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
STA zp_br_dxlo
ZERO zp_br_dxhi
LDA zp_seg_v2_evx
BPL c_v2_pos
LDA #$FF
STA zp_br_dxhi
c_v2_pos:
LDA zp_seg_v1_evx
BPL c_v1_pos
LDA zp_br_dxlo
SEC
SBC zp_seg_v1_evx
STA zp_br_dxlo
LDA zp_br_dxhi
SBC #$FF
STA zp_br_dxhi
JMP c_have_dvx
c_v1_pos:
LDA zp_br_dxlo
SEC
SBC zp_seg_v1_evx
STA zp_br_dxlo
LDA zp_br_dxhi
SBC #0
STA zp_br_dxhi
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
LDA zp_br_resh
BPL c_cx_rp
LDA #$FF
STA zp_br_t3
c_cx_rp:
LDA zp_seg_v1_evx
CLC
ADC zp_br_resh
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

; cross_umul_u8_s16 — t (u8 in zp_br_a) × dx (s16 in zp_br_dxlo:dxhi) → s16
; in zp_br_resl:resh. Caller takes resh as the (>>8) result.
cross_umul_u8_s16:
.scope
; |dx|: track sign in zp_br_sign.
ZERO zp_br_sign
LDA zp_br_dxhi
BPL c2_dxp
LDA #0
SEC
SBC zp_br_dxlo
STA zp_br_dxlo
LDA #0
SBC zp_br_dxhi
STA zp_br_dxhi
INC zp_br_sign
c2_dxp:
; t * |dx|_lo (u8 × u8 → u16 → resl:resh)
LDA zp_br_dxlo
STA zp_mul_b
LDA zp_br_a
JSR SC_UMUL8
LDA zp_prod_lo
STA zp_br_resl
LDA zp_prod_hi
STA zp_br_resh
; t * |dx|_hi (u8 × u8 → contributes to resh)
LDA zp_br_dxhi
STA zp_mul_b
LDA zp_br_a
JSR SC_UMUL8
LDA zp_br_resh
CLC
ADC zp_prod_lo
STA zp_br_resh
; sign-flip if dx was negative
LDA zp_br_sign
BEQ c2_pos
LDA #0
SEC
SBC zp_br_resl
STA zp_br_resl
LDA #0
SBC zp_br_resh
STA zp_br_resh
c2_pos:
RTS
.endscope

; br_node_setup — read node from ROM, compute side, set BSP_NEAR/FAR.
; Called twice per internal node (entry + post-near phases).
br_node_setup:
.scope
PAGE BANK_L0                            ; nodes table lives in bank L0
LDA zp_node_chlo
STA zp_br_t0
LDA zp_node_chhi
STA zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
CLC
LDA zp_rom_nodes_lo
ADC zp_br_t0
STA zp_br_p
LDA zp_rom_nodes_hi
ADC zp_br_t1
STA zp_br_p_h
LDY #0
LDA (zp_br_p),Y
STA zp_node_nxlo
INY
LDA (zp_br_p),Y
STA zp_node_nxhi
INY
LDA (zp_br_p),Y
STA zp_node_nylo
INY
LDA (zp_br_p),Y
STA zp_node_nyhi
INY
LDA (zp_br_p),Y
STA zp_node_dxlo
INY
LDA (zp_br_p),Y
STA zp_node_dxhi
INY
LDA (zp_br_p),Y
STA zp_node_dylo
INY
LDA (zp_br_p),Y
STA zp_node_dyhi
LDA zp_br_pxraw_lo
SEC
SBC zp_node_nxlo
STA zp_seg_dxraw_lo
LDA zp_br_pxraw_hi
SBC zp_node_nxhi
STA zp_seg_dxraw_hi
LDA zp_br_pyraw_lo
SEC
SBC zp_node_nylo
STA zp_seg_dyraw_lo
LDA zp_br_pyraw_hi
SBC zp_node_nyhi
STA zp_seg_dyraw_hi
LDA zp_node_dxlo
ORA zp_node_dxhi
BNE ns_ndx_nz
LDA zp_node_dylo
ORA zp_node_dyhi
BEQ ns_jmp_side1
LDA zp_seg_dxraw_lo
ORA zp_seg_dxraw_hi
BEQ ns_jmp_side1
LDA zp_node_dyhi
EOR zp_seg_dxraw_hi
BPL ns_side0
; (was BMI+JMP)
ns_jmp_side1:
JMP ns_side1
ns_ndx_nz:
LDA zp_node_dylo
ORA zp_node_dyhi
BNE ns_general
LDA zp_seg_dyraw_lo
ORA zp_seg_dyraw_hi
BEQ ns_jmp_side1
LDA zp_node_dxhi
EOR zp_seg_dyraw_hi
BPL ns_jmp_side1
JMP ns_side0
ns_general:
LDA zp_seg_dxraw_lo
STA zp_br_dxlo
LDA zp_seg_dxraw_hi
STA zp_br_dxhi
LDA zp_node_dylo
STA zp_br_dylo
LDA zp_node_dyhi
STA zp_br_dyhi
JSR br_smul_s16_s16_s32
LDA zp_br_t0
STA $0A50
LDA zp_br_t1
STA $0A51
LDA zp_br_t2
STA $0A52
LDA zp_seg_dyraw_lo
STA zp_br_dxlo
LDA zp_seg_dyraw_hi
STA zp_br_dxhi
LDA zp_node_dxlo
STA zp_br_dylo
LDA zp_node_dxhi
STA zp_br_dyhi
JSR br_smul_s16_s16_s32
LDA $0A50
SEC
SBC zp_br_t0
STA $0A50
LDA $0A51
SBC zp_br_t1
STA $0A51
LDA $0A52
SBC zp_br_t2
STA $0A52
LDA $0A52
BMI ns_side1
ORA $0A51
ORA $0A50
BEQ ns_side1
ns_side0:
LDA #0
STA zp_side
JMP ns_done
ns_side1:
LDA #1
STA zp_side
ns_done:
; Re-fetch node ptr (br_smul_s16_s16_s32 may have clobbered zp_br_p).
LDA zp_node_chlo
STA zp_br_t0
LDA zp_node_chhi
STA zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
CLC
LDA zp_rom_nodes_lo
ADC zp_br_t0
STA zp_br_p
LDA zp_rom_nodes_hi
ADC zp_br_t1
STA zp_br_p_h
LDA zp_side
BNE ns_back
LDY #8
LDA (zp_br_p),Y
STA BSP_NEAR_LO
INY
LDA (zp_br_p),Y
STA BSP_NEAR_HI
INY
LDA (zp_br_p),Y
STA BSP_FAR_LO
INY
LDA (zp_br_p),Y
STA BSP_FAR_HI
RTS
ns_back:
LDY #10
LDA (zp_br_p),Y
STA BSP_NEAR_LO
INY
LDA (zp_br_p),Y
STA BSP_NEAR_HI
LDY #8
LDA (zp_br_p),Y
STA BSP_FAR_LO
INY
LDA (zp_br_p),Y
STA BSP_FAR_HI
RTS
.endscope

; ============================================================================
; br_project_x_wide — project a view-space X whose integer part is s16
; (doesn't fit s8) to screen X, bit-exact with Python's full-width
;   sx = 128 + evx*rxh + (evx*rxl >> 8) + (frac*rxh >> 8)   (mod 2^16)
; where evx = (zp_v_xext : zp_v_xint) s16, frac = zp_v_xfrac u8,
; rxh in [0,127] (recip 8.8 clamped to $7FFF), rxl u8.
;
; Byte decomposition (5 8x8 muls; wide path only, |evx| >= 128):
;   evx*rxh mod 2^16 = umul8(xint,rxh) + (smul_s8_u8(xext,rxh).lo << 8)
;   evx*rxl >> 8     = smul_s8_u8(xext,rxl) + umul8(xint,rxl).hi
;     (exact floor: evx*rxl = 256*(xext*rxl) + xint*rxl with xint*rxl >= 0)
;   frac*rxh >> 8    = umul8(xfrac,rxh).hi
;
;   Inputs:  zp_v_xext/zp_v_xint/zp_v_xfrac, zp_br_rhi/zp_br_rlo
;   Output:  zp_br_resl/h = sx (s16, mod 2^16 of Python's value)
;   Clobbers: zp_br_a/b, zp_br_vxlo/hi, zp_mul_b, zp_prod_lo/hi
; ============================================================================
br_project_x_wide:
.scope
; 24-bit accumulation: the bbox corner path needs the true sign of
; sx when |sx| exceeds s16 (off-screen side classification); the seg
; path uses the low 16 only (matches Python's value at the s16 ZP
; interface). Accumulator: vxlo/vxhi/t2 (lo/mid/ext).

; sum := 128 + umul8(xint, rxh)
LDA zp_br_rhi
STA zp_mul_b
LDA zp_v_xint
JSR SC_UMUL8
CLC
LDA zp_prod_lo
ADC #128
STA zp_br_vxlo
LDA zp_prod_hi
ADC #0
STA zp_br_vxhi
LDA #0
ADC #0
STA zp_br_t2

; sum += smul_s8_u8(xext, rxh) << 8   (s16 product into mid/ext)
LDA zp_v_xext
STA zp_br_a
LDA zp_br_rhi
STA zp_br_b
JSR br_smul_s8_u8
LDA zp_br_resl
CLC
ADC zp_br_vxhi
STA zp_br_vxhi
LDA zp_br_resh
ADC zp_br_t2
STA zp_br_t2

; sum += sext24(smul_s8_u8(xext, rxl))   (s16 part of evx*rxl >> 8)
LDA zp_v_xext
STA zp_br_a
LDA zp_br_rlo
STA zp_br_b
JSR br_smul_s8_u8
LDX #0
LDA zp_br_resh
BPL pw_t2_pos
DEX                                     ; X = $FF sign extension
pw_t2_pos:
LDA zp_br_resl
CLC
ADC zp_br_vxlo
STA zp_br_vxlo
LDA zp_br_resh
ADC zp_br_vxhi
STA zp_br_vxhi
TXA
ADC zp_br_t2
STA zp_br_t2

; sum += umul8(xint, rxl).hi   (u8, the non-negative floor remainder)
LDA zp_br_rlo
STA zp_mul_b
LDA zp_v_xint
JSR SC_UMUL8
LDA zp_prod_hi
CLC
ADC zp_br_vxlo
STA zp_br_vxlo
LDA #0
ADC zp_br_vxhi
STA zp_br_vxhi
LDA #0
ADC zp_br_t2
STA zp_br_t2

; sum += umul8(xfrac, rxh).hi  (sub-pixel term)
LDA zp_br_rhi
STA zp_mul_b
LDA zp_v_xfrac
JSR SC_UMUL8
LDA zp_prod_hi
CLC
ADC zp_br_vxlo
STA zp_br_resl
LDA #0
ADC zp_br_vxhi
STA zp_br_resh
LDA #0
ADC zp_br_t2
STA zp_br_resext
RTS
.endscope

; (ev_clamp_evy16 moved to the B region.)

; (br_project_x_auto moved to the B region.)

.assert bsp_lo_end <= $2000, error


; ============================================================================
; ap_edges — NOVT aperture-edge verticals (SF_APEDGE1=$40 / SF_APEDGE2=$80).
; Mirrors the Python reference:
;   SOLID seg, APEDGE_K: draw (sxK, bchK', sxK, bfhK') where (bch,bfh) are
;     the colinear portal's aperture heights, projected with endpoint K's
;     reciprocal. For K=1 the packer overlays them on the bfh/bch slots,
;     so sy1_bbot/sy1_btop ALREADY hold the projections. For K=2 they sit
;     in seg detail bytes 12/13 and are projected by ap2_solid_proj.
;   PORTAL seg (has steps), APEDGE_K: draw (sxK, bt|ft, sxK, bb|fb) — all
;     four projections already in the SEG_PROJ_BUF slots.
; Off-screen endpoints (sx hi != 0) are skipped like the other verticals:
; Python computes then AP-skips or DCL-clips them; pixel output matches.
; X = sy-slot offset (0=v1, 4=v2), Y = sx-slot offset (0=v1, 2=v2).
; ============================================================================
ap_edges:
.scope
LDA zp_seg_flags
AND #$40
BEQ ap_chk2
LDX #0
LDY #0
JSR ap_edge_one
ap_chk2:
LDA zp_seg_flags
AND #$80
BEQ ap_done
LDX #4
LDY #2
JSR ap_edge_one
ap_done:
RTS
.endscope

ap_edge_one:
.scope
LDA $0062,Y
BNE ap_rts
; sx off-screen → skip
LDA zp_seg_flags
AND #$02
BNE ap_solid
; portal: top edge = bt if NEEDBT else ft; bot = bb if NEEDBB else fb
LDA zp_seg_flags
AND #$04
BEQ ap_top_ft
LDA SEG_PROJ_BUF+8,X
STA zp_line_yl
LDA SEG_PROJ_BUF+9,X
STA $B3
JMP ap_bot
ap_top_ft:
LDA SEG_PROJ_BUF+0,X
STA zp_line_yl
LDA SEG_PROJ_BUF+1,X
STA $B3
ap_bot:
LDA zp_seg_flags
AND #$08
BEQ ap_bot_fb
LDA SEG_PROJ_BUF+10,X
STA zp_line_yr
LDA SEG_PROJ_BUF+11,X
STA $B5
JMP ap_emit_y
ap_bot_fb:
LDA SEG_PROJ_BUF+2,X
STA zp_line_yr
LDA SEG_PROJ_BUF+3,X
STA $B5
JMP ap_emit_y
ap_solid:
CPX #0
BNE ap2_solid_jmp
; v1 solid: line from sy1_bbot (APV1_CH proj) to sy1_btop (APV1_FH)
LDA SEG_PROJ_BUF+10,X
STA zp_line_yl
LDA SEG_PROJ_BUF+11,X
STA $B3
LDA SEG_PROJ_BUF+8,X
STA zp_line_yr
LDA SEG_PROJ_BUF+9,X
STA $B5
ap_emit_y:
; vertical at the endpoint's sx ($61/$63 via Y)
LDA $0061,Y
STA zp_line_xl
STA zp_line_xr
LDA $0062,Y
STA $B2
STA $B4
LDA #0
STA $BD
PAGE BANK_C
JMP SC_DRAW_S16
ap2_solid_jmp:
JMP ap2_solid_proj
ap_rts:
RTS
.endscope

; ap2_solid_proj — project the solid seg's APV2 aperture heights with
; endpoint 2's reciprocal and emit the vertical at sx2.
;   v2 crossed → recip = recip(NEAR) = (127,255) constant (Python idx2).
;   else       → recip from v2's vertex cache entry (offsets 2,3).
ap2_solid_proj:
.scope
LDA zp_seg_v2_clipped
BEQ a2_cached
LDA #127
STA zp_br_rhi
LDA #255
STA zp_br_rlo
JMP a2_have_recip
a2_cached:
; cache ptr = VCACHE_BASE + v2_idx*8 (the ZP cache ptr is rasteriser-
; clobbered scratch by now — recompute).
LDA zp_seg_v2_lo
STA zp_br_t0
LDA zp_seg_v2_hi
STA zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
CLC
LDA #<VCACHE_BASE
ADC zp_br_t0
STA zp_br_p
LDA #>VCACHE_BASE
ADC zp_br_t1
STA zp_br_p_h
LDY #2
LDA (zp_br_p),Y
STA zp_br_rhi
INY
LDA (zp_br_p),Y
STA zp_br_rlo
a2_have_recip:
LDA zp_fhch_p
STA zp_br_p
LDA zp_fhch_p_h
STA zp_br_p_h
; bch2' = project(APV2_CH - vz)  (FHCH byte 4)
LDY #4
LDA (zp_br_p),Y
SEC
SBC zp_br_vz
STA zp_br_t0
JSR br_project_y                        ; output pre-biased
LDA zp_br_resl
STA zp_line_yl
LDA zp_br_resh
STA $B3
; bfh2' = project(APV2_FH - vz)  (FHCH byte 5)
LDY #5
LDA (zp_br_p),Y
SEC
SBC zp_br_vz
STA zp_br_t0
JSR br_project_y
LDA zp_br_resl
STA zp_line_yr
LDA zp_br_resh
STA $B5
JMP emit_vert_sx2
.endscope


; fhch_ptr_si6 — zp_br_p := rom_fhch + zp_seg_first*6 (the 6-byte/seg
; height table: fh, ch, bfh|apv1_ch, bch|apv1_fh, apv2_ch, apv2_fh).
fhch_ptr_si6:
.scope
LDA zp_seg_first_lo
STA zp_br_t0
LDA zp_seg_first_hi
STA zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
; *2
LDA zp_br_t0
STA zp_br_t2
LDA zp_br_t1
STA zp_br_t3
ASL zp_br_t0
ROL zp_br_t1
; *4
CLC
LDA zp_br_t0
ADC zp_br_t2
STA zp_br_t0
; *6
LDA zp_br_t1
ADC zp_br_t3
STA zp_br_t1
CLC
LDA zp_rom_fhch_lo
ADC zp_br_t0
STA zp_br_p
LDA zp_rom_fhch_hi
ADC zp_br_t1
STA zp_br_p_h
RTS
.endscope

bsp_lo_end:
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_lo_bk.bin", $1B40, bsp_lo_end, $1B40)
.else
; (ld65 writes this: SAVE "bsp_render_lo.bin", $1B40, bsp_lo_end, $1B40)
.endif
