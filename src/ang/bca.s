
; ============================================================================
; corner_phi.s — the bbox corner/angle subsystem, end to end:
;
;   box_classify     locate the viewer against a child box (ZC segment)
;   CLASSIFY_TREE    one side's classifier: x ladder + L/M/R columns,
;                    every corner arm inlined at its leaf
;   corner_phi_*     four sign-class entries: corner-phi memo probe +
;                    |delta| converters (ANGX window flat, linear banked)
;   lf_ns            the no-swap log2/atanexp pipeline (ta from |dx|,|dy|)
;   comb .. cp_havepsi  octant compose, psi memo store, r = afn - psi
;
; The whole pipeline is ONE source run: entries, width arms, lf_ns and
; the compose chain sit in a single section, so every load-bearing
; fall-through is adjacent in both builds by construction.
;
; Register discipline (the contracts that make the hot path load-free):
;   Y = node        owned by the classify caller; survives the whole
;                   tree; the arms re-load it only after corner_phi
;                   returns r-lo in Y
;   X = memo slot   hashed by the fetch macros ((dx^dy)&$7F), consumed
;                   by the probe, RETURNED as the slot on both exits
;                   (the hit serve preserves it; the miss path's psi
;                   store reloads it) — the memo-shared rows read the
;                   key planes X-direct on the strength of this
;   A = pa_dy+1     every fetch macro exits with the y-delta hi byte
;                   in A; probe stage 0 compares KDYH with no load
; ============================================================================

; ---------------------------------------------------------------------------
; ZCF — one corner fetch: delta = plane - viewer, both axes, s16.
; The CALLER owns Y = node. The memo slot hash is computed mid-macro,
; where dy-lo is in A and dx is already banked: EOR/AND/TAX preserve
; the carry the following y-hi SBC needs, so the hash rides for free.
; Exits with A = pa_dy+1 (the entry A-contract).
; ---------------------------------------------------------------------------
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
   EOR pa_dx                               ; slot = (dx ^ dy) & $7F, hashed
   AND #$7F                                ; here where dy-lo is in A —
   TAX                                     ; EOR/AND/TAX keep C for the SBC
   LDA yl+$200+(s)*$100,Y
   SBC bca_pys+1
   STA pa_dy+1
.endmacro
; Partial fetches for the axis-sharing rows: the OTHER delta must
; already be valid (carried over, or memo-reloaded first) — the hash
; reads it. ZCF_DX exits with A = pa_dx+1, so its users re-load dy-hi
; before the JSR to honour the entry A-contract.
.macro ZCF_DX s, xl
   SEC
   LDA xl+(s)*$100,Y
   SBC bca_pxs
   STA pa_dx
   EOR pa_dy                               ; slot hash (pa_dy already valid)
   AND #$7F
   TAX
   LDA xl+$200+(s)*$100,Y
   SBC bca_pxs+1
   STA pa_dx+1
.endmacro
.macro ZCF_DY s, yl
   SEC
   LDA yl+(s)*$100,Y
   SBC bca_pys
   STA pa_dy
   EOR pa_dx                               ; slot hash (pa_dx carried over)
   AND #$7F
   TAX
   LDA yl+$200+(s)*$100,Y
   SBC bca_pys+1
   STA pa_dy+1
.endmacro
; ---------------------------------------------------------------------------
; ZCF_MEMO_* — reload a shared-axis RAW delta from the memo key planes,
; X-direct. Sound on both of c1's exits: a miss just BANKED the raw key
; at the slot, and a hit means the planes MATCHED it — either way
; CPM_KD*[c1's slot] holds c1's raw deltas, and X = that slot by the
; return contract. Must run BEFORE the hashing fetch overwrites X with
; c2's slot. This is what un-does the N-class in-place negation for the
; rows whose corners share a plane.
; ---------------------------------------------------------------------------
.macro ZCF_MEMO_DX
   LDA CPM_KDXL,X
   STA pa_dx
   LDA CPM_KDXH,X
   STA pa_dx+1
.endmacro
.macro ZCF_MEMO_DY
   LDA CPM_KDYL,X
   STA pa_dy
   LDA CPM_KDYH,X
   STA pa_dy+1
.endmacro
; ---------------------------------------------------------------------------
; ZARM family — a corner arm: fetch corner 1, take its phi, fetch
; corner 2, take its phi, chain into bca_tail (which receives p2 in
; A/Y and banks X = corner 2's memo slot for the rcache cold
; snapshot; p1 is stored here). corner_phi returns r-hi in A, r-lo
; in Y, so the second fetch re-establishes Y = node itself.
;   ZARM      independent corners (full fetch both)
;   ZARM_SX   corners share the x plane, P-class: pa_dx survives c1
;   ZARM_SY   corners share the y plane, P-class: pa_dy survives c1
;   ZARM_SYM  shared y, N-class c1: the raw dy comes back from the MEMO
;   ZARM_SXM  shared x, N-class c1: the raw dx comes back from the MEMO
; SY/SYM's hashing fetch is ZCF_DX (exits A = dx-hi): they re-load
; dy-hi for the entry A-contract.
; ---------------------------------------------------------------------------
.macro ZARM s, x1, y1, x2, y2, e1, e2
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   LDY zp_node_ch_l                        ; (r-lo clobbered Y)
   ZCF s, x2, y2
   JSR e2
   JMP bca_tail                            ; p2 rides A/Y; no return trip
.endmacro
.macro ZARM_SX s, x1, y1, y2, e1, e2
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   LDY zp_node_ch_l
   ZCF_DY s, y2                            ; pa_dx carried over
   JSR e2
   JMP bca_tail
.endmacro
.macro ZARM_SY s, x1, y1, x2, e1, e2
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   LDY zp_node_ch_l
   ZCF_DX s, x2                            ; pa_dy carried over
   LDA pa_dy+1                             ; entry A-contract: dy hi
   JSR e2
   JMP bca_tail
.endmacro
.macro ZARM_SYM s, x1, y1, x2, e1, e2
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   ZCF_MEMO_DY                             ; c1's slot read FIRST — the
   LDY zp_node_ch_l                        ; hashing ZCF_DX then computes
   ZCF_DX s, x2                            ; c2's slot into X
   LDA pa_dy+1                             ; entry A-contract: dy hi
   JSR e2
   JMP bca_tail
.endmacro
.macro ZARM_SXM s, x1, y1, y2, e1, e2
   ZCF s, x1, y1
   JSR e1
   STA bca_p1+1
   STY bca_p1
   ZCF_MEMO_DX                             ; c1's slot read FIRST
   LDY zp_node_ch_l
   ZCF_DY s, y2
   JSR e2
   JMP bca_tail
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
; publishes p1 = 0, p2 = $0800 (span exactly 2048), and the check's
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
   CMP BBP_L_HI+(s)*$100,Y
   BCC yL                                  ; px < L (hi): LEFT, direct
   BNE xge_nr                              ; px > L (hi): right-of tests,
                                           ; pxs+1 still live
   LDA BBP_L_LO+(s)*$100,Y                 ; hi tie: plane in A —
   CMP bca_pxs                             ; C = L_lo >= px_lo, so ONE
   BCS yL                                  ; branch covers px <= L
xge:
   LDA bca_pxs+1                           ; (inverted-lo fall only)
xge_nr:
   CMP BBP_R_HI+(s)*$100,Y
   BCC ymj                                 ; px < R (hi): MID via stub
   BNE yrj                                 ; px > R (hi): RIGHT via stub
   LDA BBP_R_LO+(s)*$100,Y                 ; hi tie: px <= R is mid,
   CMP bca_pxs                             ; one BCS; fall = strict
   BCS ymj                                 ; right
yrj:
   JMP yR
ymj:
   JMP yM
; --- LEFT column (ladder-adjacent, all exits direct) ---
yL:
   LDA bca_pys+1
   CMP BBP_T_HI+(s)*$100,Y
   BCC yLlo_nr                             ; py < T (hi): bottom test,
                                           ; pys+1 still live
   BNE yLtop                               ; py > T strictly (hi)
   LDA bca_pys
   CMP BBP_T_LO+(s)*$100,Y
   BCC yLlo
yLtop:                                     ; py >= T: row 0 (NW)
   ZARM s, BBP_R_LO, BBP_T_LO, BBP_L_LO, BBP_B_LO, corner_phi_pn, corner_phi_pn
yLlo:
   LDA bca_pys+1                           ; (lo-tier arrivals only)
yLlo_nr:
   CMP BBP_B_HI+(s)*$100,Y
   BCC yLbot                               ; py < B strictly (hi)
   BNE yLmid                               ; py > B (hi): mid band
   LDA bca_pys
   CMP BBP_B_LO+(s)*$100,Y
   BCS yLmid                               ; py >= B: mid band
yLbot:                                     ; py < B: row 8 (SW)
   ZARM s, BBP_L_LO, BBP_T_LO, BBP_R_LO, BBP_B_LO, corner_phi_pp, corner_phi_pp
yLmid:                                     ; row 4 (W): corners share L
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
yMtop:                                     ; row 1 (N): corners share T,
                                           ; c1 negates it -> memo reload
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
yMbot:                                     ; row 9 (S): corners share B
   ZARM_SY s, BBP_L_LO, BBP_B_LO, BBP_R_LO, corner_phi_np, corner_phi_pp
cxi:
; viewer inside (or on the boundary of) the CLOSED box: no corners
; ran, so corner 2's memo slot is stale — publish the $80 marker
; instead (slots are 0-127; bit 7 is the impossible flag). The rcache
; cold snapshot sees it and sets COMPUTED+FULL directly, never
; touching the psi planes.
   LDA #$80
   STA zp_cpm_s2
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
yRtop:                                     ; py >= T: row 2 (NE)
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
yRbot:                                     ; py < B: row 10 (SE)
   ZARM s, BBP_L_LO, BBP_B_LO, BBP_R_LO, BBP_T_LO, corner_phi_np, corner_phi_np
yRmid:                                     ; row 6 (E): corners share R,
                                           ; c1 negates it -> memo reload
   ZARM_SXM s, BBP_R_LO, BBP_B_LO, BBP_T_LO, corner_phi_nn, corner_phi_np
.endmacro

; ============================================================================
; box_classify — THE bbox visibility check body (bbox_check_angle is a
; JMP here). One LDY serves both side trees; the side picks a fully
; side-baked instantiation and is never consulted again.
;   in : zp_node_ch_l, zp_bbox_side, bca_pxs/pys (offset-binned hi)
;   out: control at a corner arm or full_vis; bca_p1 = raw phi 1 in
;        memory, zp_cpm_s2 = corner 2's memo slot (or the $80 inside
;        marker) — the rcache cold snapshot's two psi sources
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

full_vis:                               ; span >= ANG180: full width
   LDA #0
   STA bca_ilo
   LDA #255
   STA bca_ihi
   LDA #1
   STA bca_vis
   JMP SC_HAS_GAP                          ; FUSED EXIT (2026-07-18): every
                                           ; visible exit chains straight into
                                           ; has_gap on the freshly-written
                                           ; zp_i interval — the caller gets
                                           ; the COMBINED verdict in A/Z, and
                                           ; the bv wrapper's JSR/BNE/JMP
                                           ; round trip is gone. Cull exits
                                           ; still RTS (A=0/Z=1).

; (scope opened out to file level so the rotation cache — bbox_check_angle_cached
;  + bca_frame below — can share box_classify, corner_phi and the bca_tail
;  span/clip/column code. Tail labels ck_*/full_vis/cull are unique file-wide.)
; (No bca_vis entry preset: EVERY exit stores the verdict — full_vis/cull/
;  cull_far/visok, and box_classify's inside-escape goes through full_vis —
;  so the old LDA #0/STA preset was 5 dead cycles per check, 2026-07-16.)
; bca_pxs/bca_pys (px,py sign-extended to s16) are precomputed once/frame
; by br_view_setup — frame-constant. Direct unit-test callers set them.
; bca_px/bca_py (s8) are still read below by ins_test/box_pos.
; inside test: left<=px<=right and bot<=py<=top  -> full (0,255)
; left<=px : px-left >= 0
; a_fine (bca_afn) is precomputed once/frame by the caller
; (br_view_setup), not recomputed here — it is frame-constant. Direct
; unit-test callers (test_bca, check_angle_calls) set bca_afn themselves.
; inside test + boxx/boxy classification share one set of subtractions:
; JMP-THREADED CHAIN (2026-07-18, enabled by the cold-route
; unification making classify/corners single-caller): classify exits
; dispatch straight to the corner arm (push-push-RTS with the zone-
; composed index), the arm falls into bca_tail via JMP, and the tail's
; exits return to OUR caller — the JSR/RTS shuttles at every stage are
; gone. Inside boxes escape via cx_inside -> full_vis directly.
   ; ============================================================================
.segment "ZC"
zc_corners:                                ; harness window start
bbox_check_angle:                          ; the check IS the classifier —
box_classify:                              ; the old JMP stub died 2026-07-19
   LDY zp_node_ch_l                        ; ONE LDY serves both trees
   LDA zp_bbox_side
   BNE bcls_s1
   JMP bcls_s0
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
; ENTRY CONTRACT (2026-07-19, Eben's convention flip, adjusted): the
; caller hands p2 IN REGISTERS — A = p2 hi, Y = p2 lo, exactly what
; cp_havepsi returns. p2 NEVER LANDS IN MEMORY (bca_p2 died
; 2026-07-19): the span math keeps it live in X/Y and the right window
; runs first, register-sourced. The rcache cold snapshot gets psi2
; from the corner memo instead, via zp_cpm_s2 — armed entries arrive
; with X = corner 2's slot (the corner_phi return contract) and the
; tail banks it below; warm entries write junk there, which is
; harmless (the cold path reads only its own check's value). NB
; hi-in-A is pinned by cp_havepsi's borrow direction (hi computes
; last); a lo-in-A flip costs a +4 shuffle per corner call — measured
; worse.
bca_tail:                               ; shared by bbox_check_angle + _cached
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
   STX zp_cpm_s2                           ; corner 2's memo slot -> the
                                           ; rcache cold snapshot's psi2 key
; classify r2: A = p2' hi (masked by cp_havepsi's exit), Y = p2' lo
   CMP #4
   BCS ct_r2out                            ; r2 >= 1024: R or L
; --- (F,*): ihi = vatox[r2]+1. C=0 (the BCS fell); the pointer ADC's
; carry-out is CONSTANT 0 (r_hi <= 4, link-asserted) and rides into
; the +1 adjust; overflow clamps to 255. ---
   ADC #>VATOX
   STA pa_ptr+1
   LDA (pa_ptr),Y                          ; vatox[r2]
   ADC #1
   BCC ct_ih
   LDA #255
ct_ih:
   STA bca_ihi
ct_left:
; r1'' = (p1' - 2*EPS) & 4095 in registers (raw p1' stays in memory)
   LDA bca_p1
   SEC
   SBC #(2*EPSILON_F)
   TAY
   LDA bca_p1+1
   SBC #0
   AND #$0F
   CMP #4
   BCS ct_r1out_r2f                        ; r1 out, r2 in: ilo = 0
lk_left:
   ADC #>VATOX                             ; C=0 (BCS fell / ct_f_r2out's
   STA pa_ptr+1                            ; BCC — both arrive C=0)
   LDA (pa_ptr),Y                          ; vatox[r1'']
   SBC #0                                  ; C=0 (constant carry-out) -> v-1
   BCS ct_il                               ; C=1: v >= 1
   LDA #0                                  ; v == 0: ilo clamps to 0
ct_il:
   STA bca_ilo
; falls into visok. NO ilo > ihi check: in (F,F) the corners can
; invert by at most 2*EPS (true span < 2048 outside the box, each
; corner within +-EPS), and the left -2*EPS bias plus the -1/+1
; adjusts restore ilo <= ihi; every other cell emits constants in
; order. The python mirror keeps its tripwire.
; A-CONTRACT (2026-07-09, backface rule 1): every bbox_check_angle exit
; returns the verdict in A (Z valid) AS WELL AS in bca_vis — the byte
; stays for the D-cache store, but callers branch without reloading.
; full_vis is the CANONICAL full-visibility tail (the rcache warm-full
; path and box_classify's inside case JMP here instead of local copies).
visok:
   LDA #1                                  ; visible: bca_vis for the D store,
   STA bca_vis                             ; then the fused has_gap exit — the
   JMP SC_HAS_GAP                          ; walk consumes has_gap's A/Z
cull:                                      ; THE cull exit (the file-head twin
   LDA #0                                  ; is gone, 2026-07-17: every BCS/BCC
   STA bca_vis                             ; cull now reaches FORWARD to here —
   RTS                                     ; ranges link-checked); A=0/Z=1

; --- out-of-line cells (rarer paths) ---------------------------------
ct_r1out_r2f:
   LDA #0                                  ; (R,F)/(L,F): the box wraps in
   STA bca_ilo                             ; from the left edge — ilo = 0
   JMP visok
ct_r2out:
; A = r2 hi in [4,15]. X is free (the slot store above consumed it):
; bank r2's R/L class there, then classify r1.
   LDX #0
   CMP #10
   BCC ct_r2have                           ; hi < 10: R (X = 0)
   INX                                     ; else L (X = 1)
ct_r2have:
   LDA bca_p1                              ; r1'' build (same as ct_left)
   SEC
   SBC #(2*EPSILON_F)
   TAY
   LDA bca_p1+1
   SBC #0
   AND #$0F
   CMP #4
   BCC ct_f_r2out                          ; r1 in F: [col1, 255]
; both corners out: (L,R) -> full, everything else -> cull
   CMP #10
   BCC ct_cull_j                           ; r1 = R: (R,R)/(R,L) cull
   CPX #0
   BEQ ct_full_j                           ; (L,R): full
ct_cull_j:
   JMP cull                                ; (L,L) falls here too
ct_full_j:
   JMP full_vis
ct_f_r2out:
; (F,R)/(F,L): ihi = 255, then the ordinary left lookup. A = r1'' hi,
; Y = r1'' lo, C=0 from the BCC — TAX/LDA/STA/TXA/JMP preserve it
; into lk_left's pointer ADC.
   TAX
   LDA #255
   STA bca_ihi
   TXA
   JMP lk_left

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
; CPM_ENTRY — one sign-class corner_phi entry: probe the corner-phi
; memo, and on a miss bank the key, convert to |dx|/|dy| and jump into
; the shared lf_ns pipeline. Four instances, one per (sign dx, sign dy)
; class: each arm's row fixes both corners' delta signs statically, so
; the converters dead-code the sign tests — P-axes are already their
; own absolute value, N-axes negate pa_dx/pa_dy IN PLACE.
;
; ENTRY CONTRACT: X = memo slot (hashed by the fetch macros),
;                 A = pa_dy+1 (the fetch's exit state).
; RETURN CONTRACT: r-hi in A, r-lo in Y, X = slot again — the hit
;                 serve never touches X, and the miss path's psi store
;                 reloads it. Harness drivers must mirror the entry
;                 registers (test_slope_div sets mpu.x/mpu.a).
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
.macro CPM_ENTRY name, negx, negy, obase
   .local cmiss0, cmiss1, cmiss2, cmiss3, czx, czy
name:
   CMP CPM_KDYH,X                          ; stage 0: A = dy hi, no load
   BNE cmiss0
   LDA pa_dy
   CMP CPM_KDYL,X
   BNE cmiss1
   LDA pa_dx
   CMP CPM_KDXL,X
   BNE cmiss2
   LDA pa_dx+1
   CMP CPM_KDXH,X
   BNE cmiss3
   LDA CPM_PSIL,X                          ; HIT: serve psi; X = slot
   STA pa_res                              ; rides through untouched
   LDA CPM_PSIH,X
   STA pa_res+1
   JMP cp_havepsi
cmiss0:
   STA CPM_KDYH,X                          ; staggered key bank: enter at
   LDA pa_dy                               ; the missed stage, store the
cmiss1:
   STA CPM_KDYL,X                          ; byte in A, load-store the
   LDA pa_dx                               ; rest; matched bytes are
cmiss2:
   STA CPM_KDXL,X                          ; already in the planes
   LDA pa_dx+1
cmiss3:
   STA CPM_KDXH,X                          ; the validity mark (made good
                                           ; when the psi lands; single-
                                           ; threaded, no early outs)
   STX zp_cpm_slot                         ; slot to zp on the MISS path
                                           ; only — X becomes the octant
   LDX #obase
   ORA pa_dx                               ; A = pa_dx+1 (converged): the
   BEQ czx                                 ; x zero-out costs no load
.if negx
   LDA #0                                  ; |dx| = -dx in place (dx <= 0)
   SEC
   SBC pa_dx
   STA pa_dx
   LDA #0
   SBC pa_dx+1
   STA pa_dx+1
.endif
.if negy
   LDA #0                                  ; |dy| = -dy in place (dy <= 0);
   SEC                                     ; the zero-out folds into the
   SBC pa_dy                               ; negate's final ORA
   STA pa_dy
   LDA #0
   SBC pa_dy+1
   STA pa_dy+1
   ORA pa_dy
   BEQ czy
.else
   LDA pa_dy+1                             ; |dy| = dy already (dy >= 0):
   ORA pa_dy                               ; just the zero-out
   BEQ czy
.endif
   JMP lf_ns
czx:
   JMP ns_dx0
czy:
   JMP ns_dy0
.endmacro
; octant class base = (dx<0)*4 + (dy<0)*2; lf_ns adds axgt.
; PLACEMENT: flat = the ANGX window; banked = linear in ANG_BK. Either
; way the entries, the width arms, lf_ns and the compose chain below
; are one contiguous run.
.if ::BANKED = 0
.segment "ANGX"
angx_head:
.endif
CPM_ENTRY corner_phi_nn, 1, 1, 6
CPM_ENTRY corner_phi_pn, 0, 1, 2
CPM_ENTRY corner_phi_np, 1, 0, 4
CPM_ENTRY corner_phi_pp, 0, 0, 0

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
ns_x8y16:
; |dx| 8-bit, |dy| 16-bit: axgt static clear.
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
   BCS ns_pos96
   ADC #96                                 ; C=0: wraps to diff+96 exactly
   JMP ns_khave                            ; (diff >= -95: k >= 1)
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
   BCS ns_k255
   JMP ns_khave
ns_k255:
   LDA #255                                ; k clamp (the AE tail is flat
   JMP ns_khave                            ; there — certified exact)
ns_dy0:
   INX                                     ; |dy| = 0: ta = 0, axgt set
ns_dx0:
   LDA #0                                  ; zero-delta axis: ta = 0, so
   STA pa_res                              ; psi = octant base EXACTLY in
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
ns_x8y16_j:
   JMP ns_x8y16                            ; (the half-bit recovery grew the
                                           ; arms past branch range)
lf_ns:
   LDA pa_dx+1
   BNE ns_x16                              ; 16-bit widths: backward, the
   LDA pa_dy+1                             ; tested hi byte rides A into
   BNE ns_x8y16_j                          ; the arm
; both 8-bit (the common case): direct table reads, no reduction
   LDY pa_dy
   LDA L8_TAB,Y                            ; L8[|dy|]
   LDY pa_dx
   SEC
   SBC L8_TAB,Y                            ; s = L8[|dy|] - L8[|dx|]
   BCS ns_khave                            ; s >= 0 (ties ride k = 0)
ns_neg:
   EOR #$FF                                ; k = -s (C = 0 on every
   ADC #1                                  ; arrival: the ADC supplies
   INX                                     ; exactly +1); axgt
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
   TAY                                     ; k
   LDA pa_sign,X                           ; octant sign, N off the load
   BMI khave_sub
   LDA AE_LO,Y
   STA pa_res                              ; psi lo = ta lo
   LDA AE_HI,Y
   CLC
   ADC pa_base_hi,X                        ; psi hi = base + ta hi
   STA pa_res+1
mask_done:
; psi memo store; entries persist forever (psi is a pure function of
; the key). The LDX does double duty: store index AND the X = slot
; return contract (the octant chain repurposed X) — both mask_done
; and khave_sub's exit depend on it, so list its duties before
; touching it.
   LDX zp_cpm_slot
   STA CPM_PSIH,X
   LDA pa_res
   STA CPM_PSIL,X
cp_havepsi:
; r = (afn - psi) & 4095, pure u12 (consumers do mod-4096 arithmetic
; on the hi nibble directly). Also the rotation cache warm path's
; re-derive (JSR). pa_res stays stored: the psi-hi SBC and the test
; hooks read it.
;   out: A = r hi, Y = r lo, X = slot
   SEC
   LDA bca_afn
   SBC pa_res
   TAY                                     ; r lo rides Y to the caller
   LDA bca_afn+1
   SBC pa_res+1
   AND #$0F
   RTS
khave_sub:
   SEC
   LDA #0
   SBC AE_LO,Y                             ; psi lo = -ta lo, borrow out
   STA pa_res
   LDA pa_base_hi,X
   SBC AE_HI,Y                             ; psi hi = base - ta hi - b
   AND #$0F                                ; octant 3's mod-4096 wrap
   STA pa_res+1
   JMP mask_done
.if ::BANKED = 0
.segment "ANG"
.endif

