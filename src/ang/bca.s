.import vc_bit_mask                     ; defq.s: 1 << (n & 7) table
; ============================================================================
; TWO CACHES USED TO LIVE IN THIS FILE.  BOTH ARE GONE — read this before
; reintroducing either.
;
; 1. The bbox EXTENT cache (rcache + the D/forward-coherence wheel), keyed
;    by box ordinal, storing psi1/psi2 in the RC_P1L/P2L/PH planes with an
;    RCACHE_COMPUTED validity bit.  Stripped 2026-09-04 (cadcec0): it cost
;    +2.06% on the armour walk to remove and freed 6 pages of bank B
;    ($A900-$AEFF), RCACHE_STATE's 137 B, RCACHE_COMPUTED's 59 B and 885 B
;    of code.  The walk got that back and more from the dynamic
;    always-descend bit (4cab6b5).
; 2. The corner-phi MEMO: a 128-slot xor-hashed key/psi plane set probed at
;    each corner entry.  Retired 2026-09-04 (b872178) at a 15.5% hit rate —
;    walk -0.54%, suite -0.77%, heavy -1.01% WITHOUT it, because the
;    machinery (hash per fetch, staggered key bank per miss, psi store,
;    slot stash) cost more than the hits bought.  Its key planes had a
;    SECOND job — handing the shared-axis rows their raw delta back across
;    the converters' in-place negation — and that is now four bytes of
;    scratch (corner_sx/corner_sy) filled by ZCF_SAVE_D*.
;
; What is left here is a straight classifier: box_classify computes every
; verdict from scratch, every time.
; ============================================================================

; ($C4/$C5 freed 2026-07-15: the PSI pointer died with the plane
;  conversion — k rides Y and the senior page is an arm.)
rc_bit      = bca_ccsave                ; bit mask for (idx>>3)&7


; ============================================================================
; corner_phi.s — the bbox corner/angle subsystem, end to end:
;
;   box_classify     locate the viewer against a child box (ZC segment)
;   CLASSIFY_TREE    one side's classifier: x ladder + L/M/R columns,
;                    every corner arm inlined at its leaf
;   corner_phi_*     four sign-class entries: the |delta| converters
;                    (ANGX window flat, linear banked)
;   lf_ns            the no-swap log2/atanexp pipeline (ta from |dx|,|dy|)
;   comb .. cp_havepsi  octant compose, r = afn - psi
;
; The whole pipeline is ONE source run: entries, width arms, lf_ns and
; the compose chain sit in a single section, so every load-bearing
; fall-through is adjacent in both builds by construction.
;
; Register discipline (the contracts that make the hot path load-free):
;   Y = node        owned by the classify caller; survives the whole
;                   tree; the arms re-load it only after corner_phi
;                   returns r-lo in Y
;   X = octant      set at the corner entry and held to the exit (it
;                   was the memo slot until 2026-09-04)
;   A = pa_dy+1     every fetch macro exits with the y-delta hi byte
;                   in A, which is the corner entry's contract
; ============================================================================

; ---------------------------------------------------------------------------
; ZCF — one corner fetch: delta = plane - viewer, both axes, s16.
; The CALLER owns Y = node.  Exits with A = pa_dy+1 (the entry
; A-contract).  (The memo's (dx^dy)&$7F slot hash used to ride in the
; middle of this, where dy-lo was already in A; it went with the memo.)
; ---------------------------------------------------------------------------
.macro ZCF s, xl, yl, ck
.ifblank ck
   SEC                                     ; ck set = the leaf's entry arc ;#            0.0
.endif                                     ; proves C=1 (BNE-after-BCC-untaken
                                           ; or BCS — see the ladder analysis
                                           ; at each ZARM below); bot-row
                                           ; leaves arrive via BCC (C=0) and
                                           ; keep the SEC
   LDA xl+(s)*$100,Y                                                      ;# |          0.8
   SBC bca_pxs
   STA pa_dx                                                              ;# |          0.5
   LDA xl+$200+(s)*$100,Y                                                 ;# |          0.8
   SBC bca_pxs+1                                                          ;#            0.1
   STA pa_dx+1                                                            ;#            0.1
   SEC                                                                    ;#            0.3
   LDA yl+(s)*$100,Y                                                      ;# |          0.8
   SBC bca_pys                                                            ;#            0.0
   STA pa_dy                                                              ;# |          0.5
   LDA yl+$200+(s)*$100,Y                                                 ;#            0.0
   SBC bca_pys+1                                                          ;# |          0.6
   STA pa_dy+1
.endmacro
; Partial fetches for the axis-sharing rows: the OTHER delta must
; already be valid (carried over, or restored from scratch first).
; ZCF_DX exits with A = pa_dx+1, so its users re-load dy-hi before the
; JSR to honour the entry A-contract.
.macro ZCF_DX s, xl
   SEC                                                                    ;#            0.0
   LDA xl+(s)*$100,Y                                                      ;#            0.0
   SBC bca_pxs                                                            ;#            0.0
   STA pa_dx                                                              ;#            0.1
   LDA xl+$200+(s)*$100,Y
   SBC bca_pxs+1                                                          ;#            0.1
   STA pa_dx+1
.endmacro
.macro ZCF_DY s, yl
   SEC
   LDA yl+(s)*$100,Y
   SBC bca_pys                                                            ;#            0.0
   STA pa_dy                                                              ;#            0.0
   LDA yl+$200+(s)*$100,Y                                                 ;#            0.3
   SBC bca_pys+1
   STA pa_dy+1
.endmacro
; ---------------------------------------------------------------------------
; ZCF_RESTORE_* — give a shared-axis row its RAW delta back after c1's
; converter negated it in place.  ZCF_SAVE_D* stashed it in four bytes
; of scratch before the JSR.  (Until 2026-09-04 this read the memo's key
; planes X-direct instead, which was free at write time but is what kept
; those 768 bytes alive; see the file header.)
; ---------------------------------------------------------------------------
.macro ZCF_RESTORE_DX
   LDA corner_sx                           ; the scratch ZCF_SAVE_DX filled
   STA pa_dx
   LDA corner_sx+1
   STA pa_dx+1
.endmacro
; stash the raw shared delta BEFORE c1's converter negates it in place
.macro ZCF_SAVE_DX
   LDA pa_dx
   STA corner_sx
   LDA pa_dx+1
   STA corner_sx+1
.endmacro
.macro ZCF_SAVE_DY
   LDA pa_dy
   STA corner_sy
   LDA pa_dy+1
   STA corner_sy+1
.endmacro
.macro ZCF_RESTORE_DY
   LDA corner_sy                           ; the scratch ZCF_SAVE_DY filled
   STA pa_dy
   LDA corner_sy+1
   STA pa_dy+1
.endmacro
; ---------------------------------------------------------------------------
; ZARM family — a corner arm: fetch corner 1, take its phi, fetch
; corner 2, take its phi, chain into bca_tail (which receives p2 in
; A/Y; p1 is stored here — the tail's bt_store derives both psis
; from exactly those two). corner_phi returns r-hi in A, r-lo
; in Y, so the second fetch re-establishes Y = node itself.
;   ZARM      independent corners (full fetch both)
;   ZARM_SX   corners share the x plane, P-class: pa_dx survives c1
;   ZARM_SY   corners share the y plane, P-class: pa_dy survives c1
;   ZARM_SYM  shared y, N-class c1: the raw dy comes back from the MEMO
;   ZARM_SXM  shared x, N-class c1: the raw dx comes back from the MEMO
; SY/SYM's hashing fetch is ZCF_DX (exits A = dx-hi): they re-load
; dy-hi for the entry A-contract.
; ---------------------------------------------------------------------------
.macro ZARM s, x1, y1, x2, y2, e1, e2, ck
   ZCF s, x1, y1, ck                                                      ;# |          1.0
   JSR e1                                                                 ;# |          0.5
   STA bca_p1+1                                                           ;#            0.1
   STY bca_p1                                                             ;#            0.2
   LDY zp_node_ch_l                        ; (r-lo clobbered Y)           ;#            0.1
   ZCF s, x2, y2                                                          ;# |          0.5
   JSR e2                                                                 ;# |          0.5
   JMP bca_tail_postrc                         ; p2 rides A/Y; no return trip ;#            0.4
.endmacro
.macro ZARM_SX s, x1, y1, y2, e1, e2, ck
   ZCF s, x1, y1, ck
   JSR e1                                                                 ;#            0.0
   STA bca_p1+1                                                           ;#            0.0
   STY bca_p1                                                             ;#            0.0
   LDY zp_node_ch_l                                                       ;#            0.0
   ZCF_DY s, y2                            ; pa_dx carried over
   JSR e2                                                                 ;#            0.0
   JMP bca_tail_postrc                                                        ;#            0.0
.endmacro
.macro ZARM_SY s, x1, y1, x2, e1, e2, ck
   ZCF s, x1, y1, ck
   JSR e1                                                                 ;#            0.0
   STA bca_p1+1                                                           ;#            0.0
   STY bca_p1                                                             ;#            0.0
   LDY zp_node_ch_l                                                       ;#            0.0
   ZCF_DX s, x2                            ; pa_dy carried over           ;#            0.0
   LDA pa_dy+1                             ; entry A-contract: dy hi      ;#            0.0
   JSR e2                                                                 ;#            0.0
   JMP bca_tail_postrc                                                        ;#            0.0
.endmacro
.macro ZARM_SYM s, x1, y1, x2, e1, e2, ck
   ZCF s, x1, y1, ck
   ZCF_SAVE_DY                             ; 4-byte scratch (memo retired)
   JSR e1
   STA bca_p1+1
   STY bca_p1                                                             ;#            0.0
   ZCF_RESTORE_DY                             ; c1's slot read FIRST — the
   LDY zp_node_ch_l                        ; hashing ZCF_DX then computes
   ZCF_DX s, x2                            ; c2's slot into X
   LDA pa_dy+1                             ; entry A-contract: dy hi
   JSR e2
   JMP bca_tail_postrc  
.endmacro
.macro ZARM_SXM s, x1, y1, y2, e1, e2, ck
   ZCF s, x1, y1, ck
   ZCF_SAVE_DX                             ; 4-byte scratch (memo retired)
   JSR e1
   STA bca_p1+1
   STY bca_p1
   ZCF_RESTORE_DX                             ; c1's slot read FIRST
   LDY zp_node_ch_l
   ZCF_DY s, y2
   JSR e2
   JMP bca_tail_postrc  
.endmacro

; ============================================================================
; CLASSIFY_TREE — one side's complete classifier, pure diverging
; control flow: the x ladder picks a column (L / M / R), each column
; owns a copy of the hi-first y ladder, and every leaf IS its corner
; arm, inlined — (row, side) are static at the leaf, so the corner
; planes and both corners' delta sign classes are baked into the
; operands and the entry choice. Instantiated once per side (all
; labels .local); the side is the +$100 term in every plane operand.
;
; Corner rows per column (checkcoord baked; classes P = delta >= 0,
; N = delta <= 0, both CLOSED — a zero delta is legal in either):
;   L: top = row 0 (NW)   bot = row 8 (SW)   mid = row 4 (W, shared L)
;   M: top = row 1 (N, T shared via MEMO)    bot = row 9 (S, shared B)
;      mid = closed viewer-in-box band -> cx sentinel
;   R: top = row 2 (NE)   bot = row 10 (SE)  mid = row 6 (E, shared R)
;
; Geometry: the fat L column (the majority of arm runs) is ladder-
; adjacent — its exits are direct branches. M and R sit beyond
; short-branch reach, so their ladder exits ride JMP stubs (the same
; cost a direct branch + an out-of-line leaf JMP would be), and their
; leaves fall straight into their inlined arms. Every internal branch
; skips at most one arm body (~90 B), well inside range.
;
; Compare discipline (all four two-tier tests share it):
;   - hi tier first: one 8-bit compare decides unless the hi bytes tie
;     (coordinates are offset-binned, so the compares are unsigned)
;   - a branch that lands past the next tier's reload enters at the
;     _nr label: the hi-decided path still holds the operand in A
;   - lo tiers that need "<=" load the PLANE and compare the value —
;     carry alone covers < and =, one branch (a "<=" test wants the
;     table in A; a strict "<" wants the value in A)
;
; Boundary semantics: the box test is CLOSED. px == L joins the left
; column, px == R joins mid, py == T joins top, py >= B joins mid.
; The mid/mid case is the viewer inside-or-on the closed box: cx
; publishes p1 = 0, p2 = $0A00 (span exactly 2048), and the check's
; ordinary span test reads that as full visibility — which is also
; geometrically exact for on-boundary viewers (a closed-boundary
; viewer sees the box subtend at least a half-plane). The routing
; also guarantees no arm ever fetches a corner coinciding with the
; viewer, so a (0,0) delta pair is unreachable downstream.
;   in : Y = node (from box_classify), zp_bbox_side baked as s,
;        bca_pxs/pys = viewer, offset-binned hi bytes
;   out: control at a corner arm (-> bca_tail) or cx (-> full_vis)
; ============================================================================
.macro CLASSIFY_TREE s
   .local xge, xge_nr, ymj, yrj
   .local yL, yLlo, yLlo_nr, yLtop, yLbot, yLmid
   .local yM, yMlo, yMlo_nr, yMtop, yMbot, cxi
   .local yR, yRlo, yRlo_nr, yRtop, yRbot, yRmid
; --- x ladder ---
   LDA bca_pxs+1
   CMP BBP_L_HI+(s)*$100,Y                                                ;#            0.4
   BCC yL                                  ; px < L (hi): LEFT, direct    ;#            0.2
   BNE xge_nr                              ; px > L (hi): right-of tests, ;#            0.2
                                           ; pxs+1 still live
   LDA BBP_L_LO+(s)*$100,Y                 ; hi tie: plane in A —         ;#            0.4
   CMP bca_pxs                             ; C = L_lo >= px_lo, so ONE    ;# |          0.6
   BCS yL                                  ; branch covers px <= L        ;#            0.2
xge:
   LDA bca_pxs+1                           ; (inverted-lo fall only)      ;#            0.3
xge_nr:
   CMP BBP_R_HI+(s)*$100,Y
   BCC ymj                                 ; px < R (hi): MID via stub    ;#            0.2
   BNE yrj                                 ; px > R (hi): RIGHT via stub
   LDA BBP_R_LO+(s)*$100,Y                 ; hi tie: px <= R is mid,      ;# |          0.6
   CMP bca_pxs                             ; one BCS; fall = strict       ;# |          0.5
   BCS ymj                                 ; right
yrj:
   JMP yR
ymj:
   JMP yM                                                                 ;#            0.1
; --- LEFT column (ladder-adjacent, all exits direct) ---
yL:
   LDA bca_pys+1                                                          ;#            0.0
   CMP BBP_T_HI+(s)*$100,Y                                                ;#            0.0
   BCC yLlo_nr                             ; py < T (hi): bottom test,
                                           ; pys+1 still live
   BNE yLtop                               ; py > T strictly (hi)         ;#            0.0
   LDA bca_pys
   CMP BBP_T_LO+(s)*$100,Y
   BCC yLlo
yLtop:                                     ; py >= T: row 0 (NW)
   ZARM s, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO, corner_phi_pn, corner_phi_pn, 1 ;#            0.2
yLlo:
   LDA bca_pys+1                           ; (lo-tier arrivals only)
yLlo_nr:
   CMP BBP_B_HI+(s)*$100,Y                                                ;#            0.0
   BCC yLbot                               ; py < B strictly (hi)
   BNE yLmid                               ; py > B (hi): mid band
   LDA bca_pys                                                            ;#            0.0
   CMP BBP_B_LO+(s)*$100,Y
   BCS yLmid                               ; py >= B: mid band            ;#            0.0
yLbot:                                     ; py < B: row 8 (SW)
   ZARM s, BBP_L_LO, BBP_T_LO, BBP_R_LO, BBP_B_LO, corner_phi_pp, corner_phi_pp
yLmid:                                     ; row 4 (W): corners share L
   ZARM_SX s, BBP_L_LO, BBP_T_LO, BBP_B_LO, corner_phi_pp, corner_phi_pn, 1 ;#            0.1
; --- MID column ---
yM:
   LDA bca_pys+1                                                          ;#            0.1
   CMP BBP_T_HI+(s)*$100,Y                                                ;#            0.1
   BCC yMlo_nr                                                            ;#            0.0
   BNE yMtop                                                              ;#            0.1
   LDA bca_pys                                                            ;#            0.0
   CMP BBP_T_LO+(s)*$100,Y                                                ;#            0.1
   BCC yMlo                                                               ;#            0.0
yMtop:                                     ; row 1 (N): corners share T,
                                           ; c1 negates it -> memo reload
   ZARM_SYM s, BBP_R_LO, BBP_T_LO, BBP_L_LO, corner_phi_pn, corner_phi_nn, 1 ;# |          0.9
yMlo:
   LDA bca_pys+1                                                          ;#            0.1
yMlo_nr:
   CMP BBP_B_HI+(s)*$100,Y                                                ;#            0.1
   BCC yMbot                                                              ;#            0.0
   BNE cxi
   LDA bca_pys
   CMP BBP_B_LO+(s)*$100,Y                                                ;#            0.0
   BCS cxi                                                                ;#            0.0
yMbot:                                     ; row 9 (S): corners share B
   ZARM_SY s, BBP_L_LO, BBP_B_LO, BBP_R_LO, corner_phi_np, corner_phi_pp
cxi:
; viewer inside (or on the boundary of) the CLOSED box: no corners
; ran, so no store-at-birth hooks fire and COMPUTED stays clear — the
; box is naturally uncacheable and re-runs the plain path each frame
; (the classify ladder's inside detect is the cheap case). The old
; $80-marker protocol died with the wrapper scavenge (2026-07-20).
   JMP full_vis                                                           ;#            0.0
; --- RIGHT column ---
yR:
   LDA bca_pys+1                                                          ;# |          0.5
   CMP BBP_T_HI+(s)*$100,Y                                                ;# |          0.6
   BCC yRlo_nr                                                            ;#            0.2
   BNE yRtop
   LDA bca_pys                                                            ;#            0.2
   CMP BBP_T_LO+(s)*$100,Y
   BCC yRlo                                                               ;#            0.2
yRtop:                                     ; py >= T: row 2 (NE)
   ZARM s, BBP_R_LO, BBP_B_LO, BBP_L_LO, BBP_T_LO, corner_phi_nn, corner_phi_nn, 1
yRlo:
   LDA bca_pys+1                                                          ;#            0.3
yRlo_nr:
   CMP BBP_B_HI+(s)*$100,Y                                                ;#            0.2
   BCC yRbot                                                              ;#            0.2
   BNE yRmid                                                              ;#            0.2
   LDA bca_pys                                                            ;#            0.0
   CMP BBP_B_LO+(s)*$100,Y                                                ;#            0.1
   BCS yRmid
yRbot:                                     ; py < B: row 10 (SE)
   ZARM s, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO, corner_phi_np, corner_phi_np ;#            0.4
yRmid:                                     ; row 6 (E): corners share R,
                                           ; c1 negates it -> memo reload
   ZARM_SXM s, BBP_R_LO, BBP_B_LO, BBP_T_LO, corner_phi_nn, corner_phi_np, 1 ;# |||||||||| 8.6
.endmacro

; ============================================================================
; box_classify — THE bbox visibility check body (bbox_check_angle is a
; JMP here). One LDY serves both side trees; the side picks a fully
; side-baked instantiation and is never consulted again.
;   in : zp_node_ch_l, zp_bbox_side, bca_pxs/pys (offset-binned hi)
;   out: control at a corner arm or full_vis; bca_p1 = raw phi 1 in
;        memory. Armed frames (tail vector -> bt_store) also leave
;        the psi planes populated: the store block fires on the way
;        through
; zc_corners/zc_end bound the harness PC window (check_angle_calls).

; ============================================================================
; bbox_check_angle — angle-space bbox visibility (bca_check_op default target).
; Mirrors angle_bbox.bbox_check_angle exactly: faithful DOOM R_CheckBBox in
; our negated-phi convention, conservative screen-column extent, no rotation
; (0 muls; per corner: octant fold + 1 SlopeDiv + tantoangle lookup).
;   in : bca_boxp     -> the 8-byte s16 ROM box (top,bot,left,right)
;        bca_pxs/pys  player int position sign-extended s16 (frame-const)
;        bca_afn      a_fine = view angle in fineangles (frame-const)
;   out: bca_vis (1 visible / 0 cull); bca_ilo/bca_ihi (u8 column extent,
;        valid only when bca_vis=1)
; pseudocode (angle_bbox.bbox_check_angle):
;   if box contains player: return full (0,255)      [box_classify short-exit]
;   cc = checkcoord[boxy*4 + boxx]                    [box_classify -> X]
;   p1 = phi(box[cc0]-px, box[cc1]-py)                # LEFT silhouette corner
;   p2 = phi(box[cc2]-px, box[cc3]-py)                # RIGHT silhouette corner
;   -> bca_tail (span / FOV clip / column lookup, shared with the rot cache)
; ============================================================================

; (scope opened out to file level so the rotation cache — bbox_check_angle_cached
;  + bca_frame below — can share box_classify, corner_phi and the bca_tail
;  span/clip/column code. Tail labels ck_*/full_vis/cull are unique file-wide.)
; (No bca_vis entry preset: EVERY exit stores the verdict — full_vis/cull/
;  cull_far/visok, and box_classify's inside-escape goes through full_vis —
;  so the old LDA #0/STA preset was 5 dead cycles per check, 2026-07-16.)
; bca_pxs/bca_pys (px,py sign-extended to s16) are precomputed once/frame
; by view_setup — frame-constant. Direct unit-test callers set them.
; bca_px/bca_py (s8) are still read below by ins_test/box_pos.
; inside test: left<=px<=right and bot<=py<=top  -> full (0,255)
; left<=px : px-left >= 0
; a_fine (bca_afn) is precomputed once/frame by the caller
; (view_setup), not recomputed here — it is frame-constant. Direct
; unit-test callers (test_bca, check_angle_calls) set bca_afn themselves.
; inside test + boxx/boxy classification share one set of subtractions:
; JMP-THREADED CHAIN (2026-07-18, enabled by the cold-route
; unification making classify/corners single-caller): classify exits
; dispatch straight to the corner arm (push-push-RTS with the zone-
; composed index), the arm falls into bca_tail via JMP, and the tail's
; exits return to OUR caller — the JSR/RTS shuttles at every stage are
; gone. Inside boxes escape via cx_inside -> full_vis directly.
   ; ============================================================================
.if ::BANKED
SEG_CODE
.else
SEG_HIGH                                   ; flat: the probe/serve block lives
                                           ; in the HIGH island (CODE has no
                                           ; room — the 75-byte overflow was
                                           ; measured, not guessed) and the
                                           ; miss bridges with one JMP
.endif
; --- bbox_check_angle: rotation-coherent bbox visibility ----------------------
; Same contract as box_classify (in: zp_node_ch_l/zp_bbox_side, bca_pxs/
; pys, bca_afn; out: the C/V verdict + bca_ilo/ihi) and bit-identical
; results — only cycles change. Warm hits skip the per-corner abs/octant/SlopeDiv/tantoangle work
; and re-derive phi with one subtraction.
;
; PER-SIDE rcaches (2026-07-21, Eben: 'replace rcache with a pair of
; per-side rcaches: lookup moves down next to the two CLASSIFY macro
; uses'): the entry dispatches the side ONCE, and each side owns a
; fully side-baked probe+serve block sitting immediately above its
; classify tree — a probe miss FALLS into its tree, so the old shape's
; two side dispatches (hit -> serve reload, miss -> box_classify head)
; are one. The COMPUTED bitmap keeps the interleaved k = node*2 + side
; encoding — bt_store is untouched — and each probe bakes its side
; into the k & 7 arithmetic (ORA #1 / nothing) instead of ORAing
; zp_bbox_side.
; pseudocode (per side s):
;   k = node*2 + s
;   if COMPUTED[k]: p1 = sgnext((a_fine - psi1_s[node]) & 4095) ...
;   else: stash byte/bit ; fall into CLASSIFY_TREE s (bt_store
;         publishes at birth; an inside box never reaches the tail,
;         fires no stores, stays naturally uncacheable)
; (bbox_check_angle -- the rotation-cache entry -- deleted 2026-09-04;
;  box_classify below is the ONLY entry now.)
zc_corners:                                ; harness window start
box_classify:                              ; THE MOVING-FRAME ENTRY (pristine:
                                           ; no probe, no stores). Standing
                                           ; frames enter at bbox_check_angle
                                           ; above (zp_bv_entry vector).
   LDY zp_node_ch_l                        ; ONE LDY serves both trees    ;# |          0.6
   LDA zp_bbox_side                                                       ;# |          0.6
   BNE bcls_s1                                                            ;# |          0.6
   JMP bcls_s0                                                            ;#            0.3
; --- side 1: probe (side baked), serve, or fall into the tree ---
bcls_s1:
   CLASSIFY_TREE 1                                                        ;# ||         1.8
; --- side 0: mirror (k & 7 = (node & 3)*2, no ORA at all) ---
bcls_s0:
   CLASSIFY_TREE 0                                                        ;# |||||||||  7.6

zc_end:
.if BANKED
SEG_CODE
.else
SEG_HIGH
.endif
; --- Faithful DOOM R_CheckBBox, unsigned-BAM wraparound (FINEANGLES=4096).
; Our phi = -(DOOM view-relative angle), so DOOM angle1=-p1 (p1 = LEFT
; silhouette, checkcoord order), angle2=-p2 (RIGHT). All arithmetic is
; mod-4096 wraparound, which natively handles a silhouette corner behind
; the view plane — the case the old signed-sort logic mis-narrowed
; (over-culled straddling boxes -> far rooms drawn through walls).
; p1/p2 are s16 whose low 12 bits ARE the BAM value (sign extension adds
; multiples of 4096), so 16-bit sub/add + AND #$0F on the hi byte = BAM.
;
; span = (p2 - p1) & 4095 ; span >= ANG180(2048) -> viewer inside the
; box's angular span -> visible full-width.
;
; bca_tail pseudocode (CLIPANGLE=512, 2*CLIPANGLE=1024):
;   span = (p2 - p1) & 4095 ; if span >= 2048: full (0,255)
;   tspan = (512 - p1) & 4095                            # left corner vs FOV
;   if tspan > 1024: cull if tspan-1024 >= span else p1 = -512
;   tspan = (512 + p2) & 4095                            # right corner vs FOV
;   if tspan > 1024: cull if tspan-1024 >= span else p2 = +512
;   ilo = max(0, vatox[p1+512] - 1) ; ihi = min(255, vatox[p2+512] + 1)
;   cull if ilo > ihi else visible
;
; EXTENT SEMANTICS (certified 2026-08-21): (ilo, ihi) is the NATIVE
; HALF-OPEN interval [ilo, ihi) handed to strict span_has_gap — ihi is
; an EXCLUSIVE right edge, NOT a closed rightmost column. Safety story:
; a right-silhouette vertex's own seg claims only [.., sx2) and paints
; (run-out) through sx2, so coverage needs ihi >= max(sx2)+0 for
; claims and >= max(paint)+1 for paints; the margin stack — pack-time
; outward-rounded +1-unit world inflate, the +-EPS one-sided angle
; bias (guarantees no inward angle error, adds nothing outward), the
; vatox bracket centre (can sit 1 col inside true), and the +-1 column
; inflate here — certifies both with slack floor 1-2. The +-1 column
; inflate is LOAD-BEARING (bracket-mid -1 + RN projection +0.5); do
; not drop it. Certificate: tools/bbox_margin_cert.py — 20,030
; viewpoints x every (node,side), 0 violations in all four classes
; (claim/paint x left/right); the only apparent violations were the
; standing seg-staging overflow class (see margin_viol_triage.py:
; off-screen col ~ -0.5 wrapping to a 256-wide claim), float-verified
; STAGING in every case.
; ENTRY CONTRACT (2026-07-19, Eben's convention flip, adjusted): the
; caller hands p2 IN REGISTERS — A = p2 hi, Y = p2 lo, exactly what
; cp_havepsi returns. p2 NEVER LANDS IN MEMORY (bca_p2 died
; 2026-07-19). TWO ENTRIES since store-at-birth (2026-07-20):
; bca_tail is for the corner arms (an armed miss derives BOTH psis
; from p1-in-memory + p2-in-registers and completes the plane entry
; + COMPUTED in bt_store above); bca_tail_postrc is for the rcache
; warm serves, whose plane entry is already complete and whose probe
; stash is stale. NB hi-in-A is pinned by cp_havepsi's borrow
; direction (hi computes last); a lo-in-A flip costs a +4 shuffle
; per corner call — measured worse.
; ---------------------------------------------------------------------------
; bt_store — the armed-miss store block, entered ONLY via the frame's
; tail vector (zp_tail_vec, set by bca_frame): the per-check class
; test died with the vector — a moving frame's arms JMP bca_tail_postrc  
; straight to bca_tail_postrc below. MAX-SQUEEZE
; INSIGHT (2026-07-20): both psis are derivable RIGHT HERE from
; values the tail already owns — p1 is the tail's own working input
; (bca_p1, read by ct_left below), and p2 is the A/Y entry contract —
; via the exact cp_havepsi algebra psi = (afn - r) & 4095. So the
; corner2_* prologues died (no per-corner hooks, no A-contract
; re-establishment, no JMP hop on moving frames) and the STY/STA p2
; banking does double duty as psi2's subtrahend. pa_dx/pa_dy stage
; the pack (dead here, as in the old wrapper scavenge).
; (bt_store -- the rotation-cache store block -- deleted 2026-09-04.)
bca_tail_postrc:                           ; the tail proper — reached from
                                           ; the arms via JMP bca_tail_postrc  
                                           ; when moving, from bt_store when
                                           ; armed, and from the warm serves
                                           ; directly (their entry is already
                                           ; complete, so they must NOT ride
                                           ; the vector)
; REGION-CELL TAIL (2026-07-20, born from Eben's 'why the faff with
; spans?'): the old span + windows factoring was a 1-bit
; approximation of a 3x3 region table over the biased corners —
; F = in-FOV r in [0,1024) strict, R = off-right [1024,2560),
; L = wrapping-left [2560,4096) — and the span >= 2048 pre-test
; existed ONLY to screen the (L,R) cell from the windows' one-bit
; cull test. Classifying each corner directly retires the whole span
; computation (t0/t1 are FREE again):
;        r2: F           R            L
;    r1: F  lookups      [col1,255]   [col1,255]
;        R  [0,col2]     cull         cull
;        L  [0,col2]     FULL         cull
; r1-out with r2 in-FOV = the box wraps in from the left edge
; (coverage [0,col2]) whichever side r1 sits; mirrored for r2-out;
; (L,R) = viewer inside the box's arc = full; same-side and (R,L)
; miss the FOV = cull. ==1024 folds into the out-cells (right: 255,
; identical to the old constant arm; left: ilo 0 supersedes the old
; 254). Verdicts are supersets of exact (per-corner +-EPS through
; monotone vatox); every difference from the span tail is a pure
; TIGHTENING of its span>=2048 -> full blanket. Biased forms: r2'' =
; p2' as delivered (the afn hoist carries +EPS), r1'' = p1' - 2*EPS;
; bca_p1 stays RAW for the rcache snapshot. The python mirror
; implements the SAME table cell for cell.
; classify r2: A = p2' hi (masked by cp_havepsi's exit), Y = p2' lo
   CMP #4                                                                 ;#            0.4
   BCS ct_r2out                            ; r2 >= 1024: R or L           ;# |          0.5
; --- (F,*): ihi = vatox[r2]+1. C=0 (the BCS fell); the pointer ADC's
; carry-out is CONSTANT 0 (r_hi <= 4, link-asserted) and rides into
; the +1 adjust; overflow clamps to 255. ---
   ADC #>VATOX                                                            ;#            0.3
   STA pa_ptr+1                                                           ;#            0.4
   LDA (pa_ptr),Y                          ; vatox[r2]                    ;# |          0.7
   ADC #1                                                                 ;#            0.3
   BCS ct_ih_cl                            ; overflow clamp: rare (0.2%,  ;#            0.3
                                           ; census 2026-07-27, island
                                           ; past visok's fused exit)
ct_ih:
   STA bca_ihi                             ; ihi lands HERE, not in has_gap ;#            0.4
                                           ; (pure-A since Eben's 2026-07-26
                                           ; rewrite): the dst*_ext record
                                           ; store snapshots bca_ilo/bca_ihi
                                           ; after bcls_* returns — visok
                                           ; reloads it for the A-hi call
ct_left:
; r1'' = (p1' - 2*EPS) & 4095 in registers (raw p1' stays in memory)
   LDA bca_p1                                                             ;#            0.4
   SEC                                                                    ;#            0.3
   SBC #(2*EPSILON_F)                                                     ;#            0.3
   TAY                                                                    ;#            0.3
   LDA bca_p1+1                                                           ;#            0.4
   SBC #0                                                                 ;#            0.3
   AND #$0F                                                               ;#            0.3
   CMP #4                                                                 ;#            0.3
   BCS ct_r1out_r2f                        ; r1 out, r2 in: ilo = 0       ;#            0.3
lk_left:
   ADC #>VATOX                             ; C=0 (BCS fell / ct_f_r2out's ;#            0.3
   STA pa_ptr+1                            ; BCC — both arrive C=0)       ;# |          0.5
   LDA (pa_ptr),Y                          ; vatox[r1'']                  ;# |          0.8
   SBC #0                                  ; C=0 (constant carry-out) -> v-1 ;#            0.3
   BCC ct_il_z                             ; v == 0: rare clamp (island); ;#            0.3
                                           ; C rides identically both ways
ct_il:
   STA bca_ilo                                                            ;# |          0.5
; falls into visok, which recovers ihi from X into A (A-hi ABI
; 2026-07-26: has_gap's entry lands bca_ihi/zp_i_h — the pair is
; still the persistent state). NO ilo > ihi check: in (F,F) the
; corners can
; invert by at most 2*EPS (true span < 2048 outside the box, each
; corner within +-EPS), and the left -2*EPS bias plus the -1/+1
; adjusts restore ilo <= ihi; every other cell emits constants in
; order. The python mirror keeps its tripwire.
; C/V-CONTRACT (2026-07-26, supersedes the 2026-07-20 A/Z/C form —
; the A=0/1 materialization is gone from has_gap and from these
; exits). Every CLASSIFY exit returns:
;
;   C = the walk's verdict     C=1 descend (visible + gap)
;                              C=0 skip    (no gap, or angle cull)
;   V = the record-store bit   V=0 extent  (store bca_ilo/bca_ihi)
;                              V=1 angle cull (store code 1)
;   A = ihi on visible exits (has_gap preserves it); undefined on cull
;   Z/N = undefined
;
; The three states: gap C=1/V=0, no-gap C=0/V=0, cull C=0/V=1. The
; walk branches BCS/BCC and never looks at V; the dcap stores branch
; BVS and let C ride through their loads/stores untouched (this
; killed their ROL A/PHA/CMP #1 ... PLA/LSR A encode/restore dance).
;
; WHY V WORKS: no instruction in has_gap touches V (loads, compares,
; CLC, stores only — asserted in its header), so a CLV issued at the
; visible exits below survives the fused call; the tail's own ADC/SBC
; arithmetic is exactly why the CLV must sit HERE, after the last
; V-disturbing op, not at the classify entry.
;
; V SCOPE (read this before adding a consumer): V is defined ONLY at
; the exits of the uncached classify (bcls_* / box_classify) — i.e.
; the paths below. The dcv_* WARM-SERVE arms return C only, V is
; garbage there: serves feed no record store, the walk ignores V, and
; the check_angle harness probes cold frames only (every bbox
; classifies — serves cannot fire). If a new V consumer ever sees
; serve exits, the arms need their own CLV/BIT tails.
;
; full_vis is the CANONICAL full-visibility tail (the rcache warm-full
; path and box_classify's inside case JMP here instead of local copies).
visok:
   CLV                                     ; V=0: extent verdict for the  ;#            0.3
                                           ; dcap store (survives has_gap —
                                           ; see the C/V-CONTRACT above)
   LDA bca_ihi                             ; A-hi ABI (stored at ct_ih /  ;# |          0.5
                                           ; ct_f_r2out)
   JMP span_has_gap                          ; the fused exit IS the verdict: ;# |          0.5
                                           ; C from has_gap, V=0 from the
                                           ; CLV, A = ihi preserved

; --- out-of-line cells (rarer paths) ---------------------------------
; ihi/ilo clamp arms (census 2026-07-27: BCS/BCC re-enter with the SAME
; carry state the old inline fall produced — C=1 into ct_ih, C=0 into
; ct_il — so the downstream carry contracts are untouched)
ct_ih_cl:
   LDA #255
   BNE ct_ih                               ; (always: A = 255)
ct_il_z:
   LDA #0
   BEQ ct_il                               ; (always: A = 0)
ct_r1out_r2f:
   ZERO bca_ilo                            ; (R,F)/(L,F): the box wraps in ;#            0.1
                                        ; from the left edge — ilo = 0
                                        ; (visok reloads A from bca_ihi)
   JMP visok                               ; (bca_ihi stored at ct_ih)    ;#            0.0
ct_r2out:
; A = r2 hi in [4,15]. X is free (the tail entry owns it):
; bank r2's R/L class there, then classify r1.
   LDX #0                                                                 ;#            0.1
   CMP #10                                                                ;#            0.1
   BCC ct_r2have                           ; hi < 10: R (X = 0)           ;#            0.1
   INX                                     ; else L (X = 1)               ;#            0.0
ct_r2have:
   LDA bca_p1                              ; r1'' build (same as ct_left) ;#            0.1
   SEC                                                                    ;#            0.1
   SBC #(2*EPSILON_F)                                                     ;#            0.1
   TAY                                                                    ;#            0.1
   LDA bca_p1+1                                                           ;#            0.1
   SBC #0                                                                 ;#            0.1
   AND #$0F                                                               ;#            0.1
   CMP #4                                                                 ;#            0.1
   BCC ct_f_r2out                          ; r1 in F: [col1, 255]         ;#            0.1
; both corners out: (L,R) -> full, everything else -> cull
   CMP #10                                                                ;#            0.0
   BCC cull                           ; r1 = R: (R,R)/(R,L) cull          ;#            0.0
   CPX #0                                                                 ;#            0.0
   BEQ full_vis                           ; (L,R): full                   ;#            0.0
cull:                                      ; THE cull exit — (L,L) FALLS in
                                           ; off the untaken BEQ above; the
                                           ; others branch direct.
   CLC                                     ; C=0: to the walk a cull IS a ;#            0.0
                                           ; no-gap return (BCC skips)
   BIT cull_rts                            ; V=1 tells the dcap store 'angle ;#            0.1
                                           ; cull' (code 1) apart from
                                           ; no-gap (V=0 via visok's CLV).
                                           ; The operand is the RTS below:
                                           ; opcode $60 has bit6 SET, and an
                                           ; RTS opcode can never change —
                                           ; a self-certifying constant
                                           ; (6502 has no SEV instruction).
                                           ; (BIT also sets Z from A AND $60
                                           ; and N from bit7 — both already
                                           ; undefined in the contract.)
cull_rts:
   RTS                                     ; signature C=0/V=1; A undefined ;#            0.1
full_vis:
   ZERO bca_ilo                                                           ;#            0.1
   CLV                                     ; V=0: extent verdict (see the ;#            0.0
                                           ; C/V-CONTRACT at visok)
   LDA #255                                ; ihi rides in A (A-hi ABI) AND ;#            0.0
   STA bca_ihi                             ; lands for the dst*_ext record ;#            0.0
   JMP span_has_gap                          ; FUSED EXIT (2026-07-18): every ;#            0.0
                                           ; visible exit chains straight into
                                           ; has_gap on the freshly-written
                                           ; interval — the caller gets the
                                           ; combined verdict in C (V=0 rides
                                           ; from the CLV). Cull exits still
                                           ; RTS with C=0/V=1.
ct_f_r2out:
; (F,R)/(F,L): ihi = 255 via X (A holds r1'' hi, Y holds r1'' lo —
; both live into lk_left; the old TAX/LDA/STA/TXA dance is dead).
; C=0 from the BCC — LDX/STX/JMP preserve it into lk_left's pointer
; ADC. The store feeds the dst*_ext record + visok's reload.
   LDX #255                                                               ;#            0.1
   STX bca_ihi                                                            ;#            0.1
   JMP lk_left                                                            ;#            0.1

; ============================================================================
; ROTATION COHERENCE CACHE
; ---------------------------------------------------------------------------
; The corner angle psi = point_to_angle(corner - player) depends ONLY on the
; integer player position; the view angle enters afterwards as phi = a_fine -
; psi (cp_havepsi). So on a frame where the integer player position is
; unchanged, every bbox's two silhouette psi are invariant and phi can be
; re-derived by one subtraction instead of the abs/octant/SlopeDiv/tantoangle.
; Output is bit-identical (only cycles change) -> no Python mirror needed.
;



; ============================================================================
; CORNER_ENTRY — one sign-class corner_phi entry: convert to |dx|/|dy|
; and jump into the shared lf_ns pipeline. Four instances, one per
; (sign dx, sign dy) class: each arm's row fixes both corners' delta
; signs statically, so the converters dead-code the sign tests — P-axes
; are already their own absolute value, N-axes negate pa_dx/pa_dy IN
; PLACE (which is why the shared-axis rows stash first, ZCF_SAVE_D*).
;
; ENTRY CONTRACT: A = pa_dy+1 (the fetch's exit state).
; RETURN CONTRACT: r-hi in A, r-lo in Y. X is the octant all the way
;                 out now — the X = slot contract died with the memo.
;
; Probe: stage 0 compares KDYH against the A the fetch left — no load.
; A miss at stage k enters the store ladder AT k with the mismatched
; byte in A; the bytes before k matched, so the planes already hold
; them and their stores are skipped. Stage order is correctness-free:
; a compare-match means the plane holds that key byte, and the $80
; sentinel in KDXH (an impossible delta hi — |deltas| <= 2047) keeps
; a never-written slot from fully matching at any position, so KDXH
; doubles as the validity plane. The slot is banked to zp ONLY on the
; miss path (the psi store is its sole zp consumer; hits keep it in X).
;
; The key must be banked BEFORE the converters run: the N-class
; in-place negation destroys the raw values the key is made of (the
; memo-shared rows read them back from the key planes).
;
; The x zero-out is load-free: every cmiss path converges on it with
; A = pa_dx+1 (a stage-3 miss carries it from the probe; earlier
; stages exit through the ladder's final LDA pa_dx+1). A zero delta
; skips its negate entirely (-0 = 0, and the ta = 0 paths never read
; the delta again). (0,0) is unreachable — the classify routing
; excludes viewer-coincident corners.
; ============================================================================
.macro CORNER_ENTRY name, negx, negy, obase, fall
   .local czx, czy
.ifnblank fall
; `fall` expansion: the zero-axis arms move ABOVE the entry so the body's
; last instruction falls straight into lf_ns.  They are branch targets
; only (the code above this ends in a JMP), and the body is ~60 bytes, so
; the backward BEQs are comfortably in range.
czx:
   JMP ns_dx0
czy:
   JMP ns_dy0
.endif
name:
; Corner entry, one sign class.  (The corner-phi MEMO that used to sit
; here — 128-slot xor-hashed key/psi planes, probe + staggered key bank +
; psi store — was retired 2026-09-04: measured walk -0.54%, suite -0.77%,
; heavy -1.01% WITHOUT it, at a 15.5% hit rate.  The machinery cost more
; than the hits bought.  b872178 has the numbers.)
   LDX #obase
   LDA pa_dx+1
   ORA pa_dx                               ; A = pa_dx+1 (converged): the ;# |          0.6
   BEQ czx                                 ; x zero-out costs no load     ;#            0.4
.if negx
   LDA #0                                  ; |dx| = -dx in place (dx <= 0) ;#            0.2
   SEC                                                                    ;#            0.2
   SBC pa_dx                                                              ;# |          0.6
   STA pa_dx                                                              ;# |          0.6
   LDA #0                                                                 ;#            0.4
   SBC pa_dx+1                                                            ;#            0.3
   STA pa_dx+1                                                            ;#            0.3
.endif
.if negy
   LDA #0                                  ; |dy| = -dy in place (dy <= 0);
   SEC                                     ; the zero-out folds into the  ;#            0.2
   SBC pa_dy                               ; negate's final ORA           ;#            0.3
   STA pa_dy                                                              ;#            0.3
   LDA #0
   SBC pa_dy+1                                                            ;#            0.3
   STA pa_dy+1                                                            ;#            0.3
   ORA pa_dy                                                              ;#            0.3
   BEQ czy
.else
   LDA pa_dy+1                             ; |dy| = dy already (dy >= 0): ;#            0.3
   ORA pa_dy                               ; just the zero-out            ;#            0.3
   BEQ czy                                                                ;#            0.2
.endif
.ifblank fall
   JMP lf_ns                                                              ;# |          0.6
czx:
   JMP ns_dx0
czy:
   JMP ns_dy0
.endif                                     ; (the fall expansion emitted its
.endmacro                                  ;  arms above the entry instead)
; octant class base = (dx<0)*4 + (dy<0)*2; lf_ns adds axgt.
; PLACEMENT: flat = the ANGX window; banked = linear in ANG_BK. Either
; way the entries, the width arms, lf_ns and the compose chain below
; are one contiguous run.
.if ::BANKED = 0
SEG_HIGHX
angx_head:
.endif
CORNER_ENTRY corner_phi_nn, 1, 1, 6                                          ;# ||||       3.6
CORNER_ENTRY corner_phi_np, 1, 0, 4                                          ;# |          0.6
CORNER_ENTRY corner_phi_pp, 0, 0, 0                                          ;# |          0.5
; corner_phi_pn is expanded LAST, immediately above lf_ns, and falls into
; it: 24.9 of the 66.8 entries a frame, the hottest of the four
; (tools/jump_census.py, 2026-09-05).

; ============================================================================
; Width arms — the 16-bit reductions, placed ABOVE lf_ns so its
; dispatch reaches them with short backward branches and the forward
; space below lf_ns holds the whole compose chain. All are entered
; from lf_ns's dispatch with the tested hi byte still in A (the
; dispatch loads it; LDY/BNE/INX preserve it), so none re-load.
;
; k for mixed widths = L8[big >> 3] + 96 - L8[small]: the >> 3 halves
; the log argument three times and +96 = 3 * 32 re-biases (L8 is a
; 32/octave fixed-point log). A 16-bit magnitude always beats an
; 8-bit one, so axgt is STATIC in the mixed arms (the INX baked in or
; out); both-16-bit reduces both sides and the +96s cancel. The
; reducers shift COPIES in t0/t1 — pa_dx/pa_dy must stay raw-valued
; for the shared-axis rows' carryover.
; ============================================================================
; HALF-BIT RECOVERY (2026-07-19, Eben's averaging idea): the >>3
; reductions no longer truncate — the third shift's carried-out bit
; gates a two-entry average, (L8[i] + L8[i+1] + C) >> 1, with the
; SHIFTED-OUT CARRY ITSELF as the round-to-nearest +1 and the 9-bit
; overflow riding back in through ROR. Index 255 has no neighbour:
; the EOR #$FF test (C-neutral — CPY would eat the carry) skips to
; the flat load, exactly the cert/mirror guard. EPSILON drops 15->12
; certified; only the memoised MISS path pays the ~9 odd-path cycles.
ns_x16y16:
; both 16-bit: reduce and LOOK UP dx first (its half-bit carry is
; fresh), bank L(dx) in t0, then reduce+look up dy and subtract.
   STY t1                                  ; Y = pa_dy+1 (banked at the
                                           ; ns_x16 dispatch) — must land
                                           ; before the LDY below
   LDY pa_dx
   STY t0                                  ; lo staged via Y: A untouched
   LSR A                                   ; A = pa_dx+1 (from lf_ns)
   ROR t0
   LSR A
   ROR t0
   LSR A
   ROR t0                                  ; C = dx's shifted-out half bit
   LDA t0
   TAY
   BCC nsxx_dxflat
   EOR #$FF
   BEQ nsxx_dxflat                         ; index 255: no neighbour
   LDA L8_TAB,Y
   ADC L8_TAB+1,Y                          ; + neighbour + C(=1)
   ROR A                                   ; 9-bit round-to-nearest mean
   JMP nsxx_dxdone
nsxx_dxflat:
   LDA L8_TAB,Y                            ; L8[|dx| >> 3]
nsxx_dxdone:
   STA t0                                  ; t0 = L(dx) (index dead)
   LDA pa_dy
   LSR t1
   ROR A
   LSR t1
   ROR A
   LSR t1
   ROR A                                   ; C = dy's half bit
   TAY
   BCC nsxx_dyflat
   EOR #$FF
   BEQ nsxx_dyflat
   LDA L8_TAB,Y
   ADC L8_TAB+1,Y
   ROR A
   JMP nsxx_sub                            ; join the flat tail (space-
                                           ; recovery fold: one compose)
nsxx_neg:
   JMP ns_neg                              ; (range; C=0 rides the JMP
                                           ; into ns_neg's ADC #1)
nsxx_dyflat:
   LDA L8_TAB,Y                            ; L8[|dy| >> 3]
nsxx_sub:
   SEC
   SBC t0                                  ; s = L(dy) - L(dx)
   BCC nsxx_neg                            ; s < 0 (C=0 preserved)
   JMP ns_khave
ns_x16y16_j:
   JMP ns_x16y16                           ; (range: the arms grew)
ns_x16:
   LDY pa_dy+1
   BNE ns_x16y16_j
; |dx| 16-bit, |dy| 8-bit: axgt static SET.
   INX
   STA t0                                  ; A = pa_dx+1 (LDY/INX kept it)
   LDA pa_dx
   LSR t0
   ROR A
   LSR t0
   ROR A
   LSR t0
   ROR A                                   ; C = half bit
   TAY
   BCC nsyx_flat
   EOR #$FF
   BEQ nsyx_flat
   LDA L8_TAB,Y
   ADC L8_TAB+1,Y
   ROR A
   JMP nsyx_have
nsyx_flat:
   LDA L8_TAB,Y                            ; L8[|dx| >> 3]
nsyx_have:
   LDY pa_dy
   SEC
   SBC L8_TAB,Y                            ; - L8[|dy|]
   BCS ns_pos96
   ADC #96
   JMP ns_khave
ns_pos96:
   ADC #95                                 ; C=1: diff+96
   BCC ns_khave                            ; (direct 2026-08-12: +47)
ns_k255:
   LDA #255                                ; k clamp (the AE tail is flat
   JMP ns_khave                            ; there — certified exact)
ns_dy0:
   INX                                     ; |dy| = 0: ta = 0, axgt set
ns_dx0:
   STA pa_res                              ; zero-delta axis: ta = 0, so
                                        ; (A == 0 on BOTH entries: czx
                                        ; arrives on ORA/BEQ-taken and
                                        ; ns_dy0 adds only INX)
                                        ; psi = octant base EXACTLY in
   LDA pa_base_hi,X                        ; both sign conventions (base
   STA pa_res+1                            ; +/- 0) — skip the compose
   JMP mask_done                           ; (A = psi hi for the store)

; ============================================================================
; lf_ns — the no-swap pipeline: from |dx|,|dy| all the way to a
; STORED psi, in one run. No min/max is ever computed: the signed L8
; difference
;      s = L8[|dy|] - L8[|dx|]
; carries everything — L8 is MONOTONE, so sign(s) is exactly axgt
; (strict L8 order implies strict magnitude order), and k = |s|
; indexes the AE tables. Ties (s = 0) need no fallback: AE[0] is
; forced to 512, where the octant pairs collapse (certified within
; EPSILON). L8[0] = L8[1] = 0 would poison the sign trick, which is
; why zero deltas short out in the converters before arriving here.
;
; The dispatch sends 16-bit widths BACKWARD to the reduction arms
; with the tested hi byte riding A; the 8-bit body falls through.
; Every arm converges on ns_khave, which composes psi = base +/- ta
; DIRECTLY from the tables: the octant's sign is tested before the
; AE reads, so each compose arm loads ta already combining — ta is
; never staged anywhere.
;   in : X = octant class base, pa_dx/pa_dy = |dx|/|dy|,
;        A = pa_dy+1 (the dispatch re-tests it)
;   out: psi in pa_res and the memo (via mask_done), then falls
;        through cp_havepsi: A = r hi, Y = r lo, X = slot
; ============================================================================
ns_wide:
   LDA pa_dx+1                             ; rare re-split (0.1/fr): which
   BNE ns_x16                              ; axis is wide?
   LDA pa_dy+1                             ; (dy: the arm wants the hi
   JMP ns_x8y16                            ;  byte riding A)
CORNER_ENTRY corner_phi_pn, 0, 1, 2, 1                                       ;# |          1.2
                                        ; (falls through into lf_ns)
lf_ns:
; Width tests FUSED (2026-08-14 census: 72.5 of 72.6 atans/frame are
; pure 8-bit — the wide arms are one-in-a-thousand): one ORA+branch
; replaces the two load/branch pairs on the hot lane; the rare-wide
; island re-splits.
   LDA pa_dx+1                                                            ;# |          0.7
   ORA pa_dy+1                                                            ;# |          0.7
   BNE ns_wide                                                            ;# |          0.4
; both 8-bit (the common case): direct table reads, no reduction
   LDY pa_dy                                                              ;# |          0.7
   LDA L8_TAB,Y                            ; L8[|dy|]                     ;# |          0.9
   LDY pa_dx                                                              ;# |          0.7
   SEC                                                                    ;# |          0.4
   SBC L8_TAB,Y                            ; s = L8[|dy|] - L8[|dx|]      ;# |          0.9
   BCS ns_khave                            ; s >= 0 (ties ride k = 0)     ;# |          0.5
ns_neg:
   EOR #$FF                                ; k = -s (C = 0 on every       ;#            0.4
   ADC #1                                  ; arrival: the ADC supplies    ;#            0.4
   INX                                     ; exactly +1); axgt            ;#            0.4
; ---------------------------------------------------------------------------
; ns_khave — compose psi = base[oct] +/- ta, mod 4096, straight off
; the AE tables. The sign is tested BEFORE the reads (N flag off the
; pa_sign load), so the arms never stage ta:
;   add:  psi = (AE_LO[k], base + AE_HI[k])       — bases are multiples
;         of 256, so the lo byte is the table byte untouched; the hi
;         sum never wraps (ta <= 512 seed-asserted, largest add base
;         3072: tops out at $0E) — no mask. Falls into the store.
;   sub:  psi = (0 - AE_LO[k], base - AE_HI[k] - b) — the borrow rides
;         the two SBCs; the AND is octant 3's mod-4096 wrap
;         (psi = 4096 - ta); the other sub bases can't go negative.
;         Sits past cp_havepsi's RTS, exits through mask_done.
; The zero-delta paths bypass the compose entirely (base +/- 0 is the
; base either way) and enter at mask_done with psi = base staged.
; ---------------------------------------------------------------------------
ns_khave:
   TAY                                     ; k                            ;# |          0.4
   LDA pa_sign,X                           ; octant sign, N off the load  ;# |          0.9
   BMI khave_sub                                                          ;# |          0.6
   LDA AE_LO,Y                                                            ;# |          0.4
   STA pa_res                              ; psi lo = ta lo               ;#            0.3
   LDA AE_HI,Y                                                            ;# |          0.4
   CLC                                                                    ;#            0.2
   ADC pa_base_hi,X                        ; psi hi = base + ta hi        ;# |          0.4
   STA pa_res+1                                                           ;#            0.3
mask_done:
; (the psi memo store lived here until 2026-09-04.  With it went the
; X = slot return contract: X now stays the octant all the way out, and
; nothing downstream reads it.)
cp_havepsi:
; r = (afn - psi) & 4095, pure u12 (consumers do mod-4096 arithmetic
; on the hi nibble directly). pa_res stays stored: the psi-hi SBC and
; the test hooks read it. (The 'rotation cache warm re-derive (JSR)'
; note died with the per-side probes — the serve algebra is inlined
; there; the memo HIT serve is the only other arrival, at _hit.)
;   out: A = r hi, Y = r lo, X = slot
; CARRY FLOW (audit 2026-07-22): the mask_done fall-through arrives
; MIXED — add-compose C=0 (the no-wrap ADC), khave_sub C=1 (sub bases
; can't borrow), zero-delta arms inherit the classify's C — so the
; SEC stays for the fall-through; memo hits enter past it.
   SEC                                                                    ;# |          0.4
cp_havepsi_hit:
   LDA bca_afn                                                            ;# |          1.1
   SBC pa_res                                                             ;# |          1.1
   TAY                                     ; r lo rides Y to the caller   ;# |          0.7
   LDA bca_afn+1                                                          ;# |          1.1
   SBC pa_res+1                                                           ;# |          1.1
   AND #$0F                                                               ;# |          0.7
   RTS                                                                    ;# |||        2.2
khave_sub:
   SEC                                                                    ;#            0.2
   LDA #0                                                                 ;#            0.2
   SBC AE_LO,Y                             ; psi lo = -ta lo, borrow out  ;# |          0.4
   STA pa_res                                                             ;#            0.3
   LDA pa_base_hi,X                                                       ;# |          0.4
   SBC AE_HI,Y                             ; psi hi = base - ta hi - b    ;# |          0.4
   AND #$0F                                ; octant 3's mod-4096 wrap     ;#            0.2
   STA pa_res+1                                                           ;#            0.3
   JMP mask_done                                                          ;#            0.3
ns_x8y16:
; |dx| 8-bit, |dy| 16-bit: axgt static clear.
; (relocated below khave_sub 2026-07-20: puts the arm in FORWARD BNE
; range of lf_ns's dispatch — the ns_x8y16_j trampoline died. Its own
; exits: JMP ns_khave is absolute; BCS ns_pos96 reaches backward.)
   STA t0                                  ; A = pa_dy+1 (from lf_ns)
   LDA pa_dy
   LSR t0
   ROR A
   LSR t0
   ROR A
   LSR t0
   ROR A                                   ; C = half bit
   TAY
   BCC nsxy_flat
   EOR #$FF
   BEQ nsxy_flat
   LDA L8_TAB,Y
   ADC L8_TAB+1,Y
   ROR A
   JMP nsxy_have
nsxy_flat:
   LDA L8_TAB,Y                            ; L8[|dy| >> 3]
nsxy_have:
   LDY pa_dx
   SEC
   SBC L8_TAB,Y                            ; - L8[|dx|]
   BCS nsxy_pos96                          ; (local copy of the pos96 tail:
   ADC #96                                 ; ns_pos96 is out of branch range
   JMP ns_khave                            ; from down here, and BCS is the
nsxy_pos96:                                ; COMMON direction — no trampoline)
   ADC #95                                 ; C=1: diff+96
   BCC ns_khave                            ; (direct 2026-08-12: -114)
nsxy_k255:
   LDA #255                                ; k clamp (AE tail flat there)
   JMP ns_khave
.if ::BANKED = 0
SEG_HIGH
.endif


; --- The cache half of the check (2026-07-20: fully subsumed into this
; file — src/ang/rcache.s died): bca_frame is the per-frame epoch keeper,
; and bbox_check_angle below is the ONE public entry — probe at the top,
; serve-and-skip-classify on a hit, stash-and-fall-into-box_classify on a
; miss. Moving frames enter at box_classify (bbox_visible's indirect
; JMP through zp_bv_entry) and never see the probe. Callers guarantee L2
; is paged. ---
.if BANKED
SEG_CODE
.endif
.export box_classify
; (class exports died 2026-09-04) ;    ; hud.s: the frame's class letter is
                                        ; zp_bv_entry's low byte vs these
; (bca_frame DELETED 2026-09-04: with the extent cache gone its only
;  output, bca_cach_ab, had no reader left -- the D classifier was the one
;  consumer of "angle unchanged".  The whole per-frame hook went.)

; (rc_wipe, dbox_check, its probe arms and dst_drop -- the forward-
;  coherence cache and its refresh wheel -- deleted 2026-09-04.)
end:
; Corner scratch (2026-09-04): the four bytes that replaced the memo key
; planes' second job — holding a shared-axis row's raw delta across c1's
; in-place negation.  This is all the storage the corner pipeline needs.
.segment "RWC"
corner_sx: .byte 0, 0
corner_sy: .byte 0, 0
SEG_CODE

.if BANKED
; (ld65 writes this: SAVE "bsp_render_ang_bk.bin")
.else
.assert end <= $6200, error             ; flat CODE ceiling: the NJ blob
                                        ; loads at $6200 (map reshuffle)
.endif

