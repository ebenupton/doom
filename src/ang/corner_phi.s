
; ============================================================================
; box_classify — PURE DIVERGING CONTROL FLOW (Eben's design, 2026-07-18).
; No boxy accumulator, no t0, no compose, no table dispatch on ladder
; paths: the x phase picks one of four columns (Lb strict-left / L0
; left-edge / M mid / Rb strict-right), each column owns a COPY of the
; y ladder, and every LEAF knows (row, side, zone mask) statically —
; it publishes the full mask as an immediate and JMPs its corner arm
; directly. The mask-0 leaves are exactly the closed-inside cases
; (edge-on-one-axis + mid/edge on the other), so zone == 0 <=> inside
; holds by construction; inherited axes divert to their column/leaf
; and the published mask still equals this box's true strict bits
; (inherited bits are true for the child by the inheritance theorem).
; The both-axes-inherited fast path keeps its 16-byte table + zc_ptr
; dispatch (entry below); everything else is branches.
;   in : zp_par_zone (walk-stacked), zp_node_ch_l, zp_bbox_side,
;        bca_pxs/pys (offset-binned hi)
;   out: control at the corner arm (or full_vis), zp_bca_zone published
; ============================================================================
box_classify:
   LDA zp_par_zone
   BEQ bc_sides                            ; nothing inherited: ladders
   TAX
   LDA bc_zone_idx,X
   BMI bc_sides                            ; single-axis: the column diverts
   STX zp_bca_zone                         ; both-axes fast path: publish =
   ORA zp_bbox_side                        ; the inherited bits (X = par)
   TAX
   LDA zc_tab_lo,X
   STA zc_ptr
   LDA zc_tab_hi,X
   STA zc_ptr+1
   JMP (zc_ptr)
bc_zone_idx:
; zone bits (b0 strictly-left, b1 right, b2 above, b3 below) -> ZC
; dispatch index (boxy*8 | boxx*2); $FF = not fully inherited.
   .byte $FF,$FF,$FF,$FF, $FF,$00,$04,$FF, $FF,$10,$14,$FF, $FF,$FF,$FF,$FF
bc_sides:
   LDA zp_bbox_side
   BNE bcls_s1_j
   JMP bcls_s0
bcls_s1_j:
   JMP bcls_s1

bcls_s0:
; --- x phase: inherited bits divert to their column; else the
; hi-first ladder picks one of four (Lb strict / L0 edge / M / Rb) ---
   LDA zp_par_zone
   AND #$03
   BEQ xr_s0
   LSR A                                   ; bit0 -> C (strictly left)
   BCS xLbj_s0
   JMP yRb_s0                             ; strictly right (inherited)
xLbj_s0:
   JMP yLb_s0                             ; strictly left (inherited)
xr_s0:
   LDY zp_node_ch_l
   LDA bca_pxs+1
   CMP BBP_L_HI0,Y
   BCC xLbj2_s0                           ; px < L strictly (hi)
   BNE xge_s0
   LDA bca_pxs
   CMP BBP_L_LO0,Y
   BCC xLbj2_s0
   BNE xge_s0                             ; px > L strictly (lo)
   JMP yL0_s0                             ; d == 0: boxx 0, NO x bit
xLbj2_s0:
   JMP yLb_s0
xge_s0:
   LDA bca_pxs+1
   CMP BBP_R_HI0,Y
   BCC yM_s0                              ; px < R (hi): MID (adjacent: short
   BNE xRbj_s0                            ; branch reaches the yM block below)
   LDA bca_pxs
   CMP BBP_R_LO0,Y
   BCC yM_s0
   BEQ yM_s0                              ; px == R: mid
xRbj_s0:
   JMP yRb_s0
yM_s0:
   LDA zp_par_zone
   AND #$0C
   BEQ yMr_s0                      ; y not inherited: run the ladder
   AND #$04
   BNE yMAb_s0                     ; inherited-above == the strict-above leaf
   BEQ yMBb_s0                     ; (always) inherited-below
yMr_s0:
   LDY zp_node_ch_l
   LDA bca_pys+1
   CMP BBP_T_HI0,Y
   BCC yMlo_s0                     ; py < T (hi): test the bottom
   BNE yMAb_s0                     ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO0,Y
   BCC yMlo_s0
   BNE yMAb_s0                     ; py > T strictly (lo)
   LDA #$00                          ; f == 0: boxy 0, NO y bit
   STA zp_bca_zone
   JMP zc1_0
yMAb_s0:
   LDA #$04                          ; strictly above
   STA zp_bca_zone
   JMP zc1_0
yMlo_s0:
   LDA bca_pys+1
   CMP BBP_B_HI0,Y
   BCC yMBb_s0                     ; py < B strictly (hi)
   BNE yMM_s0                      ; py > B (hi): mid
   LDA bca_pys
   CMP BBP_B_LO0,Y
   BCS yMM_s0                      ; py >= B: mid (g >= 0)
yMBb_s0:
   LDA #$08                          ; strictly below
   STA zp_bca_zone
   JMP zc9_0
yMM_s0:
   LDA #0                                  ; mid/mid: the CLOSED inside
   STA zp_bca_zone                         ; case (zone 0 == inside holds
   JMP full_vis                            ; by construction)
yLb_s0:
   LDA zp_par_zone
   AND #$0C
   BEQ yLbr_s0                      ; y not inherited: run the ladder
   AND #$04
   BNE yLbAb_s0                     ; inherited-above == the strict-above leaf
   BEQ yLbBb_s0                     ; (always) inherited-below
yLbr_s0:
   LDY zp_node_ch_l
   LDA bca_pys+1
   CMP BBP_T_HI0,Y
   BCC yLblo_s0                     ; py < T (hi): test the bottom
   BNE yLbAb_s0                     ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO0,Y
   BCC yLblo_s0
   BNE yLbAb_s0                     ; py > T strictly (lo)
   LDA #$01                          ; f == 0: boxy 0, NO y bit
   STA zp_bca_zone
   JMP zc0_0
yLbAb_s0:
   LDA #$05                          ; strictly above
   STA zp_bca_zone
   JMP zc0_0
yLblo_s0:
   LDA bca_pys+1
   CMP BBP_B_HI0,Y
   BCC yLbBb_s0                     ; py < B strictly (hi)
   BNE yLbM_s0                      ; py > B (hi): mid
   LDA bca_pys
   CMP BBP_B_LO0,Y
   BCS yLbM_s0                      ; py >= B: mid (g >= 0)
yLbBb_s0:
   LDA #$09                          ; strictly below
   STA zp_bca_zone
   JMP zc8_0
yLbM_s0:
   LDA #$01
   STA zp_bca_zone
   JMP zc4_0
yL0_s0:
   LDA zp_par_zone
   AND #$0C
   BEQ yL0r_s0                      ; y not inherited: run the ladder
   AND #$04
   BNE yL0Ab_s0                     ; inherited-above == the strict-above leaf
   BEQ yL0Bb_s0                     ; (always) inherited-below
yL0r_s0:
   LDY zp_node_ch_l
   LDA bca_pys+1
   CMP BBP_T_HI0,Y
   BCC yL0lo_s0                     ; py < T (hi): test the bottom
   BNE yL0Ab_s0                     ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO0,Y
   BCC yL0lo_s0
   BNE yL0Ab_s0                     ; py > T strictly (lo)
   LDA #$00                          ; f == 0: boxy 0, NO y bit
   STA zp_bca_zone
   JMP zc0_0
yL0Ab_s0:
   LDA #$04                          ; strictly above
   STA zp_bca_zone
   JMP zc0_0
yL0lo_s0:
   LDA bca_pys+1
   CMP BBP_B_HI0,Y
   BCC yL0Bb_s0                     ; py < B strictly (hi)
   BNE yL0M_s0                      ; py > B (hi): mid
   LDA bca_pys
   CMP BBP_B_LO0,Y
   BCS yL0M_s0                      ; py >= B: mid (g >= 0)
yL0Bb_s0:
   LDA #$08                          ; strictly below
   STA zp_bca_zone
   JMP zc8_0
yL0M_s0:
   LDA #$00
   STA zp_bca_zone
   JMP zc4_0
yRb_s0:
   LDA zp_par_zone
   AND #$0C
   BEQ yRbr_s0                      ; y not inherited: run the ladder
   AND #$04
   BNE yRbAb_s0                     ; inherited-above == the strict-above leaf
   BEQ yRbBb_s0                     ; (always) inherited-below
yRbr_s0:
   LDY zp_node_ch_l
   LDA bca_pys+1
   CMP BBP_T_HI0,Y
   BCC yRblo_s0                     ; py < T (hi): test the bottom
   BNE yRbAb_s0                     ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO0,Y
   BCC yRblo_s0
   BNE yRbAb_s0                     ; py > T strictly (lo)
   LDA #$02                          ; f == 0: boxy 0, NO y bit
   STA zp_bca_zone
   JMP zc2_0
yRbAb_s0:
   LDA #$06                          ; strictly above
   STA zp_bca_zone
   JMP zc2_0
yRblo_s0:
   LDA bca_pys+1
   CMP BBP_B_HI0,Y
   BCC yRbBb_s0                     ; py < B strictly (hi)
   BNE yRbM_s0                      ; py > B (hi): mid
   LDA bca_pys
   CMP BBP_B_LO0,Y
   BCS yRbM_s0                      ; py >= B: mid (g >= 0)
yRbBb_s0:
   LDA #$0A                          ; strictly below
   STA zp_bca_zone
   JMP zc10_0
yRbM_s0:
   LDA #$02
   STA zp_bca_zone
   JMP zc6_0

bcls_s1:
; --- x phase: inherited bits divert to their column; else the
; hi-first ladder picks one of four (Lb strict / L0 edge / M / Rb) ---
   LDA zp_par_zone
   AND #$03
   BEQ xr_s1
   LSR A                                   ; bit0 -> C (strictly left)
   BCS xLbj_s1
   JMP yRb_s1                             ; strictly right (inherited)
xLbj_s1:
   JMP yLb_s1                             ; strictly left (inherited)
xr_s1:
   LDY zp_node_ch_l
   LDA bca_pxs+1
   CMP BBP_L_HI1,Y
   BCC xLbj2_s1                           ; px < L strictly (hi)
   BNE xge_s1
   LDA bca_pxs
   CMP BBP_L_LO1,Y
   BCC xLbj2_s1
   BNE xge_s1                             ; px > L strictly (lo)
   JMP yL0_s1                             ; d == 0: boxx 0, NO x bit
xLbj2_s1:
   JMP yLb_s1
xge_s1:
   LDA bca_pxs+1
   CMP BBP_R_HI1,Y
   BCC yM_s1                              ; px < R (hi): MID (adjacent: short
   BNE xRbj_s1                            ; branch reaches the yM block below)
   LDA bca_pxs
   CMP BBP_R_LO1,Y
   BCC yM_s1
   BEQ yM_s1                              ; px == R: mid
xRbj_s1:
   JMP yRb_s1
yM_s1:
   LDA zp_par_zone
   AND #$0C
   BEQ yMr_s1                      ; y not inherited: run the ladder
   AND #$04
   BNE yMAb_s1                     ; inherited-above == the strict-above leaf
   BEQ yMBb_s1                     ; (always) inherited-below
yMr_s1:
   LDY zp_node_ch_l
   LDA bca_pys+1
   CMP BBP_T_HI1,Y
   BCC yMlo_s1                     ; py < T (hi): test the bottom
   BNE yMAb_s1                     ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO1,Y
   BCC yMlo_s1
   BNE yMAb_s1                     ; py > T strictly (lo)
   LDA #$00                          ; f == 0: boxy 0, NO y bit
   STA zp_bca_zone
   JMP zc1_1
yMAb_s1:
   LDA #$04                          ; strictly above
   STA zp_bca_zone
   JMP zc1_1
yMlo_s1:
   LDA bca_pys+1
   CMP BBP_B_HI1,Y
   BCC yMBb_s1                     ; py < B strictly (hi)
   BNE yMM_s1                      ; py > B (hi): mid
   LDA bca_pys
   CMP BBP_B_LO1,Y
   BCS yMM_s1                      ; py >= B: mid (g >= 0)
yMBb_s1:
   LDA #$08                          ; strictly below
   STA zp_bca_zone
   JMP zc9_1
yMM_s1:
   LDA #0                                  ; mid/mid: the CLOSED inside
   STA zp_bca_zone                         ; case (zone 0 == inside holds
   JMP full_vis                            ; by construction)
yLb_s1:
   LDA zp_par_zone
   AND #$0C
   BEQ yLbr_s1                      ; y not inherited: run the ladder
   AND #$04
   BNE yLbAb_s1                     ; inherited-above == the strict-above leaf
   BEQ yLbBb_s1                     ; (always) inherited-below
yLbr_s1:
   LDY zp_node_ch_l
   LDA bca_pys+1
   CMP BBP_T_HI1,Y
   BCC yLblo_s1                     ; py < T (hi): test the bottom
   BNE yLbAb_s1                     ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO1,Y
   BCC yLblo_s1
   BNE yLbAb_s1                     ; py > T strictly (lo)
   LDA #$01                          ; f == 0: boxy 0, NO y bit
   STA zp_bca_zone
   JMP zc0_1
yLbAb_s1:
   LDA #$05                          ; strictly above
   STA zp_bca_zone
   JMP zc0_1
yLblo_s1:
   LDA bca_pys+1
   CMP BBP_B_HI1,Y
   BCC yLbBb_s1                     ; py < B strictly (hi)
   BNE yLbM_s1                      ; py > B (hi): mid
   LDA bca_pys
   CMP BBP_B_LO1,Y
   BCS yLbM_s1                      ; py >= B: mid (g >= 0)
yLbBb_s1:
   LDA #$09                          ; strictly below
   STA zp_bca_zone
   JMP zc8_1
yLbM_s1:
   LDA #$01
   STA zp_bca_zone
   JMP zc4_1
yL0_s1:
   LDA zp_par_zone
   AND #$0C
   BEQ yL0r_s1                      ; y not inherited: run the ladder
   AND #$04
   BNE yL0Ab_s1                     ; inherited-above == the strict-above leaf
   BEQ yL0Bb_s1                     ; (always) inherited-below
yL0r_s1:
   LDY zp_node_ch_l
   LDA bca_pys+1
   CMP BBP_T_HI1,Y
   BCC yL0lo_s1                     ; py < T (hi): test the bottom
   BNE yL0Ab_s1                     ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO1,Y
   BCC yL0lo_s1
   BNE yL0Ab_s1                     ; py > T strictly (lo)
   LDA #$00                          ; f == 0: boxy 0, NO y bit
   STA zp_bca_zone
   JMP zc0_1
yL0Ab_s1:
   LDA #$04                          ; strictly above
   STA zp_bca_zone
   JMP zc0_1
yL0lo_s1:
   LDA bca_pys+1
   CMP BBP_B_HI1,Y
   BCC yL0Bb_s1                     ; py < B strictly (hi)
   BNE yL0M_s1                      ; py > B (hi): mid
   LDA bca_pys
   CMP BBP_B_LO1,Y
   BCS yL0M_s1                      ; py >= B: mid (g >= 0)
yL0Bb_s1:
   LDA #$08                          ; strictly below
   STA zp_bca_zone
   JMP zc8_1
yL0M_s1:
   LDA #$00
   STA zp_bca_zone
   JMP zc4_1
yRb_s1:
   LDA zp_par_zone
   AND #$0C
   BEQ yRbr_s1                      ; y not inherited: run the ladder
   AND #$04
   BNE yRbAb_s1                     ; inherited-above == the strict-above leaf
   BEQ yRbBb_s1                     ; (always) inherited-below
yRbr_s1:
   LDY zp_node_ch_l
   LDA bca_pys+1
   CMP BBP_T_HI1,Y
   BCC yRblo_s1                     ; py < T (hi): test the bottom
   BNE yRbAb_s1                     ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO1,Y
   BCC yRblo_s1
   BNE yRbAb_s1                     ; py > T strictly (lo)
   LDA #$02                          ; f == 0: boxy 0, NO y bit
   STA zp_bca_zone
   JMP zc2_1
yRbAb_s1:
   LDA #$06                          ; strictly above
   STA zp_bca_zone
   JMP zc2_1
yRblo_s1:
   LDA bca_pys+1
   CMP BBP_B_HI1,Y
   BCC yRbBb_s1                     ; py < B strictly (hi)
   BNE yRbM_s1                      ; py > B (hi): mid
   LDA bca_pys
   CMP BBP_B_LO1,Y
   BCS yRbM_s1                      ; py >= B: mid (g >= 0)
yRbBb_s1:
   LDA #$0A                          ; strictly below
   STA zp_bca_zone
   JMP zc10_1
yRbM_s1:
   LDA #$02
   STA zp_bca_zone
   JMP zc6_1


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
   LDY pa_sign,X
   BMI sub
; add: res = base + ta ; low byte (= ta) unchanged since base_lo = 0.
; NO mask (2026-07-19, Eben's question): ta <= 512 (AE table range,
; seed-asserted) so hi <= 2, no lo add means no carry, and the largest
; add base is 3072 (hi 12) — the sum tops out at $0E, never wraps.
   CLC
   ADC pa_base_hi,X
   STA pa_res+1
   JMP mask_done
sub:
; sub: res = base - ta ; base_lo = 0. The mask HERE is load-bearing
; for exactly one octant: oct 3 is 0 - ta, negative for any ta > 0 —
; the AND is the mod-4096 wrap (psi = 4096 - ta). The other sub bases
; (1024/2048/3072) can't go negative with ta <= 512.
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
   STA CPM_PSIH,X                          ; valid forever: psi is a pure
   LDA pa_res
   STA CPM_PSIL,X
                                           ; function of (dx,dy); the KDXH
                                           ; write at miss entry IS the
                                           ; validity mark
; *** FALLS THROUGH into cp_havepsi. *** The macro definition and the
; ANGX-segment entry expansions between here and there emit NOTHING
; into this (ANG) segment — in the assembled image the psi store's
; last byte is immediately followed by cp_havepsi (link-adjacent).


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

; (The sign-class entries + lf_ns are placed AFTER cp_havepsi's RTS —
; 2026-07-18 REGRESSION FIX: they used to sit between mask_done and
; cp_havepsi, where the flat build's .segment "ANGX" diversion hid a
; BANKED landmine: with no segment switch, mask_done's load-bearing
; fall-through landed in corner_phi_pp instead of cp_havepsi. Pre-
; alias that was latent (the fall-in probe re-hit the just-stored key
; and produced the right answer, slowly); the in-place negations made
; the fall-in probe MISS on the mutated key and compute a wrong-class
; psi — the banked-vs-flat FB gate now guards this class.)
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
   BCS ns_khave                            ; s >= 0 (ties included: k = 0 and
                                           ; ATANEXP[0] is FORCED to 512 where
                                           ; every octant pair collapses — no
                                           ; fallback compare; cert-bounded)
ns_neg:                                    ; s < 0 falls in with C = 0
   EOR #$FF                                ; -s (the ADC supplies exactly +1;
   ADC #1                                  ; ns_neg_j arrives via BCC too)
   INX                                     ; axgt — falls into the lookup
ns_khave:
   TAY                                     ; k = |s|
   LDA AE_LO,Y
   STA pa_res
   LDA AE_HI,Y
   STA pa_res+1
   JMP comb
ns_dy0:
   INX                                     ; |dy| = 0: ta = 0, axgt = 1
ns_dx0:
   LDA #0
   STA pa_res
   STA pa_res+1
   JMP comb
ns_x16:
   LDY sd_den+1
   BNE ns_x16y16
; --- |dx| 16-bit, |dy| 8-bit: axgt STATIC; k = L8[dx>>3] + 96 - L8[dy]
;     (>= 1: L8r(16-bit) >= 256 > 255 >= L8[8-bit]) ---
   INX
; (no LDA: A = sd_num+1 from the entry dispatch — the LDY/INX above
;  preserve it. Eben 2026-07-19.)
   STA t0                                  ; >>3 NON-destructive: HI to t0
                                           ; (dead classify temp), lo rides
   LDA sd_num                              ; A so the index ends in-register
   LSR t0                                  ; (TAY, no reload) — sd_num ALIASES
   ROR A                                   ; pa_dx, which rows 4/9's shared-
   LSR t0                                  ; axis carryover still needs RAW
   ROR A                                   ; (the in-frame gate caught the
   LSR t0                                  ; in-place version)
   ROR A
   TAY
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
; (no LDA: A = sd_den+1 from the entry's second dispatch line)
   STA t0
   LDA sd_den
   LSR t0
   ROR A
   LSR t0
   ROR A
   LSR t0
   ROR A
   TAY
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
   STY t1                                  ; Y = sd_den+1 (banked at the ns_x16
                                           ; dispatch — MUST land before the
                                           ; LDY below reuses Y)
   LDY sd_num
   STY t0                                  ; lo staged via Y: A stays untouched
; (no LDA: A = sd_num+1 from the entry dispatch — LDY/BNE/STY preserve it)
   LSR A
   ROR t0
   LSR A
   ROR t0
   LSR A
   ROR t0
   LDA sd_den
   LSR t1
   ROR A
   LSR t1
   ROR A
   LSR t1
   ROR A
   TAY
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
; REAL addresses (2026-07-18: the JMP (zc_ptr) dispatch ended the
; RTS-trick's -1 bias)
zc_tab_lo:
   .byte <zc0_0,<zc0_1,<zc1_0,<zc1_1,<zc2_0,<zc2_1
   .byte <zc0_0,<zc0_1                     ; row 3 unused
   .byte <zc4_0,<zc4_1
   .byte <zc0_0,<zc0_1                     ; row 5 unused
   .byte <zc6_0,<zc6_1
   .byte <zc0_0,<zc0_1                     ; row 7 unused
   .byte <zc8_0,<zc8_1,<zc9_0,<zc9_1,<zc10_0,<zc10_1
zc_tab_hi:
   .byte >zc0_0,>zc0_1,>zc1_0,>zc1_1,>zc2_0,>zc2_1
   .byte >zc0_0,>zc0_1
   .byte >zc4_0,>zc4_1
   .byte >zc0_0,>zc0_1
   .byte >zc6_0,>zc6_1
   .byte >zc0_0,>zc0_1
   .byte >zc8_0,>zc8_1,>zc9_0,>zc9_1,>zc10_0,>zc10_1

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

