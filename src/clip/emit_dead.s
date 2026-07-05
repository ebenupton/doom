
; ======================================================================
; MS_EMIT_LINES: wall edge line emission for mark_solid
;
; Pre-pass over span list (read-only). For each span overlapping [ilo,ihi],
; evaluates the seg's top/bot lines and the span's top/bot boundaries at the
; overlap endpoints. Emits the seg line segment where it falls within the
; span's aperture.
;
; Uses same ZP seg params as tighten (sx1/sx2/yt1/yt2/yb1/yb2).
; Uses zp_save0 for current span offset, zp_save1 for ox0, zp_save2 for ox1.
; ======================================================================
.if ::EMIT_LINES
ms_emit_lines:
.scope
; NOTE: do NOT reset LINE_OUT_COUNT — draw_clipped_line may have
; already written lines before mark_solid was called.

; --- DCL-style seg Y bbox setup (one-time per mel call) ---
; Compute static seg bbox (max/min of yt1/yt2 and yb1/yb2) for the
; per-span "neither edge can emit" reject below.  Sentinels disable
; the check when:
;   - any yt/yb hi byte is non-zero (seg extends off-screen in u8)
;   - [sx1,sx2] doesn't cover [ilo,ihi] (overlap extrapolation
;     would invalidate the bbox bounds derived from yt1/yt2)
LDA zp_yt1h
ORA zp_yt2h
ORA zp_yb1h
ORA zp_yb2h
BNE mel_bbox_disable
; sx1 must be <= ilo (no left extrapolation).  sx1 negative covers
; this trivially; sx1 with hi=0 needs sx1 <= ilo.
LDA zp_sx1h
BMI mel_bbox_sx1_ok
BNE mel_bbox_disable                    ; sx1 > 255 → impossible
LDA zp_ilo
CMP zp_sx1
BCC mel_bbox_disable
; ilo < sx1 → extrap
mel_bbox_sx1_ok:
; sx2 must be >= ihi (no right extrapolation).
LDA zp_sx2h
BMI mel_bbox_disable
; sx2 < 0 → impossible
BNE mel_bbox_valid                      ; sx2 > 255 ≥ ihi → ok
LDA zp_sx2
CMP zp_ihi
BCC mel_bbox_disable
; sx2 < ihi → extrap
mel_bbox_valid:
; All hi bytes zero AND seg covers overlap — compute real bbox.
LDA zp_yt1
CMP zp_yt2
BCC mel_bbox_t_swap
STA zp_seg_top_max
LDX zp_yt2
STX zp_seg_top_min
BCS mel_bbox_t_done                     ; always taken
mel_bbox_t_swap:
STA zp_seg_top_min
LDX zp_yt2
STX zp_seg_top_max
mel_bbox_t_done:
LDA zp_yb1
CMP zp_yb2
BCC mel_bbox_b_swap
STA zp_seg_bot_max
LDX zp_yb2
STX zp_seg_bot_min
BCS mel_bbox_done                       ; always taken
mel_bbox_b_swap:
STA zp_seg_bot_min
LDX zp_yb2
STX zp_seg_bot_max
BCC mel_bbox_done                       ; always taken
mel_bbox_disable:
LDA #$FF
STA zp_seg_top_max
STA zp_seg_bot_max
LDA #$00
STA zp_seg_top_min
STA zp_seg_bot_min
mel_bbox_done:

LDX zp_head
BNE mel_loop
RTS
mel_loop:
; Skip if span is entirely before [ilo, ihi]
LDA POOL_XEND,X
CMP zp_ilo
BCS mel_chk_start
JMP mel_next
mel_chk_start:
; Skip if span starts after [ilo, ihi]
LDA zp_ihi
CMP POOL_XSTART,X
BCS mel_has_overlap
RTS                                     ; all subsequent spans are post-seg
mel_has_overlap:
STX zp_save0
; ox0 = max(xstart, ilo)
LDA POOL_XSTART,X
CMP zp_ilo
BCS mel_ox0_ok
LDA zp_ilo
mel_ox0_ok:
STA zp_save1
; ox0
; ox1 = min(xend, ihi)
LDA POOL_XEND,X
CMP zp_ihi
BCC mel_ox1_ok
LDA zp_ihi
mel_ox1_ok:
STA zp_save2
; ox1

; --- DCL-style per-span bbox reject ---
; Skip span entirely if neither top nor bot edge can emit anywhere
; in this span.  Saves all 8 interp_store calls + emission tree.
;   no top emit: seg_top_max <= POOL_OT  OR  seg_top_min >= POOL_OB
;   no bot emit: seg_bot_max <= POOL_OT  OR  seg_bot_min >= POOL_OB
; "Skip span" requires BOTH no-top AND no-bot.
LDA POOL_OT,X
CMP zp_seg_top_max
BCS mel_top_no_emit
; OT >= top_max
LDA zp_seg_top_min
CMP POOL_OB,X
BCC mel_span_check_done
; top_min < OB -> emit (was BCS+JMP)
mel_top_no_emit:
LDA POOL_OT,X
CMP zp_seg_bot_max
BCS mel_skip_span
; OT >= bot_max
LDA zp_seg_bot_min
CMP POOL_OB,X
BCC mel_span_check_done
; bot_min < OB -> emit (was BCS+JMP)
mel_skip_span:
JMP mel_next
mel_span_check_done:

; --- Evaluate span boundaries at ox0 and ox1 ---
; Constant-line fast path: tl==tr AND bl==br
LDA POOL_TL,X
CMP POOL_TR,X
BNE mel_span_not_const
STA zp_ot_l
STA zp_ot_r
LDA POOL_BL,X
CMP POOL_BR,X
BNE mel_span_not_const
STA zp_ob_l
STA zp_ob_r
JMP mel_span_done
mel_span_not_const:
; Anchor fast path: if ox0==xlo and ox1==xhi, use stored values
LDA zp_save1
CMP POOL_XLO,X
BNE mel_span_interp
LDA zp_save2
SEC
SBC zp_save1
CMP POOL_DEN,X
BNE mel_span_interp
LDA POOL_TL,X
STA zp_ot_l
LDA POOL_TR,X
STA zp_ot_r
LDA POOL_BL,X
STA zp_ob_l
LDA POOL_BR,X
STA zp_ob_r
JMP mel_span_done
mel_span_interp:
; Full interp: den = xhi - xlo
LDA POOL_XLO,X
STA zp_i_x0
LDA POOL_DEN,X
STA zp_div_den
LDA POOL_TL,X
STA zp_i_y0
LDA POOL_TR,X
STA zp_i_y1
LDA zp_save1
JSR interp_store
STA zp_ot_l
LDA zp_save2
JSR interp_store
STA zp_ot_r
LDX zp_save0
LDA POOL_BL,X
STA zp_i_y0
LDA POOL_BR,X
STA zp_i_y1
LDA zp_save1
JSR interp_store
STA zp_ob_l
LDA zp_save2
JSR interp_store
STA zp_ob_r
mel_span_done:

; --- Evaluate seg top/bot at ox0 and ox1 (u8 with Y_BIAS) ---
; Constant-line fast path: yt1==yt2 AND yb1==yb2
LDA zp_yt1
CMP zp_yt2
BNE mel_seg_slow
LDA zp_yb1
CMP zp_yb2
BNE mel_seg_slow
LDA zp_yt1
STA zp_nt_l
STA zp_nt_r
LDA zp_yb1
STA zp_nb_l
STA zp_nb_r
LDA #0
STA zp_nt_lh
STA zp_nt_rh
STA zp_nb_lh
STA zp_nb_rh
; | hi = 0
JMP mel_seg_done
mel_seg_slow:
; Anchor fast path: if ox0==sx1 and ox1==sx2
LDA zp_save1
CMP zp_sx1
BNE mel_seg_interp
LDA zp_save2
CMP zp_sx2
BNE mel_seg_interp
LDA zp_yt1
STA zp_nt_l
LDA zp_yt2
STA zp_nt_r
LDA zp_yb1
STA zp_nb_l
LDA zp_yb2
STA zp_nb_r
LDA #0
STA zp_nt_lh
STA zp_nt_rh
STA zp_nb_lh
STA zp_nb_rh
; | hi = 0
JMP mel_seg_done
mel_seg_interp:
; Full interp (u8 via interp_store)
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
LDA zp_sx1
STA zp_i_x0
LDA zp_yt1
STA zp_i_y0
LDA zp_yt2
STA zp_i_y1
LDA zp_save1
JSR interp_store
STA zp_nt_l
LDA zp_save2
JSR interp_store
STA zp_nt_r
LDA zp_yb1
STA zp_i_y0
LDA zp_yb2
STA zp_i_y1
LDA zp_save1
JSR interp_store
STA zp_nb_l
LDA zp_save2
JSR interp_store
STA zp_nb_r
LDA #0
STA zp_nt_lh
STA zp_nt_rh
STA zp_nb_lh
STA zp_nb_rh
; | hi = 0
mel_seg_done:

; --- Clamp seg values for dominance ---
; With Y_BIAS, all values are u8 (hi bytes = 0). Skip clamping.
LDA zp_nt_lh
ORA zp_nt_rh
ORA zp_nb_lh
ORA zp_nb_rh
BEQ mel_clamp_ok
mel_clamp_slow:
LDA zp_nt_lh
BMI mel_cz1
BNE mel_cf1
LDA zp_nt_l
CMP #(VIS_YMAX + 1)
BCC mel_cs1
LDA #1
STA zp_nt_lh
; mark clamped
mel_cf1:
LDA #VIS_YMAX
.byte $2C
mel_cz1:
LDA #0
mel_cs1:
STA zp_nt_l
LDA zp_nt_rh
BMI mel_cz2
BNE mel_cf2
LDA zp_nt_r
CMP #(VIS_YMAX + 1)
BCC mel_cs2
LDA #1
STA zp_nt_rh
; mark clamped
mel_cf2:
LDA #VIS_YMAX
.byte $2C
mel_cz2:
LDA #0
mel_cs2:
STA zp_nt_r
LDA zp_nb_lh
BMI mel_cz3
BNE mel_cf3
LDA zp_nb_l
CMP #(VIS_YMAX + 1)
BCC mel_cs3
LDA #1
STA zp_nb_lh
; mark clamped
mel_cf3:
LDA #VIS_YMAX
.byte $2C
mel_cz3:
LDA #0
mel_cs3:
STA zp_nb_l
LDA zp_nb_rh
BMI mel_cz4
BNE mel_cf4
LDA zp_nb_r
CMP #(VIS_YMAX + 1)
BCC mel_cs4
LDA #1
STA zp_nb_rh
; mark clamped
mel_cf4:
LDA #VIS_YMAX
.byte $2C
mel_cz4:
LDA #0
mel_cs4:
STA zp_nb_r
mel_clamp_ok:

; --- Emit visible edges ---
; The wall's top/bot edge must be INSIDE the span's aperture [ot, ob]
; to be visible. We handle four cases at each edge:
;   both endpoints inside aperture → emit full line
;   left inside, right outside       → clip right at crossover
;   left outside, right inside       → clip left at crossover
;   both outside                     → skip
; "Outside" for top edge means nt < ot (line above span top) or
; nt > ob (line below span bot). For bot: nb < ot or nb > ob.
; At present we only check the "primary" boundary (nt vs ot for top,
; nb vs ob for bot) — the "line outside on the other side" case is
; rare and not yet handled; it would require a second crossover.
; Guard: skip emission for single-column overlaps (degenerate point)
LDA zp_save1
CMP zp_save2
BCC mel_emit_any
JMP mel_no_bot
mel_emit_any:
; Top edge: visible where ot < nt (new top below span top, new
; covers more of aperture).
; Guard: skip if either top endpoint was clamped (hi byte nonzero)
LDA zp_nt_lh
ORA zp_nt_rh
BEQ mel_top_clamp_ok
JMP mel_no_top
mel_top_clamp_ok:
; Also skip if seg top is below span bot at BOTH endpoints
; (entirely below aperture — line can't be visible).
LDA zp_nt_l
CMP zp_ob_l
BCC mel_top_lok
LDA zp_nt_r
CMP zp_ob_r
BCC mel_top_lok
JMP mel_no_top                          ; both below aperture
mel_top_lok:
; Decision tree on left endpoint (nt_l vs ot_l).
; For TOP emission, "inside aperture from top" means nt > ot.
LDA zp_nt_l
CMP zp_ot_l
BCC mel_top_l_above                     ; nt_l < ot_l (above aperture)
BEQ mel_top_l_eq                        ; nt_l == ot_l (at boundary)
; nt_l > ot_l: strict inside. Check right.
LDA zp_nt_r
CMP zp_ot_r
BCS mel_emit_top_full                   ; nt_r >= ot_r → both in → emit full
; nt_r < ot_r → clip right at crossover
LDA zp_nt_l
SEC
SBC zp_ot_l
STA zp_tmp0
; |d0| = nt_l - ot_l
LDA #0
STA zp_tmp1
LDA zp_ot_r
SEC
SBC zp_nt_r
STA zp_tmp2
; |d1| = ot_r - nt_r
LDA #0
STA zp_tmp3
JSR mel_emit_top_cross_right
JMP mel_no_top
mel_top_l_eq:
; Left at boundary. Emit only if right strict inside (matches original).
LDA zp_nt_r
CMP zp_ot_r
BEQ mel_no_top
BCC mel_no_top
JMP mel_emit_top_full
mel_top_l_above:
; Left strict outside (above aperture). Check right.
LDA zp_nt_r
CMP zp_ot_r
BCC mel_no_top
BEQ mel_no_top
; Left above, right strict inside → clip left at crossover
LDA zp_ot_l
SEC
SBC zp_nt_l
STA zp_tmp0
; |d0| = ot_l - nt_l
LDA #0
STA zp_tmp1
LDA zp_nt_r
SEC
SBC zp_ot_r
STA zp_tmp2
; |d1| = nt_r - ot_r
LDA #0
STA zp_tmp3
JSR mel_emit_top_cross_left
JMP mel_no_top
mel_emit_top_full:
LDY LINE_OUT_COUNT
LDA zp_save1
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_nt_l
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_save2
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_nt_r
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JSR RASTER_ENTRY
mel_no_top:
; Bot edge: visible where nb < ob.
; Guard: skip if either bot endpoint was clamped (hi byte nonzero)
LDA zp_nb_lh
ORA zp_nb_rh
BEQ mel_bot_clamp_ok
JMP mel_no_bot
mel_bot_clamp_ok:
; Skip if seg bot is above span top at BOTH endpoints (entirely above).
LDA zp_nb_l
CMP zp_ot_l
BCS mel_bot_lok
LDA zp_nb_r
CMP zp_ot_r
BCS mel_bot_lok
JMP mel_no_bot                          ; both above aperture
mel_bot_lok:
; Decision tree on left endpoint (nb_l vs ob_l).
; For BOT emission, "inside aperture from bot" means nb < ob.
LDA zp_nb_l
CMP zp_ob_l
BCC mel_bot_l_in                        ; nb_l < ob_l (strict in)
BEQ mel_bot_l_eq                        ; nb_l == ob_l (boundary)
; nb_l > ob_l: strict outside (below aperture). Check right.
LDA zp_nb_r
CMP zp_ob_r
BCS mel_no_bot                          ; nb_r >= ob_r → both out
; nb_r < ob_r → clip left at crossover
LDA zp_nb_l
SEC
SBC zp_ob_l
STA zp_tmp0
; |d0| = nb_l - ob_l
LDA #0
STA zp_tmp1
LDA zp_ob_r
SEC
SBC zp_nb_r
STA zp_tmp2
; |d1| = ob_r - nb_r
LDA #0
STA zp_tmp3
JSR mel_emit_bot_cross_left
JMP mel_no_bot
mel_bot_l_eq:
; Left at boundary. Emit only if right strict inside.
LDA zp_nb_r
CMP zp_ob_r
BEQ mel_no_bot
BCS mel_no_bot
JMP mel_emit_bot_full
mel_bot_l_in:
; Left strict inside. Check right.
LDA zp_nb_r
CMP zp_ob_r
BCC mel_emit_bot_full                   ; both strict in → emit full
BEQ mel_emit_bot_full                   ; boundary at right → emit full
; nb_r > ob_r → clip right
LDA zp_ob_l
SEC
SBC zp_nb_l
STA zp_tmp0
; |d0| = ob_l - nb_l
LDA #0
STA zp_tmp1
LDA zp_nb_r
SEC
SBC zp_ob_r
STA zp_tmp2
; |d1| = nb_r - ob_r
LDA #0
STA zp_tmp3
JSR mel_emit_bot_cross_right
JMP mel_no_bot
mel_emit_bot_full:
LDY LINE_OUT_COUNT
LDA zp_save1
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_nb_l
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_save2
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_nb_r
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JSR RASTER_ENTRY
mel_no_bot:
; --- Advance to next span ---
LDX zp_save0
mel_next:
LDA POOL_NEXT,X
TAX
BEQ mel_rts
JMP mel_loop
mel_rts:
RTS

; === mel crossover-clip helpers ===
; Each takes |d0| in zp_tmp0:tmp1, |d1| in zp_tmp2:tmp3. Computes the
; crossover X via compute_crossover, then the line Y at that X, then
; emits the clipped line fragment. Uses zp_tmp0/tmp1 as scratch for
; saved cx/cy after compute_crossover returns.

mel_emit_top_cross_left:
; Emit (cx, cy) → (save2, nt_r). Line Y uses nt_l→nt_r interp.
LDA zp_save1
STA zp_ox0
LDA zp_save2
STA zp_ox1
JSR compute_crossover                   ; A = cx
BNE mel_emit_cx_ok
RTS                                     ; degenerate (boundary) → skip
mel_emit_cx_ok:
STA zp_ox0                              ; save cx in ox0 (interp_store preserves it)
LDA zp_save1
STA zp_i_x0
LDA zp_save2
SEC
SBC zp_save1
STA zp_div_den
LDA zp_nt_l
STA zp_i_y0
LDA zp_nt_r
STA zp_i_y1
LDA zp_ox0
JSR interp_store
; A = cy (clobbers tmp0 via umul8)
STA zp_ox1                              ; save cy in ox1
LDY LINE_OUT_COUNT
LDA zp_ox0
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_ox1
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_save2
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_nt_r
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JMP RASTER_ENTRY

mel_emit_top_cross_right:
; Emit (save1, nt_l) → (cx, cy).
LDA zp_save1
STA zp_ox0
LDA zp_save2
STA zp_ox1
JSR compute_crossover
CMP #0
BNE mel_ecx_ok_1
RTS                                     ; degenerate → skip
mel_ecx_ok_1:
STA zp_ox0                              ; save cx
LDA zp_save1
STA zp_i_x0
LDA zp_save2
SEC
SBC zp_save1
STA zp_div_den
LDA zp_nt_l
STA zp_i_y0
LDA zp_nt_r
STA zp_i_y1
LDA zp_ox0
JSR interp_store
STA zp_ox1                              ; save cy
LDY LINE_OUT_COUNT
LDA zp_save1
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_nt_l
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_ox0
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_ox1
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JMP RASTER_ENTRY

mel_emit_bot_cross_left:
; Emit (cx, cy) → (save2, nb_r).
LDA zp_save1
STA zp_ox0
LDA zp_save2
STA zp_ox1
JSR compute_crossover
CMP #0
BNE mel_ecx_ok_2
RTS                                     ; degenerate → skip
mel_ecx_ok_2:
STA zp_ox0
LDA zp_save1
STA zp_i_x0
LDA zp_save2
SEC
SBC zp_save1
STA zp_div_den
LDA zp_nb_l
STA zp_i_y0
LDA zp_nb_r
STA zp_i_y1
LDA zp_ox0
JSR interp_store
STA zp_ox1
LDY LINE_OUT_COUNT
LDA zp_ox0
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_ox1
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_save2
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_nb_r
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JMP RASTER_ENTRY

mel_emit_bot_cross_right:
; Emit (save1, nb_l) → (cx, cy).
LDA zp_save1
STA zp_ox0
LDA zp_save2
STA zp_ox1
JSR compute_crossover
CMP #0
BNE mel_ecx_ok_3
RTS                                     ; degenerate → skip
mel_ecx_ok_3:
STA zp_ox0
LDA zp_save1
STA zp_i_x0
LDA zp_save2
SEC
SBC zp_save1
STA zp_div_den
LDA zp_nb_l
STA zp_i_y0
LDA zp_nb_r
STA zp_i_y1
LDA zp_ox0
JSR interp_store
STA zp_ox1
LDY LINE_OUT_COUNT
LDA zp_save1
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_nb_l
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_ox0
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_ox1
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JMP RASTER_ENTRY
mel_emit_skip:
RTS
.endscope
.endif

; ======================================================================
; EMIT_LINE: write line to buffer AND call NJ rasteriser
;
; Call with: zp_ox0/zp_ox1 = X endpoints, A = y1, X = y2
; (caller sets up which edge: top uses nt_l/nt_r, bot uses nb_l/nb_r)
; Preserves: zp_ox0/ox1/ot_l/ot_r/ob_l/ob_r/nt_l/nt_r/nb_l/nb_r
; ======================================================================
.if ::EMIT_LINES
emit_top_edge:
.scope
LDY LINE_OUT_COUNT
LDA zp_ox0
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_nt_l
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_ox1
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_nt_r
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JMP RASTER_ENTRY                        ; tail-call rasteriser (returns via RTS)
.endscope

emit_bot_edge:
.scope
LDY LINE_OUT_COUNT
LDA zp_ox0
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_nb_l
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_ox1
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_nb_r
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JMP RASTER_ENTRY                        ; tail-call rasteriser (returns via RTS)
.endscope

; Secondary edge emitters: emit the front ceiling/floor line (ft/fb)
; passed via zp_yt_sec1/2 or zp_yb_sec1/2.  Used for step cases
; (need_bt / need_bb) where Python draws BOTH the step edge (at bt/bb,
; primary) AND the front ceiling/floor edge (at ft/fb, secondary).
; The values are u8 after the wrapper's remap.  We interp at (ox0, ox1)
; using the seg anchors (sx1, sx2), reusing zp_tmp2/tmp3 for the
; computed u8 y values.
emit_sec_top_edge:
.scope
; Fast path: constant line (yt_sec1 == yt_sec2) → skip interp
LDA zp_yt_sec1
CMP zp_yt_sec2
BNE es_top_interp
STA zp_tmp2
STA zp_tmp3
JMP es_top_emit
es_top_interp:
; interp at ox0
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
LDA zp_sx1
STA zp_i_x0
LDA zp_yt_sec1
STA zp_i_y0
LDA zp_yt_sec2
STA zp_i_y1
LDA zp_ox0
JSR interp_store
STA zp_tmp2
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
LDA zp_sx1
STA zp_i_x0
LDA zp_yt_sec1
STA zp_i_y0
LDA zp_yt_sec2
STA zp_i_y1
LDA zp_ox1
JSR interp_store
STA zp_tmp3
es_top_emit:
LDY LINE_OUT_COUNT
LDA zp_ox0
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_tmp2
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_ox1
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_tmp3
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JMP RASTER_ENTRY
.endscope

emit_sec_bot_edge:
.scope
; Fast path: constant line (yb_sec1 == yb_sec2) → skip interp
LDA zp_yb_sec1
CMP zp_yb_sec2
BNE es_bot_interp
STA zp_tmp2
STA zp_tmp3
JMP es_bot_emit
es_bot_interp:
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
LDA zp_sx1
STA zp_i_x0
LDA zp_yb_sec1
STA zp_i_y0
LDA zp_yb_sec2
STA zp_i_y1
LDA zp_ox0
JSR interp_store
STA zp_tmp2
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
LDA zp_sx1
STA zp_i_x0
LDA zp_yb_sec1
STA zp_i_y0
LDA zp_yb_sec2
STA zp_i_y1
LDA zp_ox1
JSR interp_store
STA zp_tmp3
es_bot_emit:
LDY LINE_OUT_COUNT
LDA zp_ox0
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X0
INY
LDA zp_tmp2
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y0
INY
LDA zp_ox1
STA LINE_OUT_BUF,Y
STA RASTER_ZP_X1
INY
LDA zp_tmp3
SEC
SBC #Y_BIAS
STA LINE_OUT_BUF,Y
STA RASTER_ZP_Y1
INY
STY LINE_OUT_COUNT
JMP RASTER_ENTRY
.endscope
.endif
