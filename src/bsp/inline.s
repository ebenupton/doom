; ============================================================================
; bsp/inline.s — single-caller function bodies, inlined as MACROS
; (2026-07-17 sweep: jump-table-era JSR/RTS pairs on single-caller
; functions were pure overhead — each body now expands at its one call
; site; early RTS exits became JMPs to the expansion end, tail calls
; that rode the JSR return address became explicit JSRs, and INTERNAL
; subroutines keep their RTSs — those return to
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


; (cross_compute / cross_umul_u8_s16 DELETED 2026-08-09: EV16 —
; the crossing lives openly in lo.s reproject_at_crossing now, on s24
; recovered totals; the s8 evy/evx tier died with them.)




; (chain_reuse_v1 moved BODILY into subsector.s 2026-07-26 — single
; site, no reason for the macro indirection.)


; (ev_clamp_hi_nz macro RETIRED 2026-08-09 — inlined at its single use,
;  the ec_hi_nz island in seg_xform.s SXV_BODY.)

; (vrcache_cold_store macro RETIRED 2026-08-09 — the birth store is inlined
;  per side in the seg_xform.s vrcache_on islands, side baked; the generic
;  senior-test form died with it.)

.macro vrcache_frame
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
; quantized to counts in view_setup; ref rounds ONCE per axis,
; exactly the mirror's rns(ref_88, 3). ---
   CLC
   LDA zp_br_vx_l
   ADC zp_br_fvx_l
   STA vrcache_ref_x+0
   LDA zp_br_vx_h
   ADC zp_br_fvx_h
   STA vrcache_ref_x+1
   CLC
   LDA zp_br_vy_l
   ADC zp_br_fvy_l
   STA vrcache_ref_y+0
   LDA zp_br_vy_h
   ADC zp_br_fvy_h
   STA vrcache_ref_y+1
   LDA VRCACHE_ENABLE
   STA zp_vrcache_on                           ; kept for harness/tools AND
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
   LDA #<sxv0_vrcache_on
   STA zp_vf_vec0
   LDA #>sxv0_vrcache_on
   STA zp_vf_vec0+1
   LDA #<sxv1_vrcache_on
   STA zp_vf_vec1
   LDA #>sxv1_vrcache_on
   STA zp_vf_vec1+1
   LDA vrcache_ab
   CMP vrcache_prev_ab
   BEQ vf_patch
; --- angle changed: new epoch - wipe the valid bitmap ---
; STRIPED, 57 B (2026-08-13: the exact 455-id extent — 19 stores x 3
; iterations, ~300 cyc vs the old 12x5's ~325, every rotation frame).
   STA vrcache_prev_ab
   LDA #0
   LDX #2
vf_wl:
   STA VRCACHE_VALID,X
   STA VRCACHE_VALID+3,X
   STA VRCACHE_VALID+6,X
   STA VRCACHE_VALID+9,X
   STA VRCACHE_VALID+12,X
   STA VRCACHE_VALID+15,X
   STA VRCACHE_VALID+18,X
   STA VRCACHE_VALID+21,X
   STA VRCACHE_VALID+24,X
   STA VRCACHE_VALID+27,X
   STA VRCACHE_VALID+30,X
   STA VRCACHE_VALID+33,X
   STA VRCACHE_VALID+36,X
   STA VRCACHE_VALID+39,X
   STA VRCACHE_VALID+42,X
   STA VRCACHE_VALID+45,X
   STA VRCACHE_VALID+48,X
   STA VRCACHE_VALID+51,X
   STA VRCACHE_VALID+54,X
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
; (the fresh-image 32-byte mirror rebuild died 2026-09-01: the full
; even-mirror pages are boot-generated DATA at $0200/$0500 — code
; reloads do not touch them)
rwp_repatch:
   LDA bca_ab
   STA PB_PREV_AB
   LDA #$A5
   STA rwp_stamp
; mags (t16p2, 2026-09-01): full 8-bit M per trig, sum bases SQR_LO/
; SQR_HI + M (2-byte pokes: lo = staged mag byte = M & 255 — unity
; stages 0 — hi = base hi + one), diff-base LO bytes = (-M) & 255
; (their hi bytes are ASSEMBLED constants: M in 1..256 always lands
; $02xx/$05xx, the mirror pages).  No derivation, no eps, no SQD_H.
   LDA zp_br_smag
   STA rwp_s1l+1
   STA rwp_s1h+1
   STA rwp_s4l+1
   STA rwp_s4h+1
   LDA #0
   SEC
   SBC zp_br_smag
   STA rwp_d1l+1
   STA rwp_d1h+1
   STA rwp_d4l+1
   STA rwp_d4h+1
   LDX #>SQR_LO
   LDY #>SQR_HI
   LDA zp_br_sone
   BEQ :+
   INX                                     ; unity: +$100 on the sum bases
   INY
:  STX rwp_s1l+2
   STX rwp_s4l+2
   STY rwp_s1h+2
   STY rwp_s4h+2
   LDA zp_br_cmag
   STA rwp_s2l+1
   STA rwp_s2h+1
   STA rwp_s3l+1
   STA rwp_s3h+1
   LDA #0
   SEC
   SBC zp_br_cmag
   STA rwp_d2l+1
   STA rwp_d2h+1
   STA rwp_d3l+1
   STA rwp_d3h+1
   LDX #>SQR_LO
   LDY #>SQR_HI
   LDA zp_br_cone
   BEQ :+
   INX
   INY
:  STX rwp_s2l+2
   STX rwp_s3l+2
   STY rwp_s2h+2
   STY rwp_s3h+2
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
   EOR #$0C                                ; $65->$69 / $E5->$E9 (imm twin)
   STA rwp_o1b
   STA rwp_o4b
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
   EOR #$0C
   STA rwp_o3b
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
   EOR #$0C
   STA rwp_o2b
; --- PB tables (same gate: a rebuild here is rare and cheap enough
; to ride the patch path even when only the code image was reloaded —
; the tables are recomputed from the same staged trig) ---
; --- contrib tables: Ts[k] = (k-2)*256*sin_signed, Tc[k] likewise ---
; entry layout: lo/hi interleaved (k*2). (k-2) in {-2,-1,0,+1}:
; T[2]=0, T[3]=+V, T[1]=-V, T[0]=-2V with V = mag8<<5 COUNTS (16-bit
; since 2026-08-31: PB carries the full 8-bit trig -- PX multiples of
; 256 make PX*mag8/8 exact integers).  Unity (mag=0, one=1) -> $2000.
   LDX zp_br_sone
   BEQ :+
   LDA #$20
   STA zp_rs_h
   LDA #0
   STA zp_rs_l
   BEQ :++
:  LDA zp_br_smag                          ; V = mag8 << 5: hi = mag>>3,
   LSR A                                   ; lo = mag << 5
   LSR A
   LSR A
   STA zp_rs_h
   LDA zp_br_smag
   ASL A
   ASL A
   ASL A
   ASL A
   ASL A
   STA zp_rs_l
:  LDX zp_br_sneg
   LDY #0
   JSR rwp_contrib                         ; -> PB_TS (V=zp_rs, X=neg, Y=off)
   LDX zp_br_cone
   BEQ :+
   LDA #$20
   STA zp_rs_h
   LDA #0
   STA zp_rs_l
   BEQ :++
:  LDA zp_br_cmag
   LSR A
   LSR A
   LSR A
   STA zp_rs_h
   LDA zp_br_cmag
   ASL A
   ASL A
   ASL A
   ASL A
   ASL A
   STA zp_rs_l
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

