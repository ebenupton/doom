
; --- TG_APPEND_X: append span X to the new list, with merge optimization ---
;
; Tries to merge X into the tail when both are constant-line spans
; (tl==tr, bl==br) with matching Y values and contiguous X ranges.
; This prevents span-count explosion from crossover splits; ~96% of
; merge candidates are constant-line, so the 6-compare fast path
; resolves quickly.
;
; Input:  X = span slot to append (all fields populated EXCEPT NEXT,
;         which this routine owns); zp_new_tail = tail of the list
;         being built (0 = empty); zp_head is set on first append.
; Output: X linked as the new tail, or merged into the old tail and
;         slot X freed.  Clobbers A,Y; X preserved on the link path.
;
; Python mirror: endpoint_spans._append_merge.
; pseudocode:
;   if list empty: head = tail = X
;   elif tail and X both constant (tl==tr, bl==br), same (tl, bl),
;        and tail.xend == X.xstart:            # abutting active ranges
;       tail.xend = X.xend; free(X)            # lossless: same flat line
;   else: tail.next = X; X.next = 0; tail = X
; (Non-constant co-linear pairs are rare — ~6/568 in scene 2 — and not
; worth a general slope check; see the Python mirror's note.)
tg_append_x:
.scope
   LDA zp_new_tail
   BNE ta_try_merge
; ||
; First span: set head. POOL_NEXT,X = 0 (end of list).
; A is already 0 from the LDA above (BNE not taken ↔ A=0).
   STA POOL_NEXT,X                         ; |
   STX zp_head
   STX zp_new_tail
   RTS
; |
ta_try_merge:
   LDY zp_new_tail                         ; |
; Fail fast: tail Y must be a constant-line span (tl==tr AND bl==br).
   LDA POOL_TL,Y
   CMP POOL_TR,Y
   BNE ta_link
; |||
   LDA POOL_BL,Y
   CMP POOL_BR,Y
   BNE ta_link
; ||
; New X must also be a constant-line span.
   LDA POOL_TL,X
   CMP POOL_TR,X
   BNE ta_link
; ||
   LDA POOL_BL,X
   CMP POOL_BR,X
   BNE ta_link
; |
; Matching constants?
   LDA POOL_TL,Y
   CMP POOL_TL,X
   BNE ta_link
; |
   LDA POOL_BL,Y
   CMP POOL_BL,X
   BNE ta_link
; |
; Contiguous active ranges? (abutting: tail.xend == new.xstart)
   LDA POOL_XEND,Y
   CMP POOL_XSTART,X
   BNE ta_link
; |
; Merge: extend tail's xend to cover new, then free X.
   LDA POOL_XEND,X
   STA POOL_XEND,Y
   JMP free_span                           ; frees X (via tail-call), returns
ta_link:
; X becomes new tail — write POOL_NEXT,X = 0 (deferred from entry).
   LDA #0
   STA POOL_NEXT,X
; ||
   TXA
   STA POOL_NEXT,Y
; ||
   STX zp_new_tail
   RTS
; |||
.endscope

; TFS state block ($0900-$091B) — the 3-cursor event walk's working set.
; (Moved here from the deleted 6-byte-records legacy file.)
; Plain RAM rather than ZP: all accesses are absolute (non-indexed), and
; the ZP map is full — see project_refactor_toolchain / src/zp.inc.
; PEND_* is a 1-deep output buffer: the interval most recently produced
; by the sweep, held back so the next interval can extend it in place
; (same top/bot sources) instead of allocating a new pool span.
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
;
; Input:  zp_ilo/zp_ihi = seg column range (closed, pre-clamped u8);
;         zp_head = old span list (consumed);
;         TOP_RECORDS/BOT_RECORDS = record buffers written by the
;         preceding draw_clipped_line(yt)/(yb) calls: byte 0 = count,
;         then 4-byte records (xl, yl, xr, yr) at offset 1, in
;         ascending x order (DCL walks spans left to right).
; Output: zp_head = rebuilt list (old slots freed and reused);
;         zp_hg_cache invalidated.  Clobbers A,X,Y, zp_old_cur,
;         zp_new_tail, zp_clr_save_x, zp_ox0/1, the interp/div ZP set,
;         and the TFS_* block.
;
; A record DOMINATES column x when rec.xl <= x < rec.xr: there the
; portal edge line was VISIBLE inside the old aperture (DCL emitted
; it), so it becomes the new boundary. Where no record covers x the
; edge was clipped away (old boundary wins) and the pool value is
; kept. The all-records-clipped-away case (zero records) never reaches
; this routine: the wrapper resolves it via seg_zero_rec_solid below.
;
; Python mirror: EndpointClipSpans.tighten_from_records (older 6-byte
; verdict form; this 4-byte segment walk is state-equivalent — records
; only exist for 'inside' sub-ranges).
;
; pseudocode:
;   for span in old list:
;     if span.xend <= ilo or span.xstart >= ihi:   # pixel-center overlap
;         append span unchanged; continue
;     if span.xstart < ilo: emit [xstart, ilo] unchanged  # left fragment
;     cur_x = max(xstart, ilo); x_hi = min(xend, ihi)
;     while cur_x < x_hi:                          # event sweep
;         drop stale records (rec.xr <= cur_x)
;         top_dom = T covers cur_x; bot_dom = B covers cur_x
;         next_x = min(x_hi, T.xl or T.xr, B.xl or B.xr)
;                  #  not-yet-dom → next event is xl; dom → xr
;         top/bot lines for [cur_x, next_x] = record line if dom
;                                             else pool line (interp both ends)
;         merge into pending if same sources and abutting, else flush+start
;         consume records whose xr == next_x; cur_x = next_x
;     if span.xend > ihi: emit [ihi, xend] unchanged      # right fragment
;     free original span
;   flush pending
; Fragments and sweep intervals ABUT (shared boundary column), unlike
; mark_solid's ilo-1/ihi+1 — closed-interval seam-friendly model.
; ===================================================================
tighten_from_records:
.scope
; ---- Init: detach the old list and start the new one empty ----
; Invalidate the has_gap coherence cache (see span_mark_solid note).
   ZERO zp_hg_cache
   LDA zp_head
   STA zp_old_cur
   LDA #0
   STA zp_new_tail
   STA zp_head
; Reset DCL's portal-continuation state ($FF = inactive) so the next
; draw_clipped_line starts clean. (Write-only from this module.)
   LDA #$FF
   STA zp_tg_cont

; Init top/bot cursors and buffer-end offsets.
; Cursor = offset of the current record (1 = first; 0 = exhausted/none).
; BUFEND = 1 + count*4 = first invalid offset (via ASL,ASL,+1).
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

; ---- Outer loop: walk the old span list (X = current slot) ----
   LDX zp_old_cur
tfs_walk:
   BNE tfs_proc
   JMP tfs_finish
tfs_proc:
; Save NEXT now (this slot is freed/relinked below) and stash the
; current slot in zp_clr_save_x — X is clobbered by every JSR here.
   LDA POOL_NEXT,X
   STA zp_old_cur
   STX zp_clr_save_x

; Out-of-range check: pixel-center overlap semantics — a span touching
; the seg only at a shared endpoint column (xend == ilo or
; xstart == ihi) does NOT overlap; append it unchanged.
   LDA POOL_XEND,X
   CMP zp_ilo
   BCC tfs_oor
   BEQ tfs_oor
   LDA POOL_XSTART,X
   CMP zp_ihi
   BCC tfs_in_range
tfs_oor:
; Relink the untouched span. Flush pending first to keep the output
; list in x order (pending always precedes this span).
   JSR tfs_flush_pending
   LDX zp_clr_save_x
   JSR tg_append_x
   JMP tfs_continue
tfs_in_range:

; Single-column span [x..x]: the sweep below is empty (CUR_X == X_HI),
; which used to DROP the span entirely and leave its records unconsumed
; (whose stale xl then drags next_x backwards on the next span, emitting
; reversed/overlapping phantom spans — the 1056,-3616,64 window bug).
; Enter the loop body directly with CUR_X = X_HI = x: the body evaluates
; record dominance at x, emits the one column, and the loop test exits.
   LDA POOL_XSTART,X
   CMP POOL_XEND,X
   BNE tfs_pre_chk
   STA TFS_CUR_X
   STA TFS_X_HI
   JMP tfs_body
tfs_pre_chk:

; Pre-fragment [span.xstart, ilo] if span.xstart < ilo.
; Abutting: the fragment KEEPS ilo as its xend (shared boundary column
; with the swept region starting at cur_x = ilo). Line def preserved.
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
; Neither record reaches this span: emit [cur_x, x_hi] unchanged.
   JSR tfs_flush_pending
   LDX zp_clr_save_x
   LDA TFS_CUR_X
   STA zp_ox0
   LDA TFS_X_HI
   STA zp_ox1
   JSR emit_unchanged_subspan
   JMP tfs_inner_done

; ---- Event sweep: process uniform intervals while cur_x < x_hi ----
; Each pass handles one interval [cur_x, next_x] over which the
; dominating source (record vs pool) is constant on both sides.
tfs_inner:
   LDA TFS_CUR_X
   CMP TFS_X_HI
   BCC tfs_inner_go
   JMP tfs_inner_done
tfs_inner_go:

tfs_body:
; ---- Consume stale records (xr <= cur_x) ----
; Records are captured at DCL time; ops that run between then and this
; deferred tighten can close the columns they refer to. A record that
; can no longer dominate (cur_x >= xr) must be consumed here: feeding
; its xl into the next_x computation moves the sweep BACKWARDS and
; emits reversed/overlapping spans.
tfs_st_top:
; While T exists and T.xr (offset +2) <= cur_x: advance cursor by 4
; (one record), or mark exhausted (0) at BUFEND.
   LDA TFS_T_CUR
   BEQ tfs_st_top_done
   CLC
   ADC #2
   TAY
   LDA TOP_RECORDS,Y
   CMP TFS_CUR_X
   BEQ tfs_st_top_stale
   BCS tfs_st_top_done
tfs_st_top_stale:
   LDA TFS_T_CUR
   CLC
   ADC #4
   CMP TFS_TOP_BUFEND
   BCC tfs_st_top_store
   LDA #0
tfs_st_top_store:
   STA TFS_T_CUR
   JMP tfs_st_top
tfs_st_top_done:
; Same stale-consume loop for the bot cursor.
tfs_st_bot:
   LDA TFS_B_CUR
   BEQ tfs_st_bot_done
   CLC
   ADC #2
   TAY
   LDA BOT_RECORDS,Y
   CMP TFS_CUR_X
   BEQ tfs_st_bot_stale
   BCS tfs_st_bot_done
tfs_st_bot_stale:
   LDA TFS_B_CUR
   CLC
   ADC #4
   CMP TFS_BOT_BUFEND
   BCC tfs_st_bot_store
   LDA #0
tfs_st_bot_store:
   STA TFS_B_CUR
   JMP tfs_st_bot
tfs_st_bot_done:

; ---- Determine top_dom (T.xl <= cur_x < T.xr) ----
; i.e. the current top record's segment covers cur_x, so the yt-line
; (not the pool line) is the top boundary on this interval.
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
; The next event for a side is where its dominance state CHANGES:
;   not yet dominating → the record's xl (segment starts there)
;   dominating         → the record's xr (segment ends there)
; Clamped to x_hi. Dominance is therefore uniform on [cur_x, next_x].
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
; TOP_L/TOP_R = top boundary y at the interval's two ends, plus the
; (KIND, ID) source tag used by the pending-merge test below.
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
; Top from the pool span's own line: interp (XLO,TL)-(XLO+DEN,TR) at
; cur_x / next_x. Source tag = (kind 0, id = pool slot).
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
; Mirror of the top block: bot record line if BOT_DOM, else the pool
; span's (XLO,BL)-(XLO+DEN,BR) line; tag (KIND, ID) for merging.
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
; Merge iff the pending interval abuts this one (pend.xr == cur_x) and
; BOTH boundary sources match (top kind+id AND bot kind+id). Same
; source ⇒ same line equation, so extending the interval and re-tagging
; its right-end values is lossless — no geometry is re-derived.
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
; Buffer this interval as the new pending span (materialized by
; tfs_flush_pending when the next interval can't merge into it).
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
; ---- Consume records whose segment ends exactly at next_x ----
; Only a DOMINATING record can end here (its xr was a next_x candidate).
; Advance the cursor by 4, wrapping to 0 (exhausted) at BUFEND.
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

; Step the sweep to the next event.
   LDA TFS_NEXT_X
   STA TFS_CUR_X
   JMP tfs_inner

tfs_inner_done:

; Post-fragment [ihi, span.xend] if span.xend > ihi.
; Abutting: keeps ihi as its xstart (shared with the swept region).
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
;
; Input:  TFS_PEND_* (valid only when TFS_PEND_ACT = 1; no-op otherwise).
; Output: pending interval materialized as a pool span and appended via
;         tg_append_x; TFS_PEND_ACT cleared.  The span is DENSE-ANCHORED:
;         line anchors == active range (XLO = XL, DEN = XR - XL), with
;         the OT/IT/OB/IB bbox bytes computed from the endpoint values.
;         On pool exhaustion the interval is silently dropped
;         (flush_fail) — columns vanish rather than corrupt the list.
;         Clobbers A,X,Y.
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
;
; Input:  zp_ox0/zp_ox1 = active range for the fragment (closed);
;         zp_clr_save_x = source pool slot.
; Output: new slot with the source's line definition copied VERBATIM
;         (XLO/DEN/TL/BL/TR/BR + precomputed OT/OB/IT/IB — no interp,
;         matching the lazy fragments of the Python mirrors) and active
;         range [ox0, ox1], appended via tg_append_x.  Silently dropped
;         on pool exhaustion.  Clobbers A,X,Y.
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
; zp_line_xl..zp_line_yr_hi in scratch RAM, then JSRs $201E. Routine clips
; line to u8 [0,255]×[0,255], writes u8 result to zp_line_xl/yl/xr/yr,
; then falls through to draw_clipped_line (existing DCL pipeline).
;
; The math is the slow generic version: u16×u16 = u32, u32÷u16 = u16.
; A `project_clip_arithmetic_fastpath` memo notes the obvious fast
; paths to add later (u8-fits-operand, trivial offset==0/den cases,
; early-exit divide when leading zeros guarantee u8 quotient).
;
; NB: only the DATA LAYOUT (input aliases + $0938-$0958 working set)
; lives here; the s16 clipper CODE is in clip/dcl_s16.s
; (draw_clipped_line_s16). Python wrapper: SpanClip6502.draw_clipped_line.
; ===================================================================

; ---- s16 line input (wrapper writes these) ----
; Lo bytes alias zp_line_* (the same u8 slots DCL reads). Hi bytes
; alias the CB-clip / tighten-secondary ZP block ($B2-$B5) — those
; slots are used DOWNSTREAM of the s16 clipper (DCL clobbers them
; during emission), but the wrapper rewrites them before each call,
; so there's no conflict. ZP access shaves ~7 cycles off the in-range
; fast-path detect (4 ORAs of zp vs absolute).
; (LC_*_LO alias layer removed 2026-07-10: the s16 clipper reads the
; zp_line_* slots by their real names.)
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

; ---------------------------------------------------------------------------
; seg_zero_rec_solid — classify a portal whose aperture-edge DCL emissions
; produced ZERO records. That is ambiguous: either the opening covers the
; whole screen (the tighten is a genuine no-op -> skip), or the opening is
; entirely OFF-screen (every visible row in the seg's columns shows wall or
; flat -> the columns must be CLOSED). The packed-Python reference
; (endpoint_spans records verdicts: top 'below' or bot 'above' -> solid)
; already closes; the 6502 skipped, leaving the columns open — found via
; the (-486,-3307,243) phantom, where a screen-wide portal whose aperture
; projects wholly above the screen left columns 0..69 open and the far
; rooms drew through the wall (276px cross-impl divergence).
;
; In:  the packed ZP vertex structs (zp.inc VX1/VX2) biased s16 sy pairs,
;      zp_seg_flags (SF_NEEDBT=$04, SF_NEEDBB=$08).
; Out: C=1 -> aperture band provably empty on screen (caller appends a
;      SOLID over [ilo,ihi]); C=0 -> genuine no-op (skip).
;
; Band bottom = min(fb, bb when SF_NEEDBB); band top = max(ft, bt when
; SF_NEEDBT). Empty on screen iff bottom < Y_BIAS at BOTH endpoints
; (min < k <=> either < k), or top > Y_BIAS+159 at both.
; ---------------------------------------------------------------------------
SZR_PROJ = $E2                          ; = VX1 (zp.inc vertex structs).
; X offsets below = struct offsets: +5 top, +7 bot, +9 btop, +11 bbot;
; +15 more for the v2 struct. (Old SEG_PROJ_BUF interleave retired
; 2026-07-10.) ZP,X addressing: abs,X on a ZP base still works; keep the
; absolute form for the +1 hi-byte reads (no page crossing: max $FC+1).
.export seg_zero_rec_solid

; --- s16 threshold helpers for seg_zero_rec_solid ---------------------
; X = lo-byte offset of a projection in SZR_PROJ. C=1 iff value < Y_BIAS.
; s16 compare via full SBC pair: the sign of (value - Y_BIAS) is the
; N flag of the hi-byte SBC, corrected for signed overflow by EOR #$80
; when V is set (standard 6502 signed-compare idiom). Clobbers A.
szr_lt:
   LDA SZR_PROJ,X
   SEC
   SBC #Y_BIAS
   LDA SZR_PROJ+1,X
   SBC #0
   BVC szr_lt_nv
   EOR #$80
szr_lt_nv:
   BMI szr_yes
   CLC
   RTS
; C=1 iff value > Y_BIAS+159.
; Same idiom, operands reversed: sign of ((Y_BIAS+159) - value) < 0.
szr_gt:
   LDA #<(Y_BIAS+159)
   SEC
   SBC SZR_PROJ,X
   LDA #>(Y_BIAS+159)
   SBC SZR_PROJ+1,X
   BVC szr_gt_nv
   EOR #$80
szr_gt_nv:
   BMI szr_yes
   CLC
   RTS
szr_yes:
   SEC
   RTS

seg_zero_rec_solid:
.scope
; Band bottom = min(fb, bb-if-NEEDBB), so "bottom < Y_BIAS" at an
; endpoint iff fb < Y_BIAS OR (NEEDBB and bb < Y_BIAS). Endpoint 1
; first; only if it passes do we pay for endpoint 2 (szr_b1).
; bottom family: band bottom above the screen top at endpoint 1?
   LDX #7                                  ; sy1_bot (fb1) — VX1+7
   JSR szr_lt
   BCS szr_b1
   LDA zp_seg_flags
   AND #$08                                ; SF_NEEDBB
   BEQ szr_top
   LDX #11                                 ; sy1_bbot (bb1) — VX1+11
   JSR szr_lt
   BCC szr_top
szr_b1:
; ... and at endpoint 2?
   LDX #22                                 ; sy2_bot (fb2) — VX2+7
   JSR szr_lt
   BCS szr_closed
   LDA zp_seg_flags
   AND #$08
   BEQ szr_top
   LDX #26                                 ; sy2_bbot (bb2) — VX2+11
   JSR szr_lt
   BCS szr_closed
szr_top:
; top family: band top below the screen bottom at endpoint 1?
; Band top = max(ft, bt-if-NEEDBT), and max(a,b) > k iff a > k OR
; b > k — the same either-of-two test per endpoint as the bottom
; family above, with szr_gt in place of szr_lt.
   LDX #5                                  ; sy1_top (ft1) — VX1+5
   JSR szr_gt
   BCS szr_t1
   LDA zp_seg_flags
   AND #$04                                ; SF_NEEDBT
   BEQ szr_open
   LDX #9                                  ; sy1_btop (bt1) — VX1+9
   JSR szr_gt
   BCC szr_open
szr_t1:
   LDX #20                                 ; sy2_top (ft2) — VX2+5
   JSR szr_gt
   BCS szr_closed
   LDA zp_seg_flags
   AND #$04
   BEQ szr_open
   LDX #24                                 ; sy2_btop (bt2) — VX2+9
   JSR szr_gt
   BCS szr_closed
szr_open:
   CLC
   RTS
szr_closed:
   SEC
   RTS
.endscope
