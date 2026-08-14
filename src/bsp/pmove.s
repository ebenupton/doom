; ============================================================================
; Player movement — DOOM P_TryMove / P_UseLines replica (2026-08-14).
;
; The rules live in colmap.py (the canonical python model + the pack-time
; table generator); this file is their 6502 expression. Tables (all in
; BANK_WALK banked — the same bank as the node SoA, so one paging context
; covers the whole test; flat homes = the tube parasite map):
;   COLIDX_BASE  36 x (u16 list addr, u8 count) per 128-unit column,
;                then the u8 seg-index lists
;   COLSEG_BASE  n x 8: x1,y1,dx,dy (center-relative raw s16 LE) — the
;                reachability-pruned, colinear-merged blocking lines
;                (one-sided + ML_BLOCKING)
;   SS_VZ_BASE   per-subsector prescale(floor+41) (s8)
;   SS_INFO_BASE per-subsector: $FF none | mover idx, b7 = ceil mover
;   MV_MINPASS   per-mover min passable door pos (fh+56 prescaled)
;   USETAB_BASE  u8 n_use, n_use x 9 (x1,y1,dx,dy s16 + action),
;                u8 n_walk, n_walk x 9   (action: mover idx, $FE = exit)
;
; Driver ABI (engine_syms): pmove_try / pmove_use / pm_oldx / pm_vz /
; pm_ux. Movement runs OUTSIDE render_frame, so the render's frame-scoped
; zp (zp_br_*, zp_node_ch_l, zp_anim_p) is reusable scratch here.
; ============================================================================

SEG_PMOVE

; --- driver-visible state (the PMOVE region is main RAM in every build) ---
::pm_oldx:  .res 2                      ; committed position, raw s16
::pm_oldy:  .res 2                      ;   (for walkover crossing tests)
::pm_vz:    .res 1                      ; current vz, prescaled s8 (in/out)
::pm_ux:    .res 2                      ; use-trace delta, raw s16
::pm_uy:    .res 2
pm_exx:     .res 2                      ; crossing-test endpoint (staged
pm_exy:     .res 2                      ;  by pmove_use)

; --- internal scratch ---
pm_bx0:     .res 2                      ; candidate box bounds (raw s16);
pm_by0:     .res 2                      ;  ORDER IS LOAD-BEARING: the
pm_bx1:     .res 2                      ;  bounds loop indexes pm_bx0,X /
pm_by1:     .res 2                      ;  pm_bx1,X with X = 0 (x) / 2 (y)
pm_c1:      .res 1                      ; second column (or == first)
pm_cnt:     .res 1
pm_dvz:     .res 1                      ; dest vz candidate
pm_t1s:     .res 1                      ; smul t1: sign / 24-bit mag
pm_t1m:     .res 3
pm_t2s:     .res 1
pm_t2m:     .res 3
pm_ma:      .res 2                      ; mul operands (u16)
pm_mb:      .res 2
pm_ax:      .res 2                      ; cross operands (s16)
pm_ay:      .res 2
pm_lx:      .res 2                      ; line origin / delta (s16)
pm_ly:      .res 2
pm_ldx:     .res 2
pm_ldy:     .res 2
pm_sfirst:  .res 1                      ; first corner/endpoint side bool

PM_RADIUS   = 16
PM_STEP     = 3                         ; 24 world units, prescaled
PM_XBIAS    = 1936                      ; -RAWX_MIN (walk clamp rect)

; ============================================================================
; pmove_try — C=1: move allowed, pm_vz updated, walkovers fired.
;   in: zp_br_pxraw/pyraw = CANDIDATE (raw s16), pm_oldx/y = committed
;       position, pm_vz = current vz. Pages BANK_WALK and leaves it.
; ============================================================================
.scope
::pmove_try:
   PAGE BANK_WALK
; box bounds: pm_bx0/by0 = raw-16, pm_bx1/by1 = raw+16 (X = 0 x / 2 y;
; the raws are consecutive zp $90-$93)
   LDX #2
pt_bounds:
   LDA zp_br_pxraw_l,X
   SEC
   SBC #PM_RADIUS
   STA pm_bx0,X
   LDA zp_br_pxraw_h,X
   SBC #0
   STA pm_bx0+1,X
   LDA zp_br_pxraw_l,X
   CLC
   ADC #PM_RADIUS
   STA pm_bx1,X
   LDA zp_br_pxraw_h,X
   ADC #0
   STA pm_bx1+1,X
   DEX
   DEX
   BPL pt_bounds
; columns of bx0 and bx1: c = clamp((bx + 1936) >> 7, 0..35)
   LDA pm_bx1
   LDX pm_bx1+1
   JSR pm_column
   STA pm_c1
   LDA pm_bx0
   LDX pm_bx0+1
   JSR pm_column
   JSR pm_column_scan                   ; test column c (in A)
   BCS pt_blocked
   LDA pm_c1
   CMP ::pm_c0_save
   BEQ pt_cols_done
   JSR pm_column_scan
   BCS pt_blocked
pt_cols_done:
; destination sector rules
   JSR pm_find_ss                       ; X = subsector id
   LDA SS_INFO_BASE,X
   CMP #$FF
   BEQ pt_static
   TAY                                  ; mover info
   AND #$3F
   STA pm_cnt                           ; mover idx (scratch reuse)
   ASL A
   CLC
   ADC pm_cnt                           ; idx*3
   TAY
   LDA ANIM_WS+1,Y                      ; live pos_hi (prescaled s8)
   LDY pm_cnt
   PHA
   LDA SS_INFO_BASE,X
   BMI pt_door
   PLA                                  ; lift: dvz = pos + eye offset
   CLC
   ADC #5
   STA pm_dvz
   JMP pt_step
pt_door:
   PLA                                  ; door: pos >= MV_MINPASS[idx] ?
   SEC
   SBC MV_MINPASS,Y                     ; |heights| small: SBC sign exact
   BMI pt_blocked                       ; not open enough -> blocked
   LDA SS_VZ_BASE,X
   STA pm_dvz
   JMP pt_step
pt_static:
   LDA SS_VZ_BASE,X
   STA pm_dvz
pt_step:
; step rule: dvz - vz > 3 -> blocked (drops always allowed)
   LDA pm_dvz
   SEC
   SBC pm_vz
   BMI pt_commit                        ; downward: fine
   CMP #PM_STEP+1
   BCS pt_blocked
pt_commit:
   LDA pm_dvz
   STA pm_vz
   SEC
   RTS
pt_blocked:
   CLC
   RTS

; pm_column: A/X = raw s16 -> A = column 0..35 (clamped)
::pm_column:
   CLC
   ADC #<PM_XBIAS
   STA pm_t1m
   TXA
   ADC #>PM_XBIAS
   BMI pm_col_lo                        ; below the rect: clamp 0
   STA pm_t1m+1
   LDA pm_t1m
   ASL A                                ; C = bit 7 of lo
   LDA pm_t1m+1
   ROL A                                ; A = (hi<<1)|(lo>>7)
   CMP #36
   BCS pm_col_hi
   RTS
pm_col_lo:
   LDA #0
   RTS
pm_col_hi:
   LDA #35
   RTS
::pm_c0_save: .res 1
.endscope

; ============================================================================
; pm_column_scan — test every collision seg in column A against the box.
; C=1 blocked. Preserves pm_* box state; stashes the column in pm_c0_save.
; ============================================================================
.scope
::pm_column_scan:
   STA ::pm_c0_save
   STA pm_col
   ASL A
   CLC
   ADC pm_col                           ; c*3
   TAY
   LDA COLIDX_BASE,Y
   STA zp_pm_p
   LDA COLIDX_BASE+1,Y
   STA zp_pm_p+1
   LDA COLIDX_BASE+2,Y
   STA pm_n
   BEQ pcs_clear
pcs_loop:
   LDY pm_n
   DEY
   LDA (zp_pm_p),Y                      ; seg index
; seg record addr = COLSEG_BASE + idx*8 -> zp_anim_p (frame-scoped reuse)
   STA zp_anim_p
   LDA #0
   STA zp_anim_p+1
   ASL zp_anim_p
   ROL zp_anim_p+1
   ASL zp_anim_p
   ROL zp_anim_p+1
   ASL zp_anim_p
   ROL zp_anim_p+1
   LDA zp_anim_p
   CLC
   ADC #<COLSEG_BASE
   STA zp_anim_p
   LDA zp_anim_p+1
   ADC #>COLSEG_BASE
   STA zp_anim_p+1
   JSR pm_box_vs_seg
   BCS pcs_rts                          ; blocked
   DEC pm_n
   BNE pcs_loop
pcs_clear:
   CLC
pcs_rts:
   RTS
pm_col: .res 1
pm_n:   .res 1
.endscope

; ============================================================================
; pm_box_vs_seg — the P_BoxOnLineSide core. Seg record at (zp_anim_p):
; +0 x1 +2 y1 +4 dx +6 dy (s16 LE). C=1 = box blocked by this seg.
; Mirrors colmap._box_hits_seg exactly (strict inequalities).
; ============================================================================
.scope
::pm_box_vs_seg:
; load the record into pm_lx..pm_ldy (8 consecutive bytes)
   LDY #7
bvs_ld:
   LDA (zp_anim_p),Y
   STA pm_lx,Y
   DEY
   BPL bvs_ld
; near stubs (branch-range islands; the diagonal block pushes the real
; verdicts out of reach)
   JMP bvs_start
bvs_missx0:
   JMP bvs_miss
bvs_start:
; line bbox: lx0/lx1 = x1, x1+dx ordered by dx sign (into t1m/t2m scratch)
   LDA pm_lx
   CLC
   ADC pm_ldx
   STA pm_t1m                           ; x1+dx
   LDA pm_lx+1
   ADC pm_ldx+1
   STA pm_t1m+1
   LDA pm_ldx+1
   BMI bvs_xneg
; lx0 = x1, lx1 = x1+dx
;   reject if bx1 <= lx0: need bx1 - x1 > 0
   LDA pm_bx1
   SEC
   SBC pm_lx
   TAX
   LDA pm_bx1+1
   SBC pm_lx+1
   BMI bvs_missx0
   BNE bvs_xp2
   TXA
   BEQ bvs_missx0
bvs_xp2:
;   reject if bx0 >= lx1: need x1+dx - bx0 > 0
   LDA pm_t1m
   SEC
   SBC pm_bx0
   TAX
   LDA pm_t1m+1
   SBC pm_bx0+1
   BMI bvs_missx
   BNE bvs_xok
   TXA
   BEQ bvs_missx
   JMP bvs_xok
bvs_missx:
   JMP bvs_miss
bvs_xneg:
; lx0 = x1+dx, lx1 = x1
   LDA pm_bx1
   SEC
   SBC pm_t1m
   TAX
   LDA pm_bx1+1
   SBC pm_t1m+1
   BMI bvs_missx
   BNE bvs_xn2
   TXA
   BEQ bvs_missx
bvs_xn2:
   LDA pm_lx
   SEC
   SBC pm_bx0
   TAX
   LDA pm_lx+1
   SBC pm_bx0+1
   BMI bvs_missx
   BNE bvs_xok
   TXA
   BEQ bvs_missx
bvs_xok:
; y axis, same shape
   LDA pm_ly
   CLC
   ADC pm_ldy
   STA pm_t1m
   LDA pm_ly+1
   ADC pm_ldy+1
   STA pm_t1m+1
   LDA pm_ldy+1
   BMI bvs_yneg
   LDA pm_by1
   SEC
   SBC pm_ly
   TAX
   LDA pm_by1+1
   SBC pm_ly+1
   BMI bvs_missj
   BNE bvs_y2
   TXA
   BEQ bvs_missj
bvs_y2:
   LDA pm_t1m
   SEC
   SBC pm_by0
   TAX
   LDA pm_t1m+1
   SBC pm_by0+1
   BMI bvs_missj
   BNE bvs_yok
   TXA
   BEQ bvs_missj
   JMP bvs_yok
bvs_missj:
   JMP bvs_miss
bvs_hitj:
   JMP bvs_hit
bvs_yneg:
   LDA pm_by1
   SEC
   SBC pm_t1m
   TAX
   LDA pm_by1+1
   SBC pm_t1m+1
   BMI bvs_missj
   BNE bvs_yn2
   TXA
   BEQ bvs_missj
bvs_yn2:
   LDA pm_ly
   SEC
   SBC pm_by0
   TAX
   LDA pm_ly+1
   SBC pm_by0+1
   BMI bvs_missj
   BNE bvs_yok
   TXA
   BEQ bvs_missj
bvs_yok:
; bbox overlaps. Axis-aligned line: that IS the test.
   LDA pm_ldx
   ORA pm_ldx+1
   BEQ bvs_hitj
   LDA pm_ldy
   ORA pm_ldy+1
   BEQ bvs_hitj
; diagonal: quadrant corner pair must straddle the line.
; same-sign slope (dx>0)==(dy>0): corners (bx0,by1) and (bx1,by0);
; else (bx0,by0) and (bx1,by1).
   LDA pm_ldx+1
   EOR pm_ldy+1
   BMI bvs_opp
   LDA pm_bx0
   STA pm_ax
   LDA pm_bx0+1
   STA pm_ax+1
   LDA pm_by1
   STA pm_ay
   LDA pm_by1+1
   STA pm_ay+1
   JSR pm_corner_side
   STA pm_sfirst
   LDA pm_bx1
   STA pm_ax
   LDA pm_bx1+1
   STA pm_ax+1
   LDA pm_by0
   STA pm_ay
   LDA pm_by0+1
   STA pm_ay+1
   JMP bvs_c2
bvs_opp:
   LDA pm_bx0
   STA pm_ax
   LDA pm_bx0+1
   STA pm_ax+1
   LDA pm_by0
   STA pm_ay
   LDA pm_by0+1
   STA pm_ay+1
   JSR pm_corner_side
   STA pm_sfirst
   LDA pm_bx1
   STA pm_ax
   LDA pm_bx1+1
   STA pm_ax+1
   LDA pm_by1
   STA pm_ay
   LDA pm_by1+1
   STA pm_ay+1
bvs_c2:
   JSR pm_corner_side
   EOR pm_sfirst
   BNE bvs_hit                          ; sides differ -> straddles
bvs_miss:
   CLC
   RTS
bvs_hit:
   SEC
   RTS
.endscope

; ============================================================================
; pm_corner_side — bool((ax - lx)*ldy > (ay - ly)*ldx) for the corner in
; pm_ax/pm_ay vs the line in pm_lx/ly/ldx/ldy. Returns A = 0/1.
; Exact s32 compare via sign-magnitude 16x16->24 multiplies (operand
; magnitudes are bounded well below 2^13 x 2^10).
; ============================================================================
.scope
::pm_corner_side:
   LDA pm_ax
   SEC
   SBC pm_lx
   STA pm_ma
   LDA pm_ax+1
   SBC pm_lx+1
   STA pm_ma+1
   LDA pm_ldy
   STA pm_mb
   LDA pm_ldy+1
   STA pm_mb+1
   JSR pm_smul                          ; t = (ax-lx)*ldy
   LDX #3
pcs_c1:
   LDA pm_t1s_w,X
   STA pm_t1s,X
   DEX
   BPL pcs_c1
   LDA pm_ay
   SEC
   SBC pm_ly
   STA pm_ma
   LDA pm_ay+1
   SBC pm_ly+1
   STA pm_ma+1
   LDA pm_ldx
   STA pm_mb
   LDA pm_ldx+1
   STA pm_mb+1
   JSR pm_smul                          ; t2 = (ay-ly)*ldx
   LDX #3
pcs_c2:
   LDA pm_t1s_w,X
   STA pm_t2s,X
   DEX
   BPL pcs_c2
   JMP pm_cmp_t1_gt_t2
.endscope

; ============================================================================
; pm_smul — signed multiply pm_ma * pm_mb (s16 x s16). Result as
; sign-magnitude: pm_t1s_w = $00 pos / $80 neg (canonical: mag 0 -> pos),
; pm_t1m_w..+2 = |product| (u24; callers' operands bound it).
; Plain shift-add (movement is frame-rare; no table dependencies).
; ============================================================================
.scope
::pm_smul:
   LDA #0
   STA pm_t1s_w
   LDA pm_ma+1
   BPL sm_apos
   LDA #$80
   STA pm_t1s_w
   SEC                                  ; negate ma
   LDA #0
   SBC pm_ma
   STA pm_ma
   LDA #0
   SBC pm_ma+1
   STA pm_ma+1
sm_apos:
   LDA pm_mb+1
   BPL sm_bpos
   LDA pm_t1s_w
   EOR #$80
   STA pm_t1s_w
   SEC
   LDA #0
   SBC pm_mb
   STA pm_mb
   LDA #0
   SBC pm_mb+1
   STA pm_mb+1
sm_bpos:
; u16 x u16 -> u24 (high byte discarded; callers guarantee < 2^24):
; classic shift-add: acc = 0; 16 times: acc >>= will overflow — use
; add-and-shift with the multiplier in pm_ma, addend pm_mb.
   LDA #0
   STA pm_t1m_w
   STA pm_t1m_w+1
   STA pm_t1m_w+2
   LDX #16
sm_loop:
   LSR pm_ma+1
   ROR pm_ma
   BCC sm_noadd
   CLC
   LDA pm_t1m_w
   ADC pm_mb
   STA pm_t1m_w
   LDA pm_t1m_w+1
   ADC pm_mb+1
   STA pm_t1m_w+1
   BCC sm_noadd
   INC pm_t1m_w+2
sm_noadd:
   ASL pm_mb
   ROL pm_mb+1
   ROL pm_t1m_w+2                       ; mb overflow migrates into byte 2
   DEX
   BNE sm_loop
; mag zero -> canonical positive sign
   LDA pm_t1m_w
   ORA pm_t1m_w+1
   ORA pm_t1m_w+2
   BNE sm_done
   STA pm_t1s_w
sm_done:
   RTS
::pm_t1s_w: .res 1
::pm_t1m_w: .res 3
.endscope

; ============================================================================
; pm_cmp_t1_gt_t2 — A = 1 iff (t1 as s32) > (t2 as s32); sign-magnitude
; inputs in pm_t1s/pm_t1m and pm_t2s/pm_t2m (canonical signs).
; ============================================================================
.scope
::pm_cmp_t1_gt_t2:
   LDA pm_t1s
   CMP pm_t2s
   BEQ cmp_same
   ; different signs (canonical: not both zero-mag): t1 > t2 iff t1 pos
   LDA pm_t1s
   BMI cmp_no
cmp_yes:
   LDA #1
   RTS
cmp_same:
   ; same sign: compare magnitudes hi->lo
   LDA pm_t1m+2
   CMP pm_t2m+2
   BNE cmp_m
   LDA pm_t1m+1
   CMP pm_t2m+1
   BNE cmp_m
   LDA pm_t1m
   CMP pm_t2m
   BNE cmp_m
cmp_no:
   LDA #0                               ; equal -> not greater
   RTS
cmp_m:
   ; C=1: mag1 > mag2. positive: greater iff C; negative: iff not C
   LDA pm_t1s
   BMI cmp_neg
   BCS cmp_yes
   BCC cmp_no
cmp_neg:
   BCC cmp_yes
   BCS cmp_no
.endscope

SEG_HIGH                                ; descent: CODE (the dispatch macro
                                        ; expands the shared cross core)
; ============================================================================
; pm_find_ss — BSP point descent for the candidate in zp_br_pxraw/pyraw.
; Returns X = subsector id. BANK_WALK paged (node SoA + DIR tables).
; Reuses the traversal's NODE_SETUP_DISPATCH (ties -> side1, the same
; verdicts as doom_wireframe.point_on_side / colmap.find_ss).
; ============================================================================
.scope
::pm_find_ss:
   LDA #LAY_ROOT
   STA zp_node_ch_l
fs_loop:
   NODE_SETUP_DISPATCH fs_s0, fs_s1
fs_s0:
   LDX zp_node_ch_l
   LDA NODE_TYPE,X
   ASL A                                ; C = NF_RLEAF
   LDA NODE_CRLO,X
   STA zp_node_ch_l
   BCS fs_leaf
   JMP fs_loop
fs_s1:
   LDX zp_node_ch_l
   LDA NODE_TYPE,X
   AND #$40                             ; NF_LLEAF
   PHP
   LDA NODE_CLLO,X
   STA zp_node_ch_l
   PLP
   BNE fs_leaf
   JMP fs_loop
fs_leaf:
   LDX zp_node_ch_l
   RTS
.endscope

SEG_PMOVE
; --- (zp_pm_p) += 9: the 9-byte line-record stride ---
.scope
::pm_p_add9:
   LDA zp_pm_p
   CLC
   ADC #9
   STA zp_pm_p
   BCC :+
   INC zp_pm_p+1
:  RTS
.endscope

; ============================================================================
; pm_move_crosses_line — C=1 iff the segment pm_oldx/y -> pm_exx/y strictly
; crosses the 9-byte line record at (zp_pm_p) (double straddle, exact —
; mirrors colmap._seg_cross).
; A-line = the move (pm_oldx/y -> raws); B-line = the record.
; ============================================================================
.scope
::pm_move_crosses_line:
; load record geometry (8 consecutive bytes)
   LDY #7
mc_ld:
   LDA (zp_pm_p),Y
   STA pm_lx,Y
   DEY
   BPL mc_ld
; side(old) vs record line
   LDA pm_oldx
   STA pm_ax
   LDA pm_oldx+1
   STA pm_ax+1
   LDA pm_oldy
   STA pm_ay
   LDA pm_oldy+1
   STA pm_ay+1
   JSR pm_corner_side
   STA pm_sfirst
; side(endpoint) vs record line
   LDA pm_exx
   STA pm_ax
   LDA pm_exx+1
   STA pm_ax+1
   LDA pm_exy
   STA pm_ay
   LDA pm_exy+1
   STA pm_ay+1
   JSR pm_corner_side
   EOR pm_sfirst
   BNE mc_go                            ; sides differ: keep testing
   JMP mc_no                            ; same side: no crossing
mc_go:
; endpoints of the record must straddle the MOVE line: swap roles.
; Stash the record's origin+delta in pm_r* (pm_t* is pm_corner_side
; scratch — the 2026-08-14 draft's stack dance died on exactly that),
; then restage pm_l* as the move line.
   LDX #7
mc_stash:
   LDA pm_lx,X
   STA pm_rx,X
   DEX
   BPL mc_stash
; the move as the "line": origin old, delta cand-old
   LDA pm_oldx
   STA pm_lx
   LDA pm_oldx+1
   STA pm_lx+1
   LDA pm_oldy
   STA pm_ly
   LDA pm_oldy+1
   STA pm_ly+1
   LDA pm_exx
   SEC
   SBC pm_oldx
   STA pm_ldx
   LDA pm_exx+1
   SBC pm_oldx+1
   STA pm_ldx+1
   LDA pm_exy
   SEC
   SBC pm_oldy
   STA pm_ldy
   LDA pm_exy+1
   SBC pm_oldy+1
   STA pm_ldy+1
; record endpoint 1
   LDA pm_rx
   STA pm_ax
   LDA pm_rx+1
   STA pm_ax+1
   LDA pm_ry
   STA pm_ay
   LDA pm_ry+1
   STA pm_ay+1
   JSR pm_corner_side
   STA pm_sfirst
; record endpoint 2 = endpoint 1 + record delta
   LDA pm_rx
   CLC
   ADC pm_rdx
   STA pm_ax
   LDA pm_rx+1
   ADC pm_rdx+1
   STA pm_ax+1
   LDA pm_ry
   CLC
   ADC pm_rdy
   STA pm_ay
   LDA pm_ry+1
   ADC pm_rdy+1
   STA pm_ay+1
   JSR pm_corner_side
   EOR pm_sfirst
   BEQ mc_no
   SEC
   RTS
mc_no:
   CLC
   RTS
::pm_rx:  .res 2
::pm_ry:  .res 2
::pm_rdx: .res 2
::pm_rdy: .res 2
.endscope

; ============================================================================
; pmove_use — SPACE: trace pm_ux/uy from the current position
; (zp_br_pxraw/pyraw) against the use lines. Door actions are applied
; here (ANIM_WS is main RAM); A returns the action ($FF = none,
; $FE = exit — the driver respawns). Pages BANK_WALK.
; ============================================================================
.scope
::pmove_use:
   PAGE BANK_WALK
; move origin = current position; endpoint = position + trace delta.
; pm_move_crosses_line reads origin from pm_oldx/y and endpoint from
; pm_exx/y.
   LDA zp_br_pxraw_l
   STA pm_oldx
   CLC
   ADC pm_ux
   STA pm_exx
   LDA zp_br_pxraw_h
   STA pm_oldx+1
   ADC pm_ux+1
   STA pm_exx+1
   LDA zp_br_pyraw_l
   STA pm_oldy
   CLC
   ADC pm_uy
   STA pm_exy
   LDA zp_br_pyraw_h
   STA pm_oldy+1
   ADC pm_uy+1
   STA pm_exy+1
   LDA USETAB_BASE                      ; n_use
   STA pm_i
   BEQ pu_none
   LDA #<(USETAB_BASE+1)
   STA zp_pm_p
   LDA #>(USETAB_BASE+1)
   STA zp_pm_p+1
pu_loop:
   JSR pm_move_crosses_line
   BCS pu_hit
   JSR pm_p_add9
   DEC pm_i
   BNE pu_loop
pu_none:
   LDA #$FF
   RTS
pu_hit:
   LDY #8
   LDA (zp_pm_p),Y                      ; action
   CMP #$FE
   BCS pu_exit                          ; exit switch: driver's problem
; DR door toggle: moving (bit6) -> reverse; waiting -> start moving
; away from the held end ($00->$40 opening, $80->$C0 closing)
   STA pm_i                             ; idx (list walk is over)
   ASL A
   ADC pm_i                             ; idx*3 (ASL of idx<=5 left C=0)
   TAY
   LDA ANIM_WS+2,Y
   AND #$40
   BNE pu_moving
   LDA ANIM_WS+2,Y
   AND #$C0                             ; drop residual timer bits
   EOR #$40
   STA ANIM_WS+2,Y
   LDA #0                               ; action consumed
   RTS
pu_moving:
   LDA ANIM_WS+2,Y
   EOR #$80
   STA ANIM_WS+2,Y
   LDA #0
pu_exit:
   RTS
pm_i: .res 1
.endscope
