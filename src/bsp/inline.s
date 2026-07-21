; ============================================================================
; bsp/inline.s — single-caller function bodies, inlined as MACROS
; (2026-07-17 sweep: jump-table-era JSR/RTS pairs on single-caller
; functions were pure overhead — each body now expands at its one call
; site; early RTS exits became JMPs to the expansion end, tail calls
; that rode the JSR return address became explicit JSRs, and INTERNAL
; subroutines (apv_stage's as_one) keep their RTSs — those return to
; the in-expansion JSR, not to the old caller).
; Included right after bsp/header.s so every expansion site sees the
; definitions. Emits nothing by itself.
; EXCLUDED with reasons: bbox_check_angle (SMC dispatch target),
; anim_l0_worker (200-byte cold body blows caller branch ranges for a
; once-per-frame win), dpy_back / slope_div_le / dcl_line_y_at_ox0
; (shared bodies: fall-in second entries), bca_frame (cross-unit,
; once per frame), box_classify / zc_corners (TWO callers each —
; bbox_check_angle + the rcache cold fill; zc_corners' RTS-dispatch
; arms additionally need the JSR return address on the stack).
; ============================================================================

.macro SC_UDIV16_8
.scope
   LDA zp_div_h
   CMP zp_div_den
   BCC du8                                 ; (was BCS d16: the inline's
   JMP d16                                 ; RTS->JMP conversions pushed d16
du8:                                       ; past branch range; +1 fast path,
                                           ; -12 for the dead JSR/RTS)
; --- u8-quotient fast path: numerator <<= 8, then find the first
;     committing quotient bit with compare-only steps. ---
   LDX zp_div_l
   STX zp_div_h
   LDX #0
   STX zp_div_l
   ASL zp_div_h
   ROL A
   BCS dskip_c8
   CMP zp_div_den
   BCS dskip_c8
   ASL zp_div_h
   ROL A
   BCS dskip_c7
   CMP zp_div_den
   BCS dskip_c7
   ASL zp_div_h
   ROL A
   BCS dskip_c6
   CMP zp_div_den
   BCS dskip_c6
   ASL zp_div_h
   ROL A
   BCS dskip_c5
   CMP zp_div_den
   BCS dskip_c5
   ASL zp_div_h
   ROL A
   BCS dskip_c4
   CMP zp_div_den
   BCS dskip_c4
   ASL zp_div_h
   ROL A
   BCS dskip_c3
   CMP zp_div_den
   BCS dskip_c3
   ASL zp_div_h
   ROL A
   BCS dskip_c2
   CMP zp_div_den
   BCS dskip_c2
   ASL zp_div_h
   ROL A
   BCS dskip_c1
   CMP zp_div_den
   BCS dskip_c1
   LDA #0
   JMP inl_end
; all 8 compares missed → quotient = 0
; --- dskip ladder: entered from the prelude at the first committing
;     quotient bit; X = loop iterations remaining (this bit included). ---
dskip_c8:
   LDX #8
   BNE dskip_commit
dskip_c7:
   LDX #7
   BNE dskip_commit
dskip_c6:
   LDX #6
   BNE dskip_commit
dskip_c5:
   LDX #5
   BNE dskip_commit
dskip_c4:
   LDX #4
   BNE dskip_commit
dskip_c3:
   LDX #3
   BNE dskip_commit
dskip_c2:
   LDX #2
   BNE dskip_commit
dskip_c1:
   LDX #1
dskip_commit:
; Commit the first quotient bit: remainder -= den, quotient bit → 1,
; then continue in the generic loop for the remaining X-1 bits.
   SBC zp_div_den
   INC zp_div_l
   DEX
   BNE dl
   LDA zp_div_l
   JMP inl_end
; --- 16-bit path: A = remainder, X = 16 iterations; quotient shifts
;     into div_lo:div_hi behind the departing numerator bits. ---
d16:
   LDA #0
   LDX #16
dl:
   ASL zp_div_l
   ROL zp_div_h
   ROL A
   BCS dl_over
   CMP zp_div_den
   BCC ds
   SBC zp_div_den
dl_commit:
   INC zp_div_l
ds:
   DEX
   BNE dl
   LDA zp_div_l
   JMP inl_end
dl_over:
; remainder bit 8 carried out of ROL → remainder >= 256 > den:
; the subtract always fits (carry already set), skip the CMP.
   SBC zp_div_den
   JMP dl_commit
inl_end:
.endscope
.endmacro

.macro cross_compute
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

; |den| = |v2_evy - v1_evy|; den/2 seeds the dividend low byte for a
; ROUND-TO-NEAREST t (2026-07-19 — was ZERO: truncation). num < den
; here (num == den is the special case above), so t stays u8.
   LDA zp_seg_v2_evy
   SEC
   SBC zp_seg_v1_evy
   BPL c_den_ok
   EOR #$FF
   BUMP
c_den_ok:
   STA zp_div_den
   LSR A
   STA zp_div_l

   SC_UDIV16_8                         ; A = t (u8, RN)
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

   cross_umul_u8_s16
; ROUND the product before consuming its hi byte (2026-07-19): the
; low byte's bit 7 is the (P + 128) carry — ASL lifts it into C and
; ADC folds it into resh BEFORE the sign extension (the increment can
; legitimately flip the sign byte, so the sext below must see the
; rounded value). This is where the near-clip's precision lived: the
; truncated product cost ~0.36 view units of mean crossing error.
   LDA zp_br_res_l
   ASL A
   LDA zp_br_res_h
   ADC #0
   STA zp_br_res_h
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
; (no PAGE: br_recip's caller-holds-L2 contract is met by arrival —
;  reproject_at_crossing's only callers sit right after the v2
;  transform, and br_seg_xform_vertex exits L2 on EVERY path since
;  2026-07-21; cross_compute touches only ZP/main tables.)
   LDY #2
   LDX #0
   JSR br_recip
   JMP inl_end
inl_end:
.endscope
.endmacro

.macro cross_umul_u8_s16
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
inl_end:
.endscope
.endmacro

.macro ap_edges
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
   JSR ap_edge_one                         ; tail call
   JMP inl_end
ap_done:
inl_end:
.endscope
.endmacro

.macro apv_stage
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
   JSR as_one                              ; tail call
   JMP inl_end
as_done:
   JMP inl_end
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
   RNS_SELECT                              ; (A = S; Y survives, X dies)
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
inl_end:
.endscope
.endmacro

.macro chain_reuse_v1
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
   STA zp_ys_v1ok                          ; A = ys_done, BEQ-proven nonzero:
                                        ; v1ok is zero/nonzero only (the ys
                                        ; stage LDA/BEQs it) — the old
                                        ; trailing LDA #1 coercion died
   LDA zp_seg_sy2_top_l
   STA zp_seg_sy1_top_l
   LDA zp_seg_sy2_top_h
   STA zp_seg_sy1_top_h
   LDA zp_seg_sy2_bot_l
   STA zp_seg_sy1_bot_l
   LDA zp_seg_sy2_bot_h
   STA zp_seg_sy1_bot_h
ch_rts:
inl_end:
.endscope
.endmacro

.macro ev_clamp_hi_nz
.scope
   CMP #$FF
   BEQ ev_case_ff
   ASL A
   BCS ev_clamp_neg
; carry = sign of hi byte
   LDA #$7F
   BNE ev_store
ev_clamp_neg:
   LDA #$80
   BNE ev_store
ev_case_ff:
   LDA VX1+0,X
   BMI ev_done
; $FF:%1xxxxxxx → fits s8
   LDA #$80
   BNE ev_store
; -256..-129 → clamp
ev_store:
   STA VX1+0,X
ev_done:
inl_end:
.endscope
.endmacro

.macro vxc_cold_store
.scope
   LDY zp_seg_v_idx_l
   LDA zp_seg_v_idx_b
   AND #$20                                ; idx >= 256  <=>  B >= 32
   BNE vs_hi
   SEC
   LDA zp_br_vx_l
   SBC vxc_ref_x+0
   STA VXC_XLO,Y
   LDA zp_br_vx_h
   SBC vxc_ref_x+1
   STA VXC_XHI,Y
   LDA zp_br_vx_x
   SBC vxc_ref_x+2
   STA VXC_XEXT,Y
   SEC
   LDA zp_br_vy_l
   SBC vxc_ref_y+0
   STA VXC_YLO,Y
   LDA zp_br_vy_h
   SBC vxc_ref_y+1
   STA VXC_YHI,Y
   LDA zp_br_vy_x
   SBC vxc_ref_y+2
   STA VXC_YEXT,Y
   JMP inl_end
vs_hi:
   SEC
   LDA zp_br_vx_l
   SBC vxc_ref_x+0
   STA VXC_XLO+$100,Y
   LDA zp_br_vx_h
   SBC vxc_ref_x+1
   STA VXC_XHI+$100,Y
   LDA zp_br_vx_x
   SBC vxc_ref_x+2
   STA VXC_XEXT+$100,Y
   SEC
   LDA zp_br_vy_l
   SBC vxc_ref_y+0
   STA VXC_YLO+$100,Y
   LDA zp_br_vy_h
   SBC vxc_ref_y+1
   STA VXC_YHI+$100,Y
   LDA zp_br_vy_x
   SBC vxc_ref_y+2
   STA VXC_YEXT+$100,Y
inl_end:
.endscope
.endmacro

.macro vxc_frame
.scope
   LDA VXC_ENABLE
   STA zp_vxc_on                           ; the vertex_fetch gate (SMC retired
   BNE vf_on                               ; 2026-07-18; ENABLE is 0/1)
   JMP inl_end
vf_on:
; ref = view totals of world (0,0) under this frame's context
.if ::C02
   STZ zp_br_dx_l
   STZ zp_br_dx_h
   STZ zp_br_dy_l
   STZ zp_br_dy_h
.else
   LDA #0
   STA zp_br_dx_l
   STA zp_br_dx_h
   STA zp_br_dy_l
   STA zp_br_dy_h
.endif
   JSR br_to_view
; --- publish this frame's ref (ORIGIN NORMALIZATION: stored bases are
; total - ref, i.e. the exactly-linear L(w); the warm arm adds the
; current ref back. No ref_cold, no CACC - the epoch anchor was a
; historical artifact, not a numerical need.) ---
   LDA zp_br_vx_l
   STA vxc_ref_x+0
   LDA zp_br_vx_h
   STA vxc_ref_x+1
   LDA zp_br_vx_x
   STA vxc_ref_x+2
   LDA zp_br_vy_l
   STA vxc_ref_y+0
   LDA zp_br_vy_h
   STA vxc_ref_y+1
   LDA zp_br_vy_x
   STA vxc_ref_y+2
   LDA vxc_ab
   CMP vxc_prev_ab
   BEQ vf_patch
; --- angle changed: new epoch - wipe the valid bitmap ---
   STA vxc_prev_ab
   LDX #58
   LDA #0
vf_wipe:
   STA VXC_VALID,X
   DEX
   BPL vf_wipe
vf_patch:
inl_end:
.endscope
.endmacro

.macro bv_dcache_store
.scope
   LDX zp_node_ch_l
   CPY #1                                  ; Y = the dvf_store encode: 1 =
   BNE st_vis                              ; angle cull, 0/3 = visible
   LDA #126                                ; invisible
   BNE st_put                              ; (always)
st_vis:
; Classification needs a GUARD BAND around the pivot: extent endpoints
; are conservative-wide and viewangletox rounds, so a bound within a few
; columns of centre can include points on the OTHER side of the true
; optical axis — which migrate the other way. 4 columns on each side
; (left class ends at 124, right class starts at 132); anything nearer
; the pivot is treated as straddling (0,255) — always safe.
   LDA bca_ilo
   CMP #132
   BCS st_put                              ; right of centre: code = ilo (>=132)
   LDA bca_ihi
   CMP #125
   BCC st_put                              ; left of centre: code = ihi (0-124)
   LDA #127                                ; near-pivot / straddle
st_put:
   LDY zp_bbox_side
   BNE st_left
   STA D_CODE_R,X
   JMP inl_end
st_left:
   STA D_CODE_L,X
inl_end:
.endscope
.endmacro

.macro rot_select
.scope
; --- sin variant -> A/X = lo/hi ---
   LDA zp_br_sone
   BEQ sin_notone
   LDA zp_br_sneg
   BEQ sin_up
   LDA #<rot_unity_neg_s                   ; the _s twins write zp_rs (res-
   LDX #>rot_unity_neg_s                   ; slot split): the sin slot must
   BNE sin_have                            ; never target zp_br_res
sin_up:
   LDA #<rot_unity_pos_s
   LDX #>rot_unity_pos_s
   BNE sin_have
sin_notone:
   LDA zp_br_smag
   BNE sin_gen
   LDA #<rot_zero_s
   LDX #>rot_zero_s
   BNE sin_have
sin_gen:
   STA rot_gen_sin+1                       ; mag immediate
   STA rot_sqs1l+1                         ; sum-side table bases: lo byte
   STA rot_sqs1h+1                         ; = mag (SQR pages page-aligned,
   STA rot_sqs2l+1                         ; hi byte static; abs,X crosses
   STA rot_sqs2h+1                         ; into the contiguous 2nd page)
   STA rgp_smag+1                          ; ... and the fused pair's twins
   STA rgp_sq1l+1
   STA rgp_sq1h+1
   STA rgp_sq2l+1
   STA rgp_sq2h+1
   LDA zp_br_sneg
   STA rot_gen_sin+5                       ; neg immediate
   STA rgp_sneg+1
   LDA #<rot_gen_sin
   LDX #>rot_gen_sin
sin_have:
   STA rot_s4+1                            ; (rot_s1 died in the pair fusion)
   STX rot_s4+2
   STA rpt_jsr+1                           ; thunk sin target (maintained
   STX rpt_jsr+2                           ; every frame; used on non-gen)
; --- cos variant -> rot_s2 / rot_s3 ---
   LDA zp_br_cone
   BEQ cos_notone
   LDA zp_br_cneg
   BEQ cos_up
   LDA #<rot_unity_neg
   LDX #>rot_unity_neg
   BNE cos_have
cos_up:
   LDA #<rot_unity_pos
   LDX #>rot_unity_pos
   BNE cos_have
cos_notone:
   LDA zp_br_cmag
   BNE cos_gen
   LDA #<rot_zero
   LDX #>rot_zero
   BNE cos_have
cos_gen:
   STA rot_gen_cos+1
   STA rot_sqc1l+1                         ; cos sum-side bases (see sin)
   STA rot_sqc1h+1
   STA rot_sqc2l+1
   STA rot_sqc2h+1
   STA rgp_cmag+1                          ; the fused pair's cos staging
   LDA zp_br_cneg
   STA rot_gen_cos+5
   STA rgp_cneg+1
   LDA #<rot_gen_cos
   LDX #>rot_gen_cos
cos_have:
   STA rot_s2+1                            ; (rot_s3 died in the pair fusion)
   STX rot_s2+2
   STA rpt_jmp+1                           ; thunk cos target
   STX rpt_jmp+2
; --- pair-site select: general sin AND general cos -> the fused
; variant; anything else -> the thunk (runs the two selected variants
; back to back; +3 cycles, axis-aligned frames only). ---
   LDA rot_s4+1
   CMP #<rot_gen_sin
   BNE psel_thunk
   LDA rot_s4+2
   CMP #>rot_gen_sin
   BNE psel_thunk
   LDA rot_s2+1
   CMP #<rot_gen_cos
   BNE psel_thunk
   LDA rot_s2+2
   CMP #>rot_gen_cos
   BNE psel_thunk
   LDA #<rot_gen_pair
   LDX #>rot_gen_pair
   BNE psel_have                           ; (hi never 0 — always taken)
psel_thunk:
   LDA #<rot_pair_thunk
   LDX #>rot_pair_thunk
psel_have:
   STA rot_s13+1
   STX rot_s13+2
inl_end:
.endscope
.endmacro
