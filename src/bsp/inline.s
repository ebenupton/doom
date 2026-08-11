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
   BR_BIT_CLR 1, zp_seg_flags, ap_chk2     ; APEDGE1 = $02 since the SOLID
                                        ; swap (cold path pays the test)
   LDX #0                                  ; v1 struct
   JSR ap_edge_one
ap_chk2:
.if ::C02 && ::ROCKWELL
   BBR0 zp_seg_flags, ap_done              ; C = bit 0 = SF_APEDGE2
.else
   LDA zp_seg_flags
   LSR A                                   ; C = bit 0 = SF_APEDGE2
   BCC ap_done
.endif
   LDX #VX_STRIDE                          ; v2 struct
   JSR ap_edge_one                         ; tail call
   JMP inl_end
ap_done:
inl_end:
.endscope
.endmacro

.macro apv_stage
.scope
   BR_BIT_CLR 1, zp_seg_flags, as_chk2     ; APEDGE1 = $02 (see ap_edges)
   LDX #0
   LDY #13                                 ; header +13 = apv1_fh (+12 ch)
   JSR as_one
as_chk2:
.if ::C02 && ::ROCKWELL
   BBR0 zp_seg_flags, as_done              ; C = bit 0 = APEDGE2
.else
   LDA zp_seg_flags
   LSR A                                   ; C = bit 0 = APEDGE2
   BCC as_done
.endif
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
; ref = rot5(-p_int) + count fracs. The position rides rot_w_pages too
; (2026-08-11): d = -p_int - (frac != 0) per axis (the off-by-one
; borrow seed — see the 2026-08-10 fix — lives HERE now), page-
; decomposed exactly like a vertex. br_to_view and the whole legacy
; rot machinery died with this.
   LDA #0
   SEC
   SBC zp_br_px                            ; C = (px frac == 0); result dead
   LDA #0
   SBC zp_br_px_h
   STA zp_ri_d_l                           ; ox = d & 255
   LDA #0
   SBC zp_br_px_x
   CLC
   ADC #2
   AND #3
   STA zp_br_t2                            ; pxi
   LDA #0
   SEC
   SBC zp_br_py                            ; C = (py frac == 0)
   LDA #0
   SBC zp_br_py_h
   STA zp_br_dy_l                          ; oy = d & 255
   LDA #0
   SBC zp_br_py_x
   CLC
   ADC #2
   AND #3
   ASL A
   ASL A
   ORA zp_br_t2
   STA zp_ri_d_h                           ; page nibble
::vf_rwp:
   JSR rot_w_pages                         ; SMC: rot_select picks the body
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
; (The sin/cos/pair VARIANT SELECTION died 2026-08-11 with the legacy
; rot machinery: rot_w_pages + its cardinal twins are the only rotate
; bodies, and everything below is angle-gated.)
; --- PAGE-DECOMPOSED w-path (Eben's concept, 2026-08-11): mag + sign
; + body-dispatch SMC patches + the PB table build, ALL gated on
; (rwp_stamp == $A5 AND angle unchanged). The stamp lives IN THE CODE
; IMAGE (assembled 0), so any code reload self-invalidates the gate —
; the every-frame-patch tax this replaced existed only for the
; harness reload case (Eben's catch: real game cost for testbench
; convenience). Standing/translation frames pay ~20 cyc here.
; Signs: vx = PB_X +sgn(s) P1 -sgn(c) P2; vy = PB_Y +sgn(c) P3
; +sgn(s) P4 — CLC/ADC ($18/$65) vs SEC/SBC ($38/$E5) opcode pairs. ---
   LDA rwp_stamp
   CMP #$A5
   BNE rwp_fresh                           ; fresh/reloaded code image
   LDA bca_ab
   CMP PB_PREV_AB
   BNE rwp_repatch                         ; new epoch
   JMP inl_end
rwp_fresh:
; fresh image: ALSO (re)build the 32-byte SQR_MIRROR prefix below
; sqr_l (boot zeroing / image reloads wipe it): SQR_MIRROR+k =
; sqr_l[32-k] — f is even. Runs once per image, ~420 cyc.
   LDX #31
   LDY #1
rwm_fill:
   LDA sqr_l,Y
   STA SQR_MIRROR,X
   INY
   DEX
   BPL rwm_fill
rwp_repatch:
   LDA bca_ab
   STA PB_PREV_AB
   LDA #$A5
   STA rwp_stamp
; mags: sin -> muls 1/4, cos -> muls 2/3 (operand + both table bases).
; EFFECTIVE values: unity stages as (mag=0, one=1) but mag5 unity = 32
; FITS the u8 quarter-square (sqr index <= 255+32) — the general body
; handles unity through the mul (Eben's call), and the 5-BIT UNITY
; BAND IS WIDE: near-cardinals (e.g. ab=252) have cos = unity with
; sin NONZERO, so unity does NOT imply the partner is zero.
   LDA zp_br_smag
   LDX zp_br_sone
   BEQ :+
   LDA #32
:  STA rwp_s1l+1                           ; sum bases (page-aligned trick)
   STA rwp_s1h+1
   STA rwp_s4l+1
   STA rwp_s4h+1
   TAX                                     ; X = eff sin mag
   LDA #0
   SEC
   SBC rwp_s1l+1                           ; A = (-mag) & 255: the diff-LO
   STA rwp_d1l+1                           ; base lo (hi constant, mag>=1)
   STA rwp_d4l+1
   LDA #<(SQD_H+32)
   SEC
   STX zp_br_t2
   SBC zp_br_t2
   STA rwp_d1h+1
   STA rwp_d4h+1
   LDA #>(SQD_H+32)
   SBC #0
   STA rwp_d1h+2
   STA rwp_d4h+2
   LDA zp_br_cmag
   LDX zp_br_cone
   BEQ :+
   LDA #32
:  STA rwp_s2l+1
   STA rwp_s2h+1
   STA rwp_s3l+1
   STA rwp_s3h+1
   TAX
   LDA #0
   SEC
   SBC rwp_s2l+1
   STA rwp_d2l+1
   STA rwp_d3l+1
   LDA #<(SQD_H+32)
   SEC
   STX zp_br_t2
   SBC zp_br_t2
   STA rwp_d2h+1
   STA rwp_d3h+1
   LDA #>(SQD_H+32)
   SBC #0
   STA rwp_d2h+2
   STA rwp_d3h+2
; sign opcodes: terms 1/4 follow sin, term 3 follows cos, term 2 is
; INVERTED cos (the -cos in vx)
   LDX #$18
   LDY #$65                                ; positive: CLC / ADC zp
   LDA zp_br_sneg
   BEQ rwp_sp
   LDX #$38
   LDY #$E5                                ; negative: SEC / SBC zp
rwp_sp:
   STX rwp_o1s
   STX rwp_o4s
   TYA
   STA rwp_o1l
   STA rwp_o1h
   STA rwp_o4l
   STA rwp_o4h
   LDX #$18
   LDY #$65
   LDA zp_br_cneg
   BEQ rwp_cp
   LDX #$38
   LDY #$E5
rwp_cp:
   STX rwp_o3s
   TYA
   STA rwp_o3l
   STA rwp_o3h
; term 2 = inverted cos sign
   LDX #$38
   LDY #$E5
   LDA zp_br_cneg
   BEQ rwp_ci
   LDX #$18
   LDY #$65
rwp_ci:
   STX rwp_o2s
   TYA
   STA rwp_o2l
   STA rwp_o2h
; --- PB tables (same gate: a rebuild here is rare and cheap enough
; to ride the patch path even when only the code image was reloaded —
; the tables are recomputed from the same staged trig) ---
; --- contrib tables: Ts[k] = (k-2)*256*sin_signed, Tc[k] likewise ---
; entry layout: lo/hi interleaved (k*2). (k-2) in {-2,-1,0,+1}:
; T[2]=0, T[3]=+m<<8, T[1]=-(m<<8), T[0]=-(m<<9); sign flips all.
; EFFECTIVE mags: the stagers encode unity as (mag=0, one=1) — the
; tables want 32 there (Eben's unity/zero catch, 2026-08-11).
   LDA zp_br_smag
   LDX zp_br_sone
   BEQ :+
   LDA #32
:  LDX zp_br_sneg
   LDY #0
   JSR rwp_contrib                         ; -> PB_TS (A=mag, X=neg, Y=off)
   LDA zp_br_cmag
   LDX zp_br_cone
   BEQ :+
   LDA #32
:  LDX zp_br_cneg
   LDY #8                                  ; dest offset: PB_TC = PB_TS+8
   JSR rwp_contrib
; --- the 16 combines: PB_X[pg] = Ts[pgx] - Tc[pgy],
;                      PB_Y[pg] = Tc[pgx] + Ts[pgy] ---
   LDX #15
rwp_pg:
   TXA
   AND #3
   ASL A
   TAY                                     ; Y = pgx*2
   LDA PB_TS,Y
   STA zp_br_t2                            ; Ts[pgx] lo
   LDA PB_TS+1,Y
   STA zp_br_t3
   LDA PB_TC,Y
   STA zp_ri_d_l                           ; Tc[pgx] lo
   LDA PB_TC+1,Y
   STA zp_ri_d_h
   TXA
   AND #$0C
   LSR A
   TAY                                     ; Y = pgy*2
   SEC
   LDA zp_br_t2
   SBC PB_TC,Y
   STA PB_XL,X
   LDA zp_br_t3
   SBC PB_TC+1,Y
   STA PB_XH,X
   CLC
   LDA zp_ri_d_l
   ADC PB_TS,Y
   STA PB_YL,X
   LDA zp_ri_d_h
   ADC PB_TS+1,Y
   STA PB_YH,X
   DEX
   BPL rwp_pg
rwd_dispatch:
; --- body dispatch (Eben's unity/zero catch): cardinal epochs (one
; trig ZERO, the other UNITY at mag5 scale) swap the whole body so the
; zero muls never run and unity is a splice. Patch the five rot-w JSR
; sites + the chosen cardinal body's sign ops. ---
   LDA zp_br_sone
   BEQ rwd_notsu
   LDA zp_br_cmag
   ORA zp_br_cone
   BEQ rwd_su                              ; sin unity AND cos TRUE ZERO
rwd_notsu:
   LDA zp_br_cone
   BEQ rwd_gen
   LDA zp_br_smag
   ORA zp_br_sone
   BEQ rwd_cu                              ; cos unity AND sin TRUE ZERO
rwd_gen:
   LDA #<rot_w_pages
   LDX #>rot_w_pages
   BNE rwd_patch                           ; (hi never 0: always)
rwd_su:
; sin = +-32, cos = 0: both terms follow sin's sign
   LDX #$18
   LDY #$65
   LDA zp_br_sneg
   BEQ :+
   LDX #$38
   LDY #$E5
:  STX rwc_s1s
   STX rwc_s2s
   TYA
   STA rwc_s1l
   STA rwc_s1h
   STA rwc_s2l
   STA rwc_s2h
   LDA #<rwp_card_su
   LDX #>rwp_card_su
   BNE rwd_patch
rwd_cu:
; cos = +-32, sin = 0: vx term = INVERTED cos sign (-c*oy), vy = +c*ox
   LDX #$38
   LDY #$E5
   LDA zp_br_cneg
   BEQ :+
   LDX #$18
   LDY #$65
:  STX rwc_c1s
   TYA
   STA rwc_c1l
   STA rwc_c1h
   LDX #$18
   LDY #$65
   LDA zp_br_cneg
   BEQ :+
   LDX #$38
   LDY #$E5
:  STX rwc_c2s
   TYA
   STA rwc_c2l
   STA rwc_c2h
   LDA #<rwp_card_cu
   LDX #>rwp_card_cu
rwd_patch:
   STA sxv0_rwpa+1
   STX sxv0_rwpa+2
   STA sxv0_rwpb+1
   STX sxv0_rwpb+2
   STA sxv1_rwpa+1
   STX sxv1_rwpa+2
   STA sxv1_rwpb+1
   STX sxv1_rwpb+2
   STA cr_rwp+1
   STX cr_rwp+2
   STA vf_rwp+1
   STX vf_rwp+2
inl_end:
.endscope
.endmacro

