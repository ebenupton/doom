
; --- DCL records hook helpers ---

; Write CB-clip records. Inputs: X = span slot,
;   zp_ox0, zp_ox1 = span overlap range
;   zp_cb_cx1, zp_cb_cy1 = visible portion left endpoint
;   zp_cb_cx2, zp_cb_cy2 = visible portion right endpoint
;   zp_cb_top1, zp_cb_bot1 = span aperture at cx1
;   zp_cb_top2, zp_cb_bot2 = span aperture at cx2
; Writes 1-3 records: optional 'above'/'below' for [ox0, cb_cx1],
; mandatory 'inside' for [cb_cx1, cb_cx2], optional 'above'/'below'
; for [cb_cx2, ox1]. Determines above/below by comparing cb_cy{1,2}
; with cb_top{1,2} / cb_bot{1,2} — no interp needed (already computed).
dcl_record_cb_clip:
.scope
LDY zp_dcl_rec_buf_h
BNE cb_continue
; (was BEQ+JMP)
cb_done_tramp:
RTS
cb_continue:
; --- Outer left fragment [ox0, cb_cx1] (if cb_cx1 > ox0) ---
LDA zp_ox0
CMP zp_cb_cx1
BCS no_outer_left
; Determine 'above' (cb_cy1 == cb_top1) or 'below' (cb_cy1 == cb_bot1).
LDA #REC_VERDICT_ABOVE
LDY zp_cb_cy1
CPY zp_cb_top1
BEQ ol_have_v
LDA #REC_VERDICT_BELOW
ol_have_v:
LDY zp_dcl_rec_off
PHA                                     ; save verdict
TXA
STA (zp_dcl_rec_buf),Y
INY
; si
LDA zp_ox0
STA (zp_dcl_rec_buf),Y
INY
LDA zp_cb_cx1
STA (zp_dcl_rec_buf),Y
INY
PLA
STA (zp_dcl_rec_buf),Y
INY
; verdict
LDA #0
STA (zp_dcl_rec_buf),Y
INY
STA (zp_dcl_rec_buf),Y
INY
STY zp_dcl_rec_off
LDY #0
LDA (zp_dcl_rec_buf),Y
BUMP
STA (zp_dcl_rec_buf),Y
no_outer_left:
; --- Inside fragment [cb_cx1, cb_cx2] ---
LDY zp_dcl_rec_off
TXA
STA (zp_dcl_rec_buf),Y
INY
LDA zp_cb_cx1
STA (zp_dcl_rec_buf),Y
INY
LDA zp_cb_cx2
STA (zp_dcl_rec_buf),Y
INY
LDA #REC_VERDICT_INSIDE
STA (zp_dcl_rec_buf),Y
INY
LDA zp_cb_cy1
STA (zp_dcl_rec_buf),Y
INY
LDA zp_cb_cy2
STA (zp_dcl_rec_buf),Y
INY
STY zp_dcl_rec_off
LDY #0
LDA (zp_dcl_rec_buf),Y
BUMP
STA (zp_dcl_rec_buf),Y
; --- Outer right fragment [cb_cx2, ox1] (if cb_cx2 < ox1) ---
LDA zp_cb_cx2
CMP zp_ox1
BCS no_outer_right
LDA #REC_VERDICT_ABOVE
LDY zp_cb_cy2
CPY zp_cb_top2
BEQ or_have_v
LDA #REC_VERDICT_BELOW
or_have_v:
LDY zp_dcl_rec_off
PHA
TXA
STA (zp_dcl_rec_buf),Y
INY
LDA zp_cb_cx2
STA (zp_dcl_rec_buf),Y
INY
LDA zp_ox1
STA (zp_dcl_rec_buf),Y
INY
PLA
STA (zp_dcl_rec_buf),Y
INY
LDA #0
STA (zp_dcl_rec_buf),Y
INY
STA (zp_dcl_rec_buf),Y
INY
STY zp_dcl_rec_off
LDY #0
LDA (zp_dcl_rec_buf),Y
BUMP
STA (zp_dcl_rec_buf),Y
no_outer_right:
done:
RTS
.endscope

; Write 'above'/'below' record. Caller already checked records enabled.
; Inputs: A = verdict (ABOVE or BELOW), X = span slot, zp_ox0/zp_ox1 set.
dcl_record_outside:
.scope
LDY zp_dcl_rec_buf_h
BEQ done
PHA                                     ; save verdict
LDY zp_dcl_rec_off
TXA
STA (zp_dcl_rec_buf),Y
INY
; si
LDA zp_ox0
STA (zp_dcl_rec_buf),Y
INY
LDA zp_ox1
STA (zp_dcl_rec_buf),Y
INY
PLA
STA (zp_dcl_rec_buf),Y
INY
; verdict
LDA #0
STA (zp_dcl_rec_buf),Y
INY
; cy0 (unused)
STA (zp_dcl_rec_buf),Y
INY
; cy1 (unused)
STY zp_dcl_rec_off
LDY #0
LDA (zp_dcl_rec_buf),Y
BUMP
STA (zp_dcl_rec_buf),Y
done:
RTS
.endscope

; Write 'inside' record at continuation. cy0 = line_y at ox0, cy1 = line_y at ox1.
; Both interps required — DCL doesn't track cy at span seams in continuation.
; Optimization: ox0 == line_xl is rare in continuation (continuation means
; line started before this span). ox1 == line_xr is common when line ends
; in this span (line_ends path).
; Inputs: X = span slot, zp_ox0/zp_ox1 set.
dcl_record_inside_continuation:
.scope
STX zp_save0                            ; save span slot
; cy at ox0
LDA zp_ox0
CMP zp_line_xl
BEQ cont_use_yl_lo
JSR dcl_line_y_at_a
JMP cont_have_cy0
cont_use_yl_lo:
LDA zp_line_yl
cont_have_cy0:
PHA                                     ; save cy0
; cy at ox1
LDX zp_save0
LDA zp_ox1
CMP zp_line_xr
BEQ cont_use_yr_hi
JSR dcl_line_y_at_a
JMP cont_have_cy1
cont_use_yr_hi:
LDA zp_line_yr
cont_have_cy1:
PHA                                     ; save cy1
; Write record
LDX zp_save0
LDY zp_dcl_rec_off
TXA
STA (zp_dcl_rec_buf),Y
INY
; si
LDA zp_ox0
STA (zp_dcl_rec_buf),Y
INY
LDA zp_ox1
STA (zp_dcl_rec_buf),Y
INY
LDA #REC_VERDICT_INSIDE
STA (zp_dcl_rec_buf),Y
INY
PLA
TAX
PLA
; X=cy1, A=cy0
STA (zp_dcl_rec_buf),Y
INY
; cy0
TXA
STA (zp_dcl_rec_buf),Y
INY
; cy1
STY zp_dcl_rec_off
LDY #0
LDA (zp_dcl_rec_buf),Y
BUMP
STA (zp_dcl_rec_buf),Y
LDX zp_save0
RTS
.endscope

; Write 'inside' record at dcl_accept. cy0 = zp_seg_start_y (= line_y at ox0,
; just set by accept logic). cy1 = line_y at ox1 (1 interp; OR zp_line_yr if
; ox1 == line_xr to avoid the interp).
; Inputs: X = span slot, zp_ox0/zp_ox1 set, zp_seg_start_y set.
dcl_record_inside_at_accept:
.scope
STX zp_save0                            ; save span slot
; Compute cy at ox1: if ox1 == line_xr, cy = line_yr (no interp); else interp.
LDA zp_ox1
CMP zp_line_xr
BEQ use_yr
JSR dcl_line_y_at_a                     ; A = line_y_at(ox1)
JMP write_record
use_yr:
LDA zp_line_yr
write_record:
PHA                                     ; save cy1
LDX zp_save0                            ; restore span slot
LDY zp_dcl_rec_off
TXA
STA (zp_dcl_rec_buf),Y
INY
; si
LDA zp_ox0
STA (zp_dcl_rec_buf),Y
INY
LDA zp_ox1
STA (zp_dcl_rec_buf),Y
INY
LDA #REC_VERDICT_INSIDE
STA (zp_dcl_rec_buf),Y
INY
LDA zp_seg_start_y
STA (zp_dcl_rec_buf),Y
INY
; cy0
PLA
STA (zp_dcl_rec_buf),Y
INY
; cy1
STY zp_dcl_rec_off
LDY #0
LDA (zp_dcl_rec_buf),Y
BUMP
STA (zp_dcl_rec_buf),Y
LDX zp_save0
RTS
.endscope

clip_line_records:
.scope
; --- Initialise records buffer: count=0, write offset=1 ---
LDY #0
LDA #0
STA (zp_buf),Y
STA zp_clr_count
LDA #1
STA zp_clr_offset

; Caller is responsible for line endpoint ordering. We don't swap here:
; sx2 may legitimately be > 255 (u8 wraps to look smaller than sx1) when
; the seg extends off-screen. interp_store handles via u8 SBC which wraps
; correctly to give the right den = (sx2 - sx1) mod 256.

; --- Walk active span list ---
LDX zp_head
clr_walk:
BNE clr_process
JMP clr_done                            ; X=0 → end of list
clr_process:
STX zp_clr_save_x                       ; save X early so clr_next can reload it
; Skip span if no overlap with [ilo, ihi].
; pixel-center: xe <= ilo or xs >= ihi → no overlap.
LDA POOL_XEND,X
CMP zp_ilo
BCC clr_skip_tramp
BEQ clr_skip_tramp
LDA POOL_XSTART,X
CMP zp_ihi
BCC clr_in_range
clr_skip_tramp:
JMP clr_next
clr_in_range:

; --- Compute ox0 = max(POOL_XSTART,X, ilo) ---
LDA POOL_XSTART,X
CMP zp_ilo
BCS clr_ox0_ok
LDA zp_ilo
clr_ox0_ok:
STA zp_ox0

; --- Compute ox1 = min(POOL_XEND,X, ihi) ---
LDA POOL_XEND,X
CMP zp_ihi
BCC clr_ox1_ok
LDA zp_ihi
clr_ox1_ok:
STA zp_ox1

; --- Compute line y at ox0 / ox1 (cy0, cy1) ---
; Setup interp params for line: x0=line_xl, den=line_xr-line_xl, y0=line_yl, y1=line_yr.
LDA zp_line_xl
STA zp_i_x0
LDA zp_line_xr
SEC
SBC zp_line_xl
STA zp_div_den
LDA zp_line_yl
STA zp_i_y0
LDA zp_line_yr
STA zp_i_y1
LDA zp_ox0
JSR interp_store
STA zp_clr_cy0
LDA zp_ox1
JSR interp_store
STA zp_clr_cy1

; --- Compute span_top at ox0 / ox1 (otl, otr) ---
LDX zp_clr_save_x
LDA POOL_XLO,X
STA zp_i_x0
LDA POOL_DEN,X
STA zp_div_den
LDA POOL_TL,X
STA zp_i_y0
LDA POOL_TR,X
STA zp_i_y1
LDA zp_ox0
JSR interp_store
STA zp_clr_otl
LDA zp_ox1
JSR interp_store
STA zp_clr_otr

; --- Compute span_bot at ox0 / ox1 (obl, obr) ---
LDX zp_clr_save_x
LDA POOL_BL,X
STA zp_i_y0
LDA POOL_BR,X
STA zp_i_y1
LDA zp_ox0
JSR interp_store
STA zp_clr_obl
LDA zp_ox1
JSR interp_store
STA zp_clr_obr

; --- Detect top crossing: dt = cy - top, sign change ⇒ crossing ---
; Compute |dt0|, |dt1| as u16 in zp_tmp0/1 and zp_tmp2/3 (compute_crossover args).
; dt0 = cy0 - otl. dt1 = cy1 - otr.
LDA zp_clr_cy0
SEC
SBC zp_clr_otl
STA zp_tmp0
LDA #0
SBC #0
STA zp_tmp1
; sign-extend (carry from SBC gives s8→s16)
BPL clr_dt0_pos                         ; dt0 >= 0: keep
SEC
LDA #0
SBC zp_tmp0
STA zp_tmp0
LDA #0
SBC zp_tmp1
STA zp_tmp1
clr_dt0_pos:
LDA zp_clr_cy1
SEC
SBC zp_clr_otr
STA zp_tmp2
LDA #0
SBC #0
STA zp_tmp3
BPL clr_dt1_pos
SEC
LDA #0
SBC zp_tmp2
STA zp_tmp2
LDA #0
SBC zp_tmp3
STA zp_tmp3
clr_dt1_pos:
; Sign change check: was original dt0 sign != dt1 sign?
; Re-derive from raw bytes: high bit of (cy-top) before abs.
; Simpler: redo the sign check via direct compare.
ZERO zp_clr_cx_t
LDA zp_clr_cy0
CMP zp_clr_otl
PHP                                     ; save N flag (cy0 < otl)
LDA zp_clr_cy1
CMP zp_clr_otr
BCS clr_t_signs_known                   ; cy1 >= otr: dt1 >= 0
; cy1 < otr: dt1 < 0
PLP
BCS clr_top_cross
; cy0 >= otl, cy1 < otr → cross
BCC clr_no_top_cross                    ; both < (above)
clr_t_signs_known:
PLP
BCC clr_top_cross
; cy0 < otl, cy1 >= otr → cross
clr_no_top_cross:
JMP clr_check_bot
clr_top_cross:
; |dt0|, |dt1| already in tmp0/1 and tmp2/3. compute_crossover.
JSR compute_crossover
STA zp_clr_cx_t

clr_check_bot:
; Same logic for bot: db = cy - bot, sign change ⇒ crossing.
LDA zp_clr_cy0
SEC
SBC zp_clr_obl
STA zp_tmp0
LDA #0
SBC #0
STA zp_tmp1
BPL clr_db0_pos
SEC
LDA #0
SBC zp_tmp0
STA zp_tmp0
LDA #0
SBC zp_tmp1
STA zp_tmp1
clr_db0_pos:
LDA zp_clr_cy1
SEC
SBC zp_clr_obr
STA zp_tmp2
LDA #0
SBC #0
STA zp_tmp3
BPL clr_db1_pos
SEC
LDA #0
SBC zp_tmp2
STA zp_tmp2
LDA #0
SBC zp_tmp3
STA zp_tmp3
clr_db1_pos:
ZERO zp_clr_cx_b
LDA zp_clr_cy0
CMP zp_clr_obl
PHP
LDA zp_clr_cy1
CMP zp_clr_obr
BCS clr_b_signs_known
PLP
BCS clr_bot_cross
BCC clr_no_bot_cross
clr_b_signs_known:
PLP
BCC clr_bot_cross
clr_no_bot_cross:
JMP clr_emit_subranges
clr_bot_cross:
JSR compute_crossover
STA zp_clr_cx_b

clr_emit_subranges:
; --- Emit sub-records for sub-ranges ---
; Up to 3 sub-ranges based on (cx_t, cx_b) crossings.
; Case 0 (no crossings): [ox0, ox1] only.
; Case T (top only):     [ox0, cx_t], [cx_t, ox1].
; Case B (bot only):     [ox0, cx_b], [cx_b, ox1].
; Case TB (both):        sorted at min(cx_t, cx_b), max(cx_t, cx_b).
LDA zp_clr_cx_t
BNE clr_has_cx_t
LDA zp_clr_cx_b
BNE clr_only_cx_b
; Case 0: no crossings. Single sub-range.
LDA zp_ox0
STA zp_clr_slo
LDA zp_ox1
STA zp_clr_shi
JSR clr_emit_one_subrange
JMP clr_next
clr_only_cx_b:
; Case B: bot only.
LDA zp_ox0
STA zp_clr_slo
LDA zp_clr_cx_b
STA zp_clr_shi
JSR clr_emit_one_subrange
LDA zp_clr_cx_b
STA zp_clr_slo
LDA zp_ox1
STA zp_clr_shi
JSR clr_emit_one_subrange
JMP clr_next
clr_has_cx_t:
LDA zp_clr_cx_b
BNE clr_both_cx
; Case T: top only.
LDA zp_ox0
STA zp_clr_slo
LDA zp_clr_cx_t
STA zp_clr_shi
JSR clr_emit_one_subrange
LDA zp_clr_cx_t
STA zp_clr_slo
LDA zp_ox1
STA zp_clr_shi
JSR clr_emit_one_subrange
JMP clr_next
clr_both_cx:
; Case TB: both crossings. Sort cx_t, cx_b → 3 sub-ranges.
LDA zp_clr_cx_t
CMP zp_clr_cx_b
BCC clr_t_first
; cx_t >= cx_b: order [ox0, cx_b], [cx_b, cx_t], [cx_t, ox1].
LDA zp_ox0
STA zp_clr_slo
LDA zp_clr_cx_b
STA zp_clr_shi
JSR clr_emit_one_subrange
LDA zp_clr_cx_b
STA zp_clr_slo
LDA zp_clr_cx_t
STA zp_clr_shi
JSR clr_emit_one_subrange
LDA zp_clr_cx_t
STA zp_clr_slo
LDA zp_ox1
STA zp_clr_shi
JSR clr_emit_one_subrange
JMP clr_next
clr_t_first:
; cx_t < cx_b: order [ox0, cx_t], [cx_t, cx_b], [cx_b, ox1].
LDA zp_ox0
STA zp_clr_slo
LDA zp_clr_cx_t
STA zp_clr_shi
JSR clr_emit_one_subrange
LDA zp_clr_cx_t
STA zp_clr_slo
LDA zp_clr_cx_b
STA zp_clr_shi
JSR clr_emit_one_subrange
LDA zp_clr_cx_b
STA zp_clr_slo
LDA zp_ox1
STA zp_clr_shi
JSR clr_emit_one_subrange

clr_next:
; Move to next span
LDX zp_clr_save_x
LDA POOL_NEXT,X
TAX
JMP clr_walk

clr_done:
; Write final count to buffer[0]
LDA zp_clr_count
LDY #0
STA (zp_buf),Y
RTS
.endscope

; --- Helper: emit one sub-record for [zp_clr_slo, zp_clr_shi] ---
; Determines verdict based on cy_lo/cy_hi vs t_lo/t_hi/b_lo/b_hi.
; Writes record to buffer at offset zp_clr_offset, increments offset and count.
; ===== emit_one_subrange ZP =====
; Avoid zp_tmp0..3 ($DE-$E1) — umul8 clobbers zp_tmp0; other helpers use $DE-E1.
; Use $B6-$B9 (CB clip slots, free during records mode) and $E5-$E7 (safe scratch).

clr_emit_one_subrange:
.scope
; Compute cy_lo, cy_hi, t_lo, t_hi, b_lo, b_hi at slo/shi.
; Setup line interp params.
LDA zp_line_xl
STA zp_i_x0
LDA zp_line_xr
SEC
SBC zp_line_xl
STA zp_div_den
LDA zp_line_yl
STA zp_i_y0
LDA zp_line_yr
STA zp_i_y1
LDA zp_clr_slo
JSR interp_store
STA zp_eos_cy_lo
LDA zp_clr_shi
JSR interp_store
STA zp_eos_cy_hi

; Span top at slo/shi.
LDX zp_clr_save_x
LDA POOL_XLO,X
STA zp_i_x0
LDA POOL_DEN,X
STA zp_div_den
LDA POOL_TL,X
STA zp_i_y0
LDA POOL_TR,X
STA zp_i_y1
LDA zp_clr_slo
JSR interp_store
STA zp_eos_t_lo
LDA zp_clr_shi
JSR interp_store
STA zp_eos_t_hi

; Span bot at slo/shi.
LDX zp_clr_save_x
LDA POOL_BL,X
STA zp_i_y0
LDA POOL_BR,X
STA zp_i_y1
LDA zp_clr_slo
JSR interp_store
STA zp_eos_b_lo
LDA zp_clr_shi
JSR interp_store
STA zp_eos_b_hi

; Verdict determination:
;   cy_lo <= t_lo AND cy_hi <= t_hi  → 'above'
;   cy_lo >= b_lo AND cy_hi >= b_hi  → 'below'
;   else                              → 'inside' (store cy_lo, cy_hi)
LDA zp_eos_cy_lo
CMP zp_eos_t_lo
BEQ chk_top_eq_l
BCS chk_below
chk_top_eq_l:
LDA zp_eos_cy_hi
CMP zp_eos_t_hi
BEQ above_v
BCC above_v
chk_below:
LDA zp_eos_cy_lo
CMP zp_eos_b_lo
BCC inside_v
BEQ chk_bot_eq_l
LDA zp_eos_cy_hi
CMP zp_eos_b_hi
BCS below_v
BEQ below_v
JMP inside_v
chk_bot_eq_l:
LDA zp_eos_cy_hi
CMP zp_eos_b_hi
BCS below_v
BEQ below_v
inside_v:
LDA #REC_VERDICT_INSIDE
STA zp_eos_verdict
JMP write_record
above_v:
LDA #REC_VERDICT_ABOVE
STA zp_eos_verdict
JMP write_record
below_v:
LDA #REC_VERDICT_BELOW
STA zp_eos_verdict

write_record:
; Append 6-byte record at zp_clr_offset.
LDY zp_clr_offset
LDA zp_clr_save_x
STA (zp_buf),Y
INY
; si
LDA zp_clr_slo
STA (zp_buf),Y
INY
; sox0
LDA zp_clr_shi
STA (zp_buf),Y
INY
; sox1
LDA zp_eos_verdict
STA (zp_buf),Y
INY
; verdict
LDA zp_eos_cy_lo
STA (zp_buf),Y
INY
; cy0
LDA zp_eos_cy_hi
STA (zp_buf),Y
INY
; cy1
STY zp_clr_offset
INC zp_clr_count
RTS
.endscope

; ===== tighten_from_records ZP aliases =====
; Records-mode-only — reuse tighten ZP slots that aren't active concurrently.

; ===== Segment-records tighten scratch (RAM at $0900-$0921) =====
; Records are now ONE per surviving DCL segment (4 bytes: xl, yl, xr, yr).
; Tighten consumer is a 3-cursor walk: top recs, bot recs, pool spans.
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
