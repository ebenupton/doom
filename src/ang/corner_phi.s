
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
; (The GENERIC corner_phi entry and its sign/oct/swap/log2 path died
; 2026-07-19: every runtime corner comes through the four sign-class
; entries + lf_ns (ANGX, below), and the exhaustive pa sweep in
; test_slope_div drives those directly. What follows is the SHARED
; tail: comb (octant compose), the memo store, and cp_havepsi.)
lf_join:
comb:
; res = base[oct] +/- ta  (& MASK). The octant bases are multiples of 256
; (0/1024/2048/3072), so base_lo is always 0. X = oct (from lf_ns).
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
; --- memo STORE, psi half (X = oct is dead after comb; the slot was
; stashed at the probe; the KEY was banked at miss entry, before the
; in-place negations destroyed the raw deltas) ---
   LDX zp_cpm_slot
   LDA pa_res
   STA CPM_PSIL,X
   LDA pa_res+1
   STA CPM_PSIH,X                          ; valid forever: psi is a pure
                                           ; function of (dx,dy); the KDXH
                                           ; write at miss entry IS the
                                           ; validity mark

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
   .local cmiss0, cmiss1, cmiss2, cmiss3, czx, czy
name:
   LDA pa_dx
   EOR pa_dy
   AND #$7F
   TAX
   STX zp_cpm_slot
   LDA pa_dx
   CMP CPM_KDXL,X
   BNE cmiss0
   LDA pa_dx+1
   CMP CPM_KDXH,X
   BNE cmiss1
   LDA pa_dy
   CMP CPM_KDYL,X
   BNE cmiss2
   LDA pa_dy+1
   CMP CPM_KDYH,X
   BNE cmiss3
   LDA CPM_PSIL,X
   STA pa_res
   LDA CPM_PSIH,X
   STA pa_res+1
   JMP cp_havepsi
; Bank the RAW key first (X = slot, still live from the probe): sd_num
; ALIASES pa_dx and sd_den pa_dy (2026-07-19), so P-axes need no
; staging at all and N-axes negate IN PLACE — which would destroy the
; key. mask_done stores only psi now; this KDXH write is the validity
; mark, made good when the psi lands (single-threaded, no early outs).
; (Staggered entries, Eben 2026-07-19: a miss at stage k arrives with
; the mismatched byte in A, and the bytes BEFORE stage k matched — the
; table already holds them, so their stores are skipped entirely.)
cmiss0:
   STA CPM_KDXL,X
   LDA pa_dx+1
cmiss1:
   STA CPM_KDXH,X
   LDA pa_dy
cmiss2:
   STA CPM_KDYL,X
   LDA pa_dy+1
cmiss3:
   STA CPM_KDYH,X
.if negx
   LDA #0                                  ; |dx| = -dx in place (dx <= 0)
   SEC
   SBC sd_num
   STA sd_num
   LDA #0
   SBC sd_num+1
   STA sd_num+1
   ORA sd_num                              ; zero-out folded into the abs
   BEQ czx
.else
   LDA sd_num+1                            ; |dx| = dx already (dx >= 0):
   ORA sd_num                              ; nothing to stage, just the
   BEQ czx                                 ; zero-out
.endif
.if negy
   LDA #0                                  ; |dy| = -dy in place (dy <= 0)
   SEC
   SBC sd_den
   STA sd_den
   LDA #0
   SBC sd_den+1
   STA sd_den+1
   ORA sd_den
   BEQ czy
.else
   LDA sd_den+1                            ; |dy| = dy already (dy >= 0)
   ORA sd_den
   BEQ czy
.endif
   LDX #obase                              ; no compare, no swap: lf_ns reads
   JMP lf_ns                               ; the axgt bit off the SIGN of the
                                           ; L8 difference (Eben's negate-the-
                                           ; ATANEXP-input idea, 2026-07-18)
czx:
   LDX #obase
   JMP ns_dx0
czy:
   LDX #obase
   JMP ns_dy0
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
; (the zero-outs live in the converters now — folded into the abs
; blocks where the hi byte is already in A. And (0,0) is UNREACHABLE
; at runtime: a zero pair means the viewer IS the tested box's corner,
; and the closed inside test exits through full_vis before any arm
; runs; inherited zones are strict, so at least one axis is nonzero.
; The old pa_zero arm died with it — the pa sweep skips (0,0).)
lf_ns:
   LDA sd_num+1
   BNE ns_x16
   LDA sd_den+1
   BNE ns_x8y16
; --- both 8-bit (the common case) ---
   LDY sd_den
   LDA L8_TAB,Y                            ; L8[|dy|]
   LDY sd_num
   SEC
   SBC L8_TAB,Y                            ; s = L8[|dy|] - L8[|dx|] — Y
   BCC ns_neg                              ; re-pointed, no staging byte
                                           ; (Eben: mutate/read in place)
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
   LDA #0                                  ; |dx| = 0: ta = 0, axgt = 0
   BEQ ns_ta0                              ; (always)
ns_dy0:
   INX                                     ; |dy| = 0: ta = 0, axgt = 1
   LDA #0
ns_ta0:
   STA pa_res
   STA pa_res+1
   JMP comb
ns_x16:
   LDA sd_den+1
   BNE ns_x16y16
; --- |dx| 16-bit, |dy| 8-bit: axgt STATIC; k = L8[dx>>3] + 96 - L8[dy]
;     (>= 1: L8r(16-bit) >= 256 > 255 >= L8[8-bit]) ---
   INX
   LDA sd_num                              ; >>3 NON-destructive: lo copies to
   STA t0                                  ; t0 (dead classify temp), hi rides
   LDA sd_num+1                            ; A — sd_num ALIASES pa_dx, which
   LSR A                                   ; rows 4/9's shared-axis carryover
   ROR t0                                  ; still needs RAW (the in-frame
   LSR A                                   ; gate caught the in-place version)
   ROR t0
   LSR A
   ROR t0
   LDY t0
   LDA L8_TAB,Y                            ; L8[|dx| >> 3]
   LDY sd_den
   SEC
   SBC L8_TAB,Y                            ; - L8[|dy|], direct
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
   LDA sd_den
   STA t0
   LDA sd_den+1
   LSR A
   ROR t0
   LSR A
   ROR t0
   LSR A
   ROR t0
   LDY t0
   LDA L8_TAB,Y                            ; L8[|dy| >> 3]
   LDY sd_num
   SEC
   SBC L8_TAB,Y                            ; - L8[|dx|], direct
   BCS ns_pos96
   ADC #96
   JMP ns_khave
ns_x16y16:
; --- both 16-bit: reduce both into t0/t1 (the +96s cancel), then the
;     8-bit shape — indices from the temps, no L8-value staging ---
   LDA sd_num
   STA t0
   LDA sd_num+1
   LSR A
   ROR t0
   LSR A
   ROR t0
   LSR A
   ROR t0
   LDA sd_den
   STA t1
   LDA sd_den+1
   LSR A
   ROR t1
   LSR A
   ROR t1
   LSR A
   ROR t1
   LDY t1
   LDA L8_TAB,Y                            ; L8[|dy| >> 3]
   LDY t0
   SEC
   SBC L8_TAB,Y                            ; - L8[|dx| >> 3], direct
   BCC ns_neg_j                            ; (trampolines: ns_neg/ns_khave sit
   JMP ns_khave                            ;  ~200 B up with the 8-bit arm;
                                           ;  s == 0 ties ride k = 0 like the
                                           ;  8-bit arm — AE[0] = 512)
ns_neg_j:
   JMP ns_neg                              ; C=0 rides the JMP (ns_neg's ADC #1)
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
; partial fetches for the axis-sharing rows 4/9: the two corners sit on
; one shared plane whose class is P for BOTH corners — pa_dx/pa_dy
; survive c1's call ONLY when its class doesn't negate in place (the
; sd alias, 2026-07-19), so rows 1/6 (N-class shared axis) went back
; to full fetches.
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
zc1_0:  ZARM 0, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_T_LO, corner_phi_pn, corner_phi_nn
zc1_1:  ZARM 1, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_T_LO, corner_phi_pn, corner_phi_nn
zc2_0:  ZARM 0, BBP_R_LO, BBP_B_LO, BBP_L_LO, BBP_T_LO, corner_phi_nn, corner_phi_nn
zc2_1:  ZARM 1, BBP_R_LO, BBP_B_LO, BBP_L_LO, BBP_T_LO, corner_phi_nn, corner_phi_nn
zc4_0:  ZARM_SX 0, BBP_L_LO, BBP_T_LO, BBP_B_LO, corner_phi_pp, corner_phi_pn
zc4_1:  ZARM_SX 1, BBP_L_LO, BBP_T_LO, BBP_B_LO, corner_phi_pp, corner_phi_pn
zc6_0:  ZARM 0, BBP_R_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO, corner_phi_nn, corner_phi_np
zc6_1:  ZARM 1, BBP_R_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO, corner_phi_nn, corner_phi_np
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

