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
;   MV_SS_ID     mover-subsector ids, padded to 8 with $FF
;   MV_SS_INFO   per entry: mover idx, b7 = ceil (the classic SS_INFO byte)
;   MV_MINPASS   per-mover min passable door pos (fh+56 prescaled)
;   USETAB_BASE  u8 n_use, n_use x 9 (x1,y1,dx,dy s16 + action),
;                u8 n_walk, n_walk x 9   (action: mover idx, $FE = exit)
;
; Driver ABI (engine_syms): pmove_try / pmove_use / pm_oldx / pm_vz /
; pm_ux. Movement runs OUTSIDE render_frame, so the render's frame-scoped
; zp (zp_br_*, zp_node_ch_l, zp_anim_p) is reusable scratch here.
; ============================================================================

SEG_PMOVE

; --- driver-visible state: scratch-placed equates too (engine_syms
; resolves equ symbols; oldx..oldy and ux..uy stay contiguous runs) ---
::pm_oldx  = PM_SCRATCH+$3B             ; use-trace origin, raw s16
::pm_oldy  = PM_SCRATCH+$3D
::pm_vz    = PM_SCRATCH+$3F             ; current vz, prescaled s8 (in/out)
::pm_ux    = PM_SCRATCH+$40             ; use-trace delta, raw s16
::pm_uy    = PM_SCRATCH+$42
pm_exx     = PM_SCRATCH+$24             ; crossing-test endpoint (staged
pm_exy     = PM_SCRATCH+$26             ;  by pmove_use; oldx..exy runs)
::pm_blkang = PM_SCRATCH+$44            ; wall angle of the last box hit
                                        ;  ($FF = blocked by sector rules)
::pm_sdx   = PM_SCRATCH+$45             ; slide vector out (s16 8.8; sdx/
::pm_sdy   = PM_SCRATCH+$47             ;  sdy = a 4B run for the negate)

; --- internal scratch: PLACED EQUATES, not .res — banked overlays the
; driver's ONE-SHOT init block ($1F00-$1FD3, dead after boot; a warm
; re-entry of the boot path would execute scratch as code — cold boot
; only; it tracks DRV_ORG, which slid a page down 2026-08-17); flat uses
; its free zone side. Adjacency is LOAD-BEARING throughout (indexed copy
; loops + the bounds/axis loops).
PM_SCRATCH = DRV_ORG                    ; NOT a private copy: the overlay IS
                                        ; the driver's init block (abi.inc);
                                        ; ONE home since the parasite map —
                                        ; flat carries the driver at $0F00 too
pm_bx0     = PM_SCRATCH+$00             ; box bounds; ORDER LOAD-BEARING
pm_by0     = PM_SCRATCH+$02             ;  (pm_bx0,X / pm_bx1,X, X=0/2)
pm_bx1     = PM_SCRATCH+$04
pm_by1     = PM_SCRATCH+$06
pm_c1      = PM_SCRATCH+$08             ; second column (or == first)
pm_cnt     = PM_SCRATCH+$09
pm_dvz     = PM_SCRATCH+$0A             ; dest vz candidate
pm_t1s     = PM_SCRATCH+$0B             ; smul t1: sign + u24 mag
pm_t1m     = PM_SCRATCH+$0C
pm_t2s     = PM_SCRATCH+$0F             ; (t1s..t2m contiguous: the
pm_t2m     = PM_SCRATCH+$10             ;  corner_side copy loops)
pm_ma      = PM_SCRATCH+$13             ; mul operands
pm_mb      = PM_SCRATCH+$15
pm_ax      = PM_SCRATCH+$17             ; cross operands (ax..ay 4B runs)
pm_ay      = PM_SCRATCH+$19
pm_lx      = PM_SCRATCH+$1B             ; line origin/delta (8B run)
pm_ly      = PM_SCRATCH+$1D
pm_ldx     = PM_SCRATCH+$1F
pm_ldy     = PM_SCRATCH+$21
pm_sfirst  = PM_SCRATCH+$23
pm_c0_save = PM_SCRATCH+$28             ; scan state
pm_col     = PM_SCRATCH+$29
pm_n       = PM_SCRATCH+$2A
pm_idx     = PM_SCRATCH+$2B
pm_i       = PM_SCRATCH+$2C
pm_rx      = PM_SCRATCH+$2D             ; crossing record stash (8B run:
pm_ry      = PM_SCRATCH+$2F             ;  the mc_stash copy loop)
pm_rdx     = PM_SCRATCH+$31
pm_rdy     = PM_SCRATCH+$33
pm_t1s_w   = PM_SCRATCH+$35             ; smul work (4B run: pcs_c1/c2)
pm_t1m_w   = PM_SCRATCH+$36
pm_mb2     = PM_SCRATCH+$39
pm_tmob    = PM_SCRATCH+$3A             ; tmfloorz aggregate

PM_RADIUS   = 16
PM_STEP     = 4                         ; DOOM's 24-world-unit step, in
                                        ; PRESCALED units. _prescale_height
                                        ; bakes in the 1.2x aspect, so 24
                                        ; world = 3.6 units — a limit of 3
                                        ; was really 20 world units and
                                        ; blocked the climb out of the
                                        ; nukage onto the zigzag path.
                                        ; colmap.STEP_PS is the twin and
                                        ; asserts the map has no step in
                                        ; the 24..26.7 gap this admits.
PM_XBIAS    = 1936                      ; -RAWX_MIN (walk clamp rect)

; ============================================================================
; pmove_try — C=1: move allowed, pm_vz updated, walkovers fired.
;   in: zp_br_pxraw/pyraw = CANDIDATE (raw s16), pm_oldx/y = committed
;       position, pm_vz = current vz. Pages BANK_WALK and leaves it.
; ============================================================================
; (pm_column rehomed to SEG_PMB4 2026-08-29: the y-cell prescreen
;  filled the banked PMOVE area)


SEG_PMOVE
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
   BNE pcs_loop
   JMP pcs_clear                        ; (prescreen pushed it from range)
pcs_loop:
   LDY pm_n
   DEY
   LDA (zp_pm_p),Y                      ; collision index
   CMP #COL_N_SOLID
   BCS pcs_port_j                       ; >= COL_N_SOLID: aggregation port
; per-record y-cell prescreen (2026-08-29): CYMIN/CYMAX are indexed by
; the RAW collision index, so the reject runs before the *9 address
; build and the bvs staging (~100 cycles each). Purely conservative:
; a cell-disjoint record is one bvs's own bbox test would reject.
   TAY
   LDA CYMAX_BASE,Y
   CMP pm_bycl0
   BCC pcs_yrej                         ; seg entirely below the box
   LDA CYMIN_BASE,Y
   CMP pm_bycl1p
   BCC pcs_ylive                        ; overlap: stage the record
pcs_yrej:
   DEC pm_n
   BEQ pcs_yclear
   JMP pcs_loop
pcs_yclear:
   JMP pcs_clear
pcs_port_j:
   JMP pcs_port                         ; (the prescreen pushed pcs_port
                                        ;  out of branch range)
pcs_ylive:
   LDX pm_surv                          ; record the survivor for the
   CPX #4                               ;  replay certificate (Y = idx)
   BCS pcy_over
   TYA
   STA pmt_sv,X
   INC pm_surv
   BNE pcs_solid                        ; (count >= 1: always)
pcy_over:
   LDA #$FF
   STA pm_surv                          ; 5th survivor: no certificate
   TYA
pcs_solid:
   JSR pm_test_solid
   BCC pcs_nx1
   RTS                                  ; blocked: C=1 up to pmove_try
pcs_nx1:
   JMP pcs_next
; pm_test_solid — A = solid idx -> C=1 blocked (the extracted body:
; the replay certificate re-tests recorded survivors through the SAME
; code the scan uses)
::pm_test_solid:
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
   JMP pm_box_vs_seg                    ; C out = the verdict (a JMP tail
                                        ; call, NEVER a fall-through: see
                                        ; the 7987201 phantom-blocker scar
                                        ; on the port path below)
; --- aggregation port (COLPORT @ main, stride 12): crossed -> the DOOM
; opening rules with live mover heights; block or aggregate tmfloorz ---
pcs_port:
   SBC #COL_N_SOLID                     ; C=1 from the CMP: k = idx - 199
   TAY
; port y-cell prescreen (2026-08-29): packed nibbles, 256-unit cells —
; hi = ymax cell, lo = ymin cell. Disjoint cell ranges cannot cross the
; box (bvs would reject the same port ~100 cycles later).
   LDA CYPORT_BASE,Y
   CMP pm_by8lo4
   BCC pcs_next                         ; port entirely below the box
   AND #$0F
   CMP pm_by8hi1
   BCS pcs_next                         ; entirely above
   LDX pm_surv                          ; record the RAW idx for replay
   CPX #4
   BCS pcp_over
   TYA
   ADC #COL_N_SOLID                     ; C=0: the BCS above fell through
   STA pmt_sv,X
   INC pm_surv
   BNE pcp_go                           ; (count >= 1: always)
pcp_over:
   LDA #$FF
   STA pm_surv                          ; 5th survivor: no certificate
pcp_go:
   TYA
   JSR pm_test_port_k
   BCC pcs_nx2
   RTS                                  ; blocked: C=1 up to pmove_try
pcs_nx2:
   JMP pcs_next
; pm_test_port_k — A = k (idx - COL_N_SOLID) -> C=1 blocked
::pm_test_port_k:
   STA pm_idx
   LDA #0
   STA zp_anim_p+1
   LDA pm_idx
   ASL A
   ASL A                                ; k*4 (k <= 42: fits)
   STA zp_anim_p
   ASL A
   ROL zp_anim_p+1                      ; k*8 (16-bit from here)
   CLC
   ADC zp_anim_p
   STA zp_anim_p
   BCC :+
   INC zp_anim_p+1
:  LDA zp_anim_p                        ; k*12
   CLC
   ADC #<COLPORT_BASE
   STA zp_anim_p
   LDA zp_anim_p+1
   ADC #>COLPORT_BASE
   STA zp_anim_p+1
   JSR pm_box_vs_seg                    ; geometry layout matches; main
   BCS ptp_agg                          ; RAM: readable under WALK
   CLC
   RTS                                  ; box misses the port: clear
ptp_agg:
   LDA #1                               ; the move CROSSES this port: ss
   STA pm_pcross                        ;  may change, tmob may bind
   JMP pm_port_aggr                     ; C out = the verdict

pcs_next:
   DEC pm_n
   BEQ pcs_clear
   JMP pcs_loop
pcs_clear:
   CLC
pcs_rts:
   RTS
.endscope

; ============================================================================
; pm_port_aggr — the crossed port at (zp_anim_p): +8 WALL ANGLE, then
; +9 ob_vz +10 ot_ps +11 mover. The angle sits at +8 to MATCH THE SOLID
; RECORD (colmap packs it there): pm_box_vs_seg writes pm_blkang from
; +8 for whatever record it straddled, so a port that turns out to
; block needs no second load — and pa_ok must RESTORE $FF, else a
; passable port leaves a bogus wall for a later sector-rule block to
; slide along (the 2026-08-15 momentum-fuzz find: the old layout put
; ob_vz at +8, so the speculative write stored a HEIGHT as an angle;
; every verdict still matched, only the slide direction was wrong,
; which is why the try suite stayed clean).
; C=1 = BLOCK (opening or head < 56), else aggregate pm_tmob.
; Height algebra (all prescaled s8, EYE folded):
;   opening: ot - (ob-5) < 7  <=>  ot - ob < 2
;   head:    ot - (vz-5) < 7  <=>  ot - vz < 2
; ============================================================================
.scope
::pm_port_aggr:
   LDY #9
   LDA (zp_anim_p),Y                    ; ob_vz
   STA pm_c1                            ; (scratch reuse: cols are done
   INY                                  ;  by the time ports test)
   LDA (zp_anim_p),Y                    ; ot_ps
   STA pm_cnt
   INY
   LDA (zp_anim_p),Y                    ; mover byte
   CMP #$FF
   BEQ pa_static
   PHA
   AND #$3F
   STA pm_dvz                           ; scratch: idx
   ASL A
   ADC pm_dvz                           ; idx*3 (C=0: idx<=5 ASL)
   TAY
   LDA ANIM_WS+1,Y                      ; live pos
   TAX
   PLA
   BMI pa_ceil
   TXA                                  ; lift: ob = pos + eye
   CLC
   ADC #5
   STA pm_c1
   JMP pa_static
pa_ceil:
   TXA                                  ; door: ot = pos
   STA pm_cnt
pa_static:
; opening: ot - ob < 2 -> block
   LDA pm_cnt
   SEC
   SBC pm_c1
   BMI pa_block
   CMP #2
   BCC pa_block
; head: ot - vz < 2 -> block
   LDA pm_cnt
   SEC
   SBC pm_vz
   BMI pa_block
   CMP #2
   BCC pa_block
; aggregate: pm_tmob = max(pm_tmob, ob)
   LDA pm_c1
   SEC
   SBC pm_tmob
   BMI pa_ok
   LDA pm_c1
   STA pm_tmob
pa_ok:
   LDA #$FF                             ; passable: drop the speculative
   STA pm_blkang                        ; wall (see the header)
   CLC
   RTS
pa_block:
   SEC                                  ; pm_blkang already holds this
   RTS                                  ; port's angle (record +8)
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

SEG_PMOVE

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
   CLC
   RTS
mc_go:
; endpoints of the record must straddle the MOVE line: swap roles.
; Stash the record's origin+delta in pm_r* (pm_t* is pm_corner_side
; scratch), then restage pm_l* as the move line.
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
; pu_scan — shared record scan (SPACE traces AND pm_walkover): pm_i
; records of stride 11 at (zp_pm_p), trace staged in pm_oldx/y..pm_exx/y.
; Records carry biased hi-byte y bounds at +9/+10: two unsigned
; compares reject far records before the mul-heavy crossing test.
::pu_scan:
   LDA pm_oldy+1
   EOR #$80
   STA pm_woy0                          ; biased trace-y his (NOT pm_ut:
   LDA pm_exy+1                         ;  the smuls inside the crossing
   EOR #$80                             ;  test clobber that)
   STA pm_woy1
pu_loop:
   LDY #9
   LDA pm_woy0
   CMP (zp_pm_p),Y                      ; y0 < rec ymin?
   BCS pu_s1
   LDA pm_woy1
   CMP (zp_pm_p),Y
   BCC pu_nx                            ; both below: reject
pu_s1:
   INY
   LDA (zp_pm_p),Y                      ; rec ymax
   CMP pm_woy0
   BCS pu_go
   CMP pm_woy1
   BCS pu_go
   BCC pu_nx                            ; both above: reject
pu_go:
   JSR pm_move_crosses_line
   BCS pu_hit
pu_nx:
   LDA zp_pm_p
   CLC
   ADC #11
   STA zp_pm_p
   BCC :+
   INC zp_pm_p+1
:
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
.endscope

; ============================================================================

; ============================================================================
; pm_walkover — fire the walk-over movers this frame's committed move
; crossed (colmap walk_hits' 6502 twin — it NEVER EXISTED before
; 2026-08-29: the WR lift trigger ld195 could not fire, so lift 70
; never lowered and the zigzag platform was unreachable once left).
; Reuses pu_scan (stride-11 records at WALKTAB) and pu_hit's mover
; toggle — a crossed plat waiting at B starts B->A exactly like a DR
; door face; re-crossing while it moves reverses it (a DOOM quirk we
; accept; DOOM ignores mid-motion retriggers). Skipped when nothing
; moved, when the origin raws are boot garbage (pm_moved != 2), or
; when every chunk fast-committed (no silent-class line — walk lines
; included — can have been crossed).
; ============================================================================
SEG_PMWO
.scope
::pm_walkover:
   LDA pm_moved
   CMP #2                               ; moved AND valid origin
   BNE wo_rts
   LDA pm_woneed
   BEQ wo_rts
   LDX #3
wo_ex:
   LDA zp_br_pxraw_l,X                  ; trace endpoint = committed raws
   STA pm_exx,X
   DEX
   BPL wo_ex
   PAGE BANK_SEG                        ; the records live in bank A
   LDA WALKTAB_BASE                     ; n_walk (abi bakes the section
   BEQ wo_pg                            ;  offset; colmap asserts n_use)
   STA pm_i
   LDA #<(WALKTAB_BASE+1)
   STA zp_pm_p
   LDA #>(WALKTAB_BASE+1)
   STA zp_pm_p+1
   JSR pu_scan
wo_pg:
   PAGE BANK_WALK                       ; pm_frame's caller owns WALK
wo_rts:
   RTS
.endscope

; ============================================================================
; pm_use_prefilter — C=1 iff the use-trace bbox (pm_oldx/y..pm_exx/y)
; overlaps the 9-byte line record's bbox at (zp_pm_p). Cheap s16
; compares only; conservative (never rejects a true crossing).
; ============================================================================


; ============================================================================
; pm_frame — the player's movement for one driver frame (35Hz-derived;
; momentum retired 2026-08-22, see the ABI note below).
; THE canonical rules are colmap.move_frame (python); this is their
; 6502 expression, fuzz-gated. CODE LIVES IN BANK B (Eben blessed
; movement code into bank WALK 2026-08-15 — movement already runs
; entirely under that bank): segments PMB1-4 are the bank B free
; windows from the census (colmap.py / project_pmove); flat = one
; $2300-$28FF region. THE DRIVER MUST PAGE BANK_WALK BEFORE THE JSR
; (banked) — pm_frame cannot page itself in.
;
;   in : A = PAL fields elapsed (clamped PM_FCAP), X = input (b0 fwd,
;        b1 back, b2/b3 turn), DV_ANGIDX / DV_PXF.. (24-bit 8.8
;        positions), pm_vz.
;   out: position + pm_vz updated, D_FWD written, PM_TURNREM carried.
;
; (This block described the MOMENTUM model until 2026-08-29 — thrust,
;  the +-960 clamp, STOPSPEED, *232>>8 friction, and an "out" naming
;  PM_MOMX/Y + PM_TICREM at $03F8. Momentum was retired 2026-08-22 and
;  those addresses died with the low-RAM map; the comment outlived all
;  of it. Nothing here is momentum any more.)
;
; The frame's whole displacement is ONE affine step along the view ray
; at constant speed (PF_MOVE_L/H by field count, colmap.walk_disp is the
; twin). It applies in chunks of at most MM_HALF per axis via pmove_try;
; a blocked chunk projects the REMAINING displacement onto the wall
; (dot-product P_HitSlideLine, <= 2 walls/frame), then the axis
; fallback, then stop.
; ============================================================================

; pm_frame scratch (PM_SCRATCH tail — pmove_try's stops at +$48).
; ADJACENCY LOAD-BEARING: tx/ty, fdx/fdy, cdx/cdy, remx/remy, axu/ayu,
; vx/vy are (x,y) pairs indexed X=0/2; nx..ny is the 6-byte commit run;
; pm_wu is (cmag,cneg,smag,sneg) so axis X=0 pairs with cos, X=2 sin.
pm_spd    = PM_SCRATCH+$49              ; the frame's displacement
                                        ; magnitude (u16) — the retired
                                        ; thrust vector's slot
pm_fdx    = PM_SCRATCH+$4D              ; frame displacement
pm_fdy    = PM_SCRATCH+$4F
pm_cdx    = PM_SCRATCH+$51              ; chunk delta
pm_cdy    = PM_SCRATCH+$53
pm_rem    = PM_SCRATCH+$55              ; cd*chunks_left, kept by
pm_remy   = PM_SCRATCH+$57              ;  increment (slide input)
pm_chunks = PM_SCRATCH+$59
pm_kk     = PM_SCRATCH+$5A
pm_slides = PM_SCRATCH+$5B
pm_tics   = PM_SCRATCH+$5C
pm_okf    = PM_SCRATCH+$5D              ; clean-commit flag
pm_in     = PM_SCRATCH+$5E              ; input bits
pm_thr    = PM_SCRATCH+$5F              ; thrust-active flag
pm_nx     = PM_SCRATCH+$60              ; candidate 24-bit x
pm_ny     = PM_SCRATCH+$63              ;  (nx..ny: commit copy run)
pm_tdx    = PM_SCRATCH+$66              ; intended displacement (D_FWD)
pm_tdy    = PM_SCRATCH+$68
pm_um     = PM_SCRATCH+$6A              ; mul |v| u16
pm_ures   = PM_SCRATCH+$6C              ; mul 24-bit accumulator
pm_uadd   = PM_SCRATCH+$6F              ; mul 24-bit shifting addend
                                        ;  (pm_smul's lesson: 24 bits)
pm_usgn   = PM_SCRATCH+$72
pm_umag   = PM_SCRATCH+$73
pm_ut     = PM_SCRATCH+$74
pm_pp     = PM_SCRATCH+$75              ; projection scalar
pm_wu     = PM_SCRATCH+$77              ; unit: cmag,cneg,smag,sneg
pm_vx     = PM_SCRATCH+$7B              ; project vector in/out
pm_vy     = PM_SCRATCH+$7D
pm_p1     = PM_SCRATCH+$7F              ; D_FWD product 1 (24-bit)
pm_p1s    = PM_SCRATCH+$82              ;  + its sign
pm_axu    = PM_SCRATCH+$83              ; split |fd| work
pm_ayu    = PM_SCRATCH+$85
pm_sv     = PM_SCRATCH+$87              ; fallback stash
pm_bk     = PM_SCRATCH+$89              ; back-key flag (0/1)
pm_sh     = PM_SCRATCH+$8A              ; shift counter
pm_bycl0  = PM_SCRATCH+$8B              ; box ymin cell (prescreen,
pm_bycl1p = PM_SCRATCH+$8C              ;  2026-08-29) / ymax cell + 1
pmc_ang   = PM_SCRATCH+$8D              ; displacement cache key: angidx /
pmc_fld   = PM_SCRATCH+$8E              ;  fields / key bits ($FF = cold:
pmc_in    = PM_SCRATCH+$8F              ;  fields is 1..10, never $FF)
pmc_fd    = PM_SCRATCH+$90              ; cached fdx,fdy (4 B)
pmc_hit   = PM_SCRATCH+$94              ; this frame served from cache
pmc_dfwd  = PM_SCRATCH+$95              ; cached D_FWD (a pure key
                                        ;  function); $FF = not computed
                                        ;  under this key (a blocked
                                        ;  commit skips the compute)
pm_by8lo4 = PM_SCRATCH+$96              ; box ymin 256-cell << 4 and
pm_by8hi1 = PM_SCRATCH+$97              ;  ymax 256-cell + 1: the packed-
                                        ;  nibble port prescreen operands
pmt_c0    = PM_SCRATCH+$98              ; empty-columns certificate key:
pmt_c1    = PM_SCRATCH+$99              ;  the two scan columns + the box
pmt_y0    = PM_SCRATCH+$9A              ;  y cells of the last scan that
pmt_y1p   = PM_SCRATCH+$9B              ;  rejected EVERY record
pmt_ok    = PM_SCRATCH+$9C              ; 1 = key valid (cold-init 0)
pm_surv   = PM_SCRATCH+$9D              ; any record survived prescreen
pmt_c0s   = PM_SCRATCH+$9E              ; staged c0 across the key check
; survivor-replay slots: REHOMED $57E0 -> $0ED0 (2026-09-01): SHTAB took
; the $5600-$57FF tail and the old literals STOMPED SHL5 on every move —
; sparse indexed writes at $57E5/E6/E9/EC, invisible to ld65 (baked
; equates) and to the zero-RAM harness (the corpus never moves).  The
; jsbeeb spawn artefacts + broken movement.  $0ED0-$0EFF is the WORK
; arena free run, both builds; sqr_fill_cold zeroes it (the block used
; to ship as LOW-tail zeros — junk-RAM boots need the explicit clear).
PMT_BLK   = $0ED0
pmt_sv    = PMT_BLK+$0                  ; <=4 surviving collision idxes
pm_svx    = PMT_BLK+$4                       ; replay cursor (X across testers)
pm_stmv   = PMT_BLK+$5                       ; staged ss class this zonly (1 =
pm_lmv    = PMT_BLK+$6                       ;  static) -> pm_lmv ON COMMIT: the
                                        ;  committed position's ss class
                                        ;  (0 = mover/cold: no fast commit)
pm_moved  = PMT_BLK+$9                       ; okf at entry, ASL'd by pf_move:
                                        ;  2 = moved AND origin raws valid
pm_woy0   = PMT_BLK+$A                       ; pu_scan biased trace-y his
pm_woy1   = PMT_BLK+$B                       ;  (survive pm_move_crosses_line)
pm_woneed = PMT_BLK+$C                       ; a full zonly ran (a silent-line
                                        ;  class crossing was possible)
pm_pcross = PMT_BLK+$7                       ; per-TRY: a port line was CROSSED
                                        ;  (box_vs_seg C=1) — the move may
                                        ;  change subsector / bind tmob,
                                        ;  so no same-ss fast commit
; (PM_SCRATCH+$8C..+$9D — the single-step momentum core's coefficient
;  pairs, 24-bit accumulator and sign-magnitude operands — are FREE
;  since momentum retired 2026-08-22.  colmap.walk_disp / turn_frame
;  mirror what replaced them.)

; Momentum RETIRED 2026-08-22 (Eben): holding forward/back advances
; along the view ray at a CONSTANT speed — no friction, no coasting,
; releasing the key stops dead.  The speed is 80% of the old model's
; asymptotic top speed: that model's tic was `m += T; x += m; m *= a`,
; fixed point m* = T*a/(1-a) = 232, so the per-tic DISPLACEMENT was
; m* + T = 256 (the "8.0 u/tic top speed"), and 80% of it is 204.8.
;
; Both the walk AND the rotation are scaled by the PAL field count, so
; the feel does not change with the frame rate.  Working per FIELD (20 ms
; of real elapsed time) rather than per tic drops the tic quantisation
; entirely — no fractional tic has to be carried.
PM_FCAP     = 10                        ; field hiccup clamp = table size.
                                        ; 10 fields = 200 ms, ample over the
                                        ; 3-7 a frame actually takes, and it
                                        ; halves the worst-case travel in one
                                        ; frame (56 world units, not 177) —
                                        ; margin the chunk splitter then keeps

SEG_PMB1
.scope
::pm_frame_i:                           ; (the wrapper below is the ABI
   STX pm_in                            ;  entry: it refreshes the raws)
   CMP #PM_FCAP+1
   BCC pf_fok
   LDA #PM_FCAP                         ; fields hiccup clamp (also the
pf_fok:                                 ;  coefficient table's last row)
   TAX
   BNE pf_go
pf_none:
   LDA #0
   STA D_FWD
   RTS
pf_go:
; Rotate FIRST, so the walk below uses the angle we end up facing (the
; driver used to step angidx itself, one step per FRAME — which turned
; faster the faster the frame rate).  pf_turn preserves X = fields.
   JSR pf_turn                          ; (SEG_PMOVE)
; --- the frame's walk: constant speed along the view ray -------------
; DISPLACEMENT CACHE (2026-08-29, Eben's "why actual math?"): with no
; momentum state, fdx/fdy = PF_MOVE[fields] * unit(angidx) * dir — a
; pure function of (angidx, fields, keys). Straight-line frames hit
; the one-entry cache and skip pmf_unit + both sc16 multiplies.
   LDA pm_in
   AND #3
   BEQ pf_nm_j                          ; neither key
   CMP #3
   BNE pfc_probe                        ; both cancel ->
pf_nm_j:
   JMP pf_nomove                        ;  (cache code pushed it from range)
pfc_probe:
   TAY                                  ; Y = key bits (1 or 2)
   LDA DV_ANGIDX
   CMP pmc_ang
   BNE pfc_miss
   CPX pmc_fld
   BNE pfc_miss
   TYA
   CMP pmc_in
   BNE pfc_miss
   LDA pmc_fd                           ; hit: the cached displacement
   STA pm_fdx
   LDA pmc_fd+1
   STA pm_fdx+1
   LDA pmc_fd+2
   STA pm_fdy
   LDA pmc_fd+3
   STA pm_fdy+1
   LDA #1
   STA pmc_hit
   JMP pf_move
pfc_miss:
   LDA #0
   STA pmc_hit
   LDA #$FF
   STA pmc_dfwd
   LDA DV_ANGIDX
   STA pmc_ang
   STX pmc_fld
   TYA
   STA pmc_in
   LSR A                                ; A = 1 or 2 -> b1 (back) to b0
   AND #1
   STA pm_bk
   LDA PF_MOVE_L-1,X                    ; the frame's whole displacement
   STA pm_spd                           ; magnitude, by field count
   LDA PF_MOVE_H-1,X
   STA pm_spd+1
   LDA DV_ANGIDX
   JSR pmf_unit
   LDX #0
pf_thr:
   LDA pm_spd
   STA pm_ax
   LDA pm_spd+1
   STA pm_ax+1
   LDA pm_wu,X
   STA pm_umag
   JSR pmf_sc16                         ; (speed*mag)>>5 — pm_ax positive
   LDA pm_wu+1,X
   EOR pm_bk                            ; sign = unitneg XOR back
   AND #1
   JSR pmf_negif                        ; (preserves X)
   LDA pm_ax
   STA pm_fdx,X
   STA pmc_fd,X                         ; store-through to the cache
   LDA pm_ax+1
   STA pm_fdx+1,X
   STA pmc_fd+1,X
   INX
   INX
   CPX #4
   BCC pf_thr
   JMP pf_move
pf_nomove:
   LDA #0                               ; not walking: nothing to commit,
   STA D_FWD                            ;  and the cache cannot serve
   RTS
; --- apply the displacement in DOOM-halved chunks ---------------------
pf_move:
   LDA pm_fdx
   ORA pm_fdx+1
   ORA pm_fdy
   ORA pm_fdy+1
   BNE pf_mv_go
   JMP pf_none
pf_mv_go:
   ASL pm_moved                         ; 1 -> 2: moved with a valid origin
   LDX #3
pf_ctd:
   LDA pm_fdx,X                         ; intended move, for D_FWD
   STA pm_tdx,X
   DEX
   BPL pf_ctd
   LDA #1
   STA pm_okf
   LDA #0
   STA pm_slides
   JSR pmf_split
pf_chunk:
   LDA pm_chunks
   BNE pf_c_go
   JMP pf_dfwd
pf_c_go:
   JSR pmf_cand                         ; candidate + raws
   JSR pmove_try
   BCC pf_blk
   JSR pmf_commit
   JMP pf_chunk
pf_blk:
   LDA #0
   STA pm_okf
   LDA pm_slides
   CMP #2
   BCS pf_fall
   LDA pm_blkang
   CMP #$FF
   BEQ pf_fall
   INC pm_slides
   JSR pmf_unit                         ; A = blkang -> wall unit
   LDX #3
pf_s1:
   LDA pm_rem,X                         ; remaining -> project -> new fd
   STA pm_vx,X
   DEX
   BPL pf_s1
   JSR pmf_project
   LDX #3
pf_s2:
   LDA pm_vx,X
   STA pm_fdx,X
   DEX
   BPL pf_s2
   JSR pmf_split                        ; (the second projection, which
                                        ;  put momentum on the same wall,
                                        ;  died with momentum)
   JMP pf_chunk
; --- axis fallback: keep y (X=2), then keep x (X=0), then full stop ---
pf_fall:
   LDX #2
pf_f_ax:
   LDA pm_cdx,X                         ; keep-axis delta zero: skip
   ORA pm_cdx+1,X
   BEQ pf_f_nx
   TXA
   EOR #2
   TAY                                  ; Y = axis to zero
   LDA pm_cdx,Y
   STA pm_sv
   LDA pm_cdx+1,Y
   STA pm_sv+1
   LDA #0
   STA pm_cdx,Y
   STA pm_cdx+1,Y
   TXA
   PHA
   TYA
   PHA
   JSR pmf_cand
   JSR pmove_try
   PLA
   TAY
   PLA
   TAX
   BCS pf_f_ok
   LDA pm_sv                            ; restore the zeroed axis
   STA pm_cdx,Y
   LDA pm_sv+1
   STA pm_cdx+1,Y
pf_f_nx:
   CPX #2
   BNE pf_f_stop
   LDX #0
   BEQ pf_f_ax
pf_f_ok:
   LDA #0                               ; dead axis: its remainder dies
   STA pm_rem,Y
   STA pm_rem+1,Y
   JSR pmf_commit
   JMP pf_chunk
pf_f_stop:                              ; boxed in: nothing commits
   JMP pf_dfwd

; --- rotation ---------------------------------------------------------
; SEG_PMOVE, not PMB1: main RAM is always mapped, so bank-B code reads
; this (and the tables) with no paging, and the bank-B windows are the
; scarcer resource. The region is CPU-invariant, which is the rule for
; anything bank B references.
SEG_PMH
; pf_turn — frame-rate-compensated view rotation.  X = field count
; (1..PM_FCAP) and MUST be preserved: the caller indexes PF_MOVE with it
; straight afterwards.  Input bits b2 = left, b3 = right; both cancel.
;
; The view angle is quantised to 64 steps of 4 angle-bytes, so a frame's
; turn is generally FRACTIONAL.  PF_TURN is Q8 steps for the field
; count; the sub-step fraction is carried in PM_TURNREM, which is what
; makes one slow frame turn as far as two fast ones.  (The byte is the
; retired 35Hz tic remainder, put back to work.)
pf_turn:
   LDA pm_in
   AND #$0C
   BEQ pt_none
   CMP #$0C
   BEQ pt_none                          ; left and right cancel
   CLC
   LDA PF_TURN_L-1,X
   ADC PM_TURNREM                       ; + the fraction carried in
   STA PM_TURNREM
   LDA PF_TURN_H-1,X
   ADC #0
   TAY                                  ; Y = whole steps this frame
   BEQ pt_none                          ; still short of one step
   LDA pm_in
   AND #4
   BEQ pt_right
   TYA                                  ; LEFT: angidx += steps
   CLC
   ADC DV_ANGIDX
   AND #63                              ; (the BCC that used to sit here
                                        ;  branched to the NEXT instruction:
                                        ;  the AND masks either way, so the
                                        ;  test was dead the moment it was
                                        ;  written — tools/jumpscan.py)
   STA DV_ANGIDX
pt_none:
   RTS
pt_right:                               ; RIGHT: angidx -= steps
   STY pm_sh
   LDA DV_ANGIDX
   SEC
   SBC pm_sh
   AND #63
   STA DV_ANGIDX
   RTS

; --- frame tables (colmap._walk_build generates these; pm_fuzz asserts
; the bytes against it, so they cannot drift) -------------------------
; PF_MOVE[f] = round(204.8 * f*179/256), the frame's displacement
; magnitude; PF_TURN[f] = round(0.5 * f*179/256 * 256), Q8 angle-steps.
; f = 1..PM_FCAP (f = 0 exits early), so both are indexed -1 and carry
; no dead row.
SEG_PMB2
PF_MOVE_L:
   .byte <143, <286, <430, <573, <716, <859, <1002, <1146, <1289, <1432
SEG_PMB3
PF_MOVE_H:
   .byte >143, >286, >430, >573, >716, >859, >1002, >1146, >1289, >1432
SEG_PMB1
PF_TURN_L:
   .byte <90, <179, <268, <358, <448, <537, <626, <716, <806, <895
PF_TURN_H:
   .byte >90, >179, >268, >358, >448, >537, >626, >716, >806, >895
.endscope

; ============================================================================
; D_FWD — clean commit AND intended move EXACTLY on the view ray
; (cross == 0 as 24-bit magnitude products + signs, dot > 0). See the
; model for why exact: friction drift has no epsilon budget in bca.
; ============================================================================
SEG_PMB2
.scope
::pf_dfwd:
   LDA #0
   STA D_FWD
   LDA pm_okf
   BNE df_go
   RTS
df_go:
   LDA pmc_hit                          ; cache-hit frame: D_FWD is the
   BEQ df_compute                       ; same pure function of the key
   LDA pmc_dfwd                         ; as the displacement — IF a
   BMI df_compute                       ; compute ran under this key
   STA D_FWD                            ; ($FF = it did not)
   RTS
df_compute:
   LDA DV_ANGIDX
   JSR pmf_unit
   LDA pm_tdx
   STA pm_ax
   LDA pm_tdx+1
   STA pm_ax+1
   LDA pm_wu+2                          ; smag
   STA pm_umag
   JSR pmf_mul24s                       ; A = |tdx|*smag sign
   EOR pm_wu+3                          ; product sign = sign XOR sneg
   STA pm_p1s
   LDX #2
df_c1:
   LDA pm_ures,X
   STA pm_p1,X
   DEX
   BPL df_c1
   LDA pm_tdy
   STA pm_ax
   LDA pm_tdy+1
   STA pm_ax+1
   LDA pm_wu                            ; cmag
   STA pm_umag
   JSR pmf_mul24s
   EOR pm_wu+1
   STA pm_ut                            ; sign 2
   LDA pm_ures                          ; both products zero: on the ray
   ORA pm_ures+1
   ORA pm_ures+2
   ORA pm_p1
   ORA pm_p1+1
   ORA pm_p1+2
   BEQ df_dir
   LDA pm_p1s
   CMP pm_ut
   BNE df_out
   LDX #2
df_c2:
   LDA pm_ures,X
   CMP pm_p1,X
   BNE df_out
   DEX
   BPL df_c2
df_dir:
; forward iff the dominant nonzero component points with the unit
   LDA pm_tdx
   ORA pm_tdx+1
   BEQ df_y
   LDA pm_tdx+1
   ASL A
   LDA #0
   ROL A                                ; A = sign(tdx)
   CMP pm_wu+1
   BNE df_out
   BEQ df_yes
df_y:
   LDA pm_tdy+1
   ASL A
   LDA #0
   ROL A
   CMP pm_wu+3
   BNE df_out
df_yes:
   LDA #1
   STA D_FWD
df_out:
; store-through: on a clean commit the value just derived is the pure
; key function the hit path serves (D_FWD stays 0-initialized on the
; not-clean path, which never reaches here)
   LDA D_FWD
   STA pmc_dfwd
   RTS
.endscope

; ============================================================================
; pmf_split — fd -> kk (halvings until both axes <= 480), chunks = 1<<k,
; cd = fd asr k, rem = cd << k (= cd*chunks: the slide's remaining)
; ============================================================================
.scope
::pmf_split:
   LDX #0
sp_abs:
   LDA pm_fdx+1,X                       ; |fd| -> axu/ayu
   BMI sp_neg
   STA pm_axu+1,X
   LDA pm_fdx,X
   STA pm_axu,X
   JMP sp_abn
sp_neg:
   SEC
   LDA #0
   SBC pm_fdx,X
   STA pm_axu,X
   LDA #0
   SBC pm_fdx+1,X
   STA pm_axu+1,X
sp_abn:
   INX
   INX
   CPX #4
   BCC sp_abs
   LDA #0
   STA pm_kk
sp_ck:
   LDX #0
sp_ck1:
   LDA pm_axu+1,X                       ; > 724 ($02D4)? (MM_HALF — the
   CMP #2                               ;  tunnelling-proof cap, colmap)
   BCC sp_ckn
   BNE sp_half
   LDA pm_axu,X
   CMP #$D5
   BCS sp_half
sp_ckn:
   INX
   INX
   CPX #4
   BCC sp_ck1
   BCS sp_kd
sp_half:
   LSR pm_axu+1
   ROR pm_axu
   LSR pm_ayu+1
   ROR pm_ayu
   INC pm_kk
   BNE sp_ck
sp_kd:
   LDX pm_kk
   LDA #1
sp_c1:
   CPX #0
   BEQ sp_c1d
   ASL A
   DEX
   BNE sp_c1
sp_c1d:
   STA pm_chunks
   LDX #3
sp_cp:
   LDA pm_fdx,X                         ; cd = fd ...
   STA pm_cdx,X
   DEX
   BPL sp_cp
   LDX pm_kk
   BEQ sp_r0
sp_sh:
   LDA pm_cdx+1                         ; ... asr k (both axes)
   CMP #$80
   ROR pm_cdx+1
   ROR pm_cdx
   LDA pm_cdy+1
   CMP #$80
   ROR pm_cdy+1
   ROR pm_cdy
   DEX
   BNE sp_sh
sp_r0:
   LDX #3
sp_r1:
   LDA pm_cdx,X                         ; rem = cd ...
   STA pm_rem,X
   DEX
   BPL sp_r1
   LDX pm_kk
   BEQ sp_out
sp_r2:
   ASL pm_rem                           ; ... << k (= cd*chunks)
   ROL pm_rem+1
   ASL pm_remy
   ROL pm_remy+1
   DEX
   BNE sp_r2
sp_out:
   RTS
.endscope

; ============================================================================
; pmf_cand — candidate = DV position + cd -> pm_nx/ny AND the raw s16
; pair for pmove_try ($90-$93 = candidate >> 5). X walks the DV stride-3
; side, Y the cd/raw stride-2 side. Preserves neither.
; ============================================================================
; pt_zcheck — the replay came back all-clear. Sector lines with
; |floor delta| <= 24 and opening >= 56 ship NO collision record (the
; first fast-commit cut held vz across those silent floor steps —
; pm_fuzz caught it), so the skip ALSO requires both key columns'
; SILENT-LINE y intervals (SIL_BASE nibbles, 256-unit cells, sentinel
; $0F = none — same compare forms as the CYPORT screen) to miss the
; box: then no line of ANY kind was crossed => same subsector; with a
; static class, dvz == SS_VZ[ss] == pm_vz already: commit as-is and
; skip find_ss + the mover probe + the height rules.
SEG_PMSF
.scope
::pt_zcheck:
   LDA pm_pcross
   BNE ptz_full                         ; a port was crossed: full rules
   LDA pm_lmv
   BEQ ptz_full                         ; mover ss / cold boot: run it
; box INSIDE the column's clear band: (t&$F0) <= by8lo4 (band floor at
; or below the box) AND (t&$0F) >= by8hi1 (band ceiling at or above)
   LDY pmt_c0
   LDA SIL_BASE,Y
   AND #$F0
   CMP pm_by8lo4
   BEQ :+
   BCS ptz_full                        ; band starts above the box
:  LDA SIL_BASE,Y
   AND #$0F
   CMP pm_by8hi1
   BCC ptz_full                        ; band ends below the box
   LDY pmt_c1
   LDA SIL_BASE,Y
   AND #$F0
   CMP pm_by8lo4
   BEQ :+
   BCS ptz_full
:  LDA SIL_BASE,Y
   AND #$0F
   CMP pm_by8hi1
   BCC ptz_full
   SEC
   RTS
ptz_full:
   JMP pmove_zonly                      ; (== pt_cols_done: the shared
                                        ;  z-rules entry)
.endscope

SEG_PMCND
.scope
::pmf_cand:
   LDX #0                               ; X = cd/raw side (stride 2:
   LDY #0                               ;  zp,X RORs); Y = DV/nx side
pc_ax:                                  ;  (stride 3)
   CLC
   LDA DV_PXF,Y
   ADC pm_cdx,X
   STA pm_nx,Y
   LDA DV_PXF+1,Y
   ADC pm_cdx+1,X
   STA pm_nx+1,Y
   LDA pm_cdx+1,X
   BMI pc_neg
   LDA DV_PXF+2,Y
   ADC #0
   JMP pc_hi
pc_neg:
   LDA DV_PXF+2,Y
   ADC #$FF
pc_hi:
   STA pm_nx+2,Y
; raw = candidate >> 5 AND frac = (byte0 & $1F) << 3, both from ONE
; <<3 of the 24-bit value (2026-08-29): (x << 3) >> 8 == x >> 5 for
; two's complement with the same floor semantics as the old 5-step
; ROR chain, and the shifted-out low byte IS the frac feed.
   LDA pm_nx,Y
   STA pm_ut                            ; b0
   LDA pm_nx+1,Y
   STA $90,X                            ; b1 (becomes raw lo)
   LDA pm_nx+2,Y                        ; b2 rides A (becomes raw hi)
   ASL pm_ut
   ROL $90,X
   ROL A
   ASL pm_ut
   ROL $90,X
   ROL A
   ASL pm_ut
   ROL $90,X
   ROL A
   STA $91,X
   LDA pm_ut                            ; = (b0 & $1F) << 3
   STA PM_FXW,X                         ; the EXACT-DESCENT feed
   INX
   INX
   INY
   INY
   INY
   CPY #6
   BCC pc_ax
; tie-broken doubled raws for the EXACT axis point-on-side:
; px2 = (raw << 1) | (world frac > 0), vs the baked 2*nx planes
   LDA $90
   ASL A
   STA zp_br_px2_l
   LDA $91
   ROL A
   STA zp_br_px2_h
   LDA PM_FXW
   BEQ pc_fy
   INC zp_br_px2_l                      ; bit 0 is clear after the ASL
pc_fy:
   LDA $92
   ASL A
   STA zp_br_py2_l
   LDA $93
   ROL A
   STA zp_br_py2_h
   LDA PM_FXW+2
   BEQ pc_done
   INC zp_br_py2_l
pc_done:
   RTS
.endscope

; ============================================================================
; pmf_commit — candidate -> position, rem -= cd, one chunk done.
; SEG_PMOVE, and that is LOAD-BEARING: bank-B code may only reference
; symbols with CPU-INVARIANT addresses, because L0/L2 ship ONCE for
; both the NMOS and 65C02 hosts (build_walk_ssd asserts it). CODE
; shifts between the variants (STZ/BRA), so a JSR from PMB1 to a
; CODE-resident routine made the bank image CPU-dependent — exactly 2
; operand bytes, caught by that assert 2026-08-15. The PMOVE region
; has a fixed start and no C02-variant opcodes, so it is safe.
; ============================================================================
SEG_PMOVE
.scope
::pmf_commit:
   LDX #5
cm_cp:
   LDA pm_nx,X
   STA DV_PXF,X
   DEX
   BPL cm_cp
   LDX #2
cm_rm:
   SEC
   LDA pm_rem,X
   SBC pm_cdx,X
   STA pm_rem,X
   LDA pm_rem+1,X
   SBC pm_cdx+1,X
   STA pm_rem+1,X
   DEX
   DEX
   BPL cm_rm
   DEC pm_chunks
   RTS
.endscope

; ============================================================================
; pmf_unit — A = 64-angle -> pm_wu = (cmag,cneg,smag,sneg); mag6 has
; unity pre-folded to 32 IN THE TABLE (gen_pm_sincos.py), so the decode
; is a mask + a bit test. Row = pm_sincos + a*2 via zp_pm_p.
; ============================================================================
SEG_PMB3
.scope
::pmf_unit:
   AND #63
   ASL A                                ; a*2 (fits u8: <= 126)
   CLC
   ADC #<pm_sincos
   STA zp_pm_p
   LDA #0
   ADC #>pm_sincos
   STA zp_pm_p+1
   LDY #1                               ; cos byte first (pm_wu order)
   LDX #0
pu_dec:
   LDA (zp_pm_p),Y
   PHA
   AND #$3F
   STA pm_wu,X
   PLA
   AND #$40
   BEQ pu_z
   LDA #1
pu_z:
   STA pm_wu+1,X
   INX
   INX
   DEY
   BPL pu_dec
   RTS
.endscope

; ============================================================================
; main-RAM helpers (the PMOVE region slack): the shift-add mul cluster,
; friction, clamp, negif. All X-preserving except noted; muls loop via
; pm_ut/Y, never X.
; ============================================================================
; ============================================================================
; pm_frame (ABI entry) — run the frame, then leave zp $90-$93 = the raw
; s16 of the COMMITTED position. THE contract for every later reader
; this frame (mv_reval/pmove_zonly, next frame's SPACE trace): the
; driver's own derive_raw is GONE — pmf_cand is the one derivation, and
; a blocked final chunk would otherwise leave the REJECTED candidate's
; raws in zp.
; ============================================================================
SEG_PMOVE
::pm_frame:
   PHA                                  ; A = fields, X = input mask: the
   TXA                                  ;  walkover prologue below needs
   PHA                                  ;  both registers, so bank them
   LDA pm_okf                           ; pm_moved: okf-at-entry (raws in
   STA pm_moved                         ;  zp $90-$93 = last committed
   LDA #0                               ;  position iff okf); pf_move
   STA pm_woneed                        ;  ASLs it, so ==2 means "moved
   LDX #3                               ;  AND the trace origin is real"
pf_wst:
   LDA zp_br_pxraw_l,X                  ; walkover trace origin
   STA pm_oldx,X
   DEX
   BPL pf_wst
   PLA
   TAX                                  ; X = input mask
   PLA                                  ; A = fields
   JSR pm_frame_i
   JSR pm_walkover                      ; fire crossed walk-over movers
   LDA pm_okf                           ; clean commit: the last chunk's
   BEQ pf_rederive                      ;  candidate IS the position, so
   RTS                                  ;  its raws/fracs already sit in
                                        ;  zp (no-move frames keep the
                                        ;  previous frame's, still valid;
                                        ;  cold boot forces the derive
                                        ;  via sqr_fill_cold's okf=0)
pf_rederive:
   LDA #0
   STA pm_cdx
   STA pm_cdx+1
   STA pm_cdy
   STA pm_cdy+1
   JMP pmf_cand                         ; cd = 0: candidate == position

; ============================================================================
; pmf_project — (pm_vx,pm_vy) = ((V . w-hat) w-hat) on the mag6 grid;
; unit in pm_wu. Axis X=0 pairs with cos, X=2 with sin (both loops).
; SEG_PMOVE (main): the bank-B windows are full; JSRs from bank B to
; main are free (pm code never re-pages).
; ============================================================================
SEG_PMOVE
.scope
::pmf_project:
   LDA #0
   STA pm_pp
   STA pm_pp+1
   LDX #0
pj_dot:
   LDA pm_vx,X
   STA pm_ax
   LDA pm_vx+1,X
   STA pm_ax+1
   LDA pm_wu+1,X
   JSR pmf_negif
   LDA pm_wu,X
   STA pm_umag
   JSR pmf_sc16
   CLC
   LDA pm_pp
   ADC pm_ax
   STA pm_pp
   LDA pm_pp+1
   ADC pm_ax+1
   STA pm_pp+1
   INX
   INX
   CPX #4
   BCC pj_dot
   LDX #0
pj_out:
   LDA pm_pp
   STA pm_ax
   LDA pm_pp+1
   STA pm_ax+1
   LDA pm_wu,X
   STA pm_umag
   JSR pmf_sc16
   LDA pm_wu+1,X
   JSR pmf_negif
   LDA pm_ax
   STA pm_vx,X
   LDA pm_ax+1
   STA pm_vx+1,X
   INX
   INX
   CPX #4
   BCC pj_out
   RTS
.endscope

SEG_PMOVE
.scope
; pmf_mul24s — pm_ax (s16) * pm_umag (u8) -> pm_ures (24-bit MAGNITUDE),
; A = input sign (0/1)
::pmf_mul24s:
   LDA pm_ax+1
   BPL m24_pos
   SEC
   LDA #0
   SBC pm_ax
   STA pm_um
   LDA #0
   SBC pm_ax+1
   STA pm_um+1
   LDA #1
   BNE m24_go
m24_pos:
   LDA pm_ax
   STA pm_um
   LDA pm_ax+1
   STA pm_um+1
   LDA #0
m24_go:
   STA pm_usgn
   LDA #0
   STA pm_ures
   STA pm_ures+1
   STA pm_ures+2
   STA pm_uadd+2
   LDA pm_um
   STA pm_uadd
   LDA pm_um+1
   STA pm_uadd+1
   LDA pm_umag
   STA pm_ut
m24_lp:
   LSR pm_ut
   BCC m24_sh
   CLC
   LDA pm_ures
   ADC pm_uadd
   STA pm_ures
   LDA pm_ures+1
   ADC pm_uadd+1
   STA pm_ures+1
   LDA pm_ures+2
   ADC pm_uadd+2
   STA pm_ures+2
m24_sh:
   LDA pm_ut
   BEQ m24_done
   ASL pm_uadd
   ROL pm_uadd+1
   ROL pm_uadd+2
   JMP m24_lp                           ; (a BNE here would fall through
                                        ;  whenever byte 2 rolls to 0)
m24_done:
   LDA pm_usgn
   RTS

; pmf_sc16 — pm_ax = (pm_ax * pm_umag) >> 5, sign-magnitude truncate
; (ps_scale16 semantics; mag 32 = identity falls out). Preserves X.
.endscope
SEG_PMMU
.scope
::pmf_sc16:
   JSR pmf_mul24s
   LDY #5
sc_sh:
   LSR pm_ures+2
   ROR pm_ures+1
   ROR pm_ures
   DEY
   BNE sc_sh
   LDA pm_ures
   STA pm_ax
   LDA pm_ures+1
   STA pm_ax+1
   LDA pm_usgn
; pmf_negif — negate pm_ax when A != 0 (falls through from sc16's
; sign reapply). Preserves X, Y.
.endscope
SEG_PMMU
.scope
::pmf_negif:
   BEQ ng_done
   SEC
   LDA #0
   SBC pm_ax
   STA pm_ax
   LDA #0
   SBC pm_ax+1
   STA pm_ax+1
ng_done:
   RTS

.endscope

; ============================================================================
; pm_smul — signed multiply pm_ma * pm_mb (s16 x s16). Result as
; sign-magnitude: pm_t1s_w = $00 pos / $80 neg (canonical: mag 0 -> pos),
; pm_t1m_w..+2 = |product| (u24; callers' operands bound it).
; Plain shift-add (movement is frame-rare; no table dependencies).
; ============================================================================
SEG_PMOVE
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
.endscope

SEG_PMOVE

; ============================================================================
; pm_ycells — box y cells for the column-scan prescreen (2026-08-29):
;   pm_bycl0  = clamp0((pm_by0 + 1584) >> 7)
;   pm_bycl1p = clamp0((pm_by1 + 1584) >> 7) + 1
; cell = 128-unit row of the walk rect (RAWY_MIN = -1584). Below-rect
; clamps to 0; above-rect cannot exceed u8 (the rect is 22 rows and the
; box pokes past it by at most radius+chunk). Clobbers A only.
; ============================================================================
SEG_PMEXT
.scope
::pm_ycells:
   LDA pm_by0
   CLC
   ADC #<1584
   STA pm_bycl0                         ; lo' (scratch)
   LDA pm_by0+1
   ADC #>1584
   BPL yc0
   LDA #0
   STA pm_bycl0
   BEQ yc1
yc0:
   ASL pm_bycl0                         ; C = lo' bit 7
   ROL A                                ; A = (hi'<<1)|b7 = cell
   STA pm_bycl0
yc1:
   LDA pm_by1
   CLC
   ADC #<1584
   STA pm_bycl1p
   LDA pm_by1+1
   ADC #>1584
   BPL yc2
   LDA #0
   STA pm_bycl1p
   BEQ yc3
yc2:
   ASL pm_bycl1p
   ROL A
   STA pm_bycl1p
yc3:
   INC pm_bycl1p                        ; bymax cell + 1 (BCS-reject form)
; 256-cell forms for the packed-nibble port prescreen (2026-08-29):
;   by8lo4 = (bycl0>>1)<<4 = (bycl0&$FE)<<3, by8hi1 = ((bycl1p-1)>>1)+1
; (cells <= 27 on this map, so the <<3 cannot carry out)
   LDA pm_bycl0
   AND #$FE
   ASL A
   ASL A
   ASL A
   STA pm_by8lo4
   LDA pm_bycl1p
   SEC
   SBC #1
   LSR A
   CLC
   ADC #1
   STA pm_by8hi1
   RTS
.endscope

; pt_zcheck — the replay came back all-clear. If no port is in play the
; move cannot cross a sector line, so the subsector is unchanged; if its
; class is static, dvz == SS_VZ[ss] == pm_vz already: commit as-is and
; skip find_ss + the mover probe + the height rules entirely.
SEG_PMEXT
; pt_zcheck moved to PMCND (the VPLOTF hole) 2026-08-29: the silent-
; line interval screen outgrew this area.

SEG_PMB4
.scope
::pmove_try:
   PAGE BANK_WALK
   LDA #0
   STA pm_pcross                        ; no port crossed yet this try
   LDA #$FF
   STA pm_blkang                        ; no wall hit yet
   LDA #$D8
   STA pm_tmob                          ; tmfloorz aggregate = -40: low
                                        ; enough to lose every max, small
                                        ; enough that the SBC-sign trick
                                        ; stays exact (-128 overflowed it)
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
   JSR pm_ycells                        ; box y cells for the prescreen
                                        ; (SEG_PMB4 — the PMOVE region
                                        ; is full; CODE-tail slack isn't)
; columns of bx0 and bx1: c = clamp((bx + 1936) >> 7, 0..35)
   LDA pm_bx1
   LDX pm_bx1+1
   JSR pm_column
   STA pm_c1
   LDA pm_bx0
   LDX pm_bx0+1
   JSR pm_column
   STA pmt_c0s
; EMPTY-COLUMNS CERTIFICATE (2026-08-29): if the LAST scan rejected
; every record via the y-cell prescreens under the SAME (c0,c1,ycl0,
; ycl1p) key, this scan must too — the lists and cell tables are
; static, and a mover can only influence a port that SURVIVES the
; screen (pm_port_aggr), which kills the certificate. Skip both scans.
   LDA pmt_ok
   BEQ pt_scan
   LDA pmt_c0s
   CMP pmt_c0
   BNE pt_scan
   LDA pm_c1
   CMP pmt_c1
   BNE pt_scan
   LDA pm_bycl0
   CMP pmt_y0
   BNE pt_scan
   LDA pm_bycl1p
   CMP pmt_y1p
   BNE pt_scan
; REPLAY: same key => the prescreens reject the same records, so only
; the recorded survivors (<= 4) need fresh box/port verdicts — the
; verdicts DO depend on the exact position, the set only on the cells.
   LDX #0
ptr_lp:
   CPX pm_surv
   BCS ptr_done                         ; all survivors clear
   LDA pmt_sv,X
   STX pm_svx                           ; (the testers clobber X)
   CMP #COL_N_SOLID
   BCS ptr_port
   JSR pm_test_solid
   JMP ptr_ck
ptr_port:
   SBC #COL_N_SOLID                     ; C=1 from the CMP
   JSR pm_test_port_k
ptr_ck:
   BCS pt_blocked_j                     ; a survivor blocks: full verdict
   LDX pm_svx
   INX
   BNE ptr_lp                           ; (X <= 4: always)
ptr_done:
   JMP pt_zcheck                        ; all clear: same-ss fast commit?
pt_scan:
   LDA #0
   STA pmt_ok
   STA pm_surv
   LDA pmt_c0s
   STA pmt_c0
   LDA pm_c1
   STA pmt_c1
   LDA pm_bycl0
   STA pmt_y0
   LDA pm_bycl1p
   STA pmt_y1p
   LDA pmt_c0s
   JSR pm_column_scan                   ; test column c (in A)
   BCS pt_blocked_j
   LDA pm_c1
   CMP ::pm_c0_save
   BEQ pt_scans_done
   JSR pm_column_scan
   BCC pt_scans_done
pt_blocked_j:
   JMP pt_blocked                       ; (the certificate block pushed
                                        ;  pt_blocked from branch range)
pt_scans_done:
   LDA pm_surv                          ; <= 4 survivors recorded: the key
   CMP #5                               ;  + the list certify ($FF = the
   BCS ptc_j                            ;  list overflowed, no certificate)
   LDA #1
   STA pmt_ok
ptc_j:
   JMP pt_cols_done                     ; (the zonly tail lives in PMZ —
                                        ;  EXPLICIT jump, never a cross-
                                        ;  segment fall-through)

SEG_PMZ
pt_cols_done:
::pmove_zonly:                          ; entry: z path only (mv_reval)
   INC pm_woneed                        ; full rules ran: a silent-class
                                        ;  (walk-over) crossing is possible
   PAGE BANK_WALK
; destination sector rules
   JSR pm_find_ss                       ; X = subsector id
; mover subsectors come from colmap's MV_SS probe list since 2026-08-19
; (7 on E1M1; padded to 8 with $FF, which no real id matches — n_ss <=
; 221). A linear probe here is COLD (twice per MOVE), and it bought the
; render prologue its 8 cycles per visited subsector back: the SS_PLO
; plane stays plain instead of carrying packed info bits.
   TXA
   LDY #0
pt_mvscan:
   CMP MV_SS_ID,Y
   BEQ pt_mvhit
   INY
   CPY #8
   BNE pt_mvscan
   JMP pt_static
pt_mvhit:
   LDX #0                               ; mover ss: never fast-commit
   STX pm_stmv
   LDA MV_SS_INFO,Y                     ; the classic byte: idx, b7 = ceil
   STA pm_dvz                           ; (scratch: staged for the re-read)
   AND #$3F
   STA pm_cnt                           ; mover idx (scratch reuse)
   ASL A
   CLC
   ADC pm_cnt                           ; idx*3
   TAY
   LDA ANIM_WS+1,Y                      ; live pos_hi (prescaled s8)
   LDY pm_cnt
   PHA
   LDA pm_dvz                           ; staged info byte
   BMI pt_door                          ; b7 = ceiling mover (door)
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
pt_static:
   LDY #1                               ; static ss: fast-commit eligible
   STY pm_stmv
   LDA SS_VZ_BASE,X
   STA pm_dvz
pt_step:
; crossed-port floors bind: dvz = max(dvz, tm_ob) — DOOM's tmfloorz
   LDA pm_tmob
   SEC
   SBC pm_dvz                           ; |heights| small: sign exact
   BMI pt_step2
   LDA pm_tmob
   STA pm_dvz
pt_step2:
; step rule: dvz - vz > 3 -> blocked (drops always allowed)
   LDA pm_dvz
   SEC
   SBC pm_vz
   BMI pt_commit                        ; downward: fine
   CMP #PM_STEP+1
   BCS pt_blocked
pt_commit:
   LDA pm_stmv                          ; the verdict stands: the class
   STA pm_lmv                           ;  now describes the POSITION
   LDA pm_dvz
   STA pm_vz
   SEC
   RTS
pt_blocked:
   CLC
   RTS

; pm_column: A/X = raw s16 -> A = column 0..35 (clamped).
; SEG_CODE, not PMOVE: PMOVE is the CPU-invariant pocket that bank-B
; code calls into (see pmf_commit's header) and it is full — this
; routine's only caller is pmove_try, main-to-main, so it pays the
; rent instead. (It briefly visited PMEXT 2026-08-29 — that shifted the
; whole render tail behind it and cost +0.35% MEAN in pure alignment
; noise; banked stays HERE so the CODE stream matches the pre-physics
; bytes; flat — whose CODE area is at the $4E00 cap — rides PMOVE slack.)
SEG_PMCOL
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
.endscope
