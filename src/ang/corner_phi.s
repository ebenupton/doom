
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
; Logic, flags and exits are byte-for-byte the old classify — MINUS
; the BVC/EOR V-correction (2026-07-17): the deltas are bounded by the
; prescaled map (~+-1400), s16 never overflows (the ZCF corner
; subtracts never corrected either), so N IS the sign.
; ZONE INHERITANCE (2026-07-17): child box is a subset of the parent
; box (seg-bound nesting survives the monotone prescale+inflate), so a
; STRICT outside verdict inherits: px < left_p => px < left_c, etc.
; zp_par_zone carries the parent box's strict bits (walk-stacked); an
; inherited axis skips its compare ladder ENTIRELY and reproduces the
; old ladder's class + flag byte-exactly (only STRICT bits inherit —
; the d==0/f==0 edge cases never set bits, so the inside test is
; untouched). t1 is now the strict-bit MASK (nonzero == outside, same
; inside test); classify publishes it as zp_bca_zone for the walk to
; pass down.
   LDA zp_par_zone
   STA t1                                  ; inherited bits seed the mask
   BEQ bc_ladders                          ; nothing inherited (38%): ladders
; BOTH axes strict-inherited (27% of classifies): the whole result is a
; 16-byte table of the zone bits — no plane reads at all. Single-axis
; zones read $FF and fall to the ladders (whose inh arms serve the
; known half). zone <= $0F by construction (4 ORA bits).
   TAX
   LDA bc_zone_idx,X
   BMI bc_ladders
   ORA zp_bbox_side
   TAX
   LDA t1
   STA zp_bca_zone                         ; publish = the inherited bits
   LDA zc_tab_hi,X                         ; CHAINED DISPATCH (2026-07-18):
   PHA                                     ; classify exits jump straight to
   LDA zc_tab_lo,X                         ; the corner arm; the arm ends
   PHA                                     ; JMP bca_tail — no JSR/RTS
   RTS                                     ; shuttle through bbox_check_angle
bc_ladders:
   LDA zp_bbox_side
   BNE bcls_s1_j
   JMP bcls_s0
bc_zone_idx:
; zone bits (b0 = strictly-left, b1 = right, b2 = above, b3 = below) ->
; ZC dispatch index (boxy*8 | boxx*2, side ORed in above); $FF = not
; fully inherited. L|A=5 -> row0*2, R|A=6 -> boxx2, L|B=9, R|B=$0A.
   .byte $FF,$FF,$FF,$FF, $FF,$00,$04,$FF, $FF,$10,$14,$FF, $FF,$FF,$FF,$FF
bcls_s1_j:
   JMP bcls_s1
; ---- side s0 arm (plane operands baked; Y = node per read pair,
; then freed for the raw-hi ride exactly as before) ----
bcls_s0:
; --- inherited strict-x? (bits 0/1) ---
   LDA zp_par_zone
   AND #$03
   BEQ inhx_run_s0                      ; nothing strict: run the ladder
   LSR A                                   ; bit0 -> C (strictly left)
   BCS inhx_l_s0
   LDA #4                                  ; strictly right: boxx = 2 (stored pre-doubled)
   BNE inhx_have_s0
inhx_l_s0:
   LDA #0                                  ; strictly left: boxx = 0
inhx_have_s0:
   STA t0
   JMP inhy_s0
inhx_run_s0:
; --- d = px - left ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pxs
   SBC BBP_L_LO,Y
   TAX                                     ; d lo rides X
   LDA bca_pxs+1
   SBC BBP_L_HI,Y
   BMI cx_x0_out_s0                        ; N and Z from the SBC survive the
   BNE cx_x_pos_s0                         ; BMI — the old TAY + CPY #0 were
   TXA                                     ; 4 dead cycles (Eben's catch)
   BNE cx_x_pos_s0
   BEQ cx_have_x_s0
cx_x0_out_s0:
   LDA t1
   ORA #$01                                ; strictly left of the box
   STA t1
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
   BMI cx_x2_out_s0
   LDA #2                                  ; boxx = 1 (pre-doubled)
   BNE cx_have_x_s0
cx_x2_out_s0:
   LDA t1
   ORA #$02                                ; strictly right
   STA t1
   LDA #4                                  ; boxx = 2 (pre-doubled)
cx_have_x_s0:
   STA t0                                  ; boxx
inhy_s0:
; --- inherited strict-y? (bits 2/3) ---
   LDA zp_par_zone
   AND #$0C
   BEQ inhy_run_s0
   AND #$04                                ; strictly above?
   BNE inhy_a_s0
   LDA #2                                  ; strictly below: boxy = 2
   BNE inhy_have_s0
inhy_a_s0:
   LDA #0                                  ; strictly above: boxy = 0
inhy_have_s0:
   JMP cx_compose_s0
inhy_run_s0:
; --- f = py - top ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pys
   SBC BBP_T_LO,Y
   TAX                                     ; f lo rides X
   LDA bca_pys+1
   SBC BBP_T_HI,Y
   BMI cx_y_low_s0                         ; N/Z from the SBC (see the x arm)
   BNE cx_y0_out_s0
   TXA
   BNE cx_y0_out_s0
   BEQ cx_have_y_s0
cx_y0_out_s0:
   LDA t1
   ORA #$04                                ; strictly above
   STA t1
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
   BMI cx_y2_out_s0
   LDA #1
   BNE cx_have_y_s0
cx_y2_out_s0:
   LDA t1
   ORA #$08                                ; strictly below
   STA t1
   LDA #2
cx_have_y_s0:
   JMP cx_compose_s0
; ---- side s1 arm (plane operands baked; Y = node per read pair,
; then freed for the raw-hi ride exactly as before) ----
bcls_s1:
; --- inherited strict-x? (bits 0/1) ---
   LDA zp_par_zone
   AND #$03
   BEQ inhx_run_s1                      ; nothing strict: run the ladder
   LSR A                                   ; bit0 -> C (strictly left)
   BCS inhx_l_s1
   LDA #4                                  ; strictly right: boxx = 2 (stored pre-doubled)
   BNE inhx_have_s1
inhx_l_s1:
   LDA #0                                  ; strictly left: boxx = 0
inhx_have_s1:
   STA t0
   JMP inhy_s1
inhx_run_s1:
; --- d = px - left ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pxs
   SBC BBP_L_LO+$100,Y
   TAX                                     ; d lo rides X
   LDA bca_pxs+1
   SBC BBP_L_HI+$100,Y
   BMI cx_x0_out_s1                        ; N and Z from the SBC survive the
   BNE cx_x_pos_s1                         ; BMI — the old TAY + CPY #0 were
   TXA                                     ; 4 dead cycles (Eben's catch)
   BNE cx_x_pos_s1
   BEQ cx_have_x_s1
cx_x0_out_s1:
   LDA t1
   ORA #$01                                ; strictly left of the box
   STA t1
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
   BMI cx_x2_out_s1
   LDA #2                                  ; boxx = 1 (pre-doubled)
   BNE cx_have_x_s1
cx_x2_out_s1:
   LDA t1
   ORA #$02                                ; strictly right
   STA t1
   LDA #4                                  ; boxx = 2 (pre-doubled)
cx_have_x_s1:
   STA t0                                  ; boxx
inhy_s1:
; --- inherited strict-y? (bits 2/3) ---
   LDA zp_par_zone
   AND #$0C
   BEQ inhy_run_s1
   AND #$04                                ; strictly above?
   BNE inhy_a_s1
   LDA #2                                  ; strictly below: boxy = 2
   BNE inhy_have_s1
inhy_a_s1:
   LDA #0                                  ; strictly above: boxy = 0
inhy_have_s1:
   JMP cx_compose_s1
inhy_run_s1:
; --- f = py - top ---
   LDY zp_node_ch_l
   SEC
   LDA bca_pys
   SBC BBP_T_LO+$100,Y
   TAX                                     ; f lo rides X
   LDA bca_pys+1
   SBC BBP_T_HI+$100,Y
   BMI cx_y_low_s1                         ; N/Z from the SBC (see the x arm)
   BNE cx_y0_out_s1
   TXA
   BNE cx_y0_out_s1
   BEQ cx_have_y_s1
cx_y0_out_s1:
   LDA t1
   ORA #$04                                ; strictly above
   STA t1
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
   BMI cx_y2_out_s1
   LDA #1
   BNE cx_have_y_s1
cx_y2_out_s1:
   LDA t1
   ORA #$08                                ; strictly below
   STA t1
   LDA #2
cx_have_y_s1:
   JMP cx_compose_s1
; X = the ZC dispatch index directly: (boxy*4 + boxx)*2 + side =
; boxy*8 | boxx*2 | side (bits disjoint: boxy*8 = bits 3-4, pre-doubled
; boxx = bits 1-2, side = bit 0 — ORA composes carry-free). The old
; boxpos*4-row value never leaves this unit, so the caller-side
; TXA/ASL/ORA preamble in zc_corners is gone with it.
cx_compose_s1:
   ASL A
   ASL A
   ASL A
   ORA t0
   ORA #1
   TAX
   LDA t1
   STA zp_bca_zone
   BEQ cx_inside
   LDA zc_tab_hi,X                         ; chained dispatch (see fast path)
   PHA
   LDA zc_tab_lo,X
   PHA
   RTS
cx_compose_s0:
   ASL A
   ASL A
   ASL A
   ORA t0
   TAX
   LDA t1
   STA zp_bca_zone                         ; publish the strict bits (the walk
   BEQ cx_inside                           ; hands them to this box's children)
   LDA zc_tab_hi,X                         ; chained dispatch (see fast path)
   PHA
   LDA zc_tab_lo,X
   PHA
   RTS
cx_inside:
; inside -> full: bbox_check_angle is JMP-threaded now (no classify
; frame to discard — the old PLA/PLA died with it); full_vis chains
; has_gap and returns to the check's caller.
   JMP full_vis
.endscope

; (load_val removed: inlined at the corner loads.)

; ============================================================================
; corner_phi — signed view-relative angle (phi) of one box corner.
;   in : pa_dx/pa_dy (s16 = corner - viewer int pos, loaded by the caller),
;        bca_afn (a_fine, frame-constant)
;   out: r in A (hi) / Y (lo), u12; pa_res holds psi (see cp_havepsi)
;        clobbers sd_num/sd_den, pa_sx/pa_sy (oct rides X)
;   r = (a_fine - psi) & 4095, psi = point_to_angle_f(dx,dy).
; point_to_angle_f (angle_bbox.py) is INLINED below — the divide died
; with option F (2026-07-17). pseudocode:
;   if dx == 0 and dy == 0: psi = 0
;   num = min(|dx|,|dy|) ; den = max(|dx|,|dy|)       # first-octant fold
;   oct = (dx<0)*4 | (dy<0)*2 | (|dx|>|dy|)
;   ta  = ATANEXP[L8[den] - L8[num]]                  # log2 pipeline; the
;   psi = (base[oct] +/- ta) & 4095                   # old slope_div +
;                                                     # tantoangle are GONE
; ============================================================================
; corner_phi: dx=cx-pxs, dy=cy-pys; point_to_angle; pa_res=(afn-psi)&MASK signed
; corner_phi: callers load pa_dx/pa_dy directly (box corner minus viewer).
corner_phi:
; (the .scope died 2026-07-18: the sign-class entries below need the
;  internal labels; everything here is file-scoped, no exports)
; --- inlined point_to_angle(pa_dx,pa_dy) -> pa_res (psi) ---
; .pa_entry: unit-test hook -- jump here with pa_dx/pa_dy set and
; bca_afn=0 to read back (-psi)&signed in pa_res (see test_slope_div).
pa_entry:
; --- corner-phi MEMO probe (2026-07-17 prototype): within a frame the
; same box corner (same pa_dx/pa_dy against the fixed viewer) recurs on
; ~34% of calls — parents and siblings share box corners. 128-slot xor
; hash (98% of ideal hits on the suite corpus); EXACT by construction:
; a hit requires the full 4-byte key match, collisions just evict.
; Tables via abi.inc (banked $8E00 L2 window / flat $5480 CODE-tail
; carve). PERSISTENT (2026-07-17, the option-E investigation's real
; find): psi = point_to_angle(dx,dy) is a PURE FUNCTION of the delta
; key — no viewer, no angle, no frame in it — so entries are valid
; FOREVER and hits span frames (rotation changes afn only: the whole
; corner set stays warm). The old per-frame epoch (built for an
; r-caching variant that never landed) is now a boot-validity byte:
; 0 = never written; the tables ship zeroed in the bank image and the
; flat harness zeroes RAM.
   LDA pa_dx
   EOR pa_dy
   AND #$7F
   TAX
   STX zp_cpm_slot                         ; store side reuses the slot (X is
                                           ; clobbered by the miss pipeline)
; The KDXH compare doubles as the validity test: the plane ships
; $80-filled (bank image / engine_load), and $80 is an impossible dx hi
; byte (|corner - px| < 2048 -> hi in [$F8..$07]) — the old EP plane
; (a byte read + branch per probe, a store per miss, and a whole
; 128-byte plane) is gone.
   LDA CPM_KDXH,X
   CMP pa_dx+1
   BNE cpm_miss
   LDA CPM_KDXL,X
   CMP pa_dx
   BNE cpm_miss
   LDA CPM_KDYL,X
   CMP pa_dy
   BNE cpm_miss
   LDA CPM_KDYH,X
   CMP pa_dy+1
   BNE cpm_miss
   LDA CPM_PSIL,X                          ; HIT: cached psi -> pa_res and
   STA pa_res                              ; straight to the afr tail — the
   LDA CPM_PSIH,X                          ; whole abs/oct/log2/atanexp
   STA pa_res+1                            ; core is skipped
   JMP cp_havepsi
cpm_miss:
   LDA pa_dx
   ORA pa_dx+1
   ORA pa_dy
   ORA pa_dy+1
   BNE nz
pa_zero:
   LDA #0
   STA pa_res
   STA pa_res+1
   JMP cp_havepsi
; zero -> psi=0 (was RTS; the sign-class converters JMP pa_zero)
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
; |dx| == |dy|: ta = ANG45 = 512 directly, no lookup. (Historically this
; divert let the divide assume strict num < den; under option F it also
; keeps the log2 pipeline out of the k==L8-equal corner.) Ties fold as
; |dx|<=|dy| (axgt=0), matching the BCS the equal case used to take.
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
; oct RIDES X to comb: nothing in the option-F log2/atanexp pipeline
; below touches X (the divide whose slow arm once needed the counter
; is gone).
   ORA pa_sy
   ORA pa_sx
   TAX
lf_entry:                                  ; X = oct (sign-class entries JMP
                                           ; here with the base baked)
; --- option F (2026-07-17): ta' = ATANEXP[L(den) - L(num)] — two byte
; lookups and a subtract replace the restoring divide AND tantoangle.
; Certified by tools/atanexp_cert.py (exhaustive over den <= 2047):
; EPSILON = 15 fine units; bca_tail applies the +-EPS role bias so
; every verdict is a SUPERSET of the exact convention's — pixels are
; bit-identical. num == 0 -> ta = 0 (TA0, seed-asserted). X = oct
; rides through untouched; 16-bit operands (den >= 256, rare) reduce
; via >>3 (+96/octave-triple, cancelling when both reduce — the
; cert models the identical reduction).
   LDA sd_num+1
   BNE lf_num16
   LDA sd_num
   BEQ lf_ta0
   TAY
   LDA L8_TAB,Y
   STA pa_sx                               ; L(num) (pa_sx/pa_sy are dead
                                        ; after the haveax oct fold)
   LDA sd_den+1
   BNE lf_d16n8
   LDY sd_den
   LDA L8_TAB,Y
   SEC
   SBC pa_sx                                  ; k = L8[den] - L8[num]
   BCC lf_k0                               ; defensive (cert: kmin = 0)
lf_khave:
   TAY
   LDA AE_LO,Y
   STA pa_res
   LDA AE_HI,Y
   STA pa_res+1
   JMP comb
lf_k0:
   LDA #0
   BEQ lf_khave                            ; (always)
lf_ta0:
   STA pa_res                              ; ta = 0 (A = 0 here)
   STA pa_res+1
   JMP comb
lf_d16n8:
; den 16-bit, num 8-bit: k = (L8[den>>3] - L8[num]) + 96, clamped 255
   JSR lf_dred
   SEC
   SBC pa_sx
   BCS lf_d16n8_pos
   ADC #96                                 ; C=0: wraps to diff+96 exactly
   JMP lf_khave
lf_d16n8_pos:
   ADC #95                                 ; C=1: diff+96
   BCS lf_k255
   JMP lf_khave
lf_k255:
   LDA #255
   JMP lf_khave
lf_num16:
; num 16-bit (so den is too: den > num): the +96s cancel
   LDA sd_num+1
   STA pa_sy
   LDA sd_num
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   TAY
   LDA L8_TAB,Y
   STA pa_sx                                  ; L8[num>>3]
   JSR lf_dred
   SEC
   SBC pa_sx
   BCC lf_k0
   JMP lf_khave
lf_dred:
; A = L8[den>>3] (den 16-bit; clobbers Y, pa_sy)
   LDA sd_den+1
   STA pa_sy
   LDA sd_den
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   TAY
   LDA L8_TAB,Y
   RTS
lf_join:
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
; --- memo STORE (X = oct is dead after comb; slot stashed at the probe) ---
   LDX zp_cpm_slot
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
   STA CPM_PSIH,X                          ; valid forever: psi is a pure
                                           ; function of (dx,dy); the KDXH
                                           ; store above IS the validity mark

; ============================================================================
; Sign-class corner_phi entries (2026-07-18). Every ZC arm knows BOTH
; corners' delta signs at assembly time (the zone puts the viewer on a
; known side of each corner plane: boxx=0 -> dx>=0 for both corners,
; boxx=2 -> dx<=0, boxx=1 -> per-corner by plane; same for y). So each
; arm calls a class entry whose miss converter dead-codes the sign
; tests: |delta| by a fixed-direction move/negate, oct base an
; immediate. Boundary zeros are exact: delta=0 folds to ta=0, where
; base+ta == base-ta — psi is IDENTICAL to the generic path (and the
; mirror) in every case, so memo entries stay interchangeable.
; The probe is duplicated per class (a shared probe would need a
; dynamic miss target = the dispatch this kills). Generic corner_phi
; stays for the unit-test hook (test_slope_div drives arbitrary deltas).
; PLACEMENT: flat = the ANGX window ($F200 — the TA_HI page option F
; killed; ANG itself is at its $F100 ceiling). Banked = ANG_BK floats
; in the CODE region like everything else.
; ============================================================================
.macro CPM_ENTRY name, negx, negy, obase
   .local cmiss
name:
   LDA pa_dx
   EOR pa_dy
   AND #$7F
   TAX
   STX zp_cpm_slot
   LDA CPM_KDXH,X
   CMP pa_dx+1
   BNE cmiss
   LDA CPM_KDXL,X
   CMP pa_dx
   BNE cmiss
   LDA CPM_KDYL,X
   CMP pa_dy
   BNE cmiss
   LDA CPM_KDYH,X
   CMP pa_dy+1
   BNE cmiss
   LDA CPM_PSIL,X
   STA pa_res
   LDA CPM_PSIH,X
   STA pa_res+1
   JMP cp_havepsi
cmiss:
.if negx
   LDA #0                                  ; |dx| = -dx (class: dx <= 0)
   SEC
   SBC pa_dx
   STA sd_num
   LDA #0
   SBC pa_dx+1
   STA sd_num+1
.else
   LDA pa_dx                               ; |dx| = dx (class: dx >= 0)
   STA sd_num
   LDA pa_dx+1
   STA sd_num+1
.endif
.if negy
   LDA #0                                  ; |dy| = -dy (class: dy <= 0)
   SEC
   SBC pa_dy
   STA sd_den
   LDA #0
   SBC pa_dy+1
   STA sd_den+1
.else
   LDA pa_dy                               ; |dy| = dy (class: dy >= 0)
   STA sd_den
   LDA pa_dy+1
   STA sd_den+1
.endif
   LDX #obase                              ; no compare, no swap: lf_ns reads
   JMP lf_ns                               ; the axgt bit off the SIGN of the
                                           ; L8 difference (Eben's negate-the-
                                           ; ATANEXP-input idea, 2026-07-18)
.endmacro
; oct base = (dx<0)*4 + (dy<0)*2 (P = delta >= 0, N = delta <= 0)
.if ::BANKED = 0
.segment "ANGX"
angx_head:
.endif
CPM_ENTRY corner_phi_pp, 0, 0, 0
CPM_ENTRY corner_phi_pn, 0, 1, 2
CPM_ENTRY corner_phi_np, 1, 0, 4
CPM_ENTRY corner_phi_nn, 1, 1, 6

; ============================================================================
; lf_ns — the NO-SWAP log2/atanexp pipeline (2026-07-18). sd_num = |dx|,
; sd_den = |dy| AS LOADED; the min/max swap is gone. The signed L8
; difference s = L8r(|dy|) - L8r(|dx|) carries everything:
;   - L8 is MONOTONE, so sign(s) IS the exact axgt whenever s != 0
;     (strict L8 order implies strict magnitude order);
;   - mixed widths fix the sign statically (a 16-bit magnitude always
;     beats an 8-bit one: dy >= 256 > 255 >= dx), so those arms bake
;     the axgt bit and never test a sign;
;   - s == 0 is an L8 TIE, where AE[0] = 506 != 512 means the branch
;     matters: fall back to the exact 16-bit compare (and the exact-
;     equality diagonal diverts to ta = ANG45 = 512, the mirror's rule).
; The negate is the ATANEXP-input negation: k = |s|, oct = class|(s<0).
; Zero magnitudes short out first (L8[0] = L8[1] = 0 would poison the
; sign trick): min == 0 -> ta = 0; both zero -> psi = 0.
;   in : X = octant class base (axgt clear), sd_num/sd_den = |dx|/|dy|
;   out: joins comb (ANG) with X = oct, pa_res = ta
; ============================================================================
lf_ns:
.scope
   LDA sd_num
   ORA sd_num+1
   BEQ ns_dx0
   LDA sd_den
   ORA sd_den+1
   BEQ ns_dy0
   LDA sd_num+1
   BNE ns_x16
   LDA sd_den+1
   BNE ns_x8y16
; --- both 8-bit (the common case) ---
   LDY sd_num
   LDA L8_TAB,Y
   STA pa_sx                               ; L8[|dx|]
   LDY sd_den
   LDA L8_TAB,Y
   SEC
   SBC pa_sx                               ; s = L8[|dy|] - L8[|dx|]
   BCC ns_neg                              ; s < 0: |dx| > |dy|
; (s == 0 falls straight through: ATANEXP[0] is FORCED to 512, where
;  every octant pair collapses — base+512 == base'-512 mod 4096 — so
;  ties and the exact diagonal need no fallback compare. The cert
;  verifies the one-sided bucket-0 error stays inside EPSILON.)
ns_khave:
   TAY                                     ; k = |s|
   LDA AE_LO,Y
   STA pa_res
   LDA AE_HI,Y
   STA pa_res+1
   JMP comb
ns_neg:
   EOR #$FF                                ; -s (C = 0 from the BCC: the ADC
   ADC #1                                  ; supplies exactly +1)
   INX                                     ; axgt
   BNE ns_khave                            ; (always: k >= 1)
ns_dx0:
   LDA sd_den
   ORA sd_den+1
   BEQ ns_00
   LDA #0                                  ; |dx| = 0: ta = 0, axgt = 0
   BEQ ns_ta0                              ; (always)
ns_dy0:
   INX                                     ; |dy| = 0: ta = 0, axgt = 1
   LDA #0
ns_ta0:
   STA pa_res
   STA pa_res+1
   JMP comb
ns_00:
   JMP pa_zero                             ; (0,0) -> psi = 0
ns_x16:
   LDA sd_den+1
   BNE ns_x16y16
; --- |dx| 16-bit, |dy| 8-bit: axgt STATIC; k = L8[dx>>3] + 96 - L8[dy]
;     (>= 1: L8r(16-bit) >= 256 > 255 >= L8[8-bit]) ---
   INX
   LDY sd_den
   LDA L8_TAB,Y
   STA pa_sx                               ; L8[|dy|]
   LDA sd_num+1
   STA pa_sy
   LDA sd_num
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   TAY
   LDA L8_TAB,Y                            ; L8[|dx| >> 3]
   SEC
   SBC pa_sx
   BCS ns_pos96
   ADC #96                                 ; C=0: wraps to diff+96 exactly
   JMP ns_khave                            ; (diff >= -95 here: k >= 1)
ns_pos96:
   ADC #95                                 ; C=1: diff+96
   BCS ns_k255
   JMP ns_khave
ns_k255:
   LDA #255
   BNE ns_khave                            ; (always)
ns_x8y16:
; --- |dx| 8-bit, |dy| 16-bit: axgt STATIC clear; k = L8[dy>>3] + 96 - L8[dx] ---
   LDY sd_num
   LDA L8_TAB,Y
   STA pa_sx                               ; L8[|dx|]
   LDA sd_den+1
   STA pa_sy
   LDA sd_den
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   TAY
   LDA L8_TAB,Y                            ; L8[|dy| >> 3]
   SEC
   SBC pa_sx
   BCS ns_pos96
   ADC #96
   JMP ns_khave
ns_x16y16:
; --- both 16-bit: reduce both (the +96s cancel), then sign/tie as 8-bit ---
   LDA sd_num+1
   STA pa_sy
   LDA sd_num
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   TAY
   LDA L8_TAB,Y
   STA pa_sx                               ; L8[|dx| >> 3]
   LDA sd_den+1
   STA pa_sy
   LDA sd_den
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   LSR pa_sy
   ROR A
   TAY
   LDA L8_TAB,Y                            ; L8[|dy| >> 3]
   SEC
   SBC pa_sx
   BCC ns_neg_j                            ; (trampolines: ns_neg/ns_khave sit
   JMP ns_khave                            ;  ~200 B up with the 8-bit arm;
                                           ;  s == 0 ties ride k = 0 like the
                                           ;  8-bit arm — AE[0] = 512)
ns_neg_j:
   JMP ns_neg                              ; C=0 rides the JMP (ns_neg's ADC #1)
.endscope
.if ::BANKED = 0
.segment "ANG"
.endif
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
   TAY                                     ; r lo rides Y to the caller
   LDA bca_afn+1
   SBC pa_res+1
   AND #$0F                                ; r & 4095 (hi nibble) — u12, done
   RTS                                     ; (A = r hi; the pa_res store-backs
                                           ; died 2026-07-18 — every runtime
                                           ; caller consumes A/Y, and the unit
                                           ; test reads the registers now.
                                           ; pa_res keeps holding PSI, which
                                           ; is what the memo store wants.)

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
; partial fetches for the axis-sharing rows (1/4/6/9): the two corners
; sit on one shared plane, and pa_dx/pa_dy SURVIVE corner_phi (probe,
; converters and store only read them) — so the second corner reloads
; just its own axis.
.macro ZCF_DX s, xl
   LDY zp_node_ch_l
   SEC
   LDA xl+(s)*$100,Y
   SBC bca_pxs
   STA pa_dx
   LDA xl+$200+(s)*$100,Y
   SBC bca_pxs+1
   STA pa_dx+1
.endmacro
.macro ZCF_DY s, yl
   LDY zp_node_ch_l
   SEC
   LDA yl+(s)*$100,Y
   SBC bca_pys
   STA pa_dy
   LDA yl+$200+(s)*$100,Y
   SBC bca_pys+1
   STA pa_dy+1
.endmacro
.macro ZARM s, x1, y1, x2, y2, e1, e2
   ZCF s, x1, y1
   JSR e1                                  ; sign-class corner_phi entry —
   STA bca_p1+1                            ; the arm's zone fixes each
   STY bca_p1                              ; corner's delta signs statically
   ZCF s, x2, y2
   JSR e2
   STA bca_p2+1
   STY bca_p2
   JMP bca_tail                            ; chained: no return trip
.endmacro
.macro ZARM_SX s, x1, y1, y2, e1, e2      ; corners share the x plane
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   ZCF_DY s, y2                            ; pa_dx carried over
   JSR e2
   STA bca_p2+1
   STY bca_p2
   JMP bca_tail                            ; chained
.endmacro
.macro ZARM_SY s, x1, y1, x2, e1, e2      ; corners share the y plane
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   ZCF_DX s, x2                            ; pa_dy carried over
   JSR e2
   STA bca_p2+1
   STY bca_p2
   JMP bca_tail                            ; chained
.endmacro
; (the zc_corners dispatch routine died 2026-07-18 — classify exits
; push-push-RTS to the arm themselves. The label below marks the ZC
; window start for check_angle_calls' PC classifier.)
zc_corners:
; checkcoord rows (x = L/R plane, y = T/B plane); rows 3/5/7 unused
; Sign classes per corner (P = delta >= 0, N = delta <= 0), derived from
; the row's viewer zone (boxx/boxy) and each corner's plane:
;   row 0 (NW):  c1=(R,T) dx>=0 dy<=0 PN   c2=(L,B) PN
;   row 1 (N):   c1=(R,T) PN              c2=(L,T) dx<=0 NN
;   row 2 (NE):  c1=(R,B) NN              c2=(L,T) NN
;   row 4 (W):   c1=(L,T) dy>=0 PP        c2=(L,B) dy<=0 PN
;   row 6 (E):   c1=(R,B) NN              c2=(R,T) NP
;   row 8 (SW):  c1=(L,T) PP              c2=(R,B) PP
;   row 9 (S):   c1=(L,B) NP              c2=(R,B) PP
;   row 10 (SE): c1=(L,B) NP              c2=(R,T) NP
zc0_0:  ZARM 0, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO, corner_phi_pn, corner_phi_pn
zc0_1:  ZARM 1, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO, corner_phi_pn, corner_phi_pn
zc1_0:  ZARM_SY 0, BBP_R_LO, BBP_T_LO, BBP_L_LO, corner_phi_pn, corner_phi_nn
zc1_1:  ZARM_SY 1, BBP_R_LO, BBP_T_LO, BBP_L_LO, corner_phi_pn, corner_phi_nn
zc2_0:  ZARM 0, BBP_R_LO, BBP_B_LO, BBP_L_LO, BBP_T_LO, corner_phi_nn, corner_phi_nn
zc2_1:  ZARM 1, BBP_R_LO, BBP_B_LO, BBP_L_LO, BBP_T_LO, corner_phi_nn, corner_phi_nn
zc4_0:  ZARM_SX 0, BBP_L_LO, BBP_T_LO, BBP_B_LO, corner_phi_pp, corner_phi_pn
zc4_1:  ZARM_SX 1, BBP_L_LO, BBP_T_LO, BBP_B_LO, corner_phi_pp, corner_phi_pn
zc6_0:  ZARM_SX 0, BBP_R_LO, BBP_B_LO, BBP_T_LO, corner_phi_nn, corner_phi_np
zc6_1:  ZARM_SX 1, BBP_R_LO, BBP_B_LO, BBP_T_LO, corner_phi_nn, corner_phi_np
zc8_0:  ZARM 0, BBP_L_LO, BBP_T_LO, BBP_R_LO, BBP_B_LO, corner_phi_pp, corner_phi_pp
zc8_1:  ZARM 1, BBP_L_LO, BBP_T_LO, BBP_R_LO, BBP_B_LO, corner_phi_pp, corner_phi_pp
zc9_0:  ZARM_SY 0, BBP_L_LO, BBP_B_LO, BBP_R_LO, corner_phi_np, corner_phi_pp
zc9_1:  ZARM_SY 1, BBP_L_LO, BBP_B_LO, BBP_R_LO, corner_phi_np, corner_phi_pp
zc10_0: ZARM 0, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO, corner_phi_np, corner_phi_np
zc10_1: ZARM 1, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO, corner_phi_np, corner_phi_np
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
.assert end <= $F100, error             ; flat ANG ceiling: RCACHE_STATE $F100
                                        ; (abi) is the next squatter above —
                                        ; RC_PH_S vacated $F000 (2026-07-17)
                                        ; after ANG growth CORRUPTED it (the
                                        ; old TA_HI bound was too loose;
                                        ; rotcache caught the overlap)
; (ld65 writes this: SAVE "bsp_render_ang.bin", $E940, end, $E940)
.endif

