
; ============================================================================
; box_classify — ONE pass of box-vs-viewer subtractions yields both the
; inside test and the checkcoord classification (the old ins_test + box_pos
; pair recomputed the same comparisons in opposite directions: 8 s16
; subtracts; this does at most 4).
;
;   X <- boxpos = boxy*4 + boxx
;     boxx: 0 if px<=left,  1 if px<right,  else 2   (px==right -> 1,
;     boxy: 0 if py>=top,   1 if py>bot,    else 2    py==bot  -> 1 —
;     both preserved from the original box_pos exactly)
;   inside (px-left>=0 && right-px>=0 && py-bot>=0 && top-py>=0):
;     sets vis=1/ilo=0/ihi=255 and returns STRAIGHT to
;     bbox_check_angle's caller (double-RTS pull), like the old ins_test.
;
; Derivation (d = px-left, e = right-px, f = py-top, g = py-bot):
;   boxx = 0 iff d<=0 ; 2 iff e<0 ; else 1.   inside-x iff d>=0 && e>=0
;     (d==0 implies e>0 since left<right, so the d==0 arm skips e).
;   boxy = 0 iff f>=0 ; 2 iff g<0 ; else 1.   inside-y iff f<=0 && g>=0
;     (f==0 implies g>0 since bot<top).
; ============================================================================
box_classify:
.scope
; Side-armed plane reads (2026-07-15): the box pointer is gone — each
; arm bakes its side's plane pages and reads abs,Y with Y = node,
; reloaded per field pair (Y doubles as the raw-hi ride between).
; Logic, flags and exits are byte-for-byte the old classify.
   LDA #0
   STA t1                                  ; outside flag
   LDA zp_bbox_side
   BNE bcls_s1_j
   JMP bcls_s0
bcls_s1_j:
   JMP bcls_s1
; ---- side s0 arm (plane operands baked; Y = node per read pair,
; then freed for the raw-hi ride exactly as before) ----
bcls_s0:
; --- d = px - left ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pxs
   SBC BBP_L_LO,Y
   TAX                                     ; d lo rides X
   LDA bca_pxs+1
   SBC BBP_L_HI,Y
   TAY                                     ; raw hi (zero test; Y re-seeds below)
   BVC c1_s0
   EOR #$80
c1_s0:
   BMI cx_x0_out_s0
   CPY #0
   BNE cx_x_pos_s0
   TXA
   BNE cx_x_pos_s0
   BEQ cx_have_x_s0
cx_x0_out_s0:
   INC t1
   LDA #0
   BEQ cx_have_x_s0
cx_x_pos_s0:
; --- e = right - px (sign only) ---
   LDY zp_node_ch_l
   SEC
   LDA BBP_R_LO,Y
   SBC bca_pxs
   LDA BBP_R_HI,Y
   SBC bca_pxs+1
   BVC c2_s0
   EOR #$80
c2_s0:
   BMI cx_x2_out_s0
   LDA #1
   BNE cx_have_x_s0
cx_x2_out_s0:
   INC t1
   LDA #2
cx_have_x_s0:
   STA t0                                  ; boxx
; --- f = py - top ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pys
   SBC BBP_T_LO,Y
   TAX                                     ; f lo rides X
   LDA bca_pys+1
   SBC BBP_T_HI,Y
   TAY                                     ; raw hi
   BVC c3_s0
   EOR #$80
c3_s0:
   BMI cx_y_low_s0
   CPY #0
   BNE cx_y0_out_s0
   TXA
   BNE cx_y0_out_s0
   BEQ cx_have_y_s0
cx_y0_out_s0:
   INC t1
   LDA #0
   BEQ cx_have_y_s0
cx_y_low_s0:
; --- g = py - bot (sign only) ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pys
   SBC BBP_B_LO,Y
   LDA bca_pys+1
   SBC BBP_B_HI,Y
   BVC c4_s0
   EOR #$80
c4_s0:
   BMI cx_y2_out_s0
   LDA #1
   BNE cx_have_y_s0
cx_y2_out_s0:
   INC t1
   LDA #2
cx_have_y_s0:
   JMP cx_compose
; ---- side s1 arm (plane operands baked; Y = node per read pair,
; then freed for the raw-hi ride exactly as before) ----
bcls_s1:
; --- d = px - left ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pxs
   SBC BBP_L_LO+$100,Y
   TAX                                     ; d lo rides X
   LDA bca_pxs+1
   SBC BBP_L_HI+$100,Y
   TAY                                     ; raw hi (zero test; Y re-seeds below)
   BVC c1_s1
   EOR #$80
c1_s1:
   BMI cx_x0_out_s1
   CPY #0
   BNE cx_x_pos_s1
   TXA
   BNE cx_x_pos_s1
   BEQ cx_have_x_s1
cx_x0_out_s1:
   INC t1
   LDA #0
   BEQ cx_have_x_s1
cx_x_pos_s1:
; --- e = right - px (sign only) ---
   LDY zp_node_ch_l
   SEC
   LDA BBP_R_LO+$100,Y
   SBC bca_pxs
   LDA BBP_R_HI+$100,Y
   SBC bca_pxs+1
   BVC c2_s1
   EOR #$80
c2_s1:
   BMI cx_x2_out_s1
   LDA #1
   BNE cx_have_x_s1
cx_x2_out_s1:
   INC t1
   LDA #2
cx_have_x_s1:
   STA t0                                  ; boxx
; --- f = py - top ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pys
   SBC BBP_T_LO+$100,Y
   TAX                                     ; f lo rides X
   LDA bca_pys+1
   SBC BBP_T_HI+$100,Y
   TAY                                     ; raw hi
   BVC c3_s1
   EOR #$80
c3_s1:
   BMI cx_y_low_s1
   CPY #0
   BNE cx_y0_out_s1
   TXA
   BNE cx_y0_out_s1
   BEQ cx_have_y_s1
cx_y0_out_s1:
   INC t1
   LDA #0
   BEQ cx_have_y_s1
cx_y_low_s1:
; --- g = py - bot (sign only) ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pys
   SBC BBP_B_LO+$100,Y
   LDA bca_pys+1
   SBC BBP_B_HI+$100,Y
   BVC c4_s1
   EOR #$80
c4_s1:
   BMI cx_y2_out_s1
   LDA #1
   BNE cx_have_y_s1
cx_y2_out_s1:
   INC t1
   LDA #2
cx_have_y_s1:
   JMP cx_compose
cx_compose:
; X = boxy*4 + boxx
   ASL A
   ASL A
   CLC
   ADC t0
   TAX
   LDA t1
   BEQ cx_inside
   RTS
cx_inside:
; inside -> full result; discard box_classify's return, exit to
; bbox_check_angle's caller through the canonical tail (A/Z = verdict).
   PLA
   PLA
   JMP full_vis
.endscope

; (load_val removed: inlined at the corner loads.)

; ============================================================================
; corner_phi — signed view-relative angle (phi) of one box corner.
;   in : pa_dx/pa_dy (s16 = corner - viewer int pos, loaded by the caller),
;        bca_afn (a_fine, frame-constant)
;   out: pa_res = r (u12; see cp_havepsi)
;        clobbers sd_num/sd_den/sd_q, pa_sx/pa_sy/pa_ptr (oct rides X)
;   phi = sign_extend((a_fine - psi) & 4095), psi = point_to_angle(dx,dy).
; point_to_angle (angle_bbox.py) is INLINED below — corner_phi is its sole
; caller. pseudocode:
;   if dx == 0 and dy == 0: psi = 0
;   num = min(|dx|,|dy|) ; den = max(|dx|,|dy|)       # first-octant fold
;   oct = (dx<0)*4 | (dy<0)*2 | (|dx|>|dy|)
;   ta  = tantoangle[slope_div(num,den)]              # sd_q==1024 -> ANG45
;   psi = (base[oct] +/- ta) & 4095                   # tables in header_div.s
; ============================================================================
; corner_phi: dx=cx-pxs, dy=cy-pys; point_to_angle; pa_res=(afn-psi)&MASK signed
; corner_phi: callers load pa_dx/pa_dy directly (box corner minus viewer).
corner_phi:
.scope
; --- inlined point_to_angle(pa_dx,pa_dy) -> pa_res (psi) ---
; .pa_entry: unit-test hook -- jump here with pa_dx/pa_dy set and
; bca_afn=0 to read back (-psi)&signed in pa_res (see test_slope_div).
pa_entry:
; --- corner-phi MEMO probe (2026-07-17 prototype): within a frame the
; same box corner (same pa_dx/pa_dy against the fixed viewer) recurs on
; ~34% of calls — parents and siblings share box corners. 128-slot xor
; hash (98% of ideal hits on the suite corpus); EXACT by construction:
; a hit requires the full 4-byte key match, collisions just evict.
; Tables via abi.inc (banked $8E00 L2 window / flat $5400 CODE-tail
; carve); per-slot epoch tag vs zp_cpm_frame (view_setup increments and
; wipes the tag page on the 256-frame wrap). Bare-boot note: tag pages
; ship zeroed in the bank image; a garbage frame counter can only
; false-hit the all-zero key (corner 0,0), whose cached psi 0 IS the
; exact answer — benign by coincidence, exact either way.
   LDA pa_dx
   EOR pa_dy
   AND #$7F
   TAX
   LDA CPM_EP,X
   CMP zp_cpm_frame
   BNE cpm_miss
   LDA CPM_KDXL,X
   CMP pa_dx
   BNE cpm_miss
   LDA CPM_KDXH,X
   CMP pa_dx+1
   BNE cpm_miss
   LDA CPM_KDYL,X
   CMP pa_dy
   BNE cpm_miss
   LDA CPM_KDYH,X
   CMP pa_dy+1
   BNE cpm_miss
   LDA CPM_PSIL,X                          ; HIT: cached psi -> pa_res and
   STA pa_res                              ; straight to the afr tail — the
   LDA CPM_PSIH,X                          ; whole abs/oct/slope_div/tanto
   STA pa_res+1                            ; core is skipped
   JMP cp_havepsi
cpm_miss:
   LDA pa_dx
   ORA pa_dx+1
   ORA pa_dy
   ORA pa_dy+1
   BNE nz
   LDA #0
   STA pa_res
   STA pa_res+1
   JMP cp_havepsi
; zero -> psi=0 (was RTS)
nz:
; |dx| -> sd_num, sx = (dx<0)  (abs written straight to the divide operands;
; if |dx|>|dy| we swap below so sd_num=min, sd_den=max -- no separate copy).
   LDA pa_dx+1
   BPL dxp
   LDA #4                                  ; sx pre-shifted for the oct fold
   STA pa_sx
   LDA #0
   SEC
   SBC pa_dx
   STA sd_num
   LDA #0
   SBC pa_dx+1
   STA sd_num+1
   JMP dxd
dxp:
   LDA #0
   STA pa_sx
   LDA pa_dx
   STA sd_num
   LDA pa_dx+1
   STA sd_num+1
dxd:
; |dy| -> sd_den, sy = (dy<0)
   LDA pa_dy+1
   BPL dyp
   LDA #2                                  ; sy pre-shifted for the oct fold
   STA pa_sy
   LDA #0
   SEC
   SBC pa_dy
   STA sd_den
   LDA #0
   SBC pa_dy+1
   STA sd_den+1
   JMP dyd
dyp:
   LDA #0
   STA pa_sy
   LDA pa_dy
   STA sd_den
   LDA pa_dy+1
   STA sd_den+1
dyd:
; axgt = (|dx| > |dy|): now sd_num=|dx|, sd_den=|dy|.
   LDA sd_den+1
   CMP sd_num+1
   BCC axgt
; |dy|<|dx| -> |dx|>|dy|
   BNE axle
   LDA sd_den
   CMP sd_num
   BEQ pa_equal                            ; |dx|==|dy|: exact diagonal
   BCS axle
; |dy|>=|dx| -> not axgt
axgt:
; |dx| > |dy|: swap so sd_num=|dy|(min), sd_den=|dx|(max); axgt bit=1
   LDA sd_num
   LDX sd_den
   STA sd_den
   STX sd_num
   LDA sd_num+1
   LDX sd_den+1
   STA sd_den+1
   STX sd_num+1
   LDA #1
   JMP haveax
pa_equal:
; |dx| == |dy|: sd_q would be exactly 1024 -> ta = ANG45 = 512 directly,
; no divide, no table. This divert is what lets haveax call slope_div_le
; (strict num<den) and drop the old post-divide q==1024 check. Ties fold
; as |dx|<=|dy| (axgt=0), matching the BCS the equal case used to take.
   LDA pa_sy
   ORA pa_sx
   TAX
   LDA #<512
   STA pa_res
   LDA #>512
   STA pa_res+1
   JMP comb
axle:
; |dx| <= |dy|: sd_num=|dx|(min), sd_den=|dy|(max) already; axgt bit=0
   LDA #0
haveax:
; oct = sx(0/4) | sy(0/2) | axgt(0/1) — signs stored pre-shifted.
; oct RIDES X to comb (dead-write tracker, 2026-07-11): slope_div's fast
; paths never touch X (the slow path's counter moved to Y to keep this
; contract) and neither does the tantoangle lookup.
   ORA pa_sy
   ORA pa_sx
   TAX
   JSR slope_div_le                        ; -> sd_q (0..1023); preserves X
; (num < den strictly here — pa_equal diverted the diagonal — so q fits
; the 1024-entry tantoangle and the old q==1024 check is gone.)
pa_lookup:
; ta = tantoangle[sd_q]. TA_LO/TA_HI are page-aligned (asserted), so
; the index lo byte rides Y and pa_ptr's lo byte is PERMANENTLY ZERO
; (established once per frame in br_view_setup; the VATOX tail rides
; the same invariant). q_hi <= 3, so neither hi add can wrap — the
; page-delta hop's carry-in is the first add's known-0 carry-out.
   .assert (TA_LO & $FF) = 0, error, "TA_LO must be page-aligned"
   .assert (TA_HI & $FF) = 0, error, "TA_HI must be page-aligned"
   LDY sd_q
   LDA sd_q+1
   CLC
   ADC #>TA_LO
   STA pa_ptr+1
   LDA (pa_ptr),Y
   STA pa_res
   LDA pa_ptr+1                            ; (C=0: >TA_LO + q_hi can't wrap)
   ADC #(>TA_HI - >TA_LO)
   STA pa_ptr+1
   LDA (pa_ptr),Y
   STA pa_res+1
comb:
; res = base[oct] +/- ta  (& MASK). The octant bases are multiples of 256
; (0/1024/2048/3072), so base_lo is always 0. X = oct (from haveax).
; The 12-bit mask folds into each arm — the old shared mask block
; re-loaded the byte the arm had just stored.
   LDA pa_sign,X
   BMI sub
; add: res = base + ta ; low byte (= ta) unchanged since base_lo = 0
   CLC
   LDA pa_base_hi,X
   ADC pa_res+1
   AND #$0F
   STA pa_res+1
   JMP mask_done
sub:
; sub: res = base - ta ; base_lo = 0
   SEC
   LDA #0
   SBC pa_res
   STA pa_res
   LDA pa_base_hi,X
   SBC pa_res+1
   AND #$0F
   STA pa_res+1
mask_done:
; & 4095 (psi ready; was RTS->fall through)
; --- memo STORE (X = oct is dead after comb; recompute the slot) ---
   LDA pa_dx
   EOR pa_dy
   AND #$7F
   TAX
   LDA pa_dx
   STA CPM_KDXL,X
   LDA pa_dx+1
   STA CPM_KDXH,X
   LDA pa_dy
   STA CPM_KDYL,X
   LDA pa_dy+1
   STA CPM_KDYH,X
   LDA pa_res
   STA CPM_PSIL,X
   LDA pa_res+1
   STA CPM_PSIH,X
   LDA zp_cpm_frame
   STA CPM_EP,X
.endscope
; --- afn - psi, mask to u12 (file-global: reused by the rotation
;     cache's warm path to re-derive r from cached psi) ---
;   in : pa_res = psi (u12 fineangle), bca_afn = a_fine+512 (frame-
;        constant, pre-biased — view.s)
;   out: pa_res = r = (phi+512) & 4095, PURE U12 (hi in [0,$0F])
; NOT sign-extended (2026-07-16): every consumer does mod-4096
; arithmetic — bca_tail's window tests compare the u12 hi directly
; (their AND #$0F re-folds died with the extension), the span/negate/
; psi-store chains mask or nibble-shift their own hi — so the old
; CMP #8 / SBC #$10 wrap was 4 dead cycles per corner.
; RETURNS r hi in A, lo in Y (dead-write tracker 2026-07-11: every
; caller immediately copied pa_res out — the register return drops both
; loads at all six sites). pa_res is STILL stored: the test hooks
; (test_slope_div) read it from memory, and psi-hi feeds the SBC below.
cp_havepsi:
   SEC
   LDA bca_afn
   SBC pa_res
   STA pa_res
   TAY                                     ; r lo rides Y to the caller
   LDA bca_afn+1
   SBC pa_res+1
   AND #$0F                                ; r & 4095 (hi nibble) — u12, done
   STA pa_res+1                            ; (A still = r hi at RTS)
   RTS

; checkcoord[boxpos*4]: indices into (top=0,bot=1,left=2,right=3).
; rows 3,7,11 and 5 unused (5=inside handled earlier).
; checkcoord indices PRE-DOUBLED (byte offsets into the s16 box: top=0,
; bot=2, left=4, right=6) so the corner loads index (bca_boxp),Y directly.
; (bca_cc retired 2026-07-15: the checkcoord rows are BAKED into the
; zone/side corner arms below.)

; ============================================================================
; zc_corners — raw silhouette corner phis via zone/side arms (ZC segment
; in the CODE region — the carve freed by the RCACHE plane conversion).
;   in : X = boxpos (0..10, box_classify), zp_bbox_side, zp_node_ch_l,
;        bca_pxs/pys, bca_afn
;   out: bca_p1/p2 = RAW phi1/phi2 (pre-clip — rcache snapshots these)
; Each arm is the old cc-row corner block with the four plane operands
; baked (checkcoord: corner1 = LEFT silhouette, corner2 = RIGHT).
; RTS-dispatch: the arm's RTS returns to zc_corners' caller.
; ============================================================================
.segment "ZC"
.macro ZCF s, xl, yl
   LDY zp_node_ch_l
   SEC
   LDA xl+(s)*$100,Y
   SBC bca_pxs
   STA pa_dx
   LDA xl+$200+(s)*$100,Y
   SBC bca_pxs+1
   STA pa_dx+1
   SEC
   LDA yl+(s)*$100,Y
   SBC bca_pys
   STA pa_dy
   LDA yl+$200+(s)*$100,Y
   SBC bca_pys+1
   STA pa_dy+1
.endmacro
.macro ZARM s, x1, y1, x2, y2
   ZCF s, x1, y1
   JSR corner_phi
   STA bca_p1+1
   STY bca_p1
   ZCF s, x2, y2
   JSR corner_phi
   STA bca_p2+1
   STY bca_p2
   RTS
.endmacro
zc_corners:
   TXA                                     ; X = boxpos
   ASL A
   ORA zp_bbox_side
   TAX
   LDA zc_tab_hi,X
   PHA
   LDA zc_tab_lo,X
   PHA
   RTS                                     ; dispatch; arm RTSes to our caller
; checkcoord rows (x = L/R plane, y = T/B plane); rows 3/5/7 unused
zc0_0:  ZARM 0, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO
zc0_1:  ZARM 1, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO
zc1_0:  ZARM 0, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_T_LO
zc1_1:  ZARM 1, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_T_LO
zc2_0:  ZARM 0, BBP_R_LO, BBP_B_LO, BBP_L_LO, BBP_T_LO
zc2_1:  ZARM 1, BBP_R_LO, BBP_B_LO, BBP_L_LO, BBP_T_LO
zc4_0:  ZARM 0, BBP_L_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO
zc4_1:  ZARM 1, BBP_L_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO
zc6_0:  ZARM 0, BBP_R_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO
zc6_1:  ZARM 1, BBP_R_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO
zc8_0:  ZARM 0, BBP_L_LO, BBP_T_LO, BBP_R_LO, BBP_B_LO
zc8_1:  ZARM 1, BBP_L_LO, BBP_T_LO, BBP_R_LO, BBP_B_LO
zc9_0:  ZARM 0, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_B_LO
zc9_1:  ZARM 1, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_B_LO
zc10_0: ZARM 0, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO
zc10_1: ZARM 1, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO
zc_tab_lo:
   .byte <(zc0_0-1),<(zc0_1-1),<(zc1_0-1),<(zc1_1-1),<(zc2_0-1),<(zc2_1-1)
   .byte <(zc0_0-1),<(zc0_1-1)             ; row 3 unused
   .byte <(zc4_0-1),<(zc4_1-1)
   .byte <(zc0_0-1),<(zc0_1-1)             ; row 5 unused
   .byte <(zc6_0-1),<(zc6_1-1)
   .byte <(zc0_0-1),<(zc0_1-1)             ; row 7 unused
   .byte <(zc8_0-1),<(zc8_1-1),<(zc9_0-1),<(zc9_1-1),<(zc10_0-1),<(zc10_1-1)
zc_tab_hi:
   .byte >(zc0_0-1),>(zc0_1-1),>(zc1_0-1),>(zc1_1-1),>(zc2_0-1),>(zc2_1-1)
   .byte >(zc0_0-1),>(zc0_1-1)
   .byte >(zc4_0-1),>(zc4_1-1)
   .byte >(zc0_0-1),>(zc0_1-1)
   .byte >(zc6_0-1),>(zc6_1-1)
   .byte >(zc0_0-1),>(zc0_1-1)
   .byte >(zc8_0-1),>(zc8_1-1),>(zc9_0-1),>(zc9_1-1),>(zc10_0-1),>(zc10_1-1)

.if BANKED
.segment "ANG_BK"                       ; back to the angle-module segment
.else
.segment "ANG"
.endif



end:
.if BANKED
; (ld65 writes this: SAVE "bsp_render_ang_bk.bin", $3400, end, $3400)
.else
.assert end <= TA_HI, error             ; code must not grow into the relocated tables ($F200+)
; (ld65 writes this: SAVE "bsp_render_ang.bin", $E940, end, $E940)
.endif

