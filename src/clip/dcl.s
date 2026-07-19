
; ============================================================================
; clip/dcl.s — clipper fragment 7 of 10 (module map: clip/header.s).
; Contents: draw_clipped_line + dcl_vertical, the CB
; trapezoid clip, dcl_boundary_ix, dcl_emit_segment (records writer +
; plot dispatch), dcl_yband_clip, and line_interp_store.
; ============================================================================

; ======================================================================
; DRAW_CLIPPED_LINE: clip a single line against the span list and plot
; the visible portions (plot_h / plot_v / NJ rasteriser).
;
; Reached natively THROUGH dcl_s16.s (draw_clipped_line_s16[_h] falls
; through / jumps here once coords are u8); the direct u8 entry
; draw_clipped_line is used by the Python harness (by symbol
; on the bsp side).  Banked build: bank C must already be paged.
;
; Phase 1: basic walk with outer bbox reject / inner bbox accept.
; No CB clip (ambiguous cases skipped), no portal continuation
; (each span is considered independently).
;
; Inputs (ZP): zp_line_xl_l, zp_line_yl_l, zp_line_xr_l, zp_line_yr_l
; The line MUST be oriented left-to-right (xl <= xr).
; All Y values u8, biased by Y_BIAS (visible rows [0,159] -> [48,207]).
;   zp_head                = first slot of the sorted active span list
;   zp_dcl_rec_buf(_h)     = segment-record buffer ptr; hi byte $00
;                            disables records mode entirely
;
; Output: each surviving segment is staged into RASTER_ZP_X0..Y1 (Y
; un-biased) and dispatched to plot_h / plot_v / RASTER_ENTRY as it is
; produced.  Only when LINE_OUT_EN is set (HARNESS-ONLY — the buffer
; overlaps the D-cache; see the note in clip/arith.s) is each segment
; also appended to LINE_OUT_BUF (4 bytes: x0,y0,x1,y1, Y un-biased,
; count at LINE_OUT_COUNT).  In records mode, one 4-byte record
; (xl,yl,xr,yr — BIASED Y) per surviving segment is appended to the
; record buffer (count in byte 0) for the records-driven tighten
; (consumer: tighten_from_records, clip/tfr.s).
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
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BNE dcl_not_vert
   JMP dcl_vertical
dcl_not_vert:
; --- Compute dx, dy, ylo, yhi ---
   LDA zp_line_xr_l
   SEC
   SBC zp_line_xl_l
   STA zp_line_dx
   LDA zp_line_yr_l
   SEC
   SBC zp_line_yl_l
   STA zp_line_dy

; (initial ylo/yhi min-max deleted 2026-07-14: dcl_entry_path recomputes
; the full-line bbox before every Tier read, and the continuation path
; only narrows values the entry pass wrote — the block was dead work on
; every non-vertical line)

; (Records-mode init moved to ARM time — bsp/subsector.s dcl_rec_arm,
; 2026-07-13: the s16 band clip appends verdict records before this
; core runs, and rejected lines never reach it.)
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
; Skip if xend <= xl (strict: pixel-center model). xl is LOOP-
; INVARIANT: it rides A across the whole skip walk via an X/Y
; ping-pong advance (the has_gap idiom) — the old inline advance
; reloaded it every span because LDA POOL_NEXT/TAX consumed A.
   LDA zp_line_xl_l
dclw_x:
   CMP POOL_XEND,X
   BCC dcl_not_left
   LDY POOL_NEXT,X
   BEQ dclw_flush
   CMP POOL_XEND,Y
   BCC dclw_found_y
   LDX POOL_NEXT,Y
   BNE dclw_x
dclw_flush:
   JMP dcl_flush
dclw_found_y:
   TYA
   TAX                                     ; canonicalize: span rides X into
                                           ; the right-skip test below
dcl_not_left:

; --- Skip spans entirely right of line ---
; Done if xstart >= xr (all remaining spans are further right)
   LDA POOL_XSTART,X
   CMP zp_line_xr_l
   BCC dcl_in_range
   JMP dcl_flush                           ; xstart >= xr → done
dcl_in_range:

; --- Compute overlap ---
; ox0 = max(xstart, xl) — A already holds POOL_XSTART,X from skip check
   CMP zp_line_xl_l
   BCS dcl_ox0_ok
   LDA zp_line_xl_l
dcl_ox0_ok:
   STA zp_ox0
; ox1 = min(xend, xr)
   LDA POOL_XEND,X
   CMP zp_line_xr_l
   BCC dcl_ox1_ok
   LDA zp_line_xr_l
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
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BCS dcl_ep_yge
   STA zp_line_y_l
   LDA zp_line_yr_l
   STA zp_line_y_h
   JMP dcl_ep_done
dcl_ep_yge:
   STA zp_line_y_h
   LDA zp_line_yr_l
   STA zp_line_y_l
dcl_ep_done:

; ========== ENTRY: seg_start is NULL ==========
; --- Tier 1: outer bbox reject ---
   LDA zp_line_y_h
   CMP POOL_OT,X
   BCC dcl_reject_above
; yhi < OT → line above aperture
   LDA POOL_OB,X
   CMP zp_line_y_l
   BCC dcl_reject_below
; OB < ylo → line below aperture

; --- Tier 2: inner bbox accept ---
   LDA zp_line_y_l
   CMP POOL_IT,X
   BCC dcl_amb_jmp
; ylo < max(tl,tr) → CB clip
   LDA POOL_IB,X
   CMP zp_line_y_h
   BCS dcl_accept
; min(bl,br) >= yhi → accept
; yhi > ib → ambiguous
dcl_amb_jmp:
   JMP dcl_cb_clip

dcl_reject_above:
   LDA zp_dcl_rec_buf_h                    ; records off: plain reject
   BEQ dcl_outer_reject
   LDA #0                                  ; verdict 'above' over [ox0,ox1]
   BEQ dcl_rej_rec                         ; (always)
dcl_reject_below:
   LDA zp_dcl_rec_buf_h
   BEQ dcl_outer_reject
   LDA #$FF                                ; verdict 'below'
dcl_rej_rec:
   JSR dcl_rec_flat_span
dcl_outer_reject:
; Outer reject → advance to next span (inline; JMP — the ping-pong
; walk pushed dcl_walk2 out of branch range, and an always-guarded
; BNE+JMP pair costs the same as the test+JMP form)
   LDA POOL_NEXT,X
   TAX
   BEQ dclor_flush
   JMP dcl_walk2
dclor_flush:
   JMP dcl_flush

; ── dcl_accept: record seg_start for an inner-bbox-accepted entry ──
; Sets seg_start = (ox0, line_y_at(ox0)).
; Three cases converge at STA zp_seg_start_y:
;   ox0 == xl  → A = yl      (common: line starts at/before span)
;   dy == 0    → A = yl      (flat line, y constant everywhere)
;   else       → A = interp  (rare: line enters span mid-way)
; The rare interp path uses BIT abs to skip the LDA zp_line_yl_l.
dcl_accept:
   LDA zp_ox0
   STA zp_seg_start_x
   CMP zp_line_xl_l
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
   LDA zp_line_yl_l
   STA zp_seg_start_y
; (Records hook moved to dcl_emit_segment — one record per surviving
;  segment, not per-span.)
; Fall through to exit check

dcl_exit_check:
; ========== EXIT CHECK ==========
; Does the line end within this span? (xr <= xend)
   LDA POOL_XEND,X
   CMP zp_line_xr_l
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
; (X = save0 rides in from the abutting test — no reload)
   LDY zp_line_dy
   BEQ dcl_pp_use_yr
   LDA POOL_XEND,X
   CMP zp_line_xr_l
   BEQ dcl_pp_use_yr
   JSR dcl_line_y_at_a                     ; A = xend already
   .byte $2C                               ; BIT abs: skip LDA yr
dcl_pp_use_yr:
   LDA zp_line_yr_l
; bbox of the line over [boundary, xr] = [min(ly,yr), max(ly,yr)].
; (A = ly rides both arms — the zp_tmp2 shuttle is gone)
   CMP zp_line_yr_l
   BCS dcl_pp_ly_ge
   STA zp_tmp0
   LDA zp_line_yr_l
   STA zp_tmp1
; ly < yr: lo=ly, hi=yr
   JMP dcl_pp_bbox
dcl_pp_ly_ge:
   STA zp_tmp1
   LDA zp_line_yr_l
   STA zp_tmp0
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
   STA zp_line_y_l
   LDA zp_tmp1
   STA zp_line_y_h
   TYA
   TAX
   BEQ dclwb_flush0                        ; (entry guard bypassed: TAX's Z
   JMP dcl_walk2                           ; answers the null test here)
dclwb_flush0:
   JMP dcl_flush

; (dcl_exit_no_portal_a — the 'restore X for emit' alias — is retired:
; no caller remained, and every entry below arrives with X = save0
; already, dfscan-proven.)
dcl_exit_no_portal:
; Portal failed or closed: emit current segment and reset.
; Compute exit point Y — three cases converge at dcl_exit_emit via
; chained BIT abs tricks (interp skips yl, yl skips yr):
;   xend == xr → A = yr
;   dy == 0    → A = yl
;   else       → A = line_y_at(xend)
   LDA POOL_XEND,X
   STA zp_ox1                              ; end_x = xend of current span
   CMP zp_line_xr_l
   BEQ dcl_exit_use_yr
   LDY zp_line_dy
   BEQ dcl_exit_use_yr
; dy==0 → yr (== yl for flat lines)
; xend < xr, sloped: interp (A = xend still)
   JSR dcl_line_y_at_a
   .byte $2C                               ; BIT abs: skip LDA yr
dcl_exit_use_yr:
   LDA zp_line_yr_l
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
   BEQ dclwb_flush1                        ; (entry guard bypassed: TAX's Z
   JMP dcl_walk2                           ; answers the null test here)
dclwb_flush1:
   JMP dcl_flush

dcl_line_ends:
; Line ends within this span. Emit seg_start → (xr, yr)
; (STX zp_save0 deleted: the tail-call consumes the line; no reader)
   LDA zp_line_yr_l
   STA zp_tmp0
; end_y = yr
   LDA zp_line_xr_l
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
   LDA zp_line_yr_l
   STA zp_tmp0
   LDA zp_line_xr_l
   STA zp_ox1
   JMP dcl_emit_segment                    ; tail call
dcl_done:
   RTS

; ========== Vertical line handler ==========
; For xl == xr: find the first span containing column xl, compute
; aperture [top_y, bot_y] at that column, clip [ylo, yhi] to aperture,
; emit single vertical line segment.  Matches Python's draw_clipped
; vertical path (break on first span containing ix).
;
; Inputs:  zp_line_xl_l (== xr), zp_line_yl_l, zp_line_yr_l; zp_head.
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
   LDA zp_line_yl_l
   LDX zp_line_yr_l
   CMP zp_line_yr_l
   BCC dv_yl_lo
   STA zp_line_y_h
   STX zp_line_y_l
   JMP dv_bbox_done
dv_yl_lo:
   STA zp_line_y_l
   STX zp_line_y_h
dv_bbox_done:
   ZERO LINE_OUT_COUNT
   LDX zp_head
dv_walk:
   BNE dv_check
   RTS                                     ; span list exhausted
dv_check:
; Skip if xend < xl (span entirely left of column — strict)
   LDA POOL_XEND,X
   CMP zp_line_xl_l
   BCC dv_next
; Done if xstart > xl (span entirely right of column; list sorted)
   LDA zp_line_xl_l                        ; INVERTED (audit 2026-07-19):
   CMP POOL_XSTART,X                       ; C = xl >= xstart — one BCS
   BCS dv_in                               ; replaces the BEQ/BCC pair
   RTS
dv_next:
   LDA POOL_NEXT,X
   TAX
   BNE dv_check                            ; direct loop-back (the head's
   RTS                                     ; BNE is the entry test only)
dv_in:
; Span contains column xl. Compute top_y and bot_y at xl.
   STX zp_save0
; Top: constant-line fast path or interp
   LDA POOL_TL,X
   CMP POOL_TR,X
   BNE dv_top_interp
   STA zp_cb_top1
   BEQ dv_top_done                         ; Z=1 from the TL==TR CMP
dv_top_interp:
   LDA POOL_XLO,X
   STA zp_i_x0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA POOL_TL,X
   STA zp_i_y0
   LDA POOL_TR,X
   STA zp_i_y1
   LDA zp_line_xl_l
   JSR interp_store
   STA zp_cb_top1
dv_top_done:
; Bot: constant-line fast path or interp
   LDX zp_save0
   LDA POOL_BL,X
   CMP POOL_BR,X
   BNE dv_bot_interp
   STA zp_cb_bot1
   BEQ dv_bot_done                         ; Z=1 from the BL==BR CMP
dv_bot_interp:
   LDA POOL_XLO,X
   STA zp_i_x0
   LDA POOL_DEN,X
   STA zp_div_den
   LDA POOL_BL,X
   STA zp_i_y0
   LDA POOL_BR,X
   STA zp_i_y1
   LDA zp_line_xl_l
   JSR interp_store
   STA zp_cb_bot1
dv_bot_done:
; Clip [ylo, yhi] to [top_y, bot_y]
; cy1 = max(ylo, top_y)
   LDA zp_line_y_l
   CMP zp_cb_top1
   BCS dv_cy1_ok
   LDA zp_cb_top1
dv_cy1_ok:
   STA zp_cb_cy1
; cy2 = min(yhi, bot_y)
   LDA zp_line_y_h
   CMP zp_cb_bot1
   BCC dv_cy2_ok
   LDA zp_cb_bot1
dv_cy2_ok:
   STA zp_cb_cy2
; Emit if cy1 <= cy2  (swapped compare: cy2 >= cy1 is one BCS;
; A = cy2 rides out of both min() arms)
   CMP zp_cb_cy1
   BCS dv_emit
   RTS                                     ; line clipped away
dv_emit:
; Stage the rasteriser ZP args (x, cy1, x, cy2), un-biasing Y (biased
; [48,207] -> screen [0,159]) and tail-call the vertical plotter.
; LINE_OUT capture is wrapper-only (LINE_OUT_EN — see arith.s): the
; native path skips the buffer entirely.
   LDA LINE_OUT_EN
   BNE dv_emit_cap
   LDA zp_line_xl_l
   STA RASTER_ZP_X0
   STA RASTER_ZP_X1
   LDA zp_cb_cy1
   SBC #Y_BIAS                             ; C=1 from the BCS dv_emit guard
   STA RASTER_ZP_Y0
   LDA zp_cb_cy2
   SBC #Y_BIAS                             ; C=1 from the in-band SBC
   STA RASTER_ZP_Y1
   JMP plot_v
dv_emit_cap:
   LDY LINE_OUT_COUNT
   LDA zp_line_xl_l
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_X0
   INY
   LDA zp_cb_cy1
   SEC
   SBC #Y_BIAS
   STA LINE_OUT_BUF,Y
   STA RASTER_ZP_Y0
   INY
   LDA zp_line_xl_l
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
; verdict-record housekeeping: no pending right verdict; stash the
; span's true ox1 (the mid-span-exit path overwrites zp_ox1)
   LDA zp_dcl_rec_buf_h
   BEQ dcl_cb_nvrec
   LDA #$80
   STA DCLV_RVY
   LDA zp_ox1
   STA DCLV_OX1S
dcl_cb_nvrec:

; Step 1: X-clip line to [xstart, xend] = [ox0, ox1]
; cx1 = ox0
   LDA zp_ox0
   STA zp_cb_cx1
; cx2 = ox1
   LDA zp_ox1
   STA zp_cb_cx2

; Step 2: Compute line Y at clipped X endpoints
; dy==0 fast path: flat line → cy1 = cy2 = yl (skips the line-mode
; preset below — its only consumers are the two interps in cy_slow)
   LDA zp_line_dy
   BNE dcl_cb_cy_slow
   LDA zp_line_yl_l
   STA zp_cb_cy1
   STA zp_cb_cy2
   JMP dcl_cb_cy_done
dcl_cb_cy_slow:
; Pre-set interp workspace to line-mode so both cy interps can call
; interp_store directly (no shuffle).
   LDA zp_line_xl_l
   STA zp_i_x0
   LDA zp_line_yl_l
   STA zp_i_y0
   LDA zp_line_yr_l
   STA zp_i_y1
   LDA zp_line_dx
   STA zp_div_den
; cy1 = line_y_at(cx1). CMP preserves A, so interp reuses it.
; Interp workspace already in line-mode — call interp_store directly.
   LDA zp_cb_cx1
   CMP zp_line_xl_l
   BEQ dcl_cb_cy1_yl
   JSR interp_store
   .byte $2C
; BIT abs: skip LDA
dcl_cb_cy1_yl:
   LDA zp_line_yl_l
   STA zp_cb_cy1

; cy2 = line_y_at(cx2)
   LDA zp_cb_cx2
   CMP zp_line_xr_l
   BEQ dcl_cb_cy2_yr
   JSR interp_store
   .byte $2C
; BIT abs: skip LDA
dcl_cb_cy2_yr:
   LDA zp_line_yr_l
   STA zp_cb_cy2
dcl_cb_cy_done:

; ── Step 3: Top boundary ──────────────────────────────────────────
; Bbox filter: if both cy values are below the span's tightest top
; (cy >= IT = max(tl,tr) for both endpoints), the line can't cross
; the top boundary anywhere.  Skip top eval + clip entirely.
   LDX zp_save0
   CMP POOL_IT,X                           ; A = cy2 from both cy paths
   BCC dcl_cb_top_eval
   LDA zp_cb_cy1
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
   BEQ dcl_cb_top_evaled                   ; Z=1 from the TL==TR CMP
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
; d1 = cy1 - top1 >= 0  (=> C=1: no SEC for the next subtract)
   LDA zp_cb_cy2
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
dcl_cb_top_cy2_const:                      ; BEQ lands here with A = top1
   STA zp_cb_cy2
   LDA #0                                  ; exit was through the TOP:
   STA DCLV_RVY                            ; [cx2, orig ox1] pends 'above'
   JMP dcl_cb_top_done

dcl_cb_top_clip:
; cy1 < top1, cy2 >= top2: clip at p1 end (entered via BCS => C=1)
   LDA zp_cb_cy1
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
dcl_cb_top_cy1_const:                      ; BEQ lands here with A = top1
   STA zp_cb_cy1
   LDA zp_dcl_rec_buf_h
   BEQ dcl_cb_top_done
   LDA #0                                  ; [ox0, cx1] was above the aperture
   JSR dcl_rec_flat_left

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
   CMP zp_cb_cy2                           ; A = IB still
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
   BEQ dcl_cb_bot_eval_done                ; Z=1 from the BL==BR CMP
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
dcl_cb_bot_cy2_const:                      ; BEQ lands here with A = bot1
   STA zp_cb_cy2
   LDA #$FF                                ; exit through the BOTTOM:
   STA DCLV_RVY                            ; [cx2, orig ox1] pends 'below'
   JMP dcl_cb_bot_done

dcl_cb_bot_clip:
; bot1 < cy1, bot2 >= cy2: clip p1 end (entered via BCS => C=1)
   LDA zp_cb_cy1
   SBC zp_cb_bot1
   STA zp_tmp0
; d1 > 0  (=> C=1 again)
   LDA zp_cb_cy2
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
dcl_cb_bot_cy1_const:                      ; BEQ lands here with A = bot1
   STA zp_cb_cy1
   LDA zp_dcl_rec_buf_h
   BEQ dcl_cb_bot_done
   LDA #$FF                                ; [ox0, cx1] was below the aperture
   JSR dcl_rec_flat_left

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
   CMP zp_ox1                              ; A = cx2 from the reject test
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
   JSR dcl_rec_right                       ; pending [cx2, orig ox1] verdict
   LDA #$FF
   STA zp_seg_start_x
   LDX zp_save0
   LDA POOL_NEXT,X
   TAX
   BEQ dclwb_flush2                        ; (entry guard bypassed: TAX's Z
   JMP dcl_walk2                           ; answers the null test here)
dclwb_flush2:
   JMP dcl_flush

dcl_cb_no_exit_clip:
; cx2 == ox1: CB did not clip the exit. Set seg_start = (cx1, cy1)
; and fall through to the normal exit check (portal or line_ends).
; Segment record written by dcl_emit_segment when the segment closes.
   LDX zp_save0
   LDA zp_cb_cx1
   STA zp_seg_start_x
   LDA zp_cb_cy1
   STA zp_seg_start_y
; Update Y bbox for portal checks (A = cy1 still)
   CMP zp_cb_cy2
   BCC dcl_cb_ylo_ok
; cy1 >= cy2
   STA zp_line_y_h
   LDA zp_cb_cy2
   STA zp_line_y_l
   JMP dcl_cb_bbox_done
dcl_cb_ylo_ok:
; cy1 < cy2
   STA zp_line_y_l
   LDA zp_cb_cy2
   STA zp_line_y_h
dcl_cb_bbox_done:
; (X = save0 still: nothing above touched it since the entry load)
   JMP dcl_exit_check

dcl_cb_reject_above:
   LDA zp_dcl_rec_buf_h
   BEQ dcl_cb_reject
   LDA #0                                  ; whole overlap above the aperture
   BEQ dcl_cb_rej_rec                      ; (always)
dcl_cb_reject_below:
   LDA zp_dcl_rec_buf_h
   BEQ dcl_cb_reject
   LDA #$FF
dcl_cb_rej_rec:
   JSR dcl_rec_flat_span
dcl_cb_reject:
; CB clip rejected — skip this span
   LDX zp_save0
   LDA POOL_NEXT,X
   TAX
   BEQ dclwb_flush3                        ; (entry guard bypassed: TAX's Z
   JMP dcl_walk2                           ; answers the null test here)
dclwb_flush3:
   JMP dcl_flush

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
   JSR umul8                               ; prod = dx * |d1| → zp_prod_l:hi

; Directed rounding: if clip_p1, add (denom-1) to numerator before divide
; (ceiling division). If !clip_p1, just floor division.
   LDA zp_save1
   BEQ dcl_bix_no_round
; Add (denom - 1) in one pass: den + $FF with C=0 in (the guards above
; fell through) = den-1 with C=1 out (den >= 1), then + prod_l.
   LDA zp_div_den
   ADC #$FF
   CLC
   ADC zp_prod_l
   STA zp_div_l
   BCC dcl_bix_no_round
   INC zp_div_h
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
   BCS dcl_bix_cx2                         ; == returns cx2 (same value)
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

; --- dcl_emit_segment: stage a segment to the rasteriser (plus the
;     harness-only LINE_OUT capture and the optional tighten record) ---
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
   BNE dcl_es_ok_noreload
   RTS                                     ; degenerate
dcl_es_ok:
; --- Y-band safety clip: clamp biased Y to [Y_BIAS, VIS_YMAX] so the
; un-bias below can't wrap an off-screen Y into a wild row address.  The
; tighten can produce spans whose aperture extends off-screen (a floor/
; ceil edge projecting beyond the screen, not clamped), so the DCL's
; aperture clip can still hand us an off-screen segment (e.g. the BL=241
; span at 1000,-3160,156).  Needed until the tighten clamps apertures to
; [Y_BIAS,VIS_YMAX].  In-band segments are byte-identical (4 compares).
   LDA zp_seg_start_y                      ; (x-differ path only: the y-differ
dcl_es_ok_noreload:                        ; BNE arrives with start_y live)
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
   STA (zp_dcl_rec_buf),Y                  ; A = start_x still
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
   ADC #1                                  ; C=0 from the xl>=xr BCS guard
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
   SBC #Y_BIAS                             ; C=1 from the Y0 unbias
   STA RASTER_ZP_Y1
; native path falls straight into des_dispatch (the wrapper-only
; capture path, below the dispatcher, pays the join JMP instead)
des_dispatch:
; --- axis dispatch: ~70% of rasterised pixels are in horizontal or
; vertical segments (gradient census 2026-07-05) — route them to the
; dedicated plotters instead of the generic NJ machinery ---
; (A = Y1 on both entry paths)
   CMP RASTER_ZP_Y0
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

; wrapper-only capture path (LINE_OUT_EN): moved below the dispatcher so
; the native path falls straight through; this path pays the join JMP.
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
   JMP des_dispatch

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
   STA LC_TGT_HI                           ; hoisted from all 4 clip arms
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
   JSR s16_interp
   STA zp_seg_start_x
   LDA #VIS_YMAX
   STA zp_seg_start_y
   JMP yb_c1_done
yb_c1_lo:
   LDA #Y_BIAS
   STA LC_TGT_LO
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
   JSR s16_interp
   STA zp_ox1
   LDA #VIS_YMAX
   STA zp_tmp0
   JMP yb_c2_done
yb_c2_lo:
   LDA #Y_BIAS
   STA LC_TGT_LO
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
; Reads directly from zp_line_xl_l/yl/yr/dx — no shuffle into the
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
   SBC zp_line_xl_l
   BEQ lis_yl
; offset=0 → yl
   CMP zp_line_dx
   BEQ lis_yr
; offset=dx → yr
   STA zp_mul_b
   LDY zp_line_dx
   STY zp_div_den
; Direction check
   LDA zp_line_yr_l
   CMP zp_line_yl_l
   BEQ lis_yl
   BCC lis_desc
; |||
; ASCENDING: dy = yr - yl (unsigned; C=1 — the BCC above didn't take)
   SBC zp_line_yl_l
   JSR umul_round_div
   CLC
   ADC zp_line_yl_l
   RTS
lis_desc:
; DESCENDING: |dy| = yl - yr (unsigned)
   LDA zp_line_yl_l
   SEC
   SBC zp_line_yr_l
   JSR umul_round_div
   EOR #$FF
   SEC
   ADC zp_line_yl_l
   RTS
lis_yl:
   LDA zp_line_yl_l
   RTS
lis_yr:
   LDA zp_line_yr_l
   RTS
.endscope

; ======================================================================
; RECORDS-DRIVEN TIGHTEN — architecture note (rewritten 2026-07-12)
;
; Shipping path: dcl_emit_segment (above) writes ONE 4-byte record
; (xl, yl, xr, yr) per surviving DCL segment into TOP_RECORDS /
; BOT_RECORDS — routed by zp_dcl_rec_buf (hi byte $07/$08, $00 = off) —
; while the caller draws the portal's yt / yb edge lines;
; tighten_from_records (clip/tfr.s, included next) consumes the two
; buffers and applies the narrowing.  This replaced the old
; draw_clipped + per-span tighten pair for portal segs.
;
; A separate clip_line_records ROUTINE (the Phase-A 6-byte verdict
; records described in older notes) no longer exists in the 6502; the
; name survives only in the Python reference
; (endpoint_spans.clip_line_records), which remains the behavioural
; mirror for what the records must capture.
; ======================================================================
; (End of file — no code below.  The tighten consumer and its TFS_*
; state block are in clip/tfr.s.)


; ============================================================================
; Verdict-record support (2026-07-13 off-screen-aperture fix). In MAIN:
; the CLIP region is at its ceiling; main RAM is always mapped so the
; bank-C clipper JSRs here freely. Absolutes DCLV_* live in tfr.s's block.
; ============================================================================
SEG_HIGH
; dcl_rec_flat — append a FLAT VERDICT record (A = y: 0 'above',
; $FF 'below') over [DCLV_X0, DCLV_X1] to the active record buffer.
; No-op when records mode is off or the range is empty. MERGES into the
; previous record when it is the same flat value and abuts/overlaps
; (double-reject arms can re-cover a range — the merge absorbs it).
; Capacity guard: a full buffer drops the append (never hit in corpus;
; the harness counts). Preserves X. Clobbers A, Y.
dcl_rec_flat:
   STA DCLV_YV
dcl_rec_flat_v:                            ; post-latch entry (DCLV_YV
   LDA zp_dcl_rec_buf_h                    ; already written by wrappers)
   BEQ rf_out
   LDA DCLV_X0
   CMP DCLV_X1
   BCC rf_in                               ; X0 < X1: non-empty range
rf_out:
   RTS
rf_in:
.scope
   STX DCLV_SX
   LDY zp_dcl_rec_off
   CPY #1
   BEQ rf_app                              ; no previous record
   DEY                                     ; prev.yr
   LDA (zp_dcl_rec_buf),Y
   CMP DCLV_YV
   BNE rf_app
   DEY
   DEY                                     ; prev.yl
   LDA (zp_dcl_rec_buf),Y
   CMP DCLV_YV
   BNE rf_app
   INY                                     ; prev.xr
   LDA (zp_dcl_rec_buf),Y
   CMP DCLV_X0
   BCC rf_app                              ; gap -> append fresh
; merge: prev.xr = max(prev.xr, X1)
   CMP DCLV_X1
   BCS rf_restore
   LDA DCLV_X1
   STA (zp_dcl_rec_buf),Y
   JMP rf_restore
rf_app:
   LDY zp_dcl_rec_off
   CPY #$F9
   BCS rf_restore                          ; buffer full -> drop
   LDA DCLV_X0
   STA (zp_dcl_rec_buf),Y
   INY
   LDA DCLV_YV
   STA (zp_dcl_rec_buf),Y
   INY
   LDA DCLV_X1
   STA (zp_dcl_rec_buf),Y
   INY
   LDA DCLV_YV
   STA (zp_dcl_rec_buf),Y
   INY
   STY zp_dcl_rec_off
   LDY #0
   LDA (zp_dcl_rec_buf),Y
   ADC #1                                  ; C=0 proven: BCS rf_restore
   STA (zp_dcl_rec_buf),Y                  ; not taken, INY/LDA keep C
rf_restore:
   LDX DCLV_SX
rf_done:
   RTS
.endscope

; wrappers staging the range, so CLIP call sites stay 5 bytes
dcl_rec_flat_span:                         ; whole overlap [zp_ox0, zp_ox1]
   STA DCLV_YV
   LDA zp_ox0
   STA DCLV_X0
   LDA zp_ox1
   STA DCLV_X1
   JMP dcl_rec_flat_v

dcl_rec_flat_left:                         ; left clip-off [zp_ox0, zp_cb_cx1]
   STA DCLV_YV
   LDA zp_ox0
   STA DCLV_X0
   LDA zp_cb_cx1
   STA DCLV_X1
   JMP dcl_rec_flat_v

; dcl_rec_right — flush the pending right-side verdict after the
; mid-span-exit emit (zp_ox1 == cx2 there; DCLV_OX1S = the span's
; original ox1, stashed at CB entry). $80 = no pending. The pending is
; only armed under records mode, so a stale value can't leak: the
; append itself is gated too.
dcl_rec_right:
   LDA DCLV_RVY
   CMP #$80
   BEQ rr_done
   LDY zp_ox1
   STY DCLV_X0
   LDX DCLV_OX1S
   STX DCLV_X1
   JMP dcl_rec_flat                        ; A = RVY still
rr_done:
   RTS
SEG_BANKC
