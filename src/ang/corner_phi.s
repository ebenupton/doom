
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
; Classify/corner stash — reuses the DEAD perspective-path corner
; scratch block (BBOX_CORNERS home): node-phase lifetime only, one bca
; check, disjoint from the per-seg projection overlay like its
; predecessor was.
CABS = $0A40                            ; +0..3 |d|,|e|,|f|,|g| lo; +4..7 hi;
                                        ; +8..11 sxL,sxR,syT,syB (pre-shifted)

box_classify:
.scope
; FUSED FRONT-END (2026-07-17): ONE set of subtractions feeds the zone
; classification, the silhouette corner deltas AND corner_phi's octant
; fold. The four viewer-vs-edge deltas d = px-left, e = right-px,
; f = py-top, g = py-bot are computed ONCE (all four, always — corners
; need them even for classes the old ladder short-circuited), stashed
; as |value| plus the PRE-SHIFTED corner sign bit, and the zone falls
; out of the sign bytes. The old zc ZCF plane re-reads and corner_phi's
; abs/octant fold are GONE — stage_c (ZC segment) feeds the divide
; straight from this stash. V-correction dropped: deltas are <= ~1400
; prescaled units, s16 never overflows (ZCF never corrected either).
;
; Stash (CABS = the dead perspective-path corner scratch at $0A40;
; node-phase only, disjoint from the per-seg overlay like its
; predecessor):
;   CABS+0..3  = |d|,|e|,|f|,|g| lo     CABS+4..7 = hi
;   CABS+8..11 = corner sign bits, pre-shifted for the oct fold:
;     +8  sxL = 4 iff d>0   (corner x = left-px  = -d)
;     +9  sxR = 4 iff e<0   (corner x = right-px = +e)
;     +10 syT = 2 iff f>0   (corner y = top-py   = -f)
;     +11 syB = 2 iff g>0   (corner y = bot-py   = -g)
; Zone (byte-exact to the old ladder): boxx = 0 iff d<=0 (outflag iff
; d<0), 2 iff d>0 && e<0 (flag), else 1; boxy = 0 iff f>=0 (flag iff
; f>0), 2 iff f<0 && g<0 (flag), else 1; inside iff no flags.
   LDA #0
   STA t1                                  ; outside flag
   LDA zp_bbox_side
   BNE bcls_s1_j
   JMP bcls_s0
bcls_s1_j:
   JMP bcls_s1
.endscope
; --- the two side arms share everything but the baked plane column ---
.macro BCLS_SIDE s, jout
.scope
; ---- d = px - left: |d| -> CABS+0/+4, sxL -> CABS+8 ----
   LDY zp_node_ch_l
   SEC
   LDA bca_pxs
   SBC BBP_L_LO+(s)*$100,Y
   STA CABS+0
   TAX                                     ; lo for the zero test
   LDA bca_pxs+1
   SBC BBP_L_HI+(s)*$100,Y
   STA CABS+4
   BMI d_neg
   BNE d_pos                               ; hi != 0 -> d > 0
   CPX #0
   BNE d_pos
   LDA #0                                  ; d == 0: sxL = 0, boxx 0, NO flag
   BEQ d_store                             ; (always)
d_pos:
   LDA #4                                  ; d > 0: sxL = 4
   BNE d_store
d_neg:
   INC t1                                  ; d < 0: outside-left flag
   LDA #0
   SEC
   SBC CABS+0                              ; |d| = -d
   STA CABS+0
   LDA #0
   SBC CABS+4
   STA CABS+4
   LDA #0                                  ; sxL = 0
d_store:
   STA CABS+8
; ---- e = right - px: |e| -> CABS+1/+5, sxR -> CABS+9 ----
   LDY zp_node_ch_l
   SEC
   LDA BBP_R_LO+(s)*$100,Y
   SBC bca_pxs
   STA CABS+1
   LDA BBP_R_HI+(s)*$100,Y
   SBC bca_pxs+1
   STA CABS+5
   BMI e_neg
   LDA #0                                  ; e >= 0: sxR = 0
   BEQ e_store
e_neg:
   LDA #0
   SEC
   SBC CABS+1                              ; |e| = -e
   STA CABS+1
   LDA #0
   SBC CABS+5
   STA CABS+5
   LDA #4                                  ; e < 0: sxR = 4
e_store:
   STA CABS+9
; ---- f = py - top: |f| -> CABS+2/+6, syT -> CABS+10; boxy candidate ----
   LDY zp_node_ch_l
   SEC
   LDA bca_pys
   SBC BBP_T_LO+(s)*$100,Y
   STA CABS+2
   TAX
   LDA bca_pys+1
   SBC BBP_T_HI+(s)*$100,Y
   STA CABS+6
   BMI f_neg
   BNE f_pos
   CPX #0
   BNE f_pos
   LDA #0                                  ; f == 0: syT = 0, boxy 0, NO flag
   STA CABS+10
   BEQ f_by0
f_pos:
   INC t1                                  ; f > 0: viewer above -> flag
   LDA #2
   STA CABS+10                             ; syT = 2
   LDA #0
f_by0:
   STA pa_sy                               ; boxy = 0 resolved (pa_sy = scratch)
   BEQ g_go                                ; (always: A = 0)
f_neg:
   LDA #0
   STA CABS+10                             ; syT = 0
   SEC
   SBC CABS+2                              ; |f| = -f
   STA CABS+2
   LDA #0
   SBC CABS+6
   STA CABS+6
   LDA #$FF
   STA pa_sy                               ; boxy deferred to g's sign
g_go:
; ---- g = py - bot: |g| -> CABS+3/+7, syB -> CABS+11; resolve boxy ----
   LDY zp_node_ch_l
   SEC
   LDA bca_pys
   SBC BBP_B_LO+(s)*$100,Y
   STA CABS+3
   LDA bca_pys+1
   SBC BBP_B_HI+(s)*$100,Y
   STA CABS+7
   BMI g_neg
   BNE g_pos
   LDA CABS+3
   BNE g_pos
   LDA #0                                  ; g == 0: syB = 0
   STA CABS+11
   BEQ g_resolve1                          ; deferred boxy -> 1 (g >= 0)
g_pos:
   LDA #2                                  ; g > 0: syB = 2
   STA CABS+11
g_resolve1:
   LDA pa_sy
   BPL g_haveby                            ; boxy already 0
   LDA #1                                  ; f<0, g>=0: between
   BNE g_haveby
g_neg:
   LDA #0
   STA CABS+11                             ; g < 0: syB = 0
   SEC
   SBC CABS+3                              ; |g| = -g
   STA CABS+3
   LDA #0
   SBC CABS+7
   STA CABS+7
   LDA pa_sy
   BPL g_haveby                            ; boxy already 0 (f >= 0)
   INC t1                                  ; f<0 && g<0: below -> flag
   LDA #2
g_haveby:
   TAX                                     ; X = boxy
; ---- boxx from the sign bytes (flags for x already/hereby placed) ----
   LDA CABS+8
   BEQ bx_0                                ; d <= 0 -> boxx 0
   LDA CABS+9
   BEQ bx_1                                ; d>0, e >= 0 -> boxx 1
   INC t1                                  ; d>0, e<0: outside-right flag
   LDA #2
   BNE bx_have
bx_1:
   LDA #1
   BNE bx_have
bx_0:
   LDA #0
bx_have:
   STA t0                                  ; boxx
   TXA                                     ; A = boxy
   JMP jout
.endscope
.endmacro
bcls_s0:
BCLS_SIDE 0, cx_compose
bcls_s1:
BCLS_SIDE 1, cx_compose

cx_compose:
; X = boxy*4 + boxx (A = boxy in)
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
; corner_phi_f — FUSED corner core (2026-07-17): the abs/octant fold
; moved into stage_c (ZC segment), which feeds this entry the staged
; operands directly from the classify stash. Contract:
;   in : sd_num < sd_den (strict — stage_c diverts diagonals and the
;        zero corner), X = oct (sx|sy|axgt, pre-shifted),
;        pa_sy = the 3rd memo key byte (numhi | denhi<<2 | oct<<4)
;   out: A = r hi, Y = r lo (cp_havepsi contract); pa_res = r
; MEMO — TA GRAIN (2026-07-17 v2): memoize (num,den) -> ta, BEFORE the
; signs enter. ta = tantoangle[slope_div(num,den)] doesn't depend on
; oct, so MIRROR corners (same magnitudes, different quadrant) SHARE
; entries — better hit rate than corner-grain, and the 3rd key byte
; (numhi | denhi<<2) falls out of stage_c's staging for free (the
; oct<<4 pack build died: it was the v1 regression — key manufacture
; cost more than the fusion saved). Hits skip slope_div + the TA
; lookup and land in comb with X = oct; diagonal/zero corners bypass
; the memo entirely (constant ta, own tails).
corner_phi_f:
   LDA sd_num
   EOR sd_den
   AND #$7F
   TAY
   LDA CPM_EP,Y
   CMP zp_cpm_frame
   BNE cpf_miss
   LDA CPM_KDXL,Y                          ; K_NUM
   CMP sd_num
   BNE cpf_miss
   LDA CPM_KDYL,Y                          ; K_DEN
   CMP sd_den
   BNE cpf_miss
   LDA CPM_KDXH,Y                          ; K_PACK (numhi | denhi<<2)
   CMP pa_sy
   BNE cpf_miss
   LDA CPM_PSIL,Y                          ; HIT: cached ta -> comb (X = oct)
   STA pa_res
   LDA CPM_PSIH,Y
   STA pa_res+1
   JMP comb
cpf_miss:
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
; --- memo STORE: (num,den,packlite) -> ta, before the signs fold in
;     (X = oct must survive into comb; Y is dead after the TA reads —
;     recompute the slot in Y) ---
   LDA sd_num
   EOR sd_den
   AND #$7F
   TAY
   LDA sd_num
   STA CPM_KDXL,Y                          ; K_NUM
   LDA sd_den
   STA CPM_KDYL,Y                          ; K_DEN
   LDA pa_sy
   STA CPM_KDXH,Y                          ; K_PACK
   LDA pa_res
   STA CPM_PSIL,Y                          ; ta lo
   LDA pa_res+1
   STA CPM_PSIH,Y                          ; ta hi
   LDA zp_cpm_frame
   STA CPM_EP,Y
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
; ============================================================================
; stage_c — stage ONE silhouette corner from the classify stash and run
; the fused corner core. The FUSION (2026-07-17): classify already
; computed |delta| + corner-sign for all four box edges, so a corner is
; just a (x-slot, y-slot) pick — no plane re-reads, no subtracts, no
; abs/octant fold.
;   in : X = x slot (0 = |d|/left, 1 = |e|/right)
;        Y = y slot (2 = |f|/top,  3 = |g|/bot)
;   out: A = r hi, Y = r lo (cp_havepsi contract)
; Diagonals (|x| == |y|, ties fold axgt=0 exactly like the old
; pa_equal) and the zero corner short-circuit here — corner_phi_f
; receives strict num < den only.
; ============================================================================
stage_c:
   LDA CABS+8,X                            ; sx (0/4)
   ORA CABS+8,Y                            ; | sy (0/2)
   STA pa_sx                               ; oct sans axgt
   LDA CABS+4,X                            ; |x| hi
   CMP CABS+4,Y
   BCC sc_ns                               ; |x| < |y|: no swap
   BNE sc_sw
   LDA CABS+0,X
   CMP CABS+0,Y
   BEQ sc_eq                               ; |x| == |y|: diagonal / zero
   BCC sc_ns
sc_sw:
; axgt: num = |y| (min), den = |x| (max), oct |= 1
   LDA CABS+0,Y
   STA sd_num
   LDA CABS+4,Y
   STA sd_num+1
   LDA CABS+0,X
   STA sd_den
   LDA CABS+4,X
   STA sd_den+1
   LDA CABS+4,X                            ; den hi for the key pack
   ASL A
   ASL A
   ORA CABS+4,Y                            ; | num hi
   STA pa_sy
   LDA pa_sx
   ORA #1                                  ; oct |= axgt
   TAX
   BNE sc_go                               ; (always: oct|1 != 0)
sc_ns:
; num = |x| (min), den = |y| (max), axgt = 0
   LDA CABS+0,X
   STA sd_num
   LDA CABS+4,X
   STA sd_num+1
   LDA CABS+4,Y
   ASL A
   ASL A
   ORA CABS+4,X                            ; den hi<<2 | num hi
   STA pa_sy
   LDA CABS+0,Y
   STA sd_den
   LDA CABS+4,Y
   STA sd_den+1
   LDX pa_sx                               ; X = oct (axgt 0)
sc_go:
   JMP corner_phi_f
sc_eq:
; |x| == |y|: the zero corner -> psi = 0; else the exact diagonal ->
; ta = ANG45 = 512 directly (no divide, no table), oct with axgt = 0
; (ties fold |dx| <= |dy|, byte-exact to the old pa_equal).
   LDA CABS+0,X
   ORA CABS+4,X
   BNE sc_diag
   LDA #0
   STA pa_res
   STA pa_res+1
   JMP cp_havepsi
sc_diag:
; own tail — comb now falls into the MEMO STORE, and this path's
; sd_num/sd_den/pa_sy still hold the PREVIOUS corner's key (a store
; here poisoned the memo — the 63-case bca failure). ta = ANG45 =
; $0200, so psi = base +/- 512 is a pure hi-byte add (lo stays 0),
; byte-exact to the old pa_equal -> comb arms.
   LDX pa_sx                               ; X = oct
   LDA pa_sign,X
   BMI scd_sub
   LDA pa_base_hi,X
   CLC
   ADC #2                                  ; psi = base + ANG45
   BNE scd_have                            ; (base_hi+2 in {2,6,10,14}: always)
scd_sub:
   LDA pa_base_hi,X
   SEC
   SBC #2                                  ; psi = base - ANG45
scd_have:
   AND #$0F
   STA pa_res+1
   LDA #0
   STA pa_res
   JMP cp_havepsi
; ============================================================================
; zc_corners — silhouette-corner dispatch. SIDE-AGNOSTIC since the
; fusion (the stash already absorbed the side-baked plane reads), so
; the 16 arms are 8 and the table is indexed by boxpos alone.
;   in : X = boxpos (box_classify); out: bca_p1/p2 = r1/r2 (raw)
; RTS-dispatch: the arm's RTS returns to zc_corners' caller.
; ============================================================================
zc_corners:
   LDA zc_tab_hi,X
   PHA
   LDA zc_tab_lo,X
   PHA
   RTS                                     ; dispatch; arm RTSes to our caller
; corner roles per zone: (x slot, y slot) — 0=L,1=R / 2=T,3=B
.macro ZARM2 kx1, ky1, kx2, ky2
   LDX #kx1
   LDY #ky1
   JSR stage_c
   STA bca_p1+1
   STY bca_p1
   LDX #kx2
   LDY #ky2
   JSR stage_c
   STA bca_p2+1
   STY bca_p2
   RTS
.endmacro
zc0:  ZARM2 1,2, 0,3                    ; NW : (R,T) (L,B)
zc1:  ZARM2 1,2, 0,2                    ; N  : (R,T) (L,T)
zc2:  ZARM2 1,3, 0,2                    ; NE : (R,B) (L,T)
zc4:  ZARM2 0,2, 0,3                    ; W  : (L,T) (L,B)
zc6:  ZARM2 1,3, 1,2                    ; E  : (R,B) (R,T)
zc8:  ZARM2 0,2, 1,3                    ; SW : (L,T) (R,B)
zc9:  ZARM2 0,3, 1,3                    ; S  : (L,B) (R,B)
zc10: ZARM2 0,3, 1,2                    ; SE : (L,B) (R,T)
zc_tab_lo:
   .byte <(zc0-1),<(zc1-1),<(zc2-1)
   .byte <(zc0-1)                          ; row 3 unused
   .byte <(zc4-1)
   .byte <(zc0-1)                          ; row 5 = inside (escapes earlier)
   .byte <(zc6-1)
   .byte <(zc0-1)                          ; row 7 unused
   .byte <(zc8-1),<(zc9-1),<(zc10-1)
zc_tab_hi:
   .byte >(zc0-1),>(zc1-1),>(zc2-1)
   .byte >(zc0-1)
   .byte >(zc4-1)
   .byte >(zc0-1)
   .byte >(zc6-1)
   .byte >(zc0-1)
   .byte >(zc8-1),>(zc9-1),>(zc10-1)

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

