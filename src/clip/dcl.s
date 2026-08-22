
; ============================================================================
; clip/dcl.s — clipper fragment 7 of 13 (module map: clip/header.s).
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
; produced.  RUN-OUT at the ranges->pixels boundary (Eben's ruling):
; X1 is staged as the segment's EXCLUSIVE end column and the raster
; paints through it inclusively — no -1 anywhere.  In records mode,
; one 4-byte record (xl,yl,xr,yr — BIASED Y, claiming columns
; [xl, xr)) per surviving segment is appended to the record buffer
; (count in byte 0) for the records-driven tighten (consumer:
; tighten_from_records, clip/tfr.s).  (The old LINE_OUT capture was
; RETIRED 2026-07-26 — the harness PC-traps the plot entries.)
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
; --- Compute dx, dy, ylo, yhi ---
   LDA zp_line_xr_l
   SEC
   SBC zp_line_xl_l
; --- Vertical fast path: xl == xr (trampoline — dcl_vertical out of BEQ range) ---
   BEQ dcl_to_vert                         ; verticals rare here (0.7%,
                                           ; census 2026-07-27): trampoline
                                           ; in the dclw_flush island
   STA zp_line_dx
   LDA zp_line_yr_l
   SEC
   SBC zp_line_yl_l
   STA zp_line_dy

; --- Y bbox: [min(yl,yr), max(yl,yr)] — ONCE per line -----------------
; RESTORED 2026-08-22, reversing the 2026-07-14 deletion.  That deletion
; was right at the time: dcl_entry_path recomputed the bbox before every
; Tier read, so computing it here as well was dead work.  Two things
; changed since.  The deferred-emit restructure made EVERY span run the
; entry path (1.29 times per call, measured), and the portal check's
; death removed both narrowers — the CB no-exit-clip narrowing and the
; portal commit — so nothing writes ylo/yhi mid-walk any more.  yl and yr
; are provably unchanged across a call (asserted by probe: 0 of 411
; entries saw them differ), so the bbox is loop-invariant and belongs
; here.
;
; BELOW the vertical branch on purpose: dcl_vert_on is an EXPORTED entry
; that seg_emit jumps to per vertical descriptor, bypassing this routine
; entirely, and it CLAMPS yl/yr into the u8 band before use — so the
; vertical handler must keep computing its own bbox, after that clamp.
; Hoisting above the branch and deleting the vertical's copy loses every
; descriptor vertical (tried it: walkseq 55 divergent frames).
;
; One compare, loser parked in X:
;   BCC taken => A=yl is the min, X=yr the max
;   else         A<-yr (min),     X<-yl (max)
   LDA zp_line_yl_l
   LDX zp_line_yr_l
   CMP zp_line_yr_l
   BCC dcl_bb_ylt
   TXA
   LDX zp_line_yl_l
dcl_bb_ylt:
   STA zp_line_y_l                         ; min
   STX zp_line_y_h                         ; max

; (Records-mode init moved to ARM time — bsp/subsector.s dcl_rec_arm,
; 2026-07-13: the s16 band clip appends verdict records before this
; core runs, and rejected lines never reach it.)
dcl_records_off:

; seg_start = NULL
   LDA #$FF
   STA zp_seg_start_x

; Walk span list.  Empty list exits via the dclw_flush island (dcl_flush
; is out of branch range); its seg_start test is a provable no-op here,
; seg_start_x having been set to $FF five instructions ago, but the
; empty case does not occur on the suite so it is not worth an island of
; its own.
   LDX zp_head
   BEQ dclw_flush

; --- Skip spans entirely left of line — FIRST ENTRY ONLY ---
; Skip if xend <= xl (strict: pixel-center model). xl is LOOP-
; INVARIANT: it rides A across the whole skip walk via an X/Y
; ping-pong advance (the has_gap idiom) — the old inline advance
; reloaded it every span because LDA POOL_NEXT/TAX consumed A.
;
; Every ADVANCE re-enters below at dcl_not_left, never here, because
; once a span has passed this test the rest of the walk provably cannot
; skip: the survivor has xend > xl, the next span starts at xstart >=
; that xend, and its own xend is larger still, so xend > xl holds for
; every span after.  (Both the dcl_walk and dcl_walk2 labels died with
; that routing — dcl_walk2 existed only to let an advance skip this
; test, which it now does by entering past it.)
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
dcl_to_vert:
   JMP dcl_vertical
dclw_found_y:
   TYA
   TAX                                     ; canonicalize: span rides X into
                                           ; the right-skip test below
dcl_not_left:

; --- Skip spans entirely right of line ---
; Done if xstart >= xr (all remaining spans are further right)
   LDA POOL_XSTART,X
   CMP zp_line_xr_l
   BCS dclw_flush                          ; xstart >= xr → done (18%;
                                           ; backward to the flush island —
                                           ; common case falls, census)

; --- Compute overlap ---
; ox0 = max(xstart, xl) — A already holds POOL_XSTART,X from skip check
   CMP zp_line_xl_l
   BCS dcl_ox0_ok
   LDA zp_line_xl_l
dcl_ox0_ok:
   STA zp_ox0
; ox1 = min(xend, xr).
; ox1 IS THE EXCLUSIVE CLAIM BOUND, not the last painted column: it
; becomes the record's xr (tighten dominates columns [xl, xr)) AND the
; emitted line's right end, which the raster RUNS OUT to paint
; inclusively. So a fragment paints one column past what it claims —
; deliberately, and identically at a span boundary and at the line's
; own endpoint (Eben's run-out ruling, "under all circumstances").
; DO NOT 'fix' this to xend-1: the paint looks tidier for exactly one
; frame and the record then under-claims the span's last open column,
; which under-tightens every portal edge (measured 2026-08-21:
; traversal at (-486,-3307,243) went 6 -> 34 subsectors).
   LDA POOL_XEND,X
   CMP zp_line_xr_l
   BCC dcl_ox1_ok
   LDA zp_line_xr_l
dcl_ox1_ok:
   STA zp_ox1

; --- EVERY span is verified.  There is no "continuation" fast path ---
; NEVER SPLIT A LINE (Eben's rule, 2026-08-22).  A line is drawn WHOLE
; over a contiguous visible run, or clipped; breaking one contiguous run
; into two emitted fragments draws a DIFFERENT line, because each
; fragment is rasterised from its OWN endpoints (measured: splitting at
; an interior column changes the raster 40% of the time).
;
; The old design decided at span N whether to merge into span N+1, using
; a CONSERVATIVE containment test against the next span's inner bbox.
; When that test could not prove containment it ENDED the segment at the
; shared boundary and let span N+1 re-open one at the very same column —
; a split-and-continue, i.e. exactly the forbidden thing, on 4.4% of
; drawn lines (11.5% at 845,-3084,215).
;
; Now the segment is simply left OPEN and its emit DEFERRED.  Each span
; is clipped on its own merits, and the open segment is closed only when
; the line is PROVEN to leave the chain: it exits the aperture, or the
; next visible run does not start where the last one ended (a solid gap
; between spans), or the list/line ends.  A conservative test can then
; only cost cycles, never pixels.  zp_seg_end_x carries the right end of
; the visible run so far; the end Y is computed once, at the emit.
dcl_entry_path:
; (The per-span Y-bbox reset is HOISTED to the head of the sloped path.
;  It was defending against a stale NARROWED bbox — one describing the
;  line over a range to the LEFT of this span, which made Tier-2 wrongly
;  ACCEPT and over-draw at 845,-3084,215.  Both narrowers died with the
;  portal check on 2026-08-22, so ylo/yhi are now write-once per line and
;  the reset was re-deriving the same two bytes on every span.
;  X = span slot is live for the Tier checks below.)

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
   BCC dcl_amb_jmp                         ; ylo < max(tl,tr) → CB clip
   LDA POOL_IB,X
   CMP zp_line_y_h
   BCC dcl_amb_jmp                         ; yhi > ib → ambiguous (12%)
; min(bl,br) >= yhi → accept FALLS IN (was a page-crossing BCS taken
; 88% — census 2026-07-27; the amb/reject island moved below
; dcl_exit_check's JMP boundary)
; ── dcl_accept: record seg_start for an inner-bbox-accepted entry ──
; Sets seg_start = (ox0, line_y_at(ox0)).
; Three cases converge at STA zp_seg_start_y:
;   ox0 == xl  → A = yl      (common: line starts at/before span)
;   dy == 0    → A = yl      (flat line, y constant everywhere)
;   else       → A = interp  (rare: line enters span mid-way)
; The rare interp path uses BIT abs to skip the LDA zp_line_yl_l.
dcl_accept:
; Visible over the WHOLE overlap, so the run here is [ox0, ox1].
; If a segment is already open and this run starts exactly where the
; last one ended, the line never left the chain: extend it in silence.
; That is the hot path, and it does no work at all — in particular it
; skips the entry interp, which the old portal check paid for.
; INVERTED 2026-08-22 (branch census: 84.0% taken over 487 executions,
; and the BEQ crossed a page, so the common arm was paying 4).  Nothing
; open is the common case, so it falls through now and the have-a-run
; arm is an island below the block.
   LDA zp_seg_start_x
   CMP #$FF
   BNE dcl_acc_haveopen                    ; 16%: island below
dcl_acc_open:
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
dcl_acc_extend:
   LDA zp_ox1                              ; the run now reaches ox1
   STA zp_seg_end_x
; (Records hook is at dcl_emit_segment — one record per surviving
;  segment, not per-span.)
; Fall through to exit check

dcl_exit_check:
; ========== EXIT CHECK ==========
; Does the line end within this span? (xr <= xend — inclusive, because
; xend is the exclusive claim edge the line is allowed to run out to;
; see the ox1 note above)
   LDA POOL_XEND,X
   CMP zp_line_xr_l
   BCC dcl_advance
; xend < xr → extends past: the segment stays OPEN and we simply walk on.
; No portal check, no containment proof, no emit — whether the run
; really continues is decided by the NEXT span, on its own merits.
; xend >= xr: line ends within this span
   JMP dcl_line_ends

dcl_advance:
; Walk to the next span with the segment (if any) still open.
   LDA POOL_NEXT,X
   TAX
   BEQ dcladv_flush                        ; (entry guard bypassed: TAX's Z
   JMP dcl_not_left                           ; answers the null test here)
dcladv_flush:
   JMP dcl_flush

; --- rare-arm island (census 2026-07-27): tier-1/2 targets out of the
; hot fall path; all within branch range of the tiers above ---
; --- rare arm: a run is already open (16%, census 2026-08-22) --------
; Islanded here rather than after dcl_acc_extend: that spot is the hot
; fall-through into dcl_exit_check, and putting the arm there cost the
; common path a JMP (measured +57 MEAN, more than the inversion saved).
dcl_acc_haveopen:
   LDA zp_ox0
   CMP zp_seg_end_x
   BEQ dcl_acc_extend                      ; contiguous -> just extend
; A visible run that does NOT continue the open one: the line genuinely
; left the chain at zp_seg_end_x (a solid gap between spans).  Close the
; old segment there, then open a new one here.
   STX zp_save0
   JSR dcl_emit_open
   LDX zp_save0
   JMP dcl_acc_open
dcl_amb_jmp:
   JMP dcl_cb_clip
dcl_reject_above:
; Not visible anywhere in this span, so an open run really did end at
; zp_seg_end_x.
; Close any open run FIRST — the ordering contract on dcl_close_open_nx.
; INLINED, with the X save INSIDE the branch: 97% of these calls find
; nothing open (105 of 109, census over 5 scenes), and the old
; JSR dcl_close_if_open -> STX -> JSR dcl_close_open_nx -> test -> RTS
; -> LDX -> RTS spent 39 cycles to discover it.  The test alone is 9.
   LDA zp_seg_start_x
   CMP #$FF
   BEQ dcl_ra_closed
   STX zp_save0                            ; X = span slot, live below
   JSR dcl_emit_open
   LDX zp_save0
   LDA #$FF
   STA zp_seg_start_x
dcl_ra_closed:
   LDA zp_dcl_rec_buf_h                    ; records off: plain reject
   BEQ dcl_outer_reject
   LDA zp_dcl_out                          ; feedback: off-TOP evidence
   ORA #$80
   STA zp_dcl_out
   LDA #0                                  ; verdict 'above' over [ox0,ox1]
   BEQ dcl_rej_rec                         ; (always)
dcl_reject_below:
; Close any open run FIRST — the ordering contract on dcl_close_open_nx.
; INLINED, with the X save INSIDE the branch: 97% of these calls find
; nothing open (105 of 109, census over 5 scenes), and the old
; JSR dcl_close_if_open -> STX -> JSR dcl_close_open_nx -> test -> RTS
; -> LDX -> RTS spent 39 cycles to discover it.  The test alone is 9.
   LDA zp_seg_start_x
   CMP #$FF
   BEQ dcl_rb_closed
   STX zp_save0                            ; X = span slot, live below
   JSR dcl_emit_open
   LDX zp_save0
   LDA #$FF
   STA zp_seg_start_x
dcl_rb_closed:
   LDA zp_dcl_rec_buf_h
   BEQ dcl_outer_reject
   LDA zp_dcl_out                          ; feedback: off-BOTTOM evidence
   ORA #$40
   STA zp_dcl_out
   LDA #$FF                                ; verdict 'below'
dcl_rej_rec:
   JSR dcl_rec_flat_span
dcl_outer_reject:
; Outer reject → advance to next span (inline; JMP — the ping-pong
; walk pushed the re-entry out of branch range, and an always-guarded
; BNE+JMP pair costs the same as the test+JMP form)
   LDA POOL_NEXT,X
   TAX
   BEQ dclor_flush
   JMP dcl_not_left
dclor_flush:
   JMP dcl_flush

; (The Phase-2 portal check — dcl_extends_past / dcl_has_next /
;  dcl_is_abutting / dcl_pp_use_yr / dcl_pp_ly_ge / dcl_pp_bbox /
;  dcl_exit_no_portal / dcl_exit_emit — was DELETED 2026-08-22.
;
;  It existed to decide, at span N, whether the line could be merged
;  across the portal into span N+1 without re-clipping, by testing the
;  line's bbox over [boundary, xr] against span N+1's INNER bbox.  That
;  test is conservative, and its failure path ended the segment at the
;  shared boundary — splitting a line that had not left the chain.
;
;  Walking on with the segment open and clipping span N+1 on its own
;  merits gives the same answer without ever splitting, and is CHEAPER:
;  the containment test cost a compare chain plus, when the boundary was
;  interior, a full line_y_at interp (a divide) at EVERY portal, where
;  the Tier-1/Tier-2 pair that replaces it is four compares and usually
;  falls straight through to "extend".)

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
; End of walk (span list exhausted, or every remaining span is right of
; the line).  An open run ended at zp_seg_end_x — NOT at xr: the line
; may continue past the last span into solid columns, which is exactly
; where the run stops.
   LDA zp_seg_start_x
   CMP #$FF
   BNE dcl_fl_emit
dcl_done:
   RTS
dcl_fl_emit:
   JMP dcl_emit_open                       ; tail call

; --- dcl_emit_open: close the open segment at zp_seg_end_x ---
; Emits [seg_start .. seg_end_x].  The end Y is computed HERE, ONCE per
; segment, instead of once per span boundary as the old portal path did.
; Three cases converge via chained BIT abs:
;   seg_end_x == xr → yr
;   dy == 0         → yl (== yr for flat lines)
;   else            → line_y_at(seg_end_x)
; Does NOT reset zp_seg_start_x — callers that carry on do that.
dcl_emit_open:
; PRESERVES zp_ox1.  dcl_emit_segment takes its end-x THERE, so closing a
; run would otherwise overwrite the CURRENT span's ox1 with the closed
; run's end — and every caller still needs it afterwards:
;   dcl_accept    stores it as the new run's zp_seg_end_x
;   the rejects   pass it to dcl_rec_flat_span as the verdict's xr
;   the left-clip needs it for the "cx2 < ox1" mid-span-exit test
; That clobber drew the second fragment of a re-entering line back to the
; FIRST fragment's end — (109,90)-(100,91) instead of (109,90)-(115,90),
; 99px of over-draw at X=000C.B0 Y=0052.BD R=B0.  The tail call to
; dcl_emit_segment becomes a JSR so the restore can happen after it.
   LDA zp_ox1
   PHA
   LDA zp_seg_end_x
   STA zp_ox1
   CMP zp_line_xr_l
   BEQ dcl_eo_yr
   LDY zp_line_dy
   BEQ dcl_eo_yr
   JSR dcl_line_y_at_a                     ; A = seg_end_x rides in
   .byte $2C                               ; BIT abs: skip LDA yr
dcl_eo_yr:
   LDA zp_line_yr_l
   STA zp_tmp0
   JSR dcl_emit_segment
   PLA
   STA zp_ox1
   RTS

; --- dcl_close_open_nx: emit + close, if any segment is open ---
; Clobbers A/X/Y; PRESERVES zp_save0, so the CB clip (which parks its
; span pointer there) can call it mid-clip.
;
; ORDERING CONTRACT: every caller must close the open run BEFORE writing
; any verdict record for the span it is currently on.  The record stream
; is run-length-coded in ASCENDING x — rf_in merges into the PREVIOUS
; record and silently absorbs anything arriving out of order — and the
; segment record written here covers columns to the LEFT of this span's
; verdict.  Get it backwards and the segment record is eaten, the
; tighten under-informed, and lines go missing.
dcl_close_open_nx:
   LDA zp_seg_start_x
   CMP #$FF
   BEQ dcl_cio_rts
   JSR dcl_emit_open
   LDA #$FF
   STA zp_seg_start_x
dcl_cio_rts:
   RTS

; (dcl_close_if_open — the X-preserving wrapper — is RETIRED: its only
;  two callers were the Tier-1 reject arms, which now inline the test and
;  save X only on the 4-in-135 path that actually closes.)

; ========== Vertical line handler ==========
; For xl == xr: find the first span containing column xl, compute
; aperture [top_y, bot_y] at that column, clip [ylo, yhi] to aperture,
; emit single vertical line segment.  Matches Python's draw_clipped
; vertical path (break on first span containing ix).
;
; KNOWN OPEN BUG (jamb-vertical boundary column, root-caused
; 2026-07-24): the span lookup below is doubly-inclusive first-match
; (serves xl even from a span whose EXCLUSIVE end == xl), so boundary
; columns are always served by the LEFTMOST touching span — a stale
; aperture at every portal's x_lo jamb.  The designed fix (serve from
; the more restrictive touching span; prototype in tools/joint_proto
; .py) awaits its rebaseline — do not 'tidy' the compares to strict
; without landing that fix.
;
; Inputs:  zp_line_xl_l (== xr), zp_line_yl_l, zp_line_yr_l; zp_head.
; Output:  at most one segment staged to RASTER_ZP_* + plot_v; no
;          records (vertical lines carry no tighten information).
; Pseudocode:
;   for s in spans:
;       if s.xend < xl: continue
;       if s.xstart > xl: return         # sorted list — no span has xl
;       top = span_top(s, xl); bot = span_bot(s, xl)   # interp_store
;       cy1 = max(ylo, top); cy2 = min(yhi, bot)
;       if cy1 <= cy2: emit vertical (xl, cy1)-(xl, cy2)
;       return                           # first containing span only
; ----------------------------------------------------------------------------
; dcl_vert / dcl_vert_on — the VERTICAL FASTPATH (2026-07-22, Eben's
; spec: senior-byte discard, u8 y-clamp, straight into the span query,
; no staging). Contract: A = column lo, Y = column hi (dcl_vert) or
; column verified on-screen (dcl_vert_on); zp_line_yl/yr staged s16;
; DISARMED (verticals never record — the general entry keeps the
; armed/wrapper path). Bit-exact vs the old trajectory by construction:
; the y-clamp replicates mc_vertical's arithmetic (same-side rejects,
; boundary-degenerate reject); the senior discard equals mcv_rej; the
; survivors enter the SAME dcl_vertical walk. xr/x-hi/rec staging and
; the general entry's rediscovery tests are gone (~55 cyc/vertical).
; ----------------------------------------------------------------------------
::dcl_vert:
   CPY #0                                  ; senior byte: off-screen left
   BEQ dcl_vert_on                         ; (neg) or right (>=256) discards
   RTS
::dcl_vert_on:
   STA zp_line_xl_l                        ; THE column (dv_* reads only this)
; (corner ±1 shrink REVERTED 2026-07-27: walkseq found 48 frames with
; 2-6 px gaps — portal-edge verticals whose ft/fb horizontals were
; tightened away have NO join to cover the shrunk corners, and the s16
; shrink tax ate the plot saving anyway. Revisit PRODUCER-SIDE: the
; descriptor pack knows which ends are clamped-to-frame — ±1 there is
; free and provably joined. See project_vplot memory.)
; clamp y1 into the u8 band (mc_vertical's exact ladder, lo-only:
; nothing downstream reads the y hi bytes)
   LDA zp_line_yl_h
   BNE dvc_y1_clamp                        ; rare (3%, census 2026-07-27):
                                           ; clamp arms in the island below
dvc_y1_done:
; clamp y2 (same-side pairs already rejected above)
   LDA zp_line_yr_h
   BNE dvc_y2_clamp                        ; rare (1.4%): island below
dvc_y2_done:
; clamped to a point (one end AT the boundary) -> reject, exactly as
; the generic post-clip degen check does; else FALL INTO the span query
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BEQ dvc_rej                             ; degen: rare — non-degen FALLS
                                           ; INTO the span query (was a
                                           ; 99.3%-taken BNE hop)
dcl_vertical:
   LDA zp_dcl_rec_buf_h                    ; feedback: the vertical walk is
   BEQ dv_untapped                         ; untapped — tag MIXED for
   LDA zp_dcl_out                          ; recorded (1-column lip) lines
   ORA #$C0
   STA zp_dcl_out
dv_untapped:
; Compute ylo/yhi (dx/dy not needed for verticals)
   LDA zp_line_yl_l
   LDX zp_line_yr_l
   CMP zp_line_yr_l
   BCS dv_yl_ge                            ; yl >= yr never on suite: swap
                                           ; arm in the island (census)
   STA zp_line_y_l
   STX zp_line_y_h
dv_bbox_done:
   LDX zp_head
   BEQ dvc_rej                             ; empty list (island RTS)
; THE JAMB FIX (2026-08-21). A column belongs to EXACTLY ONE span
; under half-open tiling ([xs, xe) contains ix iff xs <= ix < xe), so
; this lookup is determinate — no 'which touching span do we pick?'
; heuristic is needed. The old test skipped only when xend < xl, so a
; span whose EXCLUSIVE end equalled the column claimed it anyway:
; boundary columns were always served by the LEFTMOST touching span,
; giving a stale aperture at every portal's x_lo jamb (and drawing
; verticals straight through solid — reproduced on the harness).
;
; SEARCH IDIOM (2026-08-22, mark_solid's walk applied here): xl is
; LOOP-INVARIANT, so it is hoisted into A and rides the whole search,
; and the slot alternates X/Y in an unrolled ping-pong so the skip
; path needs no TAX. Skip step was LDA zp + CMP + BCS + LDA abs,X +
; TAX + BNE = 19 cyc; it is now CMP + BCC + LDY abs,X + BEQ = 13.
; (measured 18 vertical calls and 23.6 skip steps per frame)
   LDA zp_line_xl_l                        ; HOISTED: rides A throughout
dv_check:
dv_x:
   CMP POOL_XEND,X                         ; C=0: this span reaches past xl
   BCC dv_own_x
   LDY POOL_NEXT,X
   BEQ dvc_rej
   CMP POOL_XEND,Y                         ; (mirror)
   BCC dv_own_y
   LDX POOL_NEXT,Y
   BNE dv_x
   BEQ dvc_rej                             ; list ran out (always taken)
dv_own_x:
   CMP POOL_XSTART,X                       ; A = xl: C = xl >= xstart
   BCS dv_in                               ; -> this span owns the column
   RTS                                     ; sorted list: column is solid
dv_own_y:
   CMP POOL_XSTART,Y
   BCC dv_rts_solid
   TYA                                     ; Y->X for the X-indexed dv_in
   TAX                                     ; (the arm's only extra cost)
   BNE dv_in                               ; always taken: a live slot != 0
dv_rts_solid:
   RTS

; --- rare-arm island (census 2026-07-27): the vert clamp arms, degen/
; empty RTS and the yl>=yr swap arm, out of the hot fall path ---
dvc_y1_clamp:
   BMI dvc_y1_neg
   LDA zp_line_yr_h                        ; y1 below the band
   BMI dvc_y1_cl                           ; y2 above: crossing — clamp
   BNE dvc_rej                             ; y2 also below: nothing visible
dvc_y1_cl:
   LDA #$FF
   STA zp_line_yl_l
   BNE dvc_y1_done                         ; (always: A = $FF)
dvc_y1_neg:
   LDA zp_line_yr_h                        ; y1 above the band
   BMI dvc_rej                             ; y2 also above: nothing visible
   ZERO zp_line_yl_l
   JMP dvc_y1_done                         ; (ZERO = STZ on C02: no flags)
dvc_y2_clamp:
   BMI dvc_y2_neg
   LDA #$FF
   STA zp_line_yr_l
   BNE dvc_y2_done                         ; (always)
dvc_y2_neg:
   ZERO zp_line_yr_l
   JMP dvc_y2_done                         ; (ZERO = STZ on C02: no flags)
dvc_rej:
   RTS
dv_yl_ge:
   STA zp_line_y_h
   STX zp_line_y_l
   JMP dv_bbox_done
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
   LDA POOL_TXLO,X
   STA zp_i_x0
   LDA POOL_TDEN,X
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
   LDA POOL_BXLO,X                         ; BOTTOM line's own anchors
   STA zp_i_x0
   LDA POOL_BDEN,X
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
   BCC dv_clipped_away                     ; INVERTED 2026-08-22 (census:
                                        ; 96.2% of verticals emit, so the
                                        ; emit path now FALLS THROUGH and
                                        ; the reject takes the branch)
dv_emit:
; Stage the rasteriser ZP args (x, cy1, x, cy2), un-biasing Y (biased
; [48,207] -> screen [0,159]) and tail-call the vertical plotter.
; (LINE_OUT capture RETIRED 2026-07-26: the harness PC-traps the plot
; entries and reads RASTER_ZP_* directly — the engine no longer pays
; a gate test per emitted line.)
   LDA zp_line_xl_l
   STA RASTER_ZP_X0
   STA RASTER_ZP_X1
   LDA zp_cb_cy1
   SBC #Y_BIAS                             ; C=1 from the BCS dv_emit guard
   STA RASTER_ZP_Y0
   LDA zp_cb_cy2
   SBC #Y_BIAS                             ; C=1 from the in-band SBC
   STA RASTER_ZP_Y1
   BIT plotq_mode                          ; run-ahead queue armed?
   BMI pq_enq_j
   JMP plot_v                              ; always vertical on this path
pq_enq_j:
   JMP plot_enq
dv_clipped_away:
   RTS                                     ; cy1 > cy2: clipped away (3.8%)

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
; (the blanket ORA #$C0 MIXED tag died 2026-08-22: every CB termination
;  DOES prove a direction — see the per-reject tags below.  Tagging
;  MIXED here made the off-TOP/off-BOTTOM inference depend on WHICH
;  entry a line took, so a band width change moved pixels.)
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
   LDA POOL_TXLO,X
   STA zp_i_x0
   LDA POOL_TDEN,X
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
; span's top line (i_x0=TXLO, i_y0=TL, i_y1=TR); boundary_ix only
; clobbered div_den. Constant spans: cy = top1 directly.
   LDA zp_cb_top1
   CMP zp_cb_top2
   BEQ dcl_cb_top_cy2_const
   LDX zp_save0
   LDA POOL_TDEN,X
   STA zp_div_den
   LDA zp_cb_cx2
   JSR interp_store
dcl_cb_top_cy2_const:                      ; BEQ lands here with A = top1
   STA zp_cb_cy2
   ZERO DCLV_RVY                           ; exit was through the TOP:
                                        ; [cx2, orig ox1] pends 'above'
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
   LDA POOL_TDEN,X
   STA zp_div_den
   LDA zp_cb_cx1
   JSR interp_store
dcl_cb_top_cy1_const:                      ; BEQ lands here with A = top1
   STA zp_cb_cy1
; cx1 was clipped right of ox0, so the line is NOT visible at ox0 and an
; open run ended there.  Close it BEFORE this span's verdict record —
; ascending-x contract.  Guarded on ox0 < cx1 so an intersection landing
; exactly on ox0 (nothing clipped off, run continues) neither closes nor
; records.
   LDA zp_ox0
   CMP zp_cb_cx1
   BCS dcl_cb_top_done
   JSR dcl_close_open_nx                   ; preserves zp_save0
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
   LDA POOL_BXLO,X                         ; BOTTOM line's own anchors
   STA zp_i_x0
   LDA POOL_BDEN,X
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
   LDA POOL_BDEN,X                         ; BOTTOM anchors
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
   LDA POOL_BDEN,X                         ; BOTTOM anchors
   STA zp_div_den
   LDA zp_cb_cx1
   JSR interp_store
dcl_cb_bot_cy1_const:                      ; BEQ lands here with A = bot1
   STA zp_cb_cy1
; cx1 was clipped right of ox0, so the line is NOT visible at ox0 and an
; open run ended there.  Close it BEFORE this span's verdict record —
; ascending-x contract.  Guarded on ox0 < cx1 so an intersection landing
; exactly on ox0 (nothing clipped off, run continues) neither closes nor
; records.
   LDA zp_ox0
   CMP zp_cb_cx1
   BCS dcl_cb_bot_done
   JSR dcl_close_open_nx                   ; preserves zp_save0
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
; left the aperture mid-span. dcl_line_ends / dcl_emit_open both use
; xr/yr or line_y_at(seg_end_x) for the exit, which would be wrong here.
   CMP zp_ox1                              ; A = cx2 from the reject test
   BCS dcl_cb_no_exit_clip
; cx2 < ox1 → the line leaves the aperture INSIDE this span, so the run
; genuinely ends at cx2 and is emitted here (segment record written by
; emit).  But if a run was already open and this one starts exactly where
; that one ended, it is the SAME run: keep the original seg_start and
; emit once.  Overwriting seg_start with cx1 here would split the line.
   LDX zp_save0
   LDA zp_seg_start_x
   CMP #$FF
   BEQ dcl_cbx_open
   LDA zp_cb_cx1
   CMP zp_seg_end_x
   BEQ dcl_cbx_emit                        ; contiguous → extend it
   JSR dcl_close_open_nx                   ; a real gap → close the old run
   LDX zp_save0
dcl_cbx_open:
   LDA zp_cb_cx1
   STA zp_seg_start_x
   LDA zp_cb_cy1
   STA zp_seg_start_y
dcl_cbx_emit:
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
   JMP dcl_not_left                           ; answers the null test here)
dclwb_flush2:
   JMP dcl_flush

dcl_cb_no_exit_clip:
; cx2 == ox1: CB did not clip the exit, so the visible run reaches the
; end of the overlap and may continue into the next span.  Open, extend
; or re-open exactly as dcl_accept does.
; (The Y-bbox narrowing that used to live here died with the portal
;  check: its only consumer was dcl_pp_bbox, and dcl_entry_path resets
;  the bbox on every span anyway — it was a dead store on this path.)
   LDX zp_save0
   LDA zp_seg_start_x
   CMP #$FF
   BEQ dcl_cbn_open
   LDA zp_cb_cx1
   CMP zp_seg_end_x
   BEQ dcl_cbn_extend                      ; contiguous → extend
   JSR dcl_emit_open                       ; a real gap → close the old run
   LDX zp_save0
dcl_cbn_open:
   LDA zp_cb_cx1
   STA zp_seg_start_x
   LDA zp_cb_cy1
   STA zp_seg_start_y
dcl_cbn_extend:
   LDA zp_cb_cx2
   STA zp_seg_end_x
   JMP dcl_exit_check

; Both arms prove a direction, so both tag zp_dcl_out exactly as the
; Tier-1 arms do (feedback only when records are armed — same contract).
; Soundness: 'both endpoints above' generalises to the whole range
; because line_y - boundary_y is LINEAR in x, so a value negative at
; both ends is negative throughout; the empty-after-clip arms are the
; same fact stated by construction.  A range clipped above CANNOT also
; run below (top < bot), so a single direction is the whole story.
dcl_cb_reject_above:
   JSR dcl_close_open_nx                   ; close BEFORE this span's record
   LDA zp_dcl_rec_buf_h
   BEQ dcl_cb_reject
   LDA zp_dcl_out                          ; feedback: off-TOP evidence
   ORA #$80
   STA zp_dcl_out
   LDA #0                                  ; whole overlap above the aperture
   BEQ dcl_cb_rej_rec                      ; (always)
dcl_cb_reject_below:
   JSR dcl_close_open_nx                   ; close BEFORE this span's record
   LDA zp_dcl_rec_buf_h
   BEQ dcl_cb_reject
   LDA zp_dcl_out                          ; feedback: off-BOTTOM evidence
   ORA #$40
   STA zp_dcl_out
   LDA #$FF
dcl_cb_rej_rec:
   JSR dcl_rec_flat_span
dcl_cb_reject:
; CB clip rejected — skip this span
   LDX zp_save0
   LDA POOL_NEXT,X
   TAX
   BEQ dclwb_flush3                        ; (entry guard bypassed: TAX's Z
   JMP dcl_not_left                           ; answers the null test here)
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
;     optional tighten record) ---
; Input: zp_seg_start_x, zp_seg_start_y, zp_ox1 (end_x), zp_tmp0 (end_y)
; Clobbers: A, Y
;
; Pipeline (pseudocode):
;   if start == end: return                       # degenerate point
;   if either Y outside [Y_BIAS, VIS_YMAX]:
;       yband-clip segment; if fully off-screen: return
;   if records mode and xl < xr:                  # skip useless records
;       append record (xl, yl, xr, yr); records[0] += 1
;   stage (xl, yl-Y_BIAS, xr, yr-Y_BIAS) into the rasteriser ZP args
;   (xr = exclusive end; the raster RUNS OUT through it — no -1)
;   tail-call plot_h / plot_v / RASTER_ENTRY by segment axis
dcl_es_degen:
; maybe-degenerate: same x — degenerate iff same y too (rare: 2.6%)
   LDA zp_seg_start_y
   CMP zp_tmp0
   BNE dcl_es_ok_noreload
   RTS                                     ; degenerate
dcl_emit_segment:
; Skip degenerate segments (zero-length). Common case falls through
; (was a 97.4%-taken BNE — census 2026-07-27).
   LDA zp_seg_start_x
   CMP zp_ox1
   BEQ dcl_es_degen
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
   BCS dcl_es_yband                        ; RE-INVERTED 2026-08-22 (branch
                                        ; census): the 2026-08-12 note
                                        ; claimed "the rare yband clip
                                        ; falls in", but it had the RARE
                                        ; block in the fall-through and
                                        ; made the COMMON in-band path
                                        ; take a branch — measured 100%
                                        ; taken over 20 frames, with the
                                        ; yband arm never firing at all.
                                        ; Now the common path falls
                                        ; straight into the record hook
                                        ; and the clip arm is an island
                                        ; below (see dcl_es_yband).
dcl_es_record:
; --- Records hook: ONE record per surviving segment ---
; Segment record format: 4 bytes (xl, yl, xr, yr).
; Triggers exactly when DCL emits a visible segment, regardless of how
; many pool spans the segment crossed. Tighten consumer derives
; everything from these 4 endpoint values via interp.
   LDA zp_dcl_rec_buf_h
   BEQ dcl_es_no_record
   LDA zp_dcl_out                          ; feedback: real pixels emitted
   ORA #$01
   STA zp_dcl_out
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
.if ::C02
   LDA (zp_dcl_rec_buf)                    ; non-indexed indirect: the LDY
   ADC #1                                  ; dies and STA (zp) is 5 cyc
   STA (zp_dcl_rec_buf)                    ; (C=0 from the xl>=xr BCS guard)
.else
   LDY #0
   LDA (zp_dcl_rec_buf),Y
   ADC #1                                  ; C=0 from the xl>=xr BCS guard
   STA (zp_dcl_rec_buf),Y
.endif
dcl_es_no_record:
; (LINE_OUT capture RETIRED 2026-07-26 — see the vertical emit note.)
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
des_dispatch:
; --- axis dispatch: ~70% of rasterised pixels are in horizontal or
; vertical segments (gradient census 2026-07-05) — route them to the
; dedicated plotters instead of the generic NJ machinery ---
; (A = Y1 on both entry paths)
   BIT plotq_mode                          ; run-ahead queue armed? (driver
   BMI pq_enq_j2                           ; feature: harness stays direct)
   CMP RASTER_ZP_Y0
   BNE des_not_h
   JMP plot_h
pq_enq_j2:
   JMP plot_enq
des_to_v:
   LDA RASTER_ZP_Y0                        ; this path's segments have no
   CMP RASTER_ZP_Y1                        ; y-order guarantee — normalize
   BCC dtv_ord                             ; HERE (0 on suite): plot_v's
   LDX RASTER_ZP_Y1                        ; swap moved out for the ordered
   STA RASTER_ZP_Y1                        ; hot producers (corner-shrink
   STX RASTER_ZP_Y0                        ; arc, 2026-07-27)
dtv_ord:
   JMP plot_v
des_not_h:
   LDA RASTER_ZP_X0
   CMP RASTER_ZP_X1
   BEQ des_to_v                            ; verticals never here on suite
                                           ; (census 2026-07-27): diagonal
des_diag:                                  ; FALLS THROUGH
; (A run-slice plotter for shallow diagonals was measured-and-rejected
; here 2026-07-05: pixel-exact — proven by a 16k-sequence oracle check
; and a 15,872-draw framebuffer battery — but slower: NJ's shallow path
; is already run-accumulating at ~11 cyc/px and E1M1 lacks enough
; sub-1:33 lines to amortize even the dispatch test. See the
; 'experiment: run-slice' commit to revive.)
   JMP RASTER_ENTRY                        ; tail-call rasteriser

; --- rare-arm island: the Y-band safety clip (2026-08-22). Reached only
;     when an emitted segment has an endpoint outside [Y_BIAS,VIS_YMAX];
;     it did not fire once across the 20-frame census, so it costs the
;     hot path nothing here. ---
dcl_es_yband:
   JSR dcl_yband_clip
   BCC dcl_es_record_j                     ; clipped to something visible
   RTS                                     ; fully off-screen -> drop segment
dcl_es_record_j:
   JMP dcl_es_record

.endscope

; ============================================================================
; PLOT RUN-AHEAD QUEUE (2026-08-14, Eben's cheap-triple-buffer design).
; 64 x 4-byte post-clip segments at PLOTQ ($1000).  While plotq_mode is
; $80 (driver arms it at flip), plots append here instead of drawing —
; the back buffer is still on display until the flip's vsync.  Each
; append then calls the pq_pump vector: the DRIVER's pump polls the
; vsync latch and, once it fires (or the queue fills), full-clears the
; new back buffer, drains the queue and drops plotq_mode to direct.
; Harness/default: plotq_mode = 0 — everything draws direct and the
; only cost is the 6-cycle gate per line.  FIFO drain preserves
; production order; the plotter is re-derived from the coords exactly
; as des_dispatch would (y0==y1 -> plot_h, x0==x1 -> plot_v with the
; des_to_v normalize, else NJ) — pixels identical by construction.
; ============================================================================
PLOTQ = $1000
; ($1100-$11FF is FREE in BOTH builds since 2026-08-17: it held the driver's
;  per-frame beam-phase cadence ring, retired with the $0A50 frame counter
;  that indexed it — $0A50 is VC_RLO+$50, so that INC was corrupting one
;  cached vertex rotation per frame. Neighbours: PLOTQ below, VXC_XLO above.)
::plot_enq:
   LDX plotq_n
   LDA RASTER_ZP_X0
   STA PLOTQ+0,X
   LDA RASTER_ZP_Y0
   STA PLOTQ+1,X
   LDA RASTER_ZP_X1
   STA PLOTQ+2,X
   LDA RASTER_ZP_Y1
   STA PLOTQ+3,X
   TXA
   CLC
   ADC #4
   STA plotq_n                             ; wraps to 0 at 64 entries: the
                                        ; pump treats n==0 as FULL and
                                        ; force-waits
::pq_pump_op:
   JSR pq_pump_default                     ; SMC (named): the driver pokes
   RTS                                     ; its gated pump in here
pq_pump_default:
   RTS                                     ; engine default: no driver, no
                                        ; pump (unreachable in harness —
                                        ; mode is never armed there)

; drain: dispatch every queued segment through the axis rules.
; Caller guarantees the target buffer is cleared + off display and
; bank C is paged (banked).  Clobbers A/X/Y; resets plotq_n.
::plotq_drain:                             ; PRE: >= 1 entry queued
   LDY #0                                  ; (n == 0 at entry means FULL —
pqd_loop:                                  ;  the do-while drains all 64)
   LDA PLOTQ+0,Y
   STA RASTER_ZP_X0
   LDA PLOTQ+1,Y
   STA RASTER_ZP_Y0
   LDA PLOTQ+2,Y
   STA RASTER_ZP_X1
   LDA PLOTQ+3,Y
   STA RASTER_ZP_Y1
   INY
   INY
   INY
   INY
   STY pqd_y
                                        ; (LDA RASTER_ZP_Y1 deleted: A still
                                        ;  holds it from the PLOTQ+3 load
                                        ;  above — INY/STY do not touch A,
                                        ;  and pqd_loop is upstream of that
                                        ;  load so every entry passes it)
   CMP RASTER_ZP_Y0
   BNE pqd_not_h
   JSR plot_h
   JMP pqd_next
pqd_not_h:
   LDA RASTER_ZP_X0
   CMP RASTER_ZP_X1
   BNE pqd_diag
   LDA RASTER_ZP_Y0                        ; des_to_v normalize twin
   CMP RASTER_ZP_Y1
   BCC pqd_v_ord
   LDX RASTER_ZP_Y1
   STA RASTER_ZP_Y1
   STX RASTER_ZP_Y0
pqd_v_ord:
   JSR plot_v
   JMP pqd_next
pqd_diag:
   JSR RASTER_ENTRY
pqd_next:
   LDY pqd_y
   CPY plotq_n
   BNE pqd_loop
   ZERO plotq_n
   RTS
pqd_y: .byte 0

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
   ZERO LC_OX1_HI, LC_OX2_HI, LC_OY1_HI, LC_OY2_HI, LC_TGT_HI                          ; hoisted from all 4 clip arms

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
.if ::C02
   LDA (zp_dcl_rec_buf)                    ; non-indexed (see the es site)
   ADC #1                                  ; C=0 proven: BCS rf_restore
   STA (zp_dcl_rec_buf)                    ; not taken, INY/LDA keep C
.else
   LDY #0
   LDA (zp_dcl_rec_buf),Y
   ADC #1                                  ; C=0 proven: BCS rf_restore
   STA (zp_dcl_rec_buf),Y                  ; not taken, INY/LDA keep C
.endif
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
