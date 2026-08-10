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

; (cross_compute / cross_umul_u8_s16 DELETED 2026-08-09: EV16 —
; the crossing lives openly in lo.s reproject_at_crossing now, on s24
; recovered totals; the s8 evy/evx tier died with them.)


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
   LDA VX1+2,X                             ; sx_hi: off-screen endpoint →
   BEQ as_on                               ; ap_edge_one skips its vertical,
   RTS                                     ; so DON'T project the pair
                                        ; (spectrack 2026-07-12: every
                                        ; wasted apv_stage call was this)
as_on:
   STX as_x
   LDA VX1+11,X                            ; endpoint recip
   STA zp_br_r_m8
   LDA VX1+12,X
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
   STA VX1+8,X                            ; FH projection hi (from A)
   TYA
   STA VX1+7,X                             ; FH projection lo
   LDA zp_ap2_dlt                          ; h in A
   JSR br_project_y
   LDX as_x
   STA VX1+10,X                            ; CH projection hi (from A)
   TYA
   STA VX1+9,X                            ; CH projection lo
   RTS
; (as_x promoted to ZP — zp.inc $A1 — 3 accesses per as_one)
inl_end:
.endscope
.endmacro

; (chain_reuse_v1 moved BODILY into subsector.s 2026-07-26 — single
; site, no reason for the macro indirection.)


; (ev_clamp_hi_nz macro RETIRED 2026-08-09 — inlined at its single use,
;  the ec_hi_nz island in seg_xform.s SXV_BODY.)

; (vxc_cold_store macro RETIRED 2026-08-09 — the birth store is inlined
;  per side in the seg_xform.s vxcon islands, side baked; the generic
;  senior-test form died with it.)

.macro vxc_frame
.scope
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
   JSR br_to_view                          ; rot5(-p_int): s16 COUNTS out
                                           ; (count-native 2026-08-10)
; --- publish this frame's ref = rot5(-p_int) + count fracs (ORIGIN
; NORMALIZATION: stored bases are total - ref, i.e. the exactly-linear
; L(w); the warm arm adds the current ref back). The fracs were
; quantized to counts in br_view_setup; ref rounds ONCE per axis,
; exactly the mirror's rns(ref_88, 3). ---
   CLC
   LDA zp_br_vx_l
   ADC zp_br_fvx_l
   STA vxc_ref_x+0
   LDA zp_br_vx_h
   ADC zp_br_fvx_h
   STA vxc_ref_x+1
   CLC
   LDA zp_br_vy_l
   ADC zp_br_fvy_l
   STA vxc_ref_y+0
   LDA zp_br_vy_h
   ADC zp_br_fvy_h
   STA vxc_ref_y+1
   LDA VXC_ENABLE
   STA zp_vxc_on                           ; kept for harness/tools AND
   BNE vf_on                               ; cr_recover's plain gate; the
                                           ; fetch dispatch is the VECTORS
; cache OFF: fetch vectors -> the plain compute-only arms (canonical
; cache-off contract: same result, no probe, no store, no wipe —
; restored 2026-08-10 after a brief always-on detour)
   LDA #<sxv0_vfoff
   STA zp_vf_vec0
   LDA #>sxv0_vfoff
   STA zp_vf_vec0+1
   LDA #<sxv1_vfoff
   STA zp_vf_vec1
   LDA #>sxv1_vfoff
   STA zp_vf_vec1+1
   JMP inl_end
vf_on:
; cache ON: fetch vectors -> the serve stubs
   LDA #<sxv0_vxcon
   STA zp_vf_vec0
   LDA #>sxv0_vxcon
   STA zp_vf_vec0+1
   LDA #<sxv1_vxcon
   STA zp_vf_vec1
   LDA #>sxv1_vxcon
   STA zp_vf_vec1+1
   LDA vxc_ab
   CMP vxc_prev_ab
   BEQ vf_patch
; --- angle changed: new epoch - wipe the valid bitmap ---
; STRIPED (2026-08-09): 12 uniform 5-byte stripes = 60 bytes — byte 60
; ($07BB) is the bitmap page's sentinel gap, safe to clear (the old
; $05A0 home banned it: byte 60 was VXC_ENABLE). ~325 cyc vs the
; 1-byte loop's ~589, on every rotation frame.
   STA vxc_prev_ab
   LDA #0
   LDX #4
vf_wl:                                     ; 12 stripes x 5 = 60 bytes
   STA VXC_VALID,X
   STA VXC_VALID+5,X
   STA VXC_VALID+10,X
   STA VXC_VALID+15,X
   STA VXC_VALID+20,X
   STA VXC_VALID+25,X
   STA VXC_VALID+30,X
   STA VXC_VALID+35,X
   STA VXC_VALID+40,X
   STA VXC_VALID+45,X
   STA VXC_VALID+50,X
   STA VXC_VALID+55,X
   DEX
   BPL vf_wl
vf_patch:
inl_end:
.endscope
.endmacro

; (bv_dcache_store retired 2026-07-21: the forward cache lives in
;  src/ang/bca.s on the rcache architecture — dbox_check stores raw
;  ilo/ihi at birth; the guard-band trick moved into its SERVE.)

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
   STA rot_sqs1h+1                         ; = mag5 (SQR pages page-aligned,
   STA rot_sqs2l+1                         ; hi byte static; abs,X crosses
                                           ; into the contiguous 2nd page)
                                           ; (the _2h sites DIED count-
                                           ; native: 1-byte hi products)
   STA rgp_smag+1                          ; ... and the fused pair's twins
   STA rgp_sq1l+1
   STA rgp_sq1h+1
   STA rgp_sq2l+1
   LDA zp_br_sneg
   STA rot_gen_sin+5                       ; neg immediate
   STA rgp_sneg+1
   LDA #<rot_gen_sin
   LDX #>rot_gen_sin
sin_have:
   STA rot_s4+1                            ; (rot_s1 died in the pair fusion)
   STX rot_s4+2
   STA rot_s4w+1                           ; V16 twin (rot_w_signed core)
   STX rot_s4w+2
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
   STA rot_sqcv1l+1                        ; the pair's VY-dest cos twin
   STA rot_sqcv1h+1                        ; (rot_core_cosv_nz, 2026-07-27)
   STA rot_sqcv2l+1
   STA rgp_cmag+1                          ; the fused pair's cos staging
   LDA zp_br_cneg
   STA rot_gen_cos+5
   STA rgp_cneg+1
   LDA #<rot_gen_cos
   LDX #>rot_gen_cos
cos_have:
   STA rot_s2+1                            ; (rot_s3 died in the pair fusion)
   STX rot_s2+2
   STA rot_s2w+1                           ; V16 twin
   STX rot_s2w+2
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
   STA rot_s13w+1                          ; V16 twin
   STX rot_s13w+2
inl_end:
.endscope
.endmacro
