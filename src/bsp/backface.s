
; ============================================================================
; br_back_face_test — test current seg for back-facing.
;   Inputs (zp): zp_seg_lv1x/lv1y (s16), zp_seg_ldx/ldy (s8), zp_seg_flags.
;                zp_br_px_h, zp_br_py_h = player px_int, py_int (s8).
;   Output: zp_seg_skip = 1 if back-facing, 0 if front-facing.
;
;   dot = ldy * (px_int - lv1_x) - ldx * (py_int - lv1_y)
;   if flags & SF_DIR: dot = -dot
;   back-facing if dot <= 0.
; ============================================================================
br_back_face_test:
.scope
; dx = px_int - lv1_x (s16). px_int (s8) sign-extended.
LDA zp_br_px_h
STA zp_br_dxlo
ZERO zp_br_dxhi
LDA zp_br_dxlo
BPL bf_px_pos
LDA #$FF
STA zp_br_dxhi
bf_px_pos:
LDA zp_br_dxlo
SEC
SBC zp_seg_lv1x_lo
STA zp_br_dxlo
LDA zp_br_dxhi
SBC zp_seg_lv1x_hi
STA zp_br_dxhi
; dy = py_int - lv1_y (s16)
LDA zp_br_py_h
STA zp_br_dylo
ZERO zp_br_dyhi
LDA zp_br_dylo
BPL bf_py_pos
LDA #$FF
STA zp_br_dyhi
bf_py_pos:
LDA zp_br_dylo
SEC
SBC zp_seg_lv1y_lo
STA zp_br_dylo
LDA zp_br_dyhi
SBC zp_seg_lv1y_hi
STA zp_br_dyhi

; --- Fast path for axis-aligned linedefs (~76% of segs).
; If ldx == 0: dot = ldy*dx, sign matches iff sign(ldy)==sign(dx).
; If ldy == 0: dot = -ldx*dy, sign matches iff sign(ldx)!=sign(dy).
; SF_DIR negates dot.
LDA zp_seg_ldx
BNE bf_ldx_nz
; ldx==0
LDA zp_seg_ldy
BNE bf_ldx0_ldy_nz
JMP bf_back                             ; ldx=0, ldy=0 → dot=0 → back
bf_ldx0_ldy_nz:
LDA zp_br_dxlo
ORA zp_br_dxhi
BNE bf_ldx0_dx_nz
JMP bf_back                             ; dx == 0 → dot=0 → back
bf_ldx0_dx_nz:
; sign(dot) = sign(ldy) XOR sign(dx_hi)
LDA zp_seg_ldy
EOR zp_br_dxhi
JMP bf_apply_dir
bf_ldx_nz:
LDA zp_seg_ldy
BNE bf_general
; ldy==0: dot = -ldx*dy.
LDA zp_br_dylo
ORA zp_br_dyhi
BNE bf_ldy0_dy_nz
JMP bf_back                             ; dy==0 -> dot=0 -> back
bf_ldy0_dy_nz:
; sign(dot) = sign(-ldx*dy) = NOT(sign(ldx) XOR sign(dy_hi))
LDA zp_seg_ldx
EOR zp_br_dyhi
EOR #$80
; falls through to bf_apply_dir
bf_apply_dir:
; A holds a byte whose top bit = sign of dot (1=neg, 0=pos).
; SF_DIR ($01) negates the dot, so XOR top bit with bit 0 of flags shifted.
; Simpler: stash, then if SF_DIR set, EOR #$80.
PHA
LDA zp_seg_flags
AND #$01
BEQ bf_apply_no_neg
PLA
EOR #$80
JMP bf_check_sign
bf_apply_no_neg:
PLA
bf_check_sign:
; Top bit set → dot < 0 → back. Top bit clear → dot > 0 → front
; (zero-dot cases never reach here).
BPL bf_cs_front
JMP bf_back
bf_cs_front:
JMP bf_front

bf_general:
; Sign shortcut first (EXACT — ldx,ldy nonzero here, so P1 = ldy*dx is
; zero iff dx==0, P2 = ldx*dy zero iff dy==0, and sign(product) = XOR of
; operand signs). dot = P1 - P2 > 0 -> front. Opposite-sign products
; decide by sign alone; only same-sign products need the two multiplies.
; (Bonus: the decided-by-sign cases are immune to the s16 truncation of
; br_smul_s8_s16 — the residual risk is confined to same-sign products.)
LDA zp_br_dxlo
ORA zp_br_dxhi
BNE bf_g_dx_nz
LDA zp_br_dylo
ORA zp_br_dyhi
BNE bf_g_p2only
JMP bf_back                             ; dx==0 and dy==0 -> dot=0 -> back
bf_g_p2only:
; dot = -P2: sign = NOT(sign(ldx) ^ sign(dy))
LDA zp_seg_ldx
EOR zp_br_dyhi
EOR #$80
JMP bf_apply_dir
bf_g_dx_nz:
LDA zp_br_dylo
ORA zp_br_dyhi
BNE bf_g_both
; dy==0 -> dot = P1: sign = sign(ldy) ^ sign(dx)
LDA zp_seg_ldy
EOR zp_br_dxhi
JMP bf_apply_dir
bf_g_both:
LDA zp_seg_ldy
EOR zp_br_dxhi                          ; sign(P1)
STA zp_br_t2
EOR zp_seg_ldx
EOR zp_br_dyhi                          ; ^ sign(P2)
BPL bf_g_mul                            ; same sign -> full compare below
LDA zp_br_t2                            ; opposite: sign(dot) = sign(P1)
JMP bf_apply_dir
bf_g_mul:
; ldx and ldy both nonzero — full 2-mul s8×s16 dot product.
; ldy * dx → s16 in resl/resh; save in t2:t3.
LDA zp_seg_ldy
STA zp_br_a
JSR br_smul_s8_s16
LDA zp_br_resl
STA zp_br_t2
LDA zp_br_resh
STA zp_br_t3

; ldx * dy → s16 in resl/resh.
LDA zp_br_dylo
STA zp_br_dxlo
LDA zp_br_dyhi
STA zp_br_dxhi
LDA zp_seg_ldx
STA zp_br_a
JSR br_smul_s8_s16

; dot = prod1 - prod2 (s16)
LDA zp_br_t2
SEC
SBC zp_br_resl
STA zp_br_t2
LDA zp_br_t3
SBC zp_br_resh
STA zp_br_t3

; SF_DIR negate
LDA zp_seg_flags
AND #$01
BEQ bf_g_no_neg
LDA #0
SEC
SBC zp_br_t2
STA zp_br_t2
LDA #0
SBC zp_br_t3
STA zp_br_t3
bf_g_no_neg:
; dot <= 0 → back-facing
LDA zp_br_t3
BMI bf_back
BNE bf_front
LDA zp_br_t2
BEQ bf_back
bf_front:
LDA #0
STA zp_seg_skip
RTS
bf_back:
LDA #1
STA zp_seg_skip
RTS
.endscope

; ============================================================================
; br_bbox_visible — visibility test for a child subtree's bounding box.
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

; Per-corner storage (5 bytes × 4 = 20). bv_proj_one writes here so that a
; second pass can compute near-plane edge crossings between consecutive
; corners. Layout per corner: vx_lo, vx_hi, vy_lo, vy_hi, in_front (0/1).
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
DEFQ_BASE = $0600                       ; 256 bytes (free: span pool ends $059F)
DEFQ_TAIL = $09FB                       ; queue tail offset (u8)
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
.import jt_bca_check
BCA_CHECK = jt_bca_check                ; JSR -> bbox_check_angle (point_to_angle inlined out)
.if ::BANKED
BCA_WS = $3A00
.else
BCA_WS = $FA00
.endif
bca_top = BCA_WS+$10                    ; box input: top,bot,left,right = +$10,$12,$14,$16
bca_ilo = BCA_WS+$30                    ; output: left column (u8)
bca_ihi = BCA_WS+$31                    ; output: right column (u8)
bca_vis = BCA_WS+$32                    ; output: 1=visible, 0=cull
bca_ab = BCA_WS+$2F                     ; per-frame view angle (set by render setup)
