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
::pm_blkang: .res 1                     ; wall angle of the last box hit
                                        ;  ($FF = blocked by sector rules)
::pm_sdx:   .res 2                      ; slide vector out (s16 8.8)
::pm_sdy:   .res 2

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
   LDA #$FF
   STA pm_blkang                        ; no wall hit yet
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
::pmove_zonly:                          ; entry: z path only (mv_reval)
   PAGE BANK_WALK
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
; seg record addr = COLSEG_BASE + idx*9 -> zp_anim_p (frame-scoped
; reuse; stride 9 since the slide arc: +1 wall-angle byte)
   STA pm_idx
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
   ADC pm_idx                           ; *8 + 1 = *9
   STA zp_anim_p
   BCC :+
   INC zp_anim_p+1
:  LDA zp_anim_p
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
pm_idx: .res 1
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
; bbox phase, one loop per axis (X = 0 x / 2 y): line extent e0/e1 =
; origin, origin+delta ordered by delta sign; strict-overlap reject
; mirrors colmap._box_hits_seg. pm_lx+X = origin pair, pm_ldx+X = delta.
   LDX #0
bvs_axis:
   LDA pm_lx,X
   CLC
   ADC pm_ldx,X
   STA pm_t1m                           ; origin+delta lo
   LDA pm_lx+1,X
   ADC pm_ldx+1,X
   STA pm_t1m+1
   LDA pm_ldx+1,X
   BMI bvs_neg
; e0 = origin, e1 = origin+delta
;   need box_hi - e0 > 0
   LDA pm_bx1,X
   SEC
   SBC pm_lx,X
   TAY
   LDA pm_bx1+1,X
   SBC pm_lx+1,X
   BMI bvs_missj2
   BNE bvs_p2
   TYA
   BEQ bvs_missj2
bvs_p2:
;   need e1 - box_lo > 0
   LDA pm_t1m
   SEC
   SBC pm_bx0,X
   TAY
   LDA pm_t1m+1
   SBC pm_bx0+1,X
   BMI bvs_missj2
   BNE bvs_next
   TYA
   BEQ bvs_missj2
   JMP bvs_next
bvs_missj2:
   JMP bvs_miss
bvs_neg:
; e0 = origin+delta, e1 = origin
   LDA pm_bx1,X
   SEC
   SBC pm_t1m
   TAY
   LDA pm_bx1+1,X
   SBC pm_t1m+1
   BMI bvs_missj2
   BNE bvs_n2
   TYA
   BEQ bvs_missj2
bvs_n2:
   LDA pm_lx,X
   SEC
   SBC pm_bx0,X
   TAY
   LDA pm_lx+1,X
   SBC pm_bx0+1,X
   BMI bvs_missj2
   BNE bvs_next
   TYA
   BEQ bvs_missj2
bvs_next:
   INX
   INX
   CPX #4
   BCC bvs_axis
; bbox overlaps. Axis-aligned line: that IS the test.
   LDA pm_ldx
   ORA pm_ldx+1
   BEQ bvs_hitj
   LDA pm_ldy
   ORA pm_ldy+1
   BEQ bvs_hitj
   BNE bvs_diag
bvs_hitj:
   JMP bvs_hit
bvs_diag:
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
   LDY #8
   LDA (zp_anim_p),Y                    ; baked wall angle (64-space) —
   STA pm_blkang                        ; P_HitSlideLine's line angle
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
; u16 x u16 -> u24 (callers bound the product below 2^24): add-and-shift
; with a 24-bit shifting addend (pm_mb:pm_mb2). The first cut ROL'd the
; addend's overflow into the ACCUMULATOR's top byte instead of keeping a
; third addend byte — every diagonal straddle verdict was garbage (the
; 2026-08-14 shallow-wall-clip bug; the lockstep fuzz caught it).
   LDA #0
   STA pm_t1m_w
   STA pm_t1m_w+1
   STA pm_t1m_w+2
   STA pm_mb2
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
   LDA pm_t1m_w+2
   ADC pm_mb2
   STA pm_t1m_w+2
sm_noadd:
   ASL pm_mb
   ROL pm_mb+1
   ROL pm_mb2
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
pm_mb2:     .res 1
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
   LDA NODE_CLLO,X
   STA zp_node_ch_l
   LDA NODE_TYPE,X                      ; X intact: flags after the store
   AND #$40                             ; NF_LLEAF
   BNE fs_leaf
   JMP fs_loop
fs_leaf:
   LDX zp_node_ch_l
   RTS
.endscope

SEG_HIGH
; ============================================================================
; pmove_apply / pmove_unapply — add/subtract the slide vector (pm_sdx/y,
; s16 8.8) to the DRIVER's 24-bit position (DV_PXF.. — fixed abi
; addresses). Engine-side so the driver zone only pays the JSRs.
; ============================================================================
.scope
::pmove_unapply:                        ; negate the vector, fall into apply
   LDX #2
pun_neg:
   SEC
   LDA #0
   SBC pm_sdx,X
   STA pm_sdx,X
   LDA #0
   SBC pm_sdx+1,X
   STA pm_sdx+1,X
   DEX
   DEX
   BPL pun_neg
::pmove_apply:
   LDX #0                               ; DV offset (stride 3)
   LDY #0                               ; sd offset (stride 2)
pa_axis:
   CLC
   LDA DV_PXF,X
   ADC pm_sdx,Y
   STA DV_PXF,X
   LDA DV_PXF+1,X
   ADC pm_sdx+1,Y
   STA DV_PXF+1,X
   LDA pm_sdx+1,Y
   BPL pa_pos
   LDA DV_PXF+2,X
   ADC #$FF
   JMP pa_st
pa_pos:
   LDA DV_PXF+2,X
   ADC #0
pa_st:
   STA DV_PXF+2,X
   INY
   INY
   INX
   INX
   INX
   CPX #6
   BCC pa_axis
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
   LDX #3
mc_c0:
   LDA pm_oldx,X
   STA pm_ax,X
   DEX
   BPL mc_c0
   JSR pm_corner_side
   STA pm_sfirst
; side(endpoint) vs record line
   LDX #3
mc_c1:
   LDA pm_exx,X
   STA pm_ax,X
   DEX
   BPL mc_c1
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
   LDX #2
mc_ml:
   LDA pm_oldx,X
   STA pm_lx,X
   LDA pm_oldx+1,X
   STA pm_lx+1,X
   LDA pm_exx,X
   SEC
   SBC pm_oldx,X
   STA pm_ldx,X
   LDA pm_exx+1,X
   SBC pm_oldx+1,X
   STA pm_ldx+1,X
   DEX
   DEX
   BPL mc_ml
; record endpoint 1
   LDX #3
mc_r1:
   LDA pm_rx,X
   STA pm_ax,X
   DEX
   BPL mc_r1
   JSR pm_corner_side
   STA pm_sfirst
; record endpoint 2 = endpoint 1 + record delta
   LDX #2
mc_r2:
   LDA pm_rx,X
   CLC
   ADC pm_rdx,X
   STA pm_ax,X
   LDA pm_rx+1,X
   ADC pm_rdx+1,X
   STA pm_ax+1,X
   DEX
   DEX
   BPL mc_r2
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
   PAGE BANK_SEG                        ; USETAB lives in BANK A
; move origin = current position; endpoint = position + trace delta.
; pm_move_crosses_line reads origin from pm_oldx/y and endpoint from
; pm_exx/y.
   LDX #2
pu_st:
   LDA zp_br_pxraw_l,X
   STA pm_oldx,X
   CLC
   ADC pm_ux,X
   STA pm_exx,X
   LDA zp_br_pxraw_h,X
   STA pm_oldx+1,X
   ADC pm_ux+1,X
   STA pm_exx+1,X
   DEX
   DEX
   BPL pu_st
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

; ============================================================================
; pm_use_prefilter — C=1 iff the use-trace bbox (pm_oldx/y..pm_exx/y)
; overlaps the 9-byte line record's bbox at (zp_pm_p). Cheap s16
; compares only; conservative (never rejects a true crossing).
; ============================================================================
; ============================================================================
; pmove_slide — P_HitSlideLine (DOOM p_map.c) on the 64-angle tables.
;   in : A = move direction (0..63); pm_blkang = the blocking wall's
;        baked angle ($FF = sector-rule block: no slide, C=0)
;   out: C=1, pm_sdx/pm_sdy = slide delta (s16 8.8) =
;        step_tab[wall] * cos(delta), SIGNED cosine — delta > 90 slides
;        backward along the line exactly like DOOM's negative newlen.
;        C=0: no usable slide (sector block or cos == 0).
; Pages BANK_SEG (step + sincos tables live in bank A). FLAT NOTE: the
; $BA00/$BC00 literals are the BANKED homes; the flat/tube build links
; this code but nothing calls it yet (tube driver movement parity is a
; recorded follow-up — give the parasite its own table homes then).
; ============================================================================
.scope
::pmove_slide:
   LDY pm_blkang
   CPY #$FF
   BNE ps_go
   JMP ps_none
ps_go:
   PAGE_X BANK_SEG                      ; X-clobber page: A (move dir) rides
   SEC
   SBC pm_blkang                        ; delta = move - wall (mod 64)
   AND #63
   STA pm_cnt                           ; delta in table-index units
; cos(delta*4 BAM) from the driver sincos table (64 x 8 @ $BA00):
; +3 cmag (count-native 0..32), +4 cneg, +5 cone
   ASL A
   ASL A
   ASL A                                ; delta*8 -> table offset (fits u8:
   TAY                                  ; delta<32 here? no: delta 0..63 *8
                                        ; overflows — use the hi trick below
   LDA pm_cnt
   AND #$20                             ; upper half of the table?
   BEQ ps_lo_half
   LDA pm_cnt
   AND #$1F
   ASL A
   ASL A
   ASL A
   TAY
   LDA $BB00+3,Y                        ; second table page
   STA pm_ma
   LDA $BB00+4,Y
   STA pm_mb
   LDA $BB00+5,Y
   JMP ps_have
ps_lo_half:
   LDA $BA00+3,Y                        ; cmag
   STA pm_ma
   LDA $BA00+4,Y                        ; cneg
   STA pm_mb
   LDA $BA00+5,Y                        ; cone
ps_have:
; A = cone: |cos| == 1 -> full step_tab entry; else scale by cmag/32
   STA pm_cnt
   LDA pm_ma
   BNE ps_scaled
   LDA pm_cnt
   BNE ps_scaled                        ; cone set (mag encoded as 1.0)
   CLC                                  ; cos == 0: no slide component
   RTS
ps_scaled:
; fetch step_tab[wall] (4 bytes @ $BC00 + wall*4)
   LDA pm_blkang
   ASL A
   ASL A
   TAY
   LDA $BC00,Y
   STA pm_t1m
   LDA $BC00+1,Y
   STA pm_t1m+1
   LDA $BC00+2,Y
   STA pm_t2m
   LDA $BC00+3,Y
   STA pm_t2m+1
   LDA pm_cnt                           ; cone: skip the scale
   BNE ps_copy
   LDA pm_t1m
   LDX pm_t1m+1
   JSR ps_scale16                       ; (A:X) * cmag / 32 -> A:X
   STA pm_sdx
   STX pm_sdx+1
   LDA pm_t2m
   LDX pm_t2m+1
   JSR ps_scale16
   STA pm_sdy
   STX pm_sdy+1
   JMP ps_sign
ps_copy:
   LDA pm_t1m
   STA pm_sdx
   LDA pm_t1m+1
   STA pm_sdx+1
   LDA pm_t2m
   STA pm_sdy
   LDA pm_t2m+1
   STA pm_sdy+1
ps_sign:
   LDA pm_mb                            ; cneg: negate both components
   BEQ ps_pos
   SEC
   LDA #0
   SBC pm_sdx
   STA pm_sdx
   LDA #0
   SBC pm_sdx+1
   STA pm_sdx+1
   SEC
   LDA #0
   SBC pm_sdy
   STA pm_sdy
   LDA #0
   SBC pm_sdy+1
   STA pm_sdy+1
ps_pos:
   SEC
   RTS
ps_none:
   CLC
   RTS
; (A:X lo:hi s16) * cmag(pm_ma, 1..31) >> 5, signed via sign-magnitude
ps_scale16:
   STA pm_ax
   STX pm_ax+1
   LDA #0
   STA pm_ay                            ; sign flag
   LDA pm_ax+1
   BPL ps_s_pos
   LDA #1
   STA pm_ay
   SEC
   LDA #0
   SBC pm_ax
   STA pm_ax
   LDA #0
   SBC pm_ax+1
   STA pm_ax+1
ps_s_pos:
; u16 * u5 -> u21, keep >>5: shift-add over the 5 mag bits
   LDA #0
   STA pm_t1s
   STA pm_lx
   STA pm_lx+1
   STA pm_ly                            ; acc 24-bit: lx lo/hi, ly top
   LDA pm_ma
   STA pm_sfirst                        ; mag bits ride here
   LDX #5
ps_s_loop:
   LSR pm_sfirst
   BCC ps_s_noadd
   CLC
   LDA pm_lx
   ADC pm_ax
   STA pm_lx
   LDA pm_lx+1
   ADC pm_ax+1
   STA pm_lx+1
   LDA pm_ly
   ADC pm_t1s                           ; ax's third byte (the pm_smul
   STA pm_ly                            ; lesson: shifting addends grow)
ps_s_noadd:
   ASL pm_ax
   ROL pm_ax+1
   ROL pm_t1s                           ; ax third byte
   DEX
   BNE ps_s_loop
; >>5: take bits [20:5] of the 24-bit acc
   LDX #5
ps_s_shift:
   LSR pm_ly
   ROR pm_lx+1
   ROR pm_lx
   DEX
   BNE ps_s_shift
   LDA pm_ay
   BEQ ps_s_done
   SEC
   LDA #0
   SBC pm_lx
   STA pm_lx
   LDA #0
   SBC pm_lx+1
   STA pm_lx+1
ps_s_done:
   LDA pm_lx
   LDX pm_lx+1
   RTS
.endscope

; ============================================================================
; pmove_try_slide — the driver's one-call slide retry: A = move dir.
; Computes the P_HitSlideLine vector from the last block, applies it to
; the position, re-derives NOTHING (the DRIVER re-derives + re-tries).
; C=0: no slide available (caller falls to the DOOM stairstep).
; ============================================================================
.scope
::pmove_try_slide:
   JSR pmove_slide
   BCC ts_no
   JSR pmove_apply
   SEC
   RTS
ts_no:
   CLC
   RTS
.endscope
