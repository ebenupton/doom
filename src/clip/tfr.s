; TFS state block ($0900-$091B) — the 3-cursor event walk's working set.
; (Moved here from the deleted 6-byte-records legacy file.)
TFS_CUR_X = $0900                       ; current x in inner loop
TFS_X_HI = $0901                        ; right edge of in-range processing
TFS_NEXT_X = $0902                      ; next event x
TFS_TOP_DOM = $0903                     ; 1 if top dominated by record at cur_x, else 0
TFS_BOT_DOM = $0904                     ; same for bot
TFS_TOP_L = $0905                       ; top value at cur_x
TFS_TOP_R = $0906                       ; top value at next_x
TFS_BOT_L = $0907
TFS_BOT_R = $0908
TFS_TOP_KIND = $0909                    ; 0 = pool, 1 = top record
TFS_TOP_ID = $090A                      ; pool slot or record offset
TFS_BOT_KIND = $090B                    ; 0 = pool, 1 = bot record
TFS_BOT_ID = $090C
TFS_TOP_BUFEND = $090D                  ; 1 + top_count*4 (first invalid offset)
TFS_BOT_BUFEND = $090E
TFS_T_CUR = $090F                       ; top record cursor offset (0 = exhausted)
TFS_B_CUR = $0910                       ; bot record cursor offset (0 = exhausted)
TFS_PEND_ACT = $0911                    ; 1 if a pending output span is buffered
TFS_PEND_XL = $0912
TFS_PEND_XR = $0913
TFS_PEND_TL = $0914
TFS_PEND_TR = $0915
TFS_PEND_BL = $0916
TFS_PEND_BR = $0917
TFS_PEND_TKIND = $0918
TFS_PEND_TID = $0919
TFS_PEND_BKIND = $091A
TFS_PEND_BID = $091B


; ===================================================================
; tighten_from_records — segment-record consumer (3-cursor walk).
;
; Records (4 bytes each: xl, yl, xr, yr) are one-per-surviving-segment
; written by dcl_emit_segment. This routine walks the pool together
; with monotonic top + bot record cursors, building a brand-new pool
; list span-by-span:
;
;   both top and bot dom  → span = (T_rec.top, B_rec.bot), no pool needed
;   only top dom           → span = (T_rec.top, pool.bot)
;   only bot dom           → span = (pool.top,  B_rec.bot)
;   neither dom            → span = pool unchanged (one fragment)
;
; Adjacent emitted spans are merged when their TOP and BOT sources
; (kind + id) match — this is the lossless-merge condition because
; same-source guarantees same line equation and hence same slope.
; ===================================================================
tighten_from_records:
.scope
; Invalidate the has_gap coherence cache (see span_mark_solid note).
ZERO zp_hg_cache
LDA zp_head
STA zp_old_cur
LDA #0
STA zp_new_tail
STA zp_head
LDA #$FF
STA zp_tg_cont

; Init top/bot cursors and buffer-end offsets.
LDA TOP_RECORDS
BEQ tfs_no_top
LDA #1
STA TFS_T_CUR
JMP tfs_top_be
tfs_no_top:
LDA #0
STA TFS_T_CUR
tfs_top_be:
LDA TOP_RECORDS
ASL A
ASL A
BUMP
STA TFS_TOP_BUFEND
LDA BOT_RECORDS
BEQ tfs_no_bot
LDA #1
STA TFS_B_CUR
JMP tfs_bot_be
tfs_no_bot:
LDA #0
STA TFS_B_CUR
tfs_bot_be:
LDA BOT_RECORDS
ASL A
ASL A
BUMP
STA TFS_BOT_BUFEND

; No pending output span yet.
ZERO TFS_PEND_ACT

LDX zp_old_cur
tfs_walk:
BNE tfs_proc
JMP tfs_finish
tfs_proc:
LDA POOL_NEXT,X
STA zp_old_cur
STX zp_clr_save_x

; Out-of-range check.
LDA POOL_XEND,X
CMP zp_ilo
BCC tfs_oor
BEQ tfs_oor
LDA POOL_XSTART,X
CMP zp_ihi
BCC tfs_in_range
tfs_oor:
JSR tfs_flush_pending
LDX zp_clr_save_x
JSR tg_append_x
JMP tfs_continue
tfs_in_range:

; Pre-fragment [span.xstart, ilo] if span.xstart < ilo.
LDA POOL_XSTART,X
CMP zp_ilo
BCS tfs_no_pre
JSR tfs_flush_pending
LDX zp_clr_save_x
LDA POOL_XSTART,X
STA zp_ox0
LDA zp_ilo
STA zp_ox1
JSR emit_unchanged_subspan
LDA zp_ilo
STA TFS_CUR_X
JMP tfs_xhi_done
tfs_no_pre:
LDX zp_clr_save_x
LDA POOL_XSTART,X
STA TFS_CUR_X
tfs_xhi_done:

; x_hi = min(span.xend, ihi).
LDX zp_clr_save_x
LDA POOL_XEND,X
CMP zp_ihi
BCC tfs_xhi_xend
LDA zp_ihi
STA TFS_X_HI
JMP tfs_xhi_set
tfs_xhi_xend:
STA TFS_X_HI
tfs_xhi_set:

; Fast path: if NEITHER top nor bot record overlaps [cur_x, x_hi],
; emit the pool span unchanged and skip the interp inner loop.
; A record at the cursor doesn't overlap if its xl >= x_hi (segment
; starts past us). T_CUR == 0 also means no overlap.
LDA TFS_T_CUR
BEQ tfs_fp_chk_bot
TAY
LDA TOP_RECORDS,Y
CMP TFS_X_HI
BCC tfs_inner
; T.xl < x_hi → overlap
tfs_fp_chk_bot:
LDA TFS_B_CUR
BEQ tfs_fp_emit
TAY
LDA BOT_RECORDS,Y
CMP TFS_X_HI
BCC tfs_inner
tfs_fp_emit:
JSR tfs_flush_pending
LDX zp_clr_save_x
LDA TFS_CUR_X
STA zp_ox0
LDA TFS_X_HI
STA zp_ox1
JSR emit_unchanged_subspan
JMP tfs_inner_done

tfs_inner:
LDA TFS_CUR_X
CMP TFS_X_HI
BCC tfs_inner_go
JMP tfs_inner_done
tfs_inner_go:

; ---- Determine top_dom (T.xl <= cur_x < T.xr) ----
ZERO TFS_TOP_DOM
LDA TFS_T_CUR
BEQ tfs_top_dom_done
TAY
LDA TOP_RECORDS,Y
; T.xl
CMP TFS_CUR_X
BEQ tfs_top_chk_xr
BCS tfs_top_dom_done
tfs_top_chk_xr:
INY
INY
LDA TOP_RECORDS,Y
; T.xr
CMP TFS_CUR_X
BCC tfs_top_dom_done
BEQ tfs_top_dom_done
LDA #1
STA TFS_TOP_DOM
tfs_top_dom_done:

; ---- Determine bot_dom ----
ZERO TFS_BOT_DOM
LDA TFS_B_CUR
BEQ tfs_bot_dom_done
TAY
LDA BOT_RECORDS,Y
CMP TFS_CUR_X
BEQ tfs_bot_chk_xr
BCS tfs_bot_dom_done
tfs_bot_chk_xr:
INY
INY
LDA BOT_RECORDS,Y
CMP TFS_CUR_X
BCC tfs_bot_dom_done
BEQ tfs_bot_dom_done
LDA #1
STA TFS_BOT_DOM
tfs_bot_dom_done:

; ---- next_x = min(x_hi, top event, bot event) ----
LDA TFS_X_HI
STA TFS_NEXT_X
LDA TFS_T_CUR
BEQ tfs_skip_top_evt
LDA TFS_TOP_DOM
BNE tfs_top_evt_xr
LDY TFS_T_CUR
LDA TOP_RECORDS,Y
; not yet dom: candidate = T.xl
JMP tfs_top_evt_check
tfs_top_evt_xr:
LDA TFS_T_CUR
CLC
ADC #2
TAY
; dom: candidate = T.xr
LDA TOP_RECORDS,Y
tfs_top_evt_check:
CMP TFS_NEXT_X
BCS tfs_skip_top_evt
STA TFS_NEXT_X
tfs_skip_top_evt:
LDA TFS_B_CUR
BEQ tfs_skip_bot_evt
LDA TFS_BOT_DOM
BNE tfs_bot_evt_xr
LDY TFS_B_CUR
LDA BOT_RECORDS,Y
JMP tfs_bot_evt_check
tfs_bot_evt_xr:
LDA TFS_B_CUR
CLC
ADC #2
TAY
LDA BOT_RECORDS,Y
tfs_bot_evt_check:
CMP TFS_NEXT_X
BCS tfs_skip_bot_evt
STA TFS_NEXT_X
tfs_skip_bot_evt:

; ---- Per-interval fast path: both sides from pool → emit unchanged.
; Saves the 4 interps the normal path would do for a pool/pool sub-
; fragment (the parts of a pool span that records don't dominate).
LDA TFS_TOP_DOM
ORA TFS_BOT_DOM
BNE tfs_compute_vals
JSR tfs_flush_pending
LDX zp_clr_save_x
LDA TFS_CUR_X
STA zp_ox0
LDA TFS_NEXT_X
STA zp_ox1
JSR emit_unchanged_subspan
JMP tfs_advance_curs
tfs_compute_vals:

; ---- Compute top values for [cur_x, next_x] ----
LDA TFS_TOP_DOM
BEQ tfs_top_pool
; top from record T_CUR: read (xl, yl, xr, yr) and interp.
; Segment endpoints are on the original yt-line (DCL computes them with
; the same interp_store used here), so interp between them recovers the
; line's geometry. Small u8-rounding aliasing at sub-segment fragments
; can shift a pixel; this is inherent to integer interp.
LDY TFS_T_CUR
LDA TOP_RECORDS,Y
STA zp_i_x0
INY
LDA TOP_RECORDS,Y
STA zp_i_y0
INY
LDA TOP_RECORDS,Y
STA zp_tmp0
INY
LDA TOP_RECORDS,Y
STA zp_i_y1
LDA zp_tmp0
SEC
SBC zp_i_x0
STA zp_div_den
LDA TFS_CUR_X
JSR interp_store
STA TFS_TOP_L
LDA TFS_NEXT_X
JSR interp_store
STA TFS_TOP_R
LDA #1
STA TFS_TOP_KIND
LDA TFS_T_CUR
STA TFS_TOP_ID
JMP tfs_top_vals_done
tfs_top_pool:
LDX zp_clr_save_x
LDA POOL_XLO,X
STA zp_i_x0
LDA POOL_TL,X
STA zp_i_y0
LDA POOL_TR,X
STA zp_i_y1
LDA POOL_DEN,X
STA zp_div_den
LDA TFS_CUR_X
JSR interp_store
STA TFS_TOP_L
LDA TFS_NEXT_X
JSR interp_store
STA TFS_TOP_R
ZERO TFS_TOP_KIND
LDA zp_clr_save_x
STA TFS_TOP_ID
tfs_top_vals_done:

; ---- Compute bot values for [cur_x, next_x] ----
LDA TFS_BOT_DOM
BEQ tfs_bot_pool
LDY TFS_B_CUR
LDA BOT_RECORDS,Y
STA zp_i_x0
INY
LDA BOT_RECORDS,Y
STA zp_i_y0
INY
LDA BOT_RECORDS,Y
STA zp_tmp0
INY
LDA BOT_RECORDS,Y
STA zp_i_y1
LDA zp_tmp0
SEC
SBC zp_i_x0
STA zp_div_den
LDA TFS_CUR_X
JSR interp_store
STA TFS_BOT_L
LDA TFS_NEXT_X
JSR interp_store
STA TFS_BOT_R
LDA #1
STA TFS_BOT_KIND
LDA TFS_B_CUR
STA TFS_BOT_ID
JMP tfs_bot_vals_done
tfs_bot_pool:
LDX zp_clr_save_x
LDA POOL_XLO,X
STA zp_i_x0
LDA POOL_BL,X
STA zp_i_y0
LDA POOL_BR,X
STA zp_i_y1
LDA POOL_DEN,X
STA zp_div_den
LDA TFS_CUR_X
JSR interp_store
STA TFS_BOT_L
LDA TFS_NEXT_X
JSR interp_store
STA TFS_BOT_R
ZERO TFS_BOT_KIND
LDA zp_clr_save_x
STA TFS_BOT_ID
tfs_bot_vals_done:

; ---- Try to merge with pending ----
LDA TFS_PEND_ACT
BEQ tfs_start_pend
LDA TFS_PEND_XR
CMP TFS_CUR_X
BNE tfs_no_merge
LDA TFS_PEND_TKIND
CMP TFS_TOP_KIND
BNE tfs_no_merge
LDA TFS_PEND_TID
CMP TFS_TOP_ID
BNE tfs_no_merge
LDA TFS_PEND_BKIND
CMP TFS_BOT_KIND
BNE tfs_no_merge
LDA TFS_PEND_BID
CMP TFS_BOT_ID
BNE tfs_no_merge
; Merge: extend pending right edge.
LDA TFS_NEXT_X
STA TFS_PEND_XR
LDA TFS_TOP_R
STA TFS_PEND_TR
LDA TFS_BOT_R
STA TFS_PEND_BR
JMP tfs_advance_curs
tfs_no_merge:
JSR tfs_flush_pending
tfs_start_pend:
LDA #1
STA TFS_PEND_ACT
LDA TFS_CUR_X
STA TFS_PEND_XL
LDA TFS_NEXT_X
STA TFS_PEND_XR
LDA TFS_TOP_L
STA TFS_PEND_TL
LDA TFS_TOP_R
STA TFS_PEND_TR
LDA TFS_BOT_L
STA TFS_PEND_BL
LDA TFS_BOT_R
STA TFS_PEND_BR
LDA TFS_TOP_KIND
STA TFS_PEND_TKIND
LDA TFS_TOP_ID
STA TFS_PEND_TID
LDA TFS_BOT_KIND
STA TFS_PEND_BKIND
LDA TFS_BOT_ID
STA TFS_PEND_BID

tfs_advance_curs:
; Advance T_CUR if next_x crossed T.xr.
LDA TFS_T_CUR
BEQ tfs_skip_t_adv
LDA TFS_TOP_DOM
BEQ tfs_skip_t_adv
LDA TFS_T_CUR
CLC
ADC #2
TAY
LDA TOP_RECORDS,Y
CMP TFS_NEXT_X
BNE tfs_skip_t_adv
LDA TFS_T_CUR
CLC
ADC #4
CMP TFS_TOP_BUFEND
BCC tfs_t_adv_ok
LDA #0
tfs_t_adv_ok:
STA TFS_T_CUR
tfs_skip_t_adv:
LDA TFS_B_CUR
BEQ tfs_skip_b_adv
LDA TFS_BOT_DOM
BEQ tfs_skip_b_adv
LDA TFS_B_CUR
CLC
ADC #2
TAY
LDA BOT_RECORDS,Y
CMP TFS_NEXT_X
BNE tfs_skip_b_adv
LDA TFS_B_CUR
CLC
ADC #4
CMP TFS_BOT_BUFEND
BCC tfs_b_adv_ok
LDA #0
tfs_b_adv_ok:
STA TFS_B_CUR
tfs_skip_b_adv:

LDA TFS_NEXT_X
STA TFS_CUR_X
JMP tfs_inner

tfs_inner_done:

; Post-fragment [ihi, span.xend] if span.xend > ihi.
LDX zp_clr_save_x
LDA POOL_XEND,X
CMP zp_ihi
BCC tfs_no_post
BEQ tfs_no_post
JSR tfs_flush_pending
LDX zp_clr_save_x
LDA zp_ihi
STA zp_ox0
LDA POOL_XEND,X
STA zp_ox1
JSR emit_unchanged_subspan
tfs_no_post:

; Free original pool span (its replacements are now in the new list).
LDX zp_clr_save_x
JSR free_span

tfs_continue:
LDA zp_old_cur
TAX
JMP tfs_walk

tfs_finish:
JMP tfs_flush_pending                   ; tail call (was JSR+RTS): -9 cyc
.endscope

; ---- Flush pending output span: alloc, populate fields, append. ----
tfs_flush_pending:
.scope
LDA TFS_PEND_ACT
BNE flush_do
RTS
flush_do:
LDA #0
STA TFS_PEND_ACT
JSR alloc_span
BEQ flush_fail
LDA TFS_PEND_XL
STA POOL_XSTART,X
STA POOL_XLO,X
LDA TFS_PEND_XR
STA POOL_XEND,X
SEC
SBC TFS_PEND_XL
STA POOL_DEN,X
LDA TFS_PEND_TL
STA POOL_TL,X
LDA TFS_PEND_TR
STA POOL_TR,X
LDA TFS_PEND_BL
STA POOL_BL,X
LDA TFS_PEND_BR
STA POOL_BR,X
; OT = min(TL,TR), IT = max(TL,TR), OB = max(BL,BR), IB = min(BL,BR).
LDA TFS_PEND_TL
CMP TFS_PEND_TR
BCC fp_ot
LDA TFS_PEND_TR
fp_ot:
STA POOL_OT,X
LDA TFS_PEND_TL
CMP TFS_PEND_TR
BCS fp_it
LDA TFS_PEND_TR
fp_it:
STA POOL_IT,X
LDA TFS_PEND_BL
CMP TFS_PEND_BR
BCS fp_ob
LDA TFS_PEND_BR
fp_ob:
STA POOL_OB,X
LDA TFS_PEND_BL
CMP TFS_PEND_BR
BCC fp_ib
LDA TFS_PEND_BR
fp_ib:
STA POOL_IB,X
JSR tg_append_x
flush_fail:
RTS
.endscope

; Emit unchanged sub-span [zp_ox0, zp_ox1] with old span's line def.
emit_unchanged_subspan:
JSR alloc_span
BEQ ues_fail
LDY zp_clr_save_x
LDA POOL_XLO,Y
STA POOL_XLO,X
LDA POOL_DEN,Y
STA POOL_DEN,X
LDA POOL_TL,Y
STA POOL_TL,X
LDA POOL_BL,Y
STA POOL_BL,X
LDA POOL_TR,Y
STA POOL_TR,X
LDA POOL_BR,Y
STA POOL_BR,X
LDA POOL_OT,Y
STA POOL_OT,X
LDA POOL_OB,Y
STA POOL_OB,X
LDA POOL_IT,Y
STA POOL_IT,X
LDA POOL_IB,Y
STA POOL_IB,X
LDA zp_ox0
STA POOL_XSTART,X
LDA zp_ox1
STA POOL_XEND,X
JSR tg_append_x
ues_fail:
RTS


; ===================================================================
; s16 line clipper — generic first cut
;
; Wrapper writes 8 bytes of s16 input (4 endpoints × 2 bytes) to
; LC_X1_LO..LC_Y2_HI in scratch RAM, then JSRs $201E. Routine clips
; line to u8 [0,255]×[0,255], writes u8 result to zp_line_xl/yl/xr/yr,
; then falls through to draw_clipped_line (existing DCL pipeline).
;
; The math is the slow generic version: u16×u16 = u32, u32÷u16 = u16.
; A `project_clip_arithmetic_fastpath` memo notes the obvious fast
; paths to add later (u8-fits-operand, trivial offset==0/den cases,
; early-exit divide when leading zeros guarantee u8 quotient).
; ===================================================================

; ---- s16 line input (wrapper writes these) ----
; Lo bytes alias zp_line_* (the same u8 slots DCL reads). Hi bytes
; alias the CB-clip / tighten-secondary ZP block ($B2-$B5) — those
; slots are used DOWNSTREAM of the s16 clipper (DCL clobbers them
; during emission), but the wrapper rewrites them before each call,
; so there's no conflict. ZP access shaves ~7 cycles off the in-range
; fast-path detect (4 ORAs of zp vs absolute).
LC_X1_LO = zp_line_xl
LC_Y1_LO = zp_line_yl
LC_X2_LO = zp_line_xr
LC_Y2_LO = zp_line_yr
; ---- saved originals for interp (snapped at start of x-clip / y-clip) ----
LC_OX1_LO = $0938
LC_OX1_HI = $0939
LC_OY1_LO = $093A
LC_OY1_HI = $093B
LC_OX2_LO = $093C
LC_OX2_HI = $093D
LC_OY2_LO = $093E
LC_OY2_HI = $093F
; ---- math working ----
LC_OFF_LO = $0940
LC_OFF_HI = $0941
LC_DEN_LO = $0942
LC_DEN_HI = $0943
LC_DY_LO = $0944
LC_DY_HI = $0945
LC_DY_NEG = $0946
LC_M_A_LO = $0947
LC_M_A_HI = $0948
LC_M_B_LO = $0949
LC_M_B_HI = $094A
LC_M_R0 = $094B
LC_M_R1 = $094C
LC_M_R2 = $094D
LC_M_R3 = $094E
LC_QUOT_LO = $094F
LC_QUOT_HI = $0950
LC_REM_LO = $0951
LC_REM_HI = $0952
LC_TMP_LO = $0953
LC_TMP_HI = $0954
LC_RES_LO = $0955
LC_RES_HI = $0956
LC_TGT_LO = $0957                       ; clip target value (s16)
LC_TGT_HI = $0958
