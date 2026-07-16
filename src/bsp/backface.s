
; ============================================================================
; br_back_face_test — is the current seg back-facing?  [pipeline stage 1]
;
; CONTEXT: sole caller is the seg loop (subsector.s), which stages
; zp_seg_flags and JMPs here (no JSR). TAIL-DISPATCHED exits:
;   front  -> JMP ::bf_seg_front (subsector.s, the seg pipeline resumes)
;   back   -> JMP ::s_advance    (subsector.s, next seg — one hop; the
;                                 old bf_seg_back trampoline died 2026-07-12)
; There is NO flag/return contract: control flow IS the verdict.
;
;   Inputs (zp): zp_seg_hdr_p -> the 16-byte seg header (form at +4, C16
;                or lv1x at +5/+6, lv1y split lo +7 / hi +9);
;                zp_br_px_h/px_e, zp_br_py_h/py_e = player int pos (s16);
;                zp_bf_pxm_l/hi, zp_bf_pym_l/hi = |px|,|py| (staged
;                once per frame by br_view_setup, view.s).
;   Clobbers: A, X, Y; zp_br_dx/dy lo+hi, zp_br_t2..t5, zp_br_sign,
;             zp_bf_dir, zp_br_a, the mul workspace (via SC_UMUL8).
;   Bank state: caller holds BANK_L0 paged (header reads); no paging here.
;
; ALGORITHM (uniform C-form, 2026-07-11 — see the banner inside the
; scope for the full derivation): dot = dy'*px - dx'*py - C, with
; (dx',dy') the seg's primitive linedef direction (gcd-reduced,
; SF_SAMEDIR folded into its SIGN at pack time — the flag byte is never
; read here) and C a pack-time constant.
;   - Axis-aligned linedefs (form 0-3, ~76% of segs): dot's sign is ONE
;     s16 compare of px or py against C16 (header +5/+6). Zero muls.
;   - Diagonals (form >= 4): (form-4) indexes the DIR tables at
;     ROM_DIRS_C (layout.inc; |dx'| / |dy'| / sign byte planes,
;     MAX_DIRS=160 apart). Delta form: dot = dy'*(px-lv1x) - dx'*(py-lv1y)
;     — the deltas stay SMALL, which keeps the products 1-mul most of
;     the time (senior-byte-clear fast path). A C-form on raw coords was
;     measured 4-mul WORSE — small operands are load-bearing here.
;     Sign shortcut first (opposite product signs decide with no mul);
;     |dx'|/|dy'| magnitudes load LAZILY in the mul tier via zp_bf_dir
;     (sign-shortcut exits never read them, 2026-07-11).
;   Ties (dot == 0) are BACK on every path.
;
; Python mirror: packed_render_seg's bf_form dispatch (doom_wireframe.py)
; — bit-identical by construction; the packer (wad_packed.py) emits
; form/C/DIR data in the same loop that sets the flags.
; ============================================================================
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
; TAIL-DISPATCHED: exits JMP bf_seg_front / s_advance (no RTS).
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
   BCS bf_ax_px_lt
; form 0: front iff px > C16 — REVERSED subtract (2026-07-16): C16 - px
; is strictly negative iff front, so ties fall to BACK on the sign test
; alone and the old STA/ORA/BEQ tie chain is gone ('<' arms always
; worked this way; the reversed decode shares their overflow stub).
   INY                                     ; -> C lo (+5)
   LDA (zp_seg_hdr_p),Y
   CMP zp_br_px_h                          ; borrow seed (result dead)
   INY
   LDA (zp_seg_hdr_p),Y
   SBC zp_br_px_x                          ; C16 - px
   BVS bf_ax_lt_ovf
   BMI bf_ax_front                         ; C16 < px -> front
   BPL bf_ax_back                          ; tie/less -> back (always)
bf_ax_px_lt:
; form 1: front iff px < C16  <=>  (px - C) < 0
; (C=1 = the LSR's strict-side bit — the BCS that got us here)
   LDA zp_br_px_h
   INY
   SBC (zp_seg_hdr_p),Y
   INY
   LDA zp_br_px_x
   SBC (zp_seg_hdr_p),Y
   BVS bf_ax_lt_ovf
   BMI bf_ax_front                         ; diff < 0
bf_ax_back:
   JMP s_advance
bf_ax_lt_ovf:
   BPL bf_ax_front                         ; V:N inverted — N clear = negative
   BMI bf_ax_back
bf_ax_front:
   JMP bf_seg_front
; --- py vs C16 (forms 2/3) ---
bf_ax_py:
   BCS bf_ax_py_lt
; form 2: front iff py > C16 — reversed like form 0
   INY
   LDA (zp_seg_hdr_p),Y
   CMP zp_br_py_h
   INY
   LDA (zp_seg_hdr_p),Y
   SBC zp_br_py_x
   BVS bf_ax_lt_ovf
   BMI bf_ax_front
   BPL bf_ax_back                          ; (always)
bf_ax_py_lt:
; form 3: front iff py < C16
; (C=1 = the LSR's strict-side bit — the BCS that got us here)
   LDA zp_br_py_h
   INY
   SBC (zp_seg_hdr_p),Y
   INY
   LDA zp_br_py_x
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
   STA zp_br_dx_l
   LDA zp_br_px_x
   INY
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dx_h
   ORA zp_br_dx_l
   BEQ bfd_dx0
; dy = py - lv1y (lo at +7, hi at +9 — the split around flags)
   LDA zp_br_py_h
   SEC
   INY                                     ; -> +7 (lv1y lo)
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dy_l
   LDA zp_br_py_x
   LDY #9                                  ; -> lv1y hi
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dy_h
   ORA zp_br_dy_l
   BEQ bfd_dy0                             ; dy==0: dot = P1
bf_g_both:
; sign(P1) = sgn(dy') ^ sgn(dxhi); sign(P2) = sgn(dx')<<1... build both:
   LDA zp_br_sign                          ; b7 = sgn dy'
   EOR zp_br_dx_h                          ; b7 = sign(P1)
   TAX                                     ; ride in X across the P2 sign
   LDA zp_br_sign
   ASL A                                   ; b6 (dx' sign) -> b7
   EOR zp_br_dy_h                          ; b7 = sign(P2)
   STA zp_br_t2
   TXA
   EOR zp_br_t2                            ; b7 set = opposite signs
   BPL bf_g_mul                            ; same sign -> magnitude compare
   TXA                                     ; opposite: sign(dot) = sign(P1)
   BMI bfd_back_j
   JMP bf_seg_front
bfd_back_j:
   JMP s_advance
; dx == 0: dot = -P2 = -(dx'*dy); need dy for its sign (P2 = 0 handled:
; dy==0 too -> dot = 0 -> back)
bfd_dx0:
   LDA zp_br_py_h
   SEC
   INY                                     ; -> +7
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dy_l
   LDA zp_br_py_x
   LDY #9
   SBC (zp_seg_hdr_p),Y
   STA zp_br_dy_h
   ORA zp_br_dy_l
   BEQ bfd_back_j                          ; dx==0 and dy==0 -> back
   LDA zp_br_sign
   ASL A                                   ; b7 = sgn dx'
   EOR zp_br_dy_h                          ; b7 = sign(P2)
   BMI bfd_front_j                         ; dot = -P2 > 0 iff P2 < 0
   JMP s_advance
bfd_front_j:
   JMP bf_seg_front
; dy == 0: dot = P1 = dy'*dx (nonzero: dx != 0 here)
bfd_dy0:
   LDA zp_br_sign                          ; b7 = sgn dy'
   EOR zp_br_dx_h                          ; b7 = sign(P1)
   BMI bfd_back_j
   JMP bf_seg_front

bf_g_mul:
; both deltas nonzero, products same sign (X = shared sign, bit7):
; the magnitude comparator is the shared CROSS_MAG_DECIDE macro
; (header.s) — same core serves br_node_setup's general arm (lo.s).
   CROSS_MAG_DECIDE bf_seg_front, s_advance
.endscope
; Layout keeper: the 2026-07-15 tail cleanup shrank this routine by 10
; bytes net; shifting everything downstream rolls page-cross dice in
; hot loops (measured swings of +-1000/position on this suite). Pad
; scanned 6/10/12/14/18: 12 measured best (-207 vs -160 at exact
; restore). Safe to delete/re-scan whenever MAIN is next rebalanced.
   .res 12
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
;     zp_node_ch_l:hi = node id (used by caller; we read bbox by ourselves)
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
SC_HAS_GAP = span_has_gap               ; main-resident (no PAGE needed)
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
