
; ZCF: one corner fetch — the CALLER owns Y = node. Classify leaves
; deliver it for the first fetch; the second fetch re-loads it at the
; use site (corner_phi returns r lo in Y). One macro, no ZCF1 split
; (2026-07-19). The zone store died with the zone byte.
.macro ZCF s, xl, yl
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
   EOR pa_dx                               ; memo slot hashed HERE (Eben
   AND #$7F                                ; 2026-07-19): dy lo is in A and
   TAX                                     ; dx is banked — the entries'
                                           ; reload-and-rehash head died.
                                           ; EOR/AND/TAX keep C for the SBC.
   LDA yl+$200+(s)*$100,Y
   SBC bca_pys+1
   STA pa_dy+1
.endmacro
; partial fetches for the axis-sharing rows. Rows 4/9 (P-class shared
; axis): pa_dx/pa_dy survive c1's call untouched — the carried value
; is free. Rows 1/6 (N-class shared axis): c1's entry negates the
; shared slot in place on a memo MISS — but the miss just BANKED the
; raw key into the CPM planes, and on a HIT the planes matched the
; key, so either way CPM_KD*[zp_cpm_slot] holds c1's RAW deltas after
; the call (mask_done stores psi only; nothing else touches the slot).
; The shared axis therefore reloads from the MEMO (ZCF_MEMO_*): no
; BBP fetch, no subtract, class-independent — the full-fetch fallback
; died 2026-07-19.
.macro ZCF_DX s, xl
   SEC
   LDA xl+(s)*$100,Y
   SBC bca_pxs
   STA pa_dx
   EOR pa_dy                               ; slot hash (pa_dy carried or
   AND #$7F                                ; memo-reloaded FIRST — order
   TAX                                     ; matters in the SYM/SXM arms)
   LDA xl+$200+(s)*$100,Y
   SBC bca_pxs+1
   STA pa_dx+1
.endmacro
.macro ZCF_DY s, yl
   SEC
   LDA yl+(s)*$100,Y
   SBC bca_pys
   STA pa_dy
   EOR pa_dx                               ; slot hash (pa_dx carried)
   AND #$7F
   TAX
   LDA yl+$200+(s)*$100,Y
   SBC bca_pys+1
   STA pa_dy+1
.endmacro
; shared-axis reload from the memo key planes (see the note above):
; valid after ANY class entry, hit or miss.
.macro ZCF_MEMO_DX
   LDX zp_cpm_slot
   LDA CPM_KDXL,X
   STA pa_dx
   LDA CPM_KDXH,X
   STA pa_dx+1
.endmacro
.macro ZCF_MEMO_DY
   LDX zp_cpm_slot
   LDA CPM_KDYL,X
   STA pa_dy
   LDA CPM_KDYH,X
   STA pa_dy+1
.endmacro
.macro ZARM s, x1, y1, x2, y2, e1, e2
   ZCF s, x1, y1                           ; Y = node from the classify leaf
   JSR e1                                  ; sign-class corner_phi entry —
   STA bca_p1+1                            ; the arm's zone fixes each
   STY bca_p1                              ; corner's delta signs statically
   LDY zp_node_ch_l                        ; (corner_phi returned r lo in Y)
   ZCF s, x2, y2
   JSR e2
   JMP bca_tail                            ; p2 rides A/Y (tail stores it)                            ; chained: no return trip
.endmacro
.macro ZARM_SX s, x1, y1, y2, e1, e2      ; corners share the x plane
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   LDY zp_node_ch_l
   ZCF_DY s, y2                            ; pa_dx carried over
   JSR e2
   JMP bca_tail                            ; p2 rides A/Y (tail stores it)                            ; chained
.endmacro
.macro ZARM_SY s, x1, y1, x2, e1, e2      ; corners share the y plane
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   LDY zp_node_ch_l
   ZCF_DX s, x2                            ; pa_dy carried over
   JSR e2
   JMP bca_tail                            ; p2 rides A/Y (tail stores it)                            ; chained
.endmacro
.macro ZARM_SYM s, x1, y1, x2, e1, e2     ; shared y, N-class c1: the raw
   ZCF s, x1, y1                           ; dy comes back from the MEMO
   JSR e1
   STA bca_p1+1
   STY bca_p1
   ZCF_MEMO_DY                             ; c1's slot read FIRST — the
   LDY zp_node_ch_l                        ; hashing ZCF_DX then computes
   ZCF_DX s, x2                            ; c2's slot into X
   JSR e2
   JMP bca_tail                            ; p2 rides A/Y (tail stores it)
.endmacro
.macro ZARM_SXM s, x1, y1, y2, e1, e2     ; shared x, N-class c1: the raw
   ZCF s, x1, y1                           ; dx comes back from the MEMO
   JSR e1
   STA bca_p1+1
   STY bca_p1
   ZCF_MEMO_DX                             ; c1's slot read FIRST
   LDY zp_node_ch_l
   ZCF_DY s, y2
   JSR e2
   JMP bca_tail                            ; p2 rides A/Y (tail stores it)
.endmacro

; ============================================================================
; CLASSIFY_TREE — ONE side's complete classifier (2026-07-19, Eben's
; restructure): x ladder, then the three columns sorted LEFT / MID /
; RIGHT, each column top-to-bottom (T test, top arm, B test, bottom
; arm, mid arm), with EVERY corner arm inlined at its leaf — the ZC
; out-of-line arms and their leaf JMPs died. Instantiated twice
; (side 1 falls in from box_classify, side 0 rides the head stub);
; every label is .local and the side is baked into every plane
; operand at expansion time.
; The M/R columns sit past the fat L column, out of short-branch
; reach of the ladder, so their ladder exits ride JMP stubs — the
; same 6 cycles as the old direct-branch + leaf-JMP pair, while the
; top/bot/mid leaves now FALL straight into their arms (-3 per run).
; Corner rows per column (checkcoord baked; sign classes P = >=0,
; N = <=0 derived from the column/band):
;   L: top=row 0 (NW)  bot=row 8 (SW)   mid=row 4 (W, shared L plane)
;   M: top=row 1 (N, shared T via MEMO) bot=row 9 (S, shared B)
;      mid=closed inside band -> cx sentinel
;   R: top=row 2 (NE)  bot=row 10 (SE)  mid=row 6 (E, shared R via MEMO)
; ============================================================================
.macro CLASSIFY_TREE s
   .local xge, xge_nr, ymj, yrj
   .local yL, yLlo, yLlo_nr, yLtop, yLbot, yLmid
   .local yM, yMlo, yMlo_nr, yMtop, yMbot, cxi
   .local yR, yRlo, yRlo_nr, yRtop, yRbot, yRmid
; --- x ladder ---
   LDA bca_pxs+1
   CMP BBP_L_HI+(s)*$100,Y
   BCC yL                                  ; px <= L: LEFT (fat, forward)
   BNE xge_nr
   LDA BBP_L_LO+(s)*$100,Y                 ; hi tie: INVERTED (plane in A) —
   CMP bca_pxs                             ; C = L_lo >= px_lo: <= decided
   BCS yL                                  ; by ONE branch
xge:
   LDA bca_pxs+1                           ; (inverted-lo fall only: the hi
xge_nr:                                    ; BNE arrives with pxs+1 live)
   CMP BBP_R_HI+(s)*$100,Y
   BCC ymj                                 ; px < R (hi): MID via stub
   BNE yrj                                 ; px > R strictly (hi): RIGHT stub
   LDA BBP_R_LO+(s)*$100,Y                 ; hi tie: INVERTED —
   CMP bca_pxs                             ; C = R_lo >= px_lo: px <= R
   BCS ymj                                 ; is mid; fall = strict right
yrj:
   JMP yR
ymj:
   JMP yM
; --- LEFT column ---
yL:
   LDA bca_pys+1
   CMP BBP_T_HI+(s)*$100,Y
   BCC yLlo_nr                             ; py < T (hi): bottom test
   BNE yLtop                               ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO+(s)*$100,Y
   BCC yLlo
yLtop:                                     ; py >= T: row 0 (NW) INLINE
   ZARM s, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO, corner_phi_pn, corner_phi_pn
yLlo:
   LDA bca_pys+1                           ; (lo-tier arrivals only: the hi
yLlo_nr:                                   ; BCC arrives with pys+1 live)
   CMP BBP_B_HI+(s)*$100,Y
   BCC yLbot                               ; py < B strictly (hi)
   BNE yLmid                               ; py > B (hi): mid band
   LDA bca_pys
   CMP BBP_B_LO+(s)*$100,Y
   BCS yLmid                               ; py >= B: mid band
yLbot:                                     ; row 8 (SW) INLINE
   ZARM s, BBP_L_LO, BBP_T_LO, BBP_R_LO, BBP_B_LO, corner_phi_pp, corner_phi_pp
yLmid:                                     ; row 4 (W) INLINE
   ZARM_SX s, BBP_L_LO, BBP_T_LO, BBP_B_LO, corner_phi_pp, corner_phi_pn
; --- MID column ---
yM:
   LDA bca_pys+1
   CMP BBP_T_HI+(s)*$100,Y
   BCC yMlo_nr
   BNE yMtop
   LDA bca_pys
   CMP BBP_T_LO+(s)*$100,Y
   BCC yMlo
yMtop:                                     ; row 1 (N) INLINE, memo-shared T
   ZARM_SYM s, BBP_R_LO, BBP_T_LO, BBP_L_LO, corner_phi_pn, corner_phi_nn
yMlo:
   LDA bca_pys+1
yMlo_nr:
   CMP BBP_B_HI+(s)*$100,Y
   BCC yMbot
   BNE cxi
   LDA bca_pys
   CMP BBP_B_LO+(s)*$100,Y
   BCS cxi
yMbot:                                     ; row 9 (S) INLINE
   ZARM_SY s, BBP_L_LO, BBP_B_LO, BBP_R_LO, corner_phi_np, corner_phi_pp
cxi:
; closed viewer-in-box band: publish the FULL-span sentinel (p1 = 0,
; p2 = $0800, span 2048) — rcache cold's ordinary span test marks
; FULL off it; psi planes are never consulted under FULL.
   LDA #0
   STA bca_p1
   STA bca_p1+1
   STA bca_p2
   LDA #8
   STA bca_p2+1
   JMP full_vis
; --- RIGHT column ---
yR:
   LDA bca_pys+1
   CMP BBP_T_HI+(s)*$100,Y
   BCC yRlo_nr
   BNE yRtop
   LDA bca_pys
   CMP BBP_T_LO+(s)*$100,Y
   BCC yRlo
yRtop:                                     ; row 2 (NE) INLINE
   ZARM s, BBP_R_LO, BBP_B_LO, BBP_L_LO, BBP_T_LO, corner_phi_nn, corner_phi_nn
yRlo:
   LDA bca_pys+1
yRlo_nr:
   CMP BBP_B_HI+(s)*$100,Y
   BCC yRbot
   BNE yRmid
   LDA bca_pys
   CMP BBP_B_LO+(s)*$100,Y
   BCS yRmid
yRbot:                                     ; row 10 (SE) INLINE
   ZARM s, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO, corner_phi_np, corner_phi_np
yRmid:                                     ; row 6 (E) INLINE, memo-shared R
   ZARM_SXM s, BBP_R_LO, BBP_B_LO, BBP_T_LO, corner_phi_nn, corner_phi_np
.endmacro

; ============================================================================
; box_classify — the whole classifier lives in the ZC segment (flat:
; CODE region — it no longer fits ANG with every arm inline; banked:
; CODE as always). zc_corners/zc_end bound the harness PC window.
;   in : zp_node_ch_l, zp_bbox_side, bca_pxs/pys (offset-binned hi)
;   out: control at a corner arm (JMP bca_tail) or cx -> full_vis
; ============================================================================
.segment "ZC"
zc_corners:                                ; harness window start
bcls_s0_j:
   JMP bcls_s0                             ; (no fall-in: data precedes)
box_classify:
   LDY zp_node_ch_l                        ; ONE LDY serves both trees
   LDA zp_bbox_side
   BEQ bcls_s0_j                           ; s1 falls in; s0 rides the stub
bcls_s1:
   CLASSIFY_TREE 1
bcls_s0:
   CLASSIFY_TREE 0
zc_end:
.if BANKED
.segment "ANG_BK"
.else
.segment "ANG"
.endif

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
.macro CPM_ENTRY name, negx, negy, obase, tail
   .local cmiss0, cmiss1, cmiss2, cmiss3, czx, czy
.if tail
; TAIL instance (the hottest class, pp = 54% measured): the zero stubs
; sit ABOVE the entry so the main path FALLS straight into lf_ns.
czx:
   JMP ns_dx0
czy:
   JMP ns_dy0
.endif
name:
; ENTRY CONTRACT: X = memo slot = (pa_dx ^ pa_dy) & $7F, hashed by the
; fetch macros where the delta bytes were already in A (the old reload-
; and-rehash head died 2026-07-19). Harness drivers must mirror this
; (test_slope_div sets mpu.x — the wrapper-contract-gap rule).
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
   LDX #obase                              ; HOISTED (tension pass): the slot
                                           ; in X is dead once the key is
                                           ; banked; czx/czy shed their LDX
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
.if tail
; *** FALLS THROUGH into lf_ns *** — corner_phi_pp must stay the LAST
; entry, immediately above lf_ns (mask_done-landmine rule: assembly
; adjacency is load-bearing).
.else
   JMP lf_ns                               ; no compare, no swap: lf_ns reads
                                           ; the axgt bit off the SIGN of the
                                           ; L8 difference
czx:
   JMP ns_dx0
czy:
   JMP ns_dy0
.endif
.endmacro
; oct base = (dx<0)*4 + (dy<0)*2 (P = delta >= 0, N = delta <= 0)
.if ::BANKED = 0
.segment "ANGX"
angx_head:
.endif
CPM_ENTRY corner_phi_nn, 1, 1, 6, 0
CPM_ENTRY corner_phi_pn, 0, 1, 2, 0
CPM_ENTRY corner_phi_np, 1, 0, 4, 0
CPM_ENTRY corner_phi_pp, 0, 0, 0, 1       ; TAIL: falls into lf_ns

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
   ADC #1                                  ; the x16y16 BCC arrives via C=0 too)
   INX                                     ; axgt — falls into the lookup
ns_khave:
   TAY                                     ; k = |s|
   LDA AE_LO,Y
   STA pa_res
   LDA AE_HI,Y
   STA pa_res+1
   JMP comb
ns_x16y16:
; --- both 16-bit: reduce both into t0/t1 (the +96s cancel), then the
;     8-bit shape — indices from the temps, no L8-value staging.
;     TENSIONED (2026-07-19): placed right after the 8-bit arm so the
;     BCC reaches ns_neg DIRECTLY — the ns_neg_j trampoline died. ---
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
   BCC ns_neg                              ; DIRECT (C=0 rides into the ADC #1;
   JMP ns_khave                            ; s == 0 ties ride k = 0, AE[0]=512)
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
   JMP ns_khave                            ; (khave slid out of branch range
                                           ; in the tension reorder)
ns_dy0:
   INX                                     ; |dy| = 0: ta = 0, axgt = 1
ns_dx0:
   LDA #0
   STA pa_res
   STA pa_res+1
   JMP comb
.if ::BANKED = 0
.segment "ANG"
.endif
                                           ; died 2026-07-18 — every runtime
                                           ; caller consumes A/Y, and the unit
                                           ; test reads the registers now.
                                           ; pa_res keeps holding PSI, which
                                           ; is what the memo store wants.)





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

