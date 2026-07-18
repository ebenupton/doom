
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
; A/Y and owns the bca_p2 stores; p1 is stored here). corner_phi
; returns r-hi in A, r-lo in Y, so the second fetch re-establishes
; Y = node itself.
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
; viewer inside (or on the boundary of) the CLOSED box: publish the
; full-span sentinel — the rcache cold snapshot marks FULL off its
; ordinary span test, and the psi planes are never consulted under
; FULL, so the stale pa state is unread.
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
;   out: control at a corner arm or full_vis; bca_p1/p2 = raw phis
;        (via the arms' JSRs + bca_tail) — the rcache cold snapshot
;        reads them from memory after the check
; zc_corners/zc_end bound the harness PC window (check_angle_calls).
; ============================================================================
.segment "ZC"
zc_corners:                                ; harness window start
box_classify:
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
ns_x16y16:
; both 16-bit: reduce both >> 3 into (A:t0)/(A:t1), then the 8-bit
; shape on the reduced values.
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
   ROR t0
   LDA pa_dy
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
   SBC L8_TAB,Y                            ; - L8[|dx| >> 3]
   BCC ns_neg                              ; s < 0: forward, direct (C=0
   JMP ns_khave                            ; rides into ns_neg's ADC #1)
ns_x8y16:
; |dx| 8-bit, |dy| 16-bit: axgt static clear.
   STA t0                                  ; A = pa_dy+1 (from lf_ns)
   LDA pa_dy
   LSR t0
   ROR A
   LSR t0
   ROR A
   LSR t0
   ROR A
   TAY
   LDA L8_TAB,Y                            ; L8[|dy| >> 3]
   LDY pa_dx
   SEC
   SBC L8_TAB,Y                            ; - L8[|dx|]
   BCS ns_pos96
   ADC #96                                 ; C=0: wraps to diff+96 exactly
   JMP ns_khave                            ; (diff >= -95: k >= 1)
ns_x16:
   LDY pa_dy+1
   BNE ns_x16y16
; |dx| 16-bit, |dy| 8-bit: axgt static SET.
   INX
   STA t0                                  ; A = pa_dx+1 (LDY/INX kept it)
   LDA pa_dx
   LSR t0
   ROR A
   LSR t0
   ROR A
   LSR t0
   ROR A
   TAY
   LDA L8_TAB,Y                            ; L8[|dx| >> 3]
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
lf_ns:
   LDA pa_dx+1
   BNE ns_x16                              ; 16-bit widths: backward, the
   LDA pa_dy+1                             ; tested hi byte rides A into
   BNE ns_x8y16                            ; the arm
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

end:
.if BANKED
; (ld65 writes this: SAVE "bsp_render_ang_bk.bin")
.else
.assert end <= $F100, error             ; flat ANG ceiling: RCACHE_STATE
                                        ; squats at $F100 (abi)
.endif
