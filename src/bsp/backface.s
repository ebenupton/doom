
; ============================================================================
; br_back_face_test — test current seg for back-facing.
;   Inputs (zp): zp_seg_hdr_p -> the 12-byte seg header (read on demand via
;                (zp_seg_hdr_p),Y: linedef v1 x/y at +4..+7, delta ldx/ldy
;                at +8/+9); zp_seg_flags staged by the caller (header +10;
;                SF_SAMEDIR = $80, top bit, INVERTED: set = runs with ld).
;                zp_br_px_h/px_e, zp_br_py_h/py_e = player px_int, py_int (s16).
;   Output: Z FLAG — Z=1 (BEQ) back-facing, Z=0 (BNE) front-facing.
;           A is scratch. 2026-07-09: inverted from A=1-means-back so the
;           degenerate back exits (ldx/ldy/delta == 0) return STRAIGHT
;           from the test that decided them — the zero just tested IS the
;           verdict, no reload, no JMP to a stub. Sign-path exits load
;           #0/#1 only to force Z; the mul tail's final LDA t2 IS the
;           verdict. (Was zp_seg_skip before that; the slot now belongs
;           to the near-clip flag alone.)
;   Clobbers: A, X, Y; zp_br_dxlo/hi, zp_br_dylo/hi (the s16 deltas),
;             zp_br_t2/t3, zp_br_a, and the mul workspace (via br_smul_s8_s16).
;
;   dot = ldy * (px_int - lv1_x) - ldx * (py_int - lv1_y)
;   if flags & SF_DIR: dot = -dot
;   back-facing if dot <= 0.
;
;   (Python mirror: packed_render_seg's back-face block. dot is the 2D
;   cross product of the linedef direction with the v1→player vector:
;   > 0 → player on the seg's front side. SF_DIR marks segs running
;   opposite their linedef, which flips the sign.)
;
;   Structure — three tiers, cheapest first, all EXACT:
;     1. axis-aligned linedefs (ldx==0 or ldy==0, ~76% of segs): dot is a
;        single product; its sign is the XOR of the operand sign bits —
;        no multiplies (any zero operand short-circuits to "back").
;     2. general linedefs whose products P1=ldy*dx, P2=ldx*dy have
;        OPPOSITE signs: sign(P1-P2) = sign(P1) — still no multiplies.
;     3. same-sign products: full 2 × (s8×s16) multiply + s16 subtract.
; ============================================================================
; Pseudocode (each [label] tags the basic block below that implements it):
;
;   br_back_face_test():                        # Z=1 back, Z=0 front
;      if ldx == 0:                             # vertical linedef
;         if ldy == 0:            return BACK   # degenerate
;         [bf_ldx0_ldy_nz] dx = px - lv1x       # the only delta needed
;         if dx == 0:             return BACK
;         [bf_ldx0_dx_nz]  return TAIL(sign(ldy) ^ sign(dx))       # dot = P1
;      [bf_ldx_nz]
;      if ldy == 0:                             # horizontal linedef
;         dy = py - lv1y                        # the only delta needed
;         if dy == 0:             return BACK
;         [bf_ldy0_dy_nz]  return TAIL(~(sign(ldx) ^ sign(dy)))    # dot = -P2
;      [bf_general]     dx = px - lv1x ; dy = py - lv1y
;      if dx == 0:
;         if dy == 0:             return BACK
;         (shares [bf_ldy0_dy_nz])  TAIL(~(sign(ldx) ^ sign(dy)))  # dot = -P2
;      [bf_g_dx_nz]
;      if dy == 0:         return TAIL(sign(ldy) ^ sign(dx))       # dot = P1
;      [bf_g_both]      X = sign(P1) = sign(ldy) ^ sign(dx)
;      if X != sign(P2):   return TAIL(X)       # opposite signs decide
;      [bf_g_mul]       |P1| = |ldy|*|dx|, |P2| = |ldx|*|dy|   # u24 EXACT
;                       (high partial skipped when a senior byte is clear)
;      mode = bit7(X ^ flags):                  # sign and SAMEDIR together
;      [bfm_ge_dec] clear:  back iff |P1| >= |P2|
;      [bfm_le]     set:    back iff |P1| <= |P2|   # equal -> dot 0 -> back
;      [bfm_back]   shared Z-contract back exit
;
;   TAIL(s) = (s ^ flags) & $80                 # inlined at every producer:
;                                               # SAMEDIR is the top flag bit,
;                                               # packed INVERTED, so bit7 of
;                                               # s^flags = FRONT; A=$80/Z=0
;                                               # front, A=$00/Z=1 back.
;
br_back_face_test:
.scope
; ============================================================================
; UNIFORM C-FORM (2026-07-11, stride-16 header): dot = dy'*px - dx'*py - C
; with (dx',dy') the primitive linedef direction (SF_SAMEDIR folded into
; its sign at pack time) and C = dy'*lv1x - dx'*lv1y a pack-time s24.
;   header +4  form: 0 front iff px>C16, 1 px<C16, 2 py>C16, 3 py<C16,
;              >= 4: diagonal, (form-4) indexes the DIR tables
;   header +5..7 C (s24; axis compares use only +5/6 as s16)
; DIR tables (ROM_DIRS_C, one entry per distinct primitive direction):
;   +0*MAX |dx'| , +1*MAX |dy'| , +2*MAX sign byte (b7 dy'<0, b6 dx'<0)
; |px|/|py| are staged per frame by br_view_setup (zp_bf_p?m_*); signs
; read live from px_e/py_e bit7. Ties (dot == 0) are BACK, as always.
; TAIL-DISPATCHED: exits JMP bf_seg_front / bf_seg_back (no RTS).
; Ranges: |P1|,|P2| <= 127*2600 < 2^19; |dot|+|C| < 2^21 — s24 exact,
; no overflow handling needed anywhere.
; ============================================================================
   LDY #4
   LDA (zp_seg_hdr_p),Y
   CMP #4
   BCS bf_diag
   LSR A                                   ; C = strict-side (0 '>', 1 '<')
   BNE bf_ax_py                            ; A = 0 px : 1 py
; --- px vs C16 ---
   LDA zp_br_px_h
   BCS bf_ax_px_lt
; form 0: front iff px > C16  <=>  (px - C) > 0
   INY                                     ; -> C lo (+5)
   SEC
   SBC (zp_seg_hdr_p),Y
   STA zp_br_t2
   INY
   LDA zp_br_px_e
   SBC (zp_seg_hdr_p),Y
   BVS bf_ax_gt_ovf
   BMI bf_ax_back                          ; diff < 0
   ORA zp_br_t2
   BEQ bf_ax_back                          ; diff == 0 (tie -> back)
   JMP bf_seg_front
bf_ax_gt_ovf:
   BMI bf_ax_front                         ; V:N inverted — N set = positive
   BPL bf_ax_back
bf_ax_px_lt:
; form 1: front iff px < C16  <=>  (px - C) < 0
   INY
   SEC
   SBC (zp_seg_hdr_p),Y
   INY
   LDA zp_br_px_e
   SBC (zp_seg_hdr_p),Y
   BVS bf_ax_lt_ovf
   BMI bf_ax_front                         ; diff < 0
bf_ax_back:
   JMP bf_seg_back
bf_ax_lt_ovf:
   BPL bf_ax_front                         ; V:N inverted — N clear = negative
   BMI bf_ax_back
bf_ax_front:
   JMP bf_seg_front
; --- py vs C16 (forms 2/3) ---
bf_ax_py:
   LDA zp_br_py_h
   BCS bf_ax_py_lt
; form 2: front iff py > C16
   INY
   SEC
   SBC (zp_seg_hdr_p),Y
   STA zp_br_t2
   INY
   LDA zp_br_py_e
   SBC (zp_seg_hdr_p),Y
   BVS bf_ax_gt_ovf
   BMI bf_ax_back
   ORA zp_br_t2
   BEQ bf_ax_back
   JMP bf_seg_front
bf_ax_py_lt:
; form 3: front iff py < C16
   INY
   SEC
   SBC (zp_seg_hdr_p),Y
   INY
   LDA zp_br_py_e
   SBC (zp_seg_hdr_p),Y
   BVS bf_ax_lt_ovf
   BMI bf_ax_front
   BPL bf_ax_back

; --- diagonal: DELTA form with table primitives (2026-07-11 v2) ---
; dot = dy'*(px - lv1x) - dx'*(py - lv1y) > 0. The deltas stay SMALL
; near walls (senior-byte-clear -> 1-mul products), which measured
; FASTER than the C-form's raw-coordinate 4-mul products. Primitives
; (magnitudes + sign byte) come from the DIR tables; lv1x at +5/6,
; lv1y SPLIT +7 lo / +9 hi (the fossil L byte's slot); SF_SAMEDIR is
; folded into the primitive signs at pack time, so the old flags-EOR
; mode twist is gone.
bf_diag:
   SEC
   SBC #4
   TAX                                     ; X = dir index
   LDA ROM_DIRS_C + 2*LAY_MAX_DIRS,X       ; sign byte (b7 dy', b6 dx')
   STA zp_br_sign
   STX zp_bf_dir                           ; mags load lazily in the mul tier
; dx = px - lv1x (s16, header +5/6); dxhi rides A for the zero test
   LDA zp_br_px_h
   SEC
   LDY #5
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dxlo
   LDA zp_br_px_e
   INY
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dxhi
   ORA zp_br_dxlo
   BEQ bfd_dx0
; dy = py - lv1y (lo at +7, hi at +9 — the split around flags)
   LDA zp_br_py_h
   SEC
   INY                                     ; -> +7 (lv1y lo)
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dylo
   LDA zp_br_py_e
   LDY #9                                  ; -> lv1y hi
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dyhi
   ORA zp_br_dylo
   BEQ bfd_dy0                             ; dy==0: dot = P1
bf_g_both:
; sign(P1) = sgn(dy') ^ sgn(dxhi); sign(P2) = sgn(dx')<<1... build both:
   LDA zp_br_sign                          ; b7 = sgn dy'
   EOR zp_br_dxhi                          ; b7 = sign(P1)
   TAX                                     ; ride in X across the P2 sign
   LDA zp_br_sign
   ASL A                                   ; b6 (dx' sign) -> b7
   EOR zp_br_dyhi                          ; b7 = sign(P2)
   STA zp_br_t2
   TXA
   EOR zp_br_t2                            ; b7 set = opposite signs
   BPL bf_g_mul                            ; same sign -> magnitude compare
   TXA                                     ; opposite: sign(dot) = sign(P1)
   BMI bfd_back_j
   JMP bf_seg_front
bfd_back_j:
   JMP bf_seg_back
; dx == 0: dot = -P2 = -(dx'*dy); need dy for its sign (P2 = 0 handled:
; dy==0 too -> dot = 0 -> back)
bfd_dx0:
   LDA zp_br_py_h
   SEC
   INY                                     ; -> +7
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dylo
   LDA zp_br_py_e
   LDY #9
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dyhi
   ORA zp_br_dylo
   BEQ bfd_back_j                          ; dx==0 and dy==0 -> back
   LDA zp_br_sign
   ASL A                                   ; b7 = sgn dx'
   EOR zp_br_dyhi                          ; b7 = sign(P2)
   BMI bfd_front_j                         ; dot = -P2 > 0 iff P2 < 0
   JMP bf_seg_back
bfd_front_j:
   JMP bf_seg_front
; dy == 0: dot = P1 = dy'*dx (nonzero: dx != 0 here)
bfd_dy0:
   LDA zp_br_sign                          ; b7 = sgn dy'
   EOR zp_br_dxhi                          ; b7 = sign(P1)
   BMI bfd_back_j
   JMP bf_seg_front

bf_g_mul:
; both deltas nonzero, products same sign (X = shared sign, bit7):
;   sign + : back iff |P1| <= |P2|      sign - : back iff |P1| >= |P2|
; (SF_SAMEDIR already folded into the primitives — no flags twist.)
; u24 magnitude products with the high partial skipped when a delta's
; senior byte is clear (the common case).
   STX zp_br_sign                          ; X dies at SC_UMUL8
   LDA #0
   STA zp_br_t4                            ; |P1| hi = 0
   STA zp_br_t5                            ; |P2| hi = 0
   LDX zp_br_dxhi
   BPL bfm_dx_pos
   SEC
   SBC zp_br_dxlo
   STA zp_br_dxlo
   LDA #0
   SBC zp_br_dxhi
   STA zp_br_dxhi
bfm_dx_pos:
   LDX zp_br_dyhi
   BPL bfm_dy_pos
   LDA #0
   SEC
   SBC zp_br_dylo
   STA zp_br_dylo
   LDA #0
   SBC zp_br_dyhi
   STA zp_br_dyhi
bfm_dy_pos:
; --- |P1| = |dy'| * |dx| -> (t2, t3, t4) u24 (|dy'| pre-abs'd) ---
   LDX zp_bf_dir
   LDA ROM_DIRS_C + LAY_MAX_DIRS,X         ; |dy'| (lazy: only this tier pays)
   STA zp_br_a                             ; survives for the hi partial
   LDX zp_br_dxlo
   STX zp_mul_b
   JSR SC_UMUL8
   STA zp_br_t3
   LDA zp_prod_lo
   STA zp_br_t2
   LDA zp_br_dxhi
   BEQ bfm_p1_done                         ; senior byte clear: 1-mul product
   STA zp_mul_b
   LDA zp_br_a
   JSR SC_UMUL8
   LDA zp_prod_lo
   CLC
   ADC zp_br_t3
   STA zp_br_t3
   LDA zp_prod_hi
   ADC #0
   STA zp_br_t4
bfm_p1_done:
; --- |P2| = |dx'| * |dy| -> (t0, t1, t5) u24 ---
   LDX zp_bf_dir
   LDA ROM_DIRS_C,X                        ; |dx'|
   STA zp_br_a
   LDX zp_br_dylo
   STX zp_mul_b
   JSR SC_UMUL8
   STA zp_br_t1
   LDA zp_prod_lo
   STA zp_br_t0
   LDA zp_br_dyhi
   BEQ bfm_p2_done
   STA zp_mul_b
   LDA zp_br_a
   JSR SC_UMUL8
   LDA zp_prod_lo
   CLC
   ADC zp_br_t1
   STA zp_br_t1
   LDA zp_prod_hi
   ADC #0
   STA zp_br_t5
bfm_p2_done:
; --- mode select on sign(P1) and u24 compare ---
   LDA zp_br_sign
   BMI bfm_le
; positive: back iff |P1| <= |P2| ... i.e. FRONT iff |P1| > |P2|
   LDA zp_br_t4
   CMP zp_br_t5
   BNE bfm_gt_dec
   LDA zp_br_t3
   CMP zp_br_t1
   BNE bfm_gt_dec
   LDA zp_br_t2
   CMP zp_br_t0
   BEQ bfm_back                            ; equal -> dot == 0 -> back
bfm_gt_dec:
   BCC bfm_back                            ; |P1| < |P2| -> back
   JMP bf_seg_front
bfm_le:
; negative: back iff |P1| >= |P2| ... FRONT iff |P1| < |P2|
   LDA zp_br_t4
   CMP zp_br_t5
   BNE bfm_lt_dec
   LDA zp_br_t3
   CMP zp_br_t1
   BNE bfm_lt_dec
   LDA zp_br_t2
   CMP zp_br_t0
bfm_lt_dec:
   BCS bfm_back                            ; |P1| >= |P2| -> back
   JMP bf_seg_front
bfm_back:
   JMP bf_seg_back
.endscope

; ============================================================================
; br_bbox_visible — visibility test for a child subtree's bounding box.
;
; NOTE: the routine itself lives in src/bsp/bbox.s. The algorithm sketch
; below (steps 1-7) describes the RETIRED perspective corner-projection
; implementation; the live code dispatches to the angle-space BCA module
; instead (see the banner near BCA_CHECK below). This block is kept for
; the I/O contract and the scratch-layout documentation that follows.
;
;   Inputs:
;     zp_node_chlo:hi = node id (used by caller; we read bbox by ourselves)
;     zp_bbox_side    = 0 for right child's bbox, 1 for left child's bbox.
;
;   Output: A = 1 if any visible gap in the bbox's screen-X range, else 0.
;
;   Algorithm (matches Python fp_bbox_visible_fixed loosely):
;     1. Compute bbox ptr = ROM_BBOX + node_id*16 + (side<<3).
;     2. Inside test: if (px_int, py_int) inside bbox, return 1 (always visible).
;     3. Transform 4 corners (l,t)(r,t)(r,b)(l,b) through br_to_view.
;     4. For each in front of NEAR plane, project to screen X.
;     5. If all behind near plane → return 0 (off-screen).
;        If any behind near plane → assume visible (set ilo=0, ihi=255).
;        Else min/max projected sx, clamped to [0, 255] → ilo, ihi.
;     6. If ilo > ihi → return 0.
;     7. JSR span_has_gap → return its A.
; ============================================================================
SC_HAS_GAP = jt_has_gap
SC_IS_FULL = jt_is_full

; Per-corner storage (5 bytes × 4 = 20) — legacy perspective-path scratch
; (dead with the angle module; layout retained). bv_proj_one writes here so
; that a second pass can compute near-plane edge crossings between
; consecutive corners. Layout per corner: vx_lo, vx_hi, vy_lo, vy_hi,
; in_front (0/1).
; NOTE: these previously lived at $0E00/$0E14 — INSIDE the vertex cache
; ($0C00 + 8x467 = $1A98) — so every bbox visibility check corrupted the
; cached transforms of vertices ~64-66. $0960-$0974 is free scratch
; (span_clip's LC_* scratch ends at $0958).
BBOX_CORNERS = $0A40                    ; 4 x 8: vx16, vy16, front, vy24 (lo,hi,ext)
; (overlays the per-seg projection scratch — disjoint phases)
BBOX_CORNER_IDX = $09FD                 ; offset into BBOX_CORNERS for current corner

; Deferred per-subsector op queue (mirrors Python's packed_render_subsector
; `deferred` list): seg-ordered solid/tighten ops, applied at subsector end.
;   entry: $00, ilo, ihi                                  (solid)
;          $01, ilo, ihi, top block, bot block            (tighten)
;   where each block is (count, 6*count record bytes) snapshotted from
;   TOP_RECORDS/$0700 / BOT_RECORDS/$0800 at seg end — later segs' DCL
;   emission overwrites those buffers before the drain, exactly the
;   problem Python solves with its '__rec__' snapshots.
;   (Correction: records are 4 bytes each now — blocks are
;   (count, 4*count bytes); see defq_append_tighten in defq.s and the
;   Python snapshot `TOP_RECORDS : TOP_RECORDS + 1 + tc*4`.)
DEFQ_BASE = $0600                       ; 256 bytes (free: span pool ends $059F)
DEFQ_TAIL = $2B                         ; queue tail offset (u8) — moved from
; $F7 (2026-07-10: $F7 is now inside the VX2 vertex struct); zp.inc
; registers this address as zp_defq_tail — keep in sync
DEFQ_OVF = $09FC                        ; set if an op was dropped (queue full) — debug

; Near-plane edge-crossing scratch. Reuses the per-seg ZP block — bbox
; visibility runs during node processing, when the seg-loop variables
; ($5D-$6F) are dead.

BBOX_SCRATCH = $0960                    ; 8 bytes: top_lo,top_hi,bot_lo,bot_hi,
;          left_lo,left_hi,right_lo,right_hi
BBOX_FLAGS = $0968                      ; bit 0 = any_behind, bit 1 = any_front
BBOX_ILO = $0969                        ; running min sx clamped (u8)
BBOX_IHI = $096A                        ; running max sx clamped (u8)

; --- Angle-space bbox module (bsp_render_ang.bin @ $E940; tables $DC00/$E400/$F200).
;     Replaces the perspective corner-projection path below (now dead code).
; angle module + bca workspace relocate when banked (must match slope_div.asm:
;   code -> $3400 (entry+3 = $3403); bca workspace -> BCA_WS $3A00).
.import jt_bca_check, jt_bca_frame
BCA_CHECK = jt_bca_check                ; JSR -> bbox_check_angle (point_to_angle inlined out)
; (BCA_WS comes from abi.inc — the old triplet is dead)
bca_top = BCA_WS+$10                    ; box input: top,bot,left,right = +$10,$12,$14,$16
bca_ilo = $BB                           ; output: left column (u8) — ZP
bca_ihi = $BF                           ; output: right column (u8) — ZP
bca_vis = $64                           ; output: 1=visible, 0=cull — ZP
; (2026-07-10: $F5 is inside the VX2 vertex struct now; keep in sync with
; ang/header_div.s — BOTH define this)
bca_ab = BCA_WS+$2F                     ; per-frame view angle (set by render setup)
