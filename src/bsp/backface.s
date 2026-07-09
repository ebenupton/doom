
; ============================================================================
; br_back_face_test — test current seg for back-facing.
;   Inputs (zp): zp_seg_lv1x/lv1y (s16 linedef v1, seg header bytes 4-7),
;                zp_seg_ldx/ldy (s8 linedef delta, header bytes 8-9),
;                zp_seg_flags (header byte 10; SF_SAMEDIR = $80, the top
;                bit, INVERTED: set = seg runs with its linedef).
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
; --- Dispatch FIRST, compute deltas LAZILY (2026-07-09): the old body
; computed BOTH s16 deltas up front, but the axis-aligned majority
; (~76% of segs, measured) consumes exactly one, and the degenerate
; early-outs consume none. Each arm now derives only what it reads;
; the general arm computes both.
; If ldx == 0: dot = ldy*dx, sign matches iff sign(ldy)==sign(dx).
; If ldy == 0: dot = -ldx*dy, sign matches iff sign(ldx)!=sign(dy).
; SF_DIR negates dot.
   LDY #8                                   ; -> ldx (+8)
   LDA (zp_br_p),Y
   BNE bf_ldx_nz
; ldx==0
   INY                                      ; -> ldy (+9)
   LDA (zp_br_p),Y
   BNE bf_ldx0_ldy_nz
   RTS                                     ; ldx=0, ldy=0 → dot=0 → back (Z=1)
bf_ldx0_ldy_nz:
; A still = ldy (BNE preserves it). Stash DEFERRED past the ldy==0 RTS
; above so that degenerate back path never pays it — reused at the
; bf_ldx0_dx_nz sign below.
   STA zp_seg_ldy
; dx = px_int - lv1_x (s16) — the only delta this arm needs. lv1x is read
; ON DEMAND from the header (+4/+5) via zp_br_p, not a ZP stage.
   LDA zp_br_px_h
   SEC
   LDY #4                                   ; -> lv1x_lo (+4)
   SBC (zp_br_p),Y
   STA zp_br_dxlo
   LDA zp_br_px_e
   INY                                      ; -> lv1x_hi (+5)
   SBC (zp_br_p),Y
   STA zp_br_dxhi
   LDA zp_br_dxlo
   ORA zp_br_dxhi
   BNE bf_ldx0_dx_nz
   RTS                                     ; dx == 0 → dot=0 → back (Z=1)
bf_ldx0_dx_nz:
; sign(dot) = sign(ldy) XOR sign(dx_hi); ldy from ZP (stashed at first load)
   LDA zp_seg_ldy
   EOR zp_br_dxhi
   EOR zp_seg_flags                        ; inlined bf_apply_dir: bit7 =
   AND #$80                                ; FRONT (SAMEDIR packed inverted);
   RTS                                     ; A/Z IS the verdict
bf_ldx_nz:
   STA zp_seg_ldx                           ; A=ldx from dispatch; reused on
                                            ; every ldx!=0 path — stash from A
   INY                                      ; Y was 8 (dispatch) -> 9
   LDA (zp_br_p),Y                          ; ldy (+9)
   BNE bf_general
; ldy==0: dot = -ldx*dy. dy = py_int - lv1_y (s16) — only delta needed.
; lv1y read on demand from the header (+6/+7) via zp_br_p.
   LDA zp_br_py_h
   SEC
   LDY #6                                   ; -> lv1y_lo (+6)
   SBC (zp_br_p),Y
   STA zp_br_dylo
   LDA zp_br_py_e
   INY                                      ; -> lv1y_hi (+7)
   SBC (zp_br_p),Y
   STA zp_br_dyhi
   LDA zp_br_dylo
   ORA zp_br_dyhi
   BNE bf_ldy0_dy_nz
   RTS                                     ; dy == 0 → dot=0 → back (Z=1)
bf_ldy0_dy_nz:
; sign(dot) = sign(-ldx*dy) = NOT(sign(ldx) XOR sign(dy_hi)); ldx from ZP
   LDA zp_seg_ldx
   EOR zp_br_dyhi
   EOR #$80
; sign tail (inlined at every producer, 2026-07-09 — was JMP bf_apply_dir):
; A's top bit = sign of dot (1=neg). SF_SAMEDIR is the top flag bit and
; PACKED INVERTED (set = no direction flip), so sign ^ flags gives
; bit7 = 1 ⇔ FRONT with no correction — and AND #$80 then IS the whole
; Z-contract verdict: A=$80/Z=0 front, A=$00/Z=1 back. Branchless.
   EOR zp_seg_flags
   AND #$80
   RTS

bf_general:
; A=ldy from the bf_ldx_nz load; reused in the sign shortcut + mul arm —
; stash it (ldx was stashed at bf_ldx_nz). Both deltas on demand below,
; lv1x (+4/+5) then lv1y (+6/+7) — Y walks 4→7.
   STA zp_seg_ldy
; Deltas computed dy FIRST, dx SECOND so the last STA leaves dxhi in A
; for the dx==0 test below (saves its LDA). lv1y (+6/+7) then lv1x (+4/+5).
   LDA zp_br_py_h
   SEC
   LDY #6                                   ; -> lv1y_lo (+6)
   SBC (zp_br_p),Y
   STA zp_br_dylo
   LDA zp_br_py_e
   INY                                      ; -> lv1y_hi (+7)
   SBC (zp_br_p),Y
   STA zp_br_dyhi
   LDA zp_br_px_h
   SEC
   LDY #4                                   ; -> lv1x_lo (+4)
   SBC (zp_br_p),Y
   STA zp_br_dxlo
   LDA zp_br_px_e
   INY                                      ; -> lv1x_hi (+5)
   SBC (zp_br_p),Y
   STA zp_br_dxhi                           ; A = dxhi, in hand below
; Sign shortcut first (EXACT — ldx,ldy nonzero here, so P1 = ldy*dx is
; zero iff dx==0, P2 = ldx*dy zero iff dy==0, and sign(product) = XOR of
; operand signs). dot = P1 - P2 > 0 -> front. Opposite-sign products
; decide by sign alone; only same-sign products need the two multiplies.
; (Bonus: the decided-by-sign cases never reach the u24 magnitude path.)
   ORA zp_br_dxlo                           ; dxhi (in A) | dxlo → dx==0 test
   BNE bf_g_dx_nz
   LDA zp_br_dylo
   ORA zp_br_dyhi
   BNE bf_ldy0_dy_nz                       ; dot = -P2: byte-identical to the
                                           ; ldy==0 arm's tail — share it
   RTS                                     ; dx==0 and dy==0 → back (Z=1)
bf_g_dx_nz:
   LDA zp_br_dylo
   ORA zp_br_dyhi
   BEQ bf_ldx0_dx_nz                       ; dy==0 → dot = P1: byte-identical
                                           ; to the ldx==0 arm's tail — share
bf_g_both:
   LDA zp_seg_ldy                           ; ldy from ZP
   EOR zp_br_dxhi                          ; sign(P1)
   TAX                                     ; ride in X (was a zp_br_t2 stash)
   EOR zp_seg_ldx                           ; ^ ldx from ZP
   EOR zp_br_dyhi                          ; ^ sign(P2)
   BPL bf_g_mul                            ; same sign -> full compare below
   TXA                                     ; opposite: sign(dot) = sign(P1)
   EOR zp_seg_flags                        ; inlined bf_apply_dir: bit7 =
   AND #$80                                ; FRONT (SAMEDIR packed inverted);
   RTS                                     ; A/Z IS the verdict
bf_g_mul:
; ldx and ldy both nonzero, products SAME sign (X = the shared sign byte,
; bit7). dot = P1 - P2 with P1 = ldy*dx, P2 = ldx*dy, so in magnitudes:
;   sign + : back iff |P1| <= |P2|      sign - : back iff |P1| >= |P2|
; and SF_SAMEDIR (clear = flipped seg) swaps the sense. Mode = bit7 of
; (X ^ flags): clear -> back iff |P1| >= |P2|, set -> back iff <=.
; Unsigned u24 magnitude products — EXACT (the old br_smul_s8_s16 pair
; truncated the dot to s16) — with the HIGH PARTIAL SKIPPED whenever a
; magnitude's senior byte is clear (|delta| fits u8, the common case:
; one mul per product instead of two). |P1|==|P2| means dot == 0 ->
; back under both modes. Replaced the 2x sign-magnitude smul wrappers,
; the dy->dx operand copy, the s16 subtract and both negates; the only
; caller of br_smul_s8_s16, which is deleted.
   STX zp_br_sign                          ; the shared sign byte CANNOT ride
                                           ; in X here — SC_UMUL8 clobbers X/Y
                                           ; (zp_br_sign is free: its owner
                                           ; br_smul_s8_s16 is deleted)
; --- magnitudes in place: |dx|, |dy| ---
   LDA zp_br_dxhi
   BPL bfm_dx_pos
   LDA #0
   SEC
   SBC zp_br_dxlo
   STA zp_br_dxlo
   LDA #0
   SBC zp_br_dxhi
   STA zp_br_dxhi
bfm_dx_pos:
   LDA zp_br_dyhi
   BPL bfm_dy_pos
   LDA #0
   SEC
   SBC zp_br_dylo
   STA zp_br_dylo
   LDA #0
   SBC zp_br_dyhi
   STA zp_br_dyhi
bfm_dy_pos:
; --- |P1| = |ldy| * |dx| -> (t2, t3, vxext) u24 ---
   LDA zp_seg_ldy                           ; ldy from ZP (Y-agnostic; SC_UMUL8
   BPL bfm_ly_pos                           ;   clobbers Y so ZP read is ideal)
   EOR #$FF
   CLC
   ADC #1
bfm_ly_pos:
   STA zp_br_a                             ; |ldy| survives for the hi partial
   LDA zp_br_dxlo
   STA zp_mul_b
   LDA zp_br_a
   JSR SC_UMUL8
   LDA zp_prod_lo
   STA zp_br_t2
   LDA zp_prod_hi
   STA zp_br_t3
   LDA #0
   STA zp_br_vxext
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
   ADC #0                                  ; (+ carry; vxext was 0)
   STA zp_br_vxext
bfm_p1_done:
; --- |P2| = |ldx| * |dy| -> (t0, t1, dxlo) u24 (dx slots are dead) ---
   LDA zp_seg_ldx                           ; ldx from ZP
   BPL bfm_lx_pos
   EOR #$FF
   CLC
   ADC #1
bfm_lx_pos:
   STA zp_br_a
   LDA zp_br_dylo
   STA zp_mul_b
   LDA zp_br_a
   JSR SC_UMUL8
   LDA zp_prod_lo
   STA zp_br_t0
   LDA zp_prod_hi
   STA zp_br_t1
   LDA #0
   STA zp_br_dxlo
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
   STA zp_br_dxlo
bfm_p2_done:
; --- mode select and u24 compare (Z-contract verdict) ---
   LDA zp_br_sign
   EOR zp_seg_flags
   BMI bfm_le
; back iff |P1| >= |P2|: C=1 through the chain decides (equal -> back)
   LDA zp_br_vxext
   CMP zp_br_dxlo
   BNE bfm_ge_dec
   LDA zp_br_t3
   CMP zp_br_t1
   BNE bfm_ge_dec
   LDA zp_br_t2
   CMP zp_br_t0
bfm_ge_dec:
   BCS bfm_back
   LDA #1                                  ; Z=0: front
   RTS
bfm_le:
; back iff |P1| <= |P2|: first difference decides; equal -> back
   LDA zp_br_vxext
   CMP zp_br_dxlo
   BNE bfm_le_dec
   LDA zp_br_t3
   CMP zp_br_t1
   BNE bfm_le_dec
   LDA zp_br_t2
   CMP zp_br_t0
   BEQ bfm_back                            ; equal -> dot == 0 -> back
bfm_le_dec:
   BCC bfm_back                            ; |P1| < |P2| -> back
   LDA #1                                  ; Z=0: front
   RTS
bfm_back:
   LDA #0                                  ; Z=1: back
   RTS
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
DEFQ_TAIL = $F7                         ; queue tail offset (u8) — ZP (was $09FB)
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
.if ::BANKED
BCA_WS = $3A00
.else
BCA_WS = $FA00
.endif
bca_top = BCA_WS+$10                    ; box input: top,bot,left,right = +$10,$12,$14,$16
bca_ilo = $BB                           ; output: left column (u8) — ZP
bca_ihi = $BF                           ; output: right column (u8) — ZP
bca_vis = $F5                           ; output: 1=visible, 0=cull — ZP
; (moved from BCA_WS+$30.. 2026-07-08; keep in sync with ang/header_div.s)
bca_ab = BCA_WS+$2F                     ; per-frame view angle (set by render setup)
