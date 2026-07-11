
; ======================================================================
; DRAW_CLIPPED_LINE: clip a single line against the span list, emit
; visible portions to LINE_OUT_BUF and call the NJ rasteriser.
;
; Phase 1: basic walk with outer bbox reject / inner bbox accept.
; No CB clip (ambiguous cases skipped), no portal continuation
; (each span is considered independently).
;
; Inputs (ZP): zp_line_xl_lo, zp_line_yl_lo, zp_line_xr_lo, zp_line_yr_lo
; The line MUST be oriented left-to-right (xl <= xr).
; All Y values u8, biased by Y_BIAS (visible rows [0,159] -> [48,207]).
;   zp_head                = first slot of the sorted active span list
;   zp_dcl_rec_buf(_h)     = segment-record buffer ptr; hi byte $00
;                            disables records mode entirely
;
; Output: lines written to LINE_OUT_BUF (4 bytes each: x0,y0,x1,y1 with
; Y un-biased), count at LINE_OUT_COUNT; each segment is also handed to
; the rasteriser as it is produced.  In records mode, one 4-byte record
; (xl,yl,xr,yr — BIASED Y) per surviving segment is appended to the
; record buffer (count in byte 0) for the records-driven tighten.
; READ-ONLY walk — never modifies the span list.
;
; Python mirror: EndpointClipSpans.draw_clipped (endpoint_spans.py) —
; the sloped-line branch; dcl_vertical mirrors the |dx|<1 branch.
;
; Pseudocode (per span s in the sorted list, left to right):
;   if s.xend <= xl: continue            # span left of line
;   if s.xstart >= xr: break             # span right of line (sorted)
;   ox0 = max(s.xstart, xl); ox1 = min(s.xend, xr)
;   if seg_start is None:                # ENTRY
;       if yhi < s.OT or ylo > s.OB: continue      # Tier 1 outer reject
;       if ylo >= s.IT and yhi <= s.IB:            # Tier 2 inner accept
;           seg_start = (ox0, line_y_at(ox0))
;       else:                                       # ambiguous
;           CB-clip line to s's trapezoid aperture  # dcl_cb_clip
;   # EXIT CHECK
;   if xr <= s.xend: emit(seg_start, (xr, yr)); done
;   elif next span abuts and line's remaining bbox fits its inner
;        bbox: continue into next span (portal merge, no re-clip)
;   else: emit(seg_start, (s.xend, line_y_at(s.xend))); seg_start=None
; ======================================================================
draw_clipped_line:
.scope
; --- Vertical fast path: xl == xr (trampoline — dcl_vertical out of BEQ range) ---
   LDA zp_line_xl_lo
   CMP zp_line_xr_lo
   BNE dcl_not_vert
   JMP dcl_vertical
dcl_not_vert:
; --- Compute dx, dy, ylo, yhi ---
   LDA zp_line_xr_lo
   SEC
   SBC zp_line_xl_lo
   STA zp_line_dx
   LDA zp_line_yr_lo
   SEC
   SBC zp_line_yl_lo
   STA zp_line_dy

; Y bounding box: ylo = min(yl, yr), yhi = max(yl, yr)
   LDA zp_line_yl_lo
   LDX zp_line_yr_lo
   CMP zp_line_yr_lo
   BCC dcl_yl_lo
; yl >= yr: yhi=yl, ylo=yr
   STA zp_line_yhi
   STX zp_line_ylo
   JMP dcl_bbox_done
dcl_yl_lo:
; yl < yr: ylo=yl, yhi=yr
   STA zp_line_ylo
   STX zp_line_yhi
dcl_bbox_done:

; --- Records-mode init (if enabled) ---
   LDA zp_dcl_rec_buf_h
   BEQ dcl_records_off
   LDA #0
   LDY #0
   STA (zp_dcl_rec_buf),Y
; count = 0
   LDA #1
   STA zp_dcl_rec_off
; first record at offset 1
dcl_records_off:

; Reset output
   ZERO LINE_OUT_COUNT

; seg_start = NULL
   LDA #$FF
   STA zp_seg_start_x

; Walk span list
   LDX zp_head

dcl_walk:
; End of list?
   BNE dcl_walk2
   JMP dcl_flush
dcl_walk2:

; --- Skip spans entirely left of line ---
; Skip if xend <= xl (strict: pixel-center model)
   LDA zp_line_xl_lo
   CMP POOL_XEND,X
   BCC dcl_not_left
; xl >= xend → skip this span (inline advance)
   LDA POOL_NEXT,X
   TAX
   BNE dcl_walk2
   JMP dcl_flush
dcl_not_left:

; --- Skip spans entirely right of line ---
; Done if xstart >= xr (all remaining spans are further right)
   LDA POOL_XSTART,X
   CMP zp_line_xr_lo
   BCC dcl_in_range
   JMP dcl_flush                           ; xstart >= xr → done
dcl_in_range:

; --- Compute overlap ---
; ox0 = max(xstart, xl) — A already holds POOL_XSTART,X from skip check
   CMP zp_line_xl_lo
   BCS dcl_ox0_ok
   LDA zp_line_xl_lo
dcl_ox0_ok:
   STA zp_ox0
; ox1 = min(xend, xr)
   LDA POOL_XEND,X
   CMP zp_line_xr_lo
   BCC dcl_ox1_ok
   LDA zp_line_xr_lo
dcl_ox1_ok:
   STA zp_ox1

; --- Entry or continuation? ---
; seg_start_x == $FF means no segment is open (NULL sentinel).
; Open segment (BNE): this span was reached via a portal merge — the
; line is already known to stay inside the aperture across it, so go
; straight to the exit check.  Records are written once at
; dcl_emit_segment, not per-span.
   LDA zp_seg_start_x
   CMP #$FF
   BNE dcl_exit_check
; not entry -> exit_check (was BEQ+JMP)
; Continuation: line still in aperture across this span. Records are
; written once at dcl_emit_segment, not per-span.
dcl_entry_path:
; Reset the Y bbox to the full line range for this fresh segment.  A
; previous segment may have NARROWED ylo/yhi (continuation) and then
; reset seg_start without restoring it; a stale narrow bbox here makes
; Tier-2 wrongly ACCEPT (skip CB clip) for the new span -> over-draw
; (the slot4 over-draw at 845,-3084,215).  The full-line bbox is
; conservative: it never wrongly accepts/rejects; CB clip refines.
; (X = span slot must be preserved for the Tier checks below.)
   LDA zp_line_yl_lo
   CMP zp_line_yr_lo
   BCS dcl_ep_yge
   STA zp_line_ylo
   LDA zp_line_yr_lo
   STA zp_line_yhi
   JMP dcl_ep_done
dcl_ep_yge:
   STA zp_line_yhi
   LDA zp_line_yr_lo
   STA zp_line_ylo
dcl_ep_done:

; ========== ENTRY: seg_start is NULL ==========
; --- Tier 1: outer bbox reject ---
   LDA zp_line_yhi
   CMP POOL_OT,X
   BCC dcl_reject_above
; yhi < OT → line above aperture
   LDA POOL_OB,X
   CMP zp_line_ylo
   BCC dcl_reject_below
; OB < ylo → line below aperture

; --- Tier 2: inner bbox accept ---
   LDA zp_line_ylo
   CMP POOL_IT,X
   BCC dcl_ambiguous
; ylo < max(tl,tr) → CB clip
   LDA POOL_IB,X
   CMP zp_line_yhi
   BCS dcl_accept
; min(bl,br) >= yhi → accept
; yhi > ib → ambiguous
   JMP dcl_cb_clip

dcl_reject_above:
dcl_reject_below:
dcl_outer_reject:
; Outer reject → advance to next span (inline)
   LDA POOL_NEXT,X
   TAX
   BNE dcl_walk2
   JMP dcl_flush
dcl_ambiguous:
   JMP dcl_cb_clip                         ; trampoline → Phase 4 CB clip

; ── dcl_accept: record seg_start for an inner-bbox-accepted entry ──
; Sets seg_start = (ox0, line_y_at(ox0)).
; Three cases converge at STA zp_seg_start_y:
;   ox0 == xl  → A = yl      (common: line starts at/before span)
;   dy == 0    → A = yl      (flat line, y constant everywhere)
;   else       → A = interp  (rare: line enters span mid-way)
; The rare interp path uses BIT abs to skip the LDA zp_line_yl_lo.
dcl_accept:
   LDA zp_ox0
   STA zp_seg_start_x
   CMP zp_line_xl_lo
   BEQ dcl_accept_yl
; ox0 == xl → yl
   LDA zp_line_dy
   BEQ dcl_accept_yl
; dy == 0 → yl
; ox0 > xl, dy != 0: interp (rare path)
   STX zp_save0
   JSR dcl_line_y_at_ox0                   ; A = line_y_at(ox0)
   LDX zp_save0
   .byte $2C                               ; BIT abs: skip LDA
dcl_accept_yl:
   LDA zp_line_yl_lo
   STA zp_seg_start_y
; (Records hook moved to dcl_emit_segment — one record per surviving
;  segment, not per-span.)
; Fall through to exit check

dcl_exit_check:
; ========== EXIT CHECK ==========
; Does the line end within this span? (xr <= xend)
   LDA POOL_XEND,X
   CMP zp_line_xr_lo
   BCC dcl_extends_past
; xend < xr → extends past
; xend >= xr: line ends within this span
   JMP dcl_line_ends

dcl_extends_past:
; ========== Line extends past this span — Phase 2 portal check ==========
   STX zp_save0                            ; save current span pointer

; Check if next span abuts this one
   LDY POOL_NEXT,X
   BNE dcl_has_next
   JMP dcl_exit_no_portal                  ; no next span → emit+reset
dcl_has_next:

; Abutting? POOL_XEND[current] == POOL_XSTART[next] (shared pixel center)
   LDA POOL_XEND,X
   CMP POOL_XSTART,Y
   BEQ dcl_is_abutting
   JMP dcl_exit_no_portal
dcl_is_abutting:

; --- Continuation containment check (FIX 2026-06-19) ---
; Merge across the portal ONLY if the line, from the shared boundary to
; its end, stays within the NEXT span's inner bbox [IT, IB] — which
; guarantees the line cannot exit that span's aperture anywhere, so no
; per-span re-clip is needed.  Otherwise end the segment at the boundary
; and let the next span re-enter via the entry path (CB clip).  The old
; code only checked the portal aperture at the shared boundary column, so
; a line grazing the aperture edge at the boundary but running outside it
; WITHIN the next span was emitted across the whole span (over-extension
; -> off-screen; the 845,-3084,215 over-draw and the 1056,-3291,34 crash).
; ly = line_y at the shared boundary (= current.XEND)
   LDX zp_save0
   LDA zp_line_dy
   BEQ dcl_pp_use_yr
   LDA POOL_XEND,X
   CMP zp_line_xr_lo
   BEQ dcl_pp_use_yr
   LDA POOL_XEND,X
   JSR dcl_line_y_at_a
   .byte $2C                               ; BIT abs: skip LDA yr
dcl_pp_use_yr:
   LDA zp_line_yr_lo
; bbox of the line over [boundary, xr] = [min(ly,yr), max(ly,yr)].
   STA zp_tmp2                             ; ly (A)
   CMP zp_line_yr_lo
   BCS dcl_pp_ly_ge
   STA zp_tmp0
   LDA zp_line_yr_lo
   STA zp_tmp1
; ly < yr: lo=ly, hi=yr
   JMP dcl_pp_bbox
dcl_pp_ly_ge:
   LDA zp_line_yr_lo
   STA zp_tmp0
   LDA zp_tmp2
   STA zp_tmp1
; ly >= yr: lo=yr, hi=ly
dcl_pp_bbox:
   LDX zp_save0
   LDY POOL_NEXT,X
; Y = next span slot
   LDA zp_tmp0
   CMP POOL_IT,Y
   BCC dcl_exit_no_portal
; lo < next.IT -> may exit top
   LDA POOL_IB,Y
   CMP zp_tmp1
   BCC dcl_exit_no_portal
; next.IB < hi -> may exit bot
; Contained in next span's inner bbox: commit narrowed bbox, continue.
   LDA zp_tmp0
   STA zp_line_ylo
   LDA zp_tmp1
   STA zp_line_yhi
   TYA
   TAX
   JMP dcl_walk

dcl_exit_no_portal_a:
; Restore for emit path (ly check failed, need save0)
dcl_exit_no_portal:
; Portal failed or closed: emit current segment and reset.
; Compute exit point Y — three cases converge at dcl_exit_emit via
; chained BIT abs tricks (interp skips yl, yl skips yr):
;   xend == xr → A = yr
;   dy == 0    → A = yl
;   else       → A = line_y_at(xend)
   LDX zp_save0
   LDA POOL_XEND,X
   STA zp_ox1                              ; end_x = xend of current span
   CMP zp_line_xr_lo
   BEQ dcl_exit_use_yr
   LDA zp_line_dy
   BEQ dcl_exit_use_yr
; dy==0 → yr (== yl for flat lines)
; xend < xr, sloped: interp
   LDA zp_ox1
   JSR dcl_line_y_at_a
   .byte $2C                               ; BIT abs: skip LDA yr
dcl_exit_use_yr:
   LDA zp_line_yr_lo
dcl_exit_emit:
; A = end_y
   STA zp_tmp0
   JSR dcl_emit_segment
; Reset seg_start
   LDA #$FF
   STA zp_seg_start_x
   LDX zp_save0
; Advance to next span (inline)
   LDA POOL_NEXT,X
   TAX
   JMP dcl_walk

dcl_line_ends:
; Line ends within this span. Emit seg_start → (xr, yr)
   STX zp_save0
   LDA zp_line_yr_lo
   STA zp_tmp0
; end_y = yr
   LDA zp_line_xr_lo
   STA zp_ox1
; end_x = xr
   JMP dcl_emit_segment                    ; tail call (was JSR+RTS): -9 cyc, line fully consumed

dcl_flush:
; End of walk.  If seg_start is still active (last iteration was a
; portal-continue into a span past xr, or list exhausted), emit the
; final segment to (xr, yr).
   LDA zp_seg_start_x
   CMP #$FF
   BEQ dcl_done
   LDA zp_line_yr_lo
   STA zp_tmp0
   LDA zp_line_xr_lo
   STA zp_ox1
   JSR dcl_emit_segment
dcl_done:
   RTS

; ========== Vertical line handler ==========
; For xl == xr: find the first span containing column xl, compute
; aperture [top_y, bot_y] at that column, clip [ylo, yhi] to aperture,
; emit single vertical line segment.  Matches Python's draw_clipped
; vertical path (break on first span containing ix).
;
; Inputs:  zp_line_xl_lo (== xr), zp_line_yl_lo, zp_line_yr_lo; zp_head.
; Output:  at most one segment to LINE_OUT_BUF + plot_v; no records
;          (vertical lines carry no tighten information).
; Pseudocode:
;   for s in spans:
;       if s.xend < xl: continue
;       if s.xstart > xl: return         # sorted list — no span has xl
;       top = span_top(s, xl); bot = span_bot(s, xl)   # interp_store
;       cy1 = max(ylo, top); cy2 = min(yhi, bot)
;       if cy1 <= cy2: emit vertical (xl, cy1)-(xl, cy2)
;       return                           # first containing span only
dcl_vertical:
; Compute ylo/yhi (dx/dy not needed for verticals)
   LDA zp_line_yl_lo
   LDX zp_line_yr_lo
   CMP zp_line_yr_lo
   BCC dv_yl_lo
   STA zp_line_yhi
   STX zp_line_ylo
   JMP dv_bbox_done
dv_yl_lo:
   STA zp_line_ylo
   STX zp_line_yhi
dv_bbox_done:
   ZERO LINE_OUT_COUNT
   LDX zp_head
dv_walk:
   BNE dv_check
   RTS                                     ; span list exhausted
dv_check:
; Skip if xend < xl (span entirely left of column — strict)
   LDA POOL_XEND,X
   CMP zp_line_xl_lo
   BCC dv_next
; Done if xstart > xl (span entirely right of column; list sorted)
   LDA POOL_XSTART,X
   CMP zp_line_xl_lo
   BEQ dv_in
   BCC dv_in
   RTS
dv_next:
   LDA POOL_NEXT,X
   TAX
   JMP dv_walk
dv_in:
; Span contains column xl. Compute top_y and bot_y at xl.
   STX zp_save0
; Top: constant-line fast path or interp
   LDA POOL_TL,X
   CMP POOL_TR,X
   BNE dv_top_interp
   STA zp_cb_top1
   JMP dv_top_done
dv_top_interp:
   LDA POOL_XLO,X
   STA zp_i_x0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA POOL_TL,X
   STA zp_i_y0
   LDA POOL_TR,X
   STA zp_i_y1
   LDA zp_line_xl_lo
   JSR interp_store
   STA zp_cb_top1
dv_top_done:
; Bot: constant-line fast path or interp
   LDX zp_save0
   LDA POOL_BL,X
   CMP POOL_BR,X
   BNE dv_bot_interp
   STA zp_cb_bot1
   JMP dv_bot_done
dv_bot_interp:
   LDA POOL_XLO,X
   STA zp_i_x0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA POOL_BL,X
   STA zp_i_y0
   LDA POOL_BR,X
   STA zp_i_y1
   LDA zp_line_xl_lo
   JSR interp_store
   STA zp_cb_bot1
dv_bot_done:
; Clip [ylo, yhi] to [top_y, bot_y]
; cy1 = max(ylo, top_y)
   LDA zp_line_ylo
   CMP zp_cb_top1
   BCS dv_cy1_ok
   LDA zp_cb_top1
dv_cy1_ok:
   STA zp_cb_cy1
; cy2 = min(yhi, bot_y)
   LDA zp_line_yhi
   CMP zp_cb_bot1
   BCC dv_cy2_ok
   LDA zp_cb_bot1
dv_cy2_ok:
   STA zp_cb_cy2
; Emit if cy1 <= cy2
   LDA zp_cb_cy1
   CMP zp_cb_cy2
   BEQ dv_emit
   BCC dv_emit
   RTS                                     ; line clipped away
dv_emit:
; Stage the rasteriser ZP args (x, cy1, x, cy2), un-biasing Y (biased
; [48,207] -> screen [0,159]) and tail-call the vertical plotter.
; LINE_OUT capture is wrapper-only (LINE_OUT_EN — see arith.s): the
; native path skips the buffer entirely.
   LDA LINE_OUT_EN
   BNE dv_emit_cap
   LDA zp_line_xl_lo
   STA RASTER_ZP_X0
   STA RASTER_ZP_X1
   LDA zp_cb_cy1
   SEC
   SBC #Y_BIAS
   STA RASTER_ZP_Y0
   LDA zp_cb_cy2
   SEC
   SBC #Y_BIAS
   STA RASTER_ZP_Y1
   JMP plot_v
dv_emit_cap:
   LDY LINE_OUT_COUNT
   LDA zp_line_xl_lo
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_X0
   INY
   LDA zp_cb_cy1
   SEC
   SBC #Y_BIAS
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_Y0
   INY
   LDA zp_line_xl_lo
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_X1
   INY
   LDA zp_cb_cy2
   SEC
   SBC #Y_BIAS
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_Y1
   INY
   STY LINE_OUT_COUNT
   JMP plot_v                              ; always vertical on this path

; ========== Phase 4: CB clip (clip_to_span) ==========
; Exact clip of the line against the span's trapezoid aperture.
; Entry: X = span pointer, seg_start_x == $FF (no active segment)
; Uses interp_store to evaluate span boundaries at clipped endpoints.
;
; Python mirror: _clip_to_span (endpoint_spans.py), restricted to the
; already-computed overlap [ox0, ox1] (the X clip is just cx1=ox0,
; cx2=ox1 since the walk guarantees overlap).
;
; Inputs:  zp_ox0/zp_ox1 (overlap), zp_line_* (line), X = span slot.
; Outputs: either
;   - reject (line outside aperture): advance to next span, or
;   - exit clipped inside the span (cx2 < ox1): emit fragment
;     (cx1,cy1)-(cx2,cy2) immediately, reset seg_start, next span, or
;   - exit not clipped (cx2 == ox1): seg_start = (cx1,cy1), narrow the
;     running Y bbox to [min(cy1,cy2), max(cy1,cy2)], resume at the
;     normal exit check (portal merge still possible).
; Clobbers: zp_cb_* workspace, interp workspace, zp_tmp0/1, zp_save0/1.
;
; Pseudocode:
;   cx1, cx2 = ox0, ox1
;   cy1 = line_y_at(cx1); cy2 = line_y_at(cx2)       # round-to-nearest
;   # top boundary: need cy >= top at both ends
;   if not (cy1 >= IT and cy2 >= IT):                # bbox filter
;       top1 = span_top(cx1); top2 = span_top(cx2)
;       if cy1 < top1 and cy2 < top2: reject          # both above
;       if one above: ix = boundary_ix(...); move that end to
;           (ix, span_top(ix)); other end unchanged
;   if cx1 > cx2: reject
;   # bot boundary: need cy <= bot at both ends (same shape, mirrored)
;   if not (cy1 <= IB and cy2 <= IB):
;       ... symmetric with span_bot / reject-below ...
;   if cx1 > cx2: reject
dcl_cb_clip:
   STX zp_save0                            ; save span pointer

; Step 1: X-clip line to [xstart, xend] = [ox0, ox1]
; cx1 = ox0
   LDA zp_ox0
   STA zp_cb_cx1
; cx2 = ox1
   LDA zp_ox1
   STA zp_cb_cx2

; Pre-set interp workspace to line-mode so all line_y_at calls
; within CB clip can call interp_store directly (no shuffle).
; Span eval (top/bot) clobbers the workspace; dcl_cb_line_mode
; restores it afterward.
   LDA zp_line_xl_lo
   STA zp_i_x0
   LDA zp_line_yl_lo
   STA zp_i_y0
   LDA zp_line_yr_lo
   STA zp_i_y1
   LDA zp_line_dx
   STA zp_div_den

; Step 2: Compute line Y at clipped X endpoints
; dy==0 fast path: flat line → cy1 = cy2 = yl
   LDA zp_line_dy
   BNE dcl_cb_cy_slow
   LDA zp_line_yl_lo
   STA zp_cb_cy1
   STA zp_cb_cy2
   JMP dcl_cb_cy_done
dcl_cb_cy_slow:
; cy1 = line_y_at(cx1). CMP preserves A, so interp reuses it.
; Interp workspace already in line-mode — call interp_store directly.
   LDA zp_cb_cx1
   CMP zp_line_xl_lo
   BEQ dcl_cb_cy1_yl
   JSR interp_store
   .byte $2C
; BIT abs: skip LDA
dcl_cb_cy1_yl:
   LDA zp_line_yl_lo
   STA zp_cb_cy1

; cy2 = line_y_at(cx2)
   LDA zp_cb_cx2
   CMP zp_line_xr_lo
   BEQ dcl_cb_cy2_yr
   JSR interp_store
   .byte $2C
; BIT abs: skip LDA
dcl_cb_cy2_yr:
   LDA zp_line_yr_lo
   STA zp_cb_cy2
dcl_cb_cy_done:

; ── Step 3: Top boundary ──────────────────────────────────────────
; Bbox filter: if both cy values are below the span's tightest top
; (cy >= IT = max(tl,tr) for both endpoints), the line can't cross
; the top boundary anywhere.  Skip top eval + clip entirely.
   LDX zp_save0
   LDA zp_cb_cy1
   CMP POOL_IT,X
   BCC dcl_cb_top_eval
   LDA zp_cb_cy2
   CMP POOL_IT,X
   BCC dcl_cb_top_eval
   JMP dcl_cb_top_done                     ; both >= IT → skip top

dcl_cb_top_eval:
; Evaluate top1, top2 at cx1, cx2 (fast paths first)
; Constant top? TL==TR (also covers den=0 since that implies TL==TR)
   LDA POOL_TL,X
   CMP POOL_TR,X
   BNE dcl_cb_top_interp
   STA zp_cb_top1
   STA zp_cb_top2
   JMP dcl_cb_top_evaled
dcl_cb_top_interp:
; Setup interp and evaluate
   LDA POOL_XLO,X
   STA zp_i_x0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA POOL_TL,X
   STA zp_i_y0
   LDA POOL_TR,X
   STA zp_i_y1
   LDA zp_cb_cx1
   JSR interp_store
   STA zp_cb_top1
   LDA zp_cb_cx2
   JSR interp_store
   STA zp_cb_top2
dcl_cb_top_evaled:

; Top clip: test cy vs top at each endpoint
   LDA zp_cb_cy1
   CMP zp_cb_top1
   BCS dcl_cb_top_p1_ok
; cy1 >= top1
   LDA zp_cb_cy2
   CMP zp_cb_top2
   BCS dcl_cb_top_clip
; cy2 >= top2 → one inside, clip
   JMP dcl_cb_reject_above                 ; both above → reject
dcl_cb_top_p1_ok:
; cy1 >= top1; check cy2
   LDA zp_cb_cy2
   CMP zp_cb_top2
   BCS dcl_cb_top_done
; cy2 >= top2 → both inside, no clip
; cy2 < top2, cy1 >= top1: clip at p2 end
   LDA zp_cb_cy1
   SEC
   SBC zp_cb_top1
   STA zp_tmp0
; d1 = cy1 - top1 >= 0
   LDA zp_cb_cy2
   SEC
   SBC zp_cb_top2
   STA zp_tmp1
; d2 = cy2 - top2 < 0
   LDA #0
   JSR dcl_boundary_ix
; A = ix (clip p2, round toward cx1)
   STA zp_cb_cx2
; cy at crossing = boundary_y(ix). Interp workspace still has the
; span's top line (i_x0=XLO, i_y0=TL, i_y1=TR); boundary_ix only
; clobbered div_den. Constant spans: cy = top1 directly.
   LDA zp_cb_top1
   CMP zp_cb_top2
   BEQ dcl_cb_top_cy2_const
   LDX zp_save0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA zp_cb_cx2
   JSR interp_store
   .byte $2C
dcl_cb_top_cy2_const:
   LDA zp_cb_top1
   STA zp_cb_cy2
   JMP dcl_cb_top_done

dcl_cb_top_clip:
; cy1 < top1, cy2 >= top2: clip at p1 end
   LDA zp_cb_cy1
   SEC
   SBC zp_cb_top1
   STA zp_tmp0
; d1 < 0
   LDA zp_cb_cy2
   SEC
   SBC zp_cb_top2
   STA zp_tmp1
; d2 >= 0
   LDA #1
   JSR dcl_boundary_ix
; A = ix (clip p1, round toward cx2)
   STA zp_cb_cx1
   LDA zp_cb_top1
   CMP zp_cb_top2
   BEQ dcl_cb_top_cy1_const
   LDX zp_save0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA zp_cb_cx1
   JSR interp_store
   .byte $2C
dcl_cb_top_cy1_const:
   LDA zp_cb_top1
   STA zp_cb_cy1

dcl_cb_top_done:
; Check cx1 > cx2 after top clip → reject
   LDA zp_cb_cx2
   CMP zp_cb_cx1
   BCS dcl_cb_top_ok
   JMP dcl_cb_reject_above
dcl_cb_top_ok:

; ── Step 4: Bot boundary ──────────────────────────────────────────
; Bbox filter: if both cy values are above the span's tightest bot
; (cy <= IB = min(bl,br) for both endpoints), the line can't cross
; the bot boundary anywhere.  Skip bot eval + clip entirely.
   LDX zp_save0
   LDA POOL_IB,X
   CMP zp_cb_cy1
   BCC dcl_cb_bot_eval
   LDA POOL_IB,X
   CMP zp_cb_cy2
   BCC dcl_cb_bot_eval
   JMP dcl_cb_bot_done                     ; both <= IB → skip bot

dcl_cb_bot_eval:
; Evaluate bot1, bot2 at (possibly top-clipped) cx1, cx2
; Constant bot? BL==BR (also covers den=0 since that implies BL==BR)
   LDA POOL_BL,X
   CMP POOL_BR,X
   BNE dcl_cb_bot_interp
   STA zp_cb_bot1
   STA zp_cb_bot2
   JMP dcl_cb_bot_eval_done
dcl_cb_bot_interp:
   LDA POOL_XLO,X
   STA zp_i_x0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA POOL_BL,X
   STA zp_i_y0
   LDA POOL_BR,X
   STA zp_i_y1
   LDA zp_cb_cx1
   JSR interp_store
   STA zp_cb_bot1
   LDA zp_cb_cx2
   JSR interp_store
   STA zp_cb_bot2
dcl_cb_bot_eval_done:

; Bot clip: test cy vs bot at each endpoint
   LDA zp_cb_bot1
   CMP zp_cb_cy1
   BCS dcl_cb_bot_p1_ok
; bot1 >= cy1
   LDA zp_cb_bot2
   CMP zp_cb_cy2
   BCS dcl_cb_bot_clip
; bot2 >= cy2 → one inside, clip
   JMP dcl_cb_reject_below                 ; both below → reject
dcl_cb_bot_p1_ok:
; bot1 >= cy1; check cy2
   LDA zp_cb_bot2
   CMP zp_cb_cy2
   BCS dcl_cb_bot_done
; bot2 >= cy2 → both inside
; cy2 > bot2, cy1 <= bot1: clip p2 end
; d1 = cy1 - bot1 (negative or zero, since cy1 <= bot1)
   LDA zp_cb_cy1
   SEC
   SBC zp_cb_bot1
   STA zp_tmp0
; d1 <= 0
; d2 = cy2 - bot2 (positive, since cy2 > bot2)
   LDA zp_cb_cy2
   SEC
   SBC zp_cb_bot2
   STA zp_tmp1
; d2 > 0
; boundary_ix with clip_p1=0 (clip p2, round toward cx1)
   LDA #0
   JSR dcl_boundary_ix
   STA zp_cb_cx2
; cy at crossing = boundary_y(ix). Bot interp workspace still valid.
   LDA zp_cb_bot1
   CMP zp_cb_bot2
   BEQ dcl_cb_bot_cy2_const
   LDX zp_save0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA zp_cb_cx2
   JSR interp_store
   .byte $2C
dcl_cb_bot_cy2_const:
   LDA zp_cb_bot1
   STA zp_cb_cy2
   JMP dcl_cb_bot_done

dcl_cb_bot_clip:
; bot1 < cy1, bot2 >= cy2: clip p1 end
   LDA zp_cb_cy1
   SEC
   SBC zp_cb_bot1
   STA zp_tmp0
; d1 > 0
   LDA zp_cb_cy2
   SEC
   SBC zp_cb_bot2
   STA zp_tmp1
; d2 <= 0
   LDA #1
   JSR dcl_boundary_ix
   STA zp_cb_cx1
   LDA zp_cb_bot1
   CMP zp_cb_bot2
   BEQ dcl_cb_bot_cy1_const
   LDX zp_save0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA zp_cb_cx1
   JSR interp_store
   .byte $2C
dcl_cb_bot_cy1_const:
   LDA zp_cb_bot1
   STA zp_cb_cy1

dcl_cb_bot_done:
; Check cx1 > cx2 after bot clip → reject
   LDA zp_cb_cx2
   CMP zp_cb_cx1
   BCC dcl_cb_reject_below

; CB clip succeeded. If cx2 < ox1 the line exits the aperture INSIDE
; the span (not at a span boundary). Emit (cx1,cy1)→(cx2,cy2) directly
; and reset seg_start — no portal continuation possible since the line
; left the aperture mid-span. dcl_line_ends / dcl_exit_no_portal both
; use xr/yr or line_y_at(xend) for the exit, which would be wrong here.
   LDA zp_cb_cx2
   CMP zp_ox1
   BCS dcl_cb_no_exit_clip
; cx2 < ox1 → emit clipped fragment (segment record written by emit).
   LDX zp_save0
   LDA zp_cb_cx1
   STA zp_seg_start_x
   LDA zp_cb_cy1
   STA zp_seg_start_y
   LDA zp_cb_cx2
   STA zp_ox1
   LDA zp_cb_cy2
   STA zp_tmp0
   JSR dcl_emit_segment
   LDA #$FF
   STA zp_seg_start_x
   LDX zp_save0
   LDA POOL_NEXT,X
   TAX
   JMP dcl_walk

dcl_cb_no_exit_clip:
; cx2 == ox1: CB did not clip the exit. Set seg_start = (cx1, cy1)
; and fall through to the normal exit check (portal or line_ends).
; Segment record written by dcl_emit_segment when the segment closes.
   LDX zp_save0
   LDA zp_cb_cx1
   STA zp_seg_start_x
   LDA zp_cb_cy1
   STA zp_seg_start_y
; Update Y bbox for portal checks
   LDA zp_cb_cy1
   CMP zp_cb_cy2
   BCC dcl_cb_ylo_ok
; cy1 >= cy2
   STA zp_line_yhi
   LDA zp_cb_cy2
   STA zp_line_ylo
   JMP dcl_cb_bbox_done
dcl_cb_ylo_ok:
; cy1 < cy2
   STA zp_line_ylo
   LDA zp_cb_cy2
   STA zp_line_yhi
dcl_cb_bbox_done:
; Restore span pointer and continue with exit check
   LDX zp_save0
   JMP dcl_exit_check

dcl_cb_reject_above:
dcl_cb_reject_below:
dcl_cb_reject:
; CB clip rejected — skip this span
   LDX zp_save0
   LDA POOL_NEXT,X
   TAX
   JMP dcl_walk

; --- dcl_boundary_ix: compute intersection X for CB clip ---
; Input: zp_tmp0 = d1 (s8), zp_tmp1 = d2 (s8), A = clip_p1 flag (0 or 1)
;        zp_cb_cx1, zp_cb_cx2 = current clipped X range
; Output: A = intersection X
; Formula: ix = cx1 + (cx2 - cx1) * d1 / (d1 - d2)
;   with directed rounding: if clip_p1, round toward cx2 (ceiling)
;                           else round toward cx1 (floor)
; d1 and d2 have opposite signs (one endpoint inside, one outside).
; denom = d1 - d2, |num| = (cx2-cx1) * |d1|
;
; Python mirror: boundary_ix (clip_math.py).
; Pseudocode:
;   num = (cx2 - cx1) * abs(d1); den = abs(d1) + abs(d2)
;   q = ceil(num / den) if clip_p1 else floor(num / den)
;   return clamp(cx1 + q, cx1, cx2)
; Guards: den == 0 or den > 255 -> return midpoint (cannot occur for
; sane pixel-scale inputs); cx2 == cx1 -> return cx1.
dcl_boundary_ix:
   STA zp_save1                            ; save clip_p1 flag

; denom = d1 - d2 (s8 result, but could be s9 in theory)
; Since d1 and d2 have opposite signs, |denom| = |d1| + |d2|
; Compute |d1| and sign
   LDA zp_tmp0
   BPL dcl_bix_d1_pos
; d1 negative: |d1| = -d1
   EOR #$FF
   BUMP
dcl_bix_d1_pos:
   STA zp_tmp2                             ; |d1|

; |denom| = |d1| + |d2| (since opposite signs)
   LDA zp_tmp1
   BPL dcl_bix_d2_pos
   EOR #$FF
   BUMP
dcl_bix_d2_pos:
   CLC
   ADC zp_tmp2
   STA zp_div_den
; |denom| = |d1| + |d2|
; Handle overflow: if carry set, denom > 255 — shouldn't happen
; for pixel-scale values, but guard just in case
   BCS dcl_bix_mid                         ; denom overflow → use midpoint fallback

; Check denom == 0 (shouldn't happen if signs differ, but guard)
   BEQ dcl_bix_mid

; num = (cx2 - cx1) * |d1|
   LDA zp_cb_cx2
   SEC
   SBC zp_cb_cx1
   STA zp_mul_b
; dx = cx2 - cx1
   BEQ dcl_bix_cx1                         ; dx=0 → return cx1

   LDA zp_tmp2                             ; |d1|
   JSR umul8                               ; prod = dx * |d1| → zp_prod_lo:hi

; Directed rounding: if clip_p1, add (denom-1) to numerator before divide
; (ceiling division). If !clip_p1, just floor division.
   LDA zp_save1
   BEQ dcl_bix_no_round
; Add (denom - 1) to product for ceiling
   LDA zp_prod_lo
   CLC
   ADC zp_div_den
   STA zp_div_lo
   BCC dcl_bix_den_nc                      ; BCC/INC carry bump (prod_hi
   INC zp_div_hi                           ; aliases div_hi — same cell)
dcl_bix_den_nc:
; Subtract 1: borrow only when the low byte is zero (BNE/DEC pre-check)
   LDA zp_div_lo
   BNE dcl_bix_m1_nb
   DEC zp_div_hi
dcl_bix_m1_nb:
   DEC zp_div_lo
dcl_bix_no_round:
; prod already in div_lo:hi (aliases — fall through to divide)
   JSR udiv16_8                            ; A = quotient = num / denom

; ix = cx1 + quotient
   CLC
   ADC zp_cb_cx1
; Clamp to [cx1, cx2]
   CMP zp_cb_cx1
   BCC dcl_bix_cx1
   CMP zp_cb_cx2
   BEQ dcl_bix_ok
   BCS dcl_bix_cx2
dcl_bix_ok:
   RTS

dcl_bix_cx1:
   LDA zp_cb_cx1
   RTS
dcl_bix_cx2:
   LDA zp_cb_cx2
   RTS
dcl_bix_mid:
; Fallback: return midpoint
   LDA zp_cb_cx1
   CLC
   ADC zp_cb_cx2
   ROR A
   RTS

; --- dcl_emit_segment: write segment to LINE_OUT_BUF and call rasteriser ---
; Input: zp_seg_start_x, zp_seg_start_y, zp_ox1 (end_x), zp_tmp0 (end_y)
; Clobbers: A, Y
;
; Pipeline (pseudocode):
;   if start == end: return                       # degenerate point
;   if either Y outside [Y_BIAS, VIS_YMAX]:
;       yband-clip segment; if fully off-screen: return
;   if records mode and xl < xr:                  # skip useless records
;       append record (xl, yl, xr, yr); records[0] += 1
;   append (xl, yl-Y_BIAS, xr, yr-Y_BIAS) to LINE_OUT_BUF and the
;   rasteriser ZP args; bump LINE_OUT_COUNT
;   tail-call plot_h / plot_v / RASTER_ENTRY by segment axis
dcl_emit_segment:
; Skip degenerate segments (zero-length).
   LDA zp_seg_start_x
   CMP zp_ox1
   BNE dcl_es_ok
   LDA zp_seg_start_y
   CMP zp_tmp0
   BNE dcl_es_ok
   RTS                                     ; degenerate
dcl_es_ok:
; --- Y-band safety clip: clamp biased Y to [Y_BIAS, VIS_YMAX] so the
; un-bias below can't wrap an off-screen Y into a wild row address.  The
; tighten can produce spans whose aperture extends off-screen (a floor/
; ceil edge projecting beyond the screen, not clamped), so the DCL's
; aperture clip can still hand us an off-screen segment (e.g. the BL=241
; span at 1000,-3160,156).  Needed until the tighten clamps apertures to
; [Y_BIAS,VIS_YMAX].  In-band segments are byte-identical (4 compares).
   LDA zp_seg_start_y
   CMP #Y_BIAS
   BCC dcl_es_yband
   CMP #(VIS_YMAX + 1)
   BCS dcl_es_yband
   LDA zp_tmp0
   CMP #Y_BIAS
   BCC dcl_es_yband
   CMP #(VIS_YMAX + 1)
   BCS dcl_es_yband
   JMP dcl_es_record
dcl_es_yband:
   JSR dcl_yband_clip
   BCC dcl_es_record
   RTS                                     ; fully off-screen -> drop segment
dcl_es_record:
; --- Records hook: ONE record per surviving segment ---
; Segment record format: 4 bytes (xl, yl, xr, yr).
; Triggers exactly when DCL emits a visible segment, regardless of how
; many pool spans the segment crossed. Tighten consumer derives
; everything from these 4 endpoint values via interp.
   LDA zp_dcl_rec_buf_h
   BEQ dcl_es_no_record
; (A) Skip degenerate records where xl >= xr (zero-width xl==xr OR reversed
; xl>xr). Such a record carries no tighten information AND deadlocks
; tfs_inner: bot_dom needs xl<=cur<xr (impossible when xl>=xr), so the
; cursor never advances and the inner loop spins forever. Edge-on segs that
; project to one column give xl==xr (e.g. 1308,-3289,252); the per-span
; clip can also emit a 1-column REVERSED sliver xl>xr (e.g. 1160,-3400,102
; after the continuation/entry clip fix). The segment is already drawn
; above; only the (useless) tighten record is dropped.
   LDA zp_seg_start_x
   CMP zp_ox1
   BCS dcl_es_no_record
   LDY zp_dcl_rec_off
   LDA zp_seg_start_x
   STA (zp_dcl_rec_buf),Y
   INY
   LDA zp_seg_start_y
   STA (zp_dcl_rec_buf),Y
   INY
   LDA zp_ox1
   STA (zp_dcl_rec_buf),Y
   INY
   LDA zp_tmp0
   STA (zp_dcl_rec_buf),Y
   INY
   STY zp_dcl_rec_off
   LDY #0
   LDA (zp_dcl_rec_buf),Y
   BUMP
   STA (zp_dcl_rec_buf),Y
dcl_es_no_record:
; LINE_OUT capture is wrapper-only (LINE_OUT_EN): native emits stage the
; rasteriser args directly.
   LDA LINE_OUT_EN
   BNE des_cap
   LDA zp_seg_start_x
   STA RASTER_ZP_X0
   LDA zp_seg_start_y
   SEC
   SBC #Y_BIAS
   STA RASTER_ZP_Y0
   LDA zp_ox1
   STA RASTER_ZP_X1
   LDA zp_tmp0
   SEC
   SBC #Y_BIAS
   STA RASTER_ZP_Y1
   JMP des_dispatch
des_cap:
   LDY LINE_OUT_COUNT
   LDA zp_seg_start_x
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_X0
   INY
   LDA zp_seg_start_y
   SEC
   SBC #Y_BIAS
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_Y0
   INY
   LDA zp_ox1
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_X1
   INY
   LDA zp_tmp0
   SEC
   SBC #Y_BIAS
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_Y1
   INY
   STY LINE_OUT_COUNT
des_dispatch:
; --- axis dispatch: ~70% of rasterised pixels are in horizontal or
; vertical segments (gradient census 2026-07-05) — route them to the
; dedicated plotters instead of the generic NJ machinery ---
   LDA RASTER_ZP_Y0
   CMP RASTER_ZP_Y1
   BNE des_not_h
   JMP plot_h
des_not_h:
   LDA RASTER_ZP_X0
   CMP RASTER_ZP_X1
   BNE des_diag
   JMP plot_v
des_diag:
; (A run-slice plotter for shallow diagonals was measured-and-rejected
; here 2026-07-05: pixel-exact — proven by a 16k-sequence oracle check
; and a 15,872-draw framebuffer battery — but slower: NJ's shallow path
; is already run-accumulating at ~11 cyc/px and E1M1 lacks enough
; sub-1:33 lines to amortize even the dispatch test. See the
; 'experiment: run-slice' commit to revive.)
   JMP RASTER_ENTRY                        ; tail-call rasteriser

.endscope

; --- dcl_yband_clip: clip emit segment to visible Y band [Y_BIAS,VIS_YMAX].
; In: zp_seg_start_x/y, zp_ox1, zp_tmp0 (u8 biased). Out: clipped; C clear=keep,
; C set=reject. Uses s16_interp axis-swapped (free=Y,target=X); LC_OX*/OY*
; anchors preserved across the call so both ends clip against the ORIGINAL line.
;
; Cohen-Sutherland-style: count endpoints above the band (X reg) and
; below it (Y reg); 2 on the same side = trivial reject; otherwise each
; out-of-band endpoint is moved to its band edge with X recomputed by
; interpolation along the original segment.
; Pseudocode:
;   if y1 < LO and y2 < LO: reject      # LO = Y_BIAS, HI = VIS_YMAX
;   if y1 > HI and y2 > HI: reject
;   for each endpoint (x, y):
;       if y < LO: x = interp_x_at(LO); y = LO
;       if y > HI: x = interp_x_at(HI); y = HI
;   keep
dcl_yband_clip:
.scope
; --- Load s16_interp anchors, axis-swapped: free axis (OX*) = Y,
; target axis (OY*) = X.  Hi bytes zero — all values are u8. ---
   LDA zp_seg_start_y
   STA LC_OX1_LO
   LDA zp_tmp0
   STA LC_OX2_LO
   LDA zp_seg_start_x
   STA LC_OY1_LO
   LDA zp_ox1
   STA LC_OY2_LO
   LDA #0
   STA LC_OX1_HI
   STA LC_OX2_HI
   STA LC_OY1_HI
   STA LC_OY2_HI
; --- Outcode census: X = #endpoints above band (y < Y_BIAS),
; Y = #endpoints below band (y > VIS_YMAX) ---
   LDX #0
   LDY #0
   LDA zp_seg_start_y
   CMP #Y_BIAS
   BCC yb_e1_lo
   CMP #(VIS_YMAX + 1)
   BCS yb_e1_hi
   JMP yb_e2
yb_e1_lo:
   INX
   JMP yb_e2
yb_e1_hi:
   INY
yb_e2:
   LDA zp_tmp0
   CMP #Y_BIAS
   BCC yb_e2_lo
   CMP #(VIS_YMAX + 1)
   BCS yb_e2_hi
   JMP yb_decide
yb_e2_lo:
   INX
   JMP yb_decide
yb_e2_hi:
   INY
yb_decide:
; Both endpoints on the same off-screen side -> trivial reject.
   CPX #2
   BEQ yb_reject
   CPY #2
   BEQ yb_reject
; --- Endpoint 1 (seg_start): if out of band, interpolate X at the
; band edge and clamp Y to that edge ---
   LDA zp_seg_start_y
   CMP #Y_BIAS
   BCC yb_c1_lo
   CMP #(VIS_YMAX + 1)
   BCC yb_c1_done
   LDA #VIS_YMAX
   STA LC_TGT_LO
   LDA #0
   STA LC_TGT_HI
   JSR s16_interp
   STA zp_seg_start_x
   LDA #VIS_YMAX
   STA zp_seg_start_y
   JMP yb_c1_done
yb_c1_lo:
   LDA #Y_BIAS
   STA LC_TGT_LO
   LDA #0
   STA LC_TGT_HI
   JSR s16_interp
   STA zp_seg_start_x
   LDA #Y_BIAS
   STA zp_seg_start_y
yb_c1_done:
; --- Endpoint 2 (end_x/end_y in zp_ox1/zp_tmp0): same treatment ---
   LDA zp_tmp0
   CMP #Y_BIAS
   BCC yb_c2_lo
   CMP #(VIS_YMAX + 1)
   BCC yb_c2_done
   LDA #VIS_YMAX
   STA LC_TGT_LO
   LDA #0
   STA LC_TGT_HI
   JSR s16_interp
   STA zp_ox1
   LDA #VIS_YMAX
   STA zp_tmp0
   JMP yb_c2_done
yb_c2_lo:
   LDA #Y_BIAS
   STA LC_TGT_LO
   LDA #0
   STA LC_TGT_HI
   JSR s16_interp
   STA zp_ox1
   LDA #Y_BIAS
   STA zp_tmp0
yb_c2_done:
   CLC
   RTS
yb_reject:
   SEC
   RTS
.endscope

; --- line_interp_store: compute line Y at column A ---
; Reads directly from zp_line_xl_lo/yl/yr/dx — no shuffle into the
; interp workspace needed.  Defers div_den setup past offset-zero
; and offset-max shortcuts.
; Input: A = x column.  Output: A = line Y.
; Clobbers: Y, mul_b, prod_*, div_*.
;
; Python mirror: _interp_store (endpoint_spans.py) with anchors
; (xl,yl)-(xr,yr): direction-split unsigned round-to-nearest —
;   off = x - xl
;   if yr >= yl: return yl + (off*(yr-yl) + dx//2) // dx
;   else:        return yl - (off*(yl-yr) + dx//2) // dx
; The multiply-round-divide is umul_round_div (umul8 + den/2 bias +
; udiv16_8).  Descending path negates via EOR #$FF / SEC ADC yl
; (= yl - q).  Entry points:
;   dcl_line_y_at_ox0 — x taken from zp_ox0 (literal $E9 keeps ZP
;                       addressing despite the forward reference)
;   dcl_line_y_at_a   — x in A
dcl_line_y_at_ox0:
   LDA zp_ox0                              ; (was a hardcoded $E9 "forward
; ref" — zp.inc is included first, the symbol resolves fine; the literal
; silently missed the 2026-07-10 relocation and read struct sy garbage)
dcl_line_y_at_a:
line_interp_store:
.scope
   SEC
   SBC zp_line_xl_lo
   BEQ lis_yl
; offset=0 → yl
   CMP zp_line_dx
   BEQ lis_yr
; offset=dx → yr
   STA zp_mul_b
   LDY zp_line_dx
   STY zp_div_den
; Direction check
   LDA zp_line_yr_lo
   CMP zp_line_yl_lo
   BEQ lis_yl
   BCC lis_desc
; |||
; ASCENDING: dy = yr - yl (unsigned)
   SEC
   SBC zp_line_yl_lo
   JSR umul_round_div
   CLC
   ADC zp_line_yl_lo
   RTS
lis_desc:
; DESCENDING: |dy| = yl - yr (unsigned)
   LDA zp_line_yl_lo
   SEC
   SBC zp_line_yr_lo
   JSR umul_round_div
   EOR #$FF
   SEC
   ADC zp_line_yl_lo
   RTS
lis_yl:
   LDA zp_line_yl_lo
   RTS
lis_yr:
   LDA zp_line_yr_lo
   RTS
.endscope

; ======================================================================
; CLIP_LINE_RECORDS / TIGHTEN_FROM_RECORDS — Phase B records-driven tighten
;
; Records-driven tighten architecture: clip_line_records walks the active
; span list and writes per-span sub-records describing the line vs span
; aperture relationship; tighten_from_records consumes the top+bot records
; and applies the narrowing. Replaces the existing draw_clipped+tighten
; pair for portal segs in records mode.
;
; Inputs (caller writes ZP):
;   zp_line_xl_lo, zp_line_yl_lo, zp_line_xr_lo, zp_line_yr_lo  — line endpoints (u8)
;   zp_ilo, zp_ihi                                  — clamp range (u8)
; Output: records buffer pointed to by zp_buf is populated.
; ======================================================================

; ===== Records mode ZP aliases =====
; Reuse tighten ZP slots since the two modes never run concurrently.
; Per-sub-range scratch (overlap with tighten temps):
