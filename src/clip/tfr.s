
; ============================================================================
; clip/tfr.s — clipper fragment 8 of 13 (module map: clip/header.s).
; Contents: tg_append_x (list builder + merge), the TFS_* state block,
; tighten_from_records and its helpers, the
; LC_* absolute working set for the s16 clipper (code in clip/dcl_s16.s),
; and seg_zero_rec_solid (exported to bsp/subsector.s).
; Consumes the 4-byte records written by dcl_emit_segment (clip/dcl.s).
; ============================================================================

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
SEG_HIGH
; (tg_append_x relocated to LO 2026-07-13 — CLIP at its ceiling; main
; RAM is always mapped, so the bank-C sweep JSRs here at no cost.)
tg_append_x:
.scope
   LDA zp_new_tail                                                        ;# |||||      0.6
   BEQ ta_first                            ; empty list rare (24%, census ;# ||||       0.4
                                           ; 2026-07-27): island at the
                                           ; scope tail — merge path falls
ta_try_merge:
   TAY                                     ; A = zp_new_tail from the gate ;# |||        0.4
; Merge preconditions, reordered by measured fail rate (census
; 2026-08-14: TL-match rejects 12.2/fr — the old order buried it
; fifth) and FUSED by transitivity: once TL,Y == TL,X, that one value
; rides A through all four top-side compares (TLy==TLx==TRy==TRx is
; the same conjunction as the old pairwise tests); bottom mirrors.
; SAME-LINE test (2026-08-22, source anchoring). The old test asked
; whether both spans were CONSTANT with equal values — the only cheap
; way to prove they lay on one line back when TL/TR were the values at
; each span's OWN ends. Now the anchors ARE the source line, so "same
; line" is plain equality on (anchor, den, yl, yr), which also catches
; the SLOPED co-linear pairs the constant test had to give up on.
; WITHOUT this the change is a NET LOSS: a sloped source no longer
; looks constant over a narrow span, so nearly every merge failed and
; the span count exploded (heavy scene 33 -> 46).
; ORDERED BY MEASURED REJECT RATE (re-censused 2026-08-22).  The
; 2026-08-14 order was tuned for the OLD constant-value test; the
; same-line rewrite changed which fields discriminate and nobody
; re-measured, leaving the chain almost exactly BACKWARDS — the 3.8%
; test first and the 85.9% test last.  Unconditional reject rates over
; 205 merge candidates (5 scenes):
;   BDEN 85.9%  BXLO 82.1%  BL 52.6%  BR 46.2%
;   TXLO 11.5%  TDEN 11.5%  TR 10.3%  TL 9.0%  abut 3.8%
; The order below is the EXHAUSTIVE optimum over all 9! permutations
; (greedy agrees): 354 test executions against the old order's 913.
; Only 12% of candidates merge, so the chain's job is to reject fast.
;
; Any order is correct — every test must pass to merge, so the set that
; merges is identical and the frame is byte-for-byte the same.  Moving
; the abutting test off the front is safe: the other compares read live
; span slots either way, so a non-adjacent pair is just compared and
; rejected a little later.
; (The old note claimed the top-side compares were FUSED by transitivity
; with one value riding A — that was true of the retired constant-value
; test; this chain reloads for every pair, so reordering is free.)
   LDA POOL_BDEN,Y                                                        ;# ||||||     0.7
   CMP POOL_BDEN,X                                                        ;# ||||||     0.7
   BNE ta_link                          ; 85.9% reject                    ;# |||||      0.5
   LDA POOL_TDEN,Y                                                        ;# |          0.1
   CMP POOL_TDEN,X                                                        ;# |          0.1
   BNE ta_link                          ; 11.5% reject                    ;#            0.1
   LDA POOL_XEND,Y                                                        ;# |          0.1
   CMP POOL_XSTART,X                                                      ;# |          0.1
   BNE ta_link                          ; 3.8% reject                     ;#            0.0
   LDA POOL_BXLO,Y                                                        ;# |          0.1
   CMP POOL_BXLO,X                                                        ;# |          0.1
   BNE ta_link                          ; 82.1% reject                    ;#            0.0
   LDA POOL_TL,Y                                                          ;# |          0.1
   CMP POOL_TL,X                                                          ;# |          0.1
   BNE ta_link                          ; 9.0% reject                     ;#            0.0
   LDA POOL_TR,Y                                                          ;# |          0.1
   CMP POOL_TR,X                                                          ;# |          0.1
   BNE ta_link                          ; 10.3% reject                    ;#            0.0
   LDA POOL_TXLO,Y                                                        ;# |          0.1
   CMP POOL_TXLO,X                                                        ;# |          0.1
   BNE ta_link                          ; 11.5% reject                    ;#            0.0
   LDA POOL_BL,Y                                                          ;# |          0.1
   CMP POOL_BL,X                                                          ;# |          0.1
   BNE ta_link                          ; 52.6% reject                    ;#            0.0
   LDA POOL_BR,Y                                                          ;# |          0.1
   CMP POOL_BR,X                                                          ;# |          0.1
   BNE ta_link                          ; 46.2% reject                    ;#            0.0
; Merge: extend tail's xend to cover new, then free X (free_span
; INLINED 2026-08-21 — the tail-call JMP's 3 cycles die with it).
; The merged range stays INSIDE the anchors now: both spans carry the
; same SOURCE line, and each one's active range is a sub-interval of
; that source's extent, so their union is too. (Before source
; anchoring the anchor was the span's own range, so a merge pushed the
; active range past it and relied on the constant-line test to keep
; interp_store from extrapolating — see the precondition note in
; clip/interp.s.)
   LDA POOL_XEND,X                                                        ;# |          0.1
   STA POOL_XEND,Y                                                        ;# |          0.1
   LDA zp_free                                                            ;# |          0.1
   STA POOL_NEXT,X                                                        ;# |          0.1
   STX zp_free                                                            ;# |          0.1
   RTS                                                                    ;# |          0.1
ta_link:
; X becomes new tail — write POOL_NEXT,X = 0 (deferred from entry).
   ZERO {POOL_NEXT,X}                                                     ;# |||||||||| 1.1
; ||
   TXA                                                                    ;# |||        0.3
   STA POOL_NEXT,Y                                                        ;# |||||||    0.8
; ||
   STX zp_new_tail                                                        ;# ||||       0.5
   RTS                                                                    ;# |||||||||  0.9
; |||
ta_first:
; First span: set head. POOL_NEXT,X = 0 (end of list).
; A is already 0 from the LDA above (BEQ taken ↔ A=0).
   STA POOL_NEXT,X                         ; |                            ;# |          0.1
   STX zp_head                                                            ;#            0.0
   STX zp_new_tail                                                        ;#            0.0
   RTS                                                                    ;# |          0.1
.endscope
SEG_BANKC
; TFS state block — the 3-cursor event walk's working set.
; (Moved here from the deleted 6-byte-records legacy file.)
; ZP SWEEP (2026-08-11, profiled): the HOT members moved to the zp
; bytes freed by the TRUE16/TRIG5 arcs (heat-ranked py65 profile,
; ~1k cyc/frame in this block alone); the cold tail stays in the
; $06xx scratch page. Every promoted byte is logged in src/zp.inc —
; the free-list is the trap (the $CB/zp_tail_vec near-miss). The
; PROMOTED equates live in src/zp.inc (must be seen before all code
; or ca65 sizes the operands absolute — codescan caught exactly that).
; PEND_* is a 1-deep output buffer: the interval most recently produced
; by the sweep, held back so the next interval can extend it in place
; (same top/bot sources) instead of allocating a new pool span.
; SOURCE-ANCHORED BOUNDARIES (2026-08-22). Each side is carried as its
; SOURCE line's own (anchor_lo, den, y_lo, y_hi) rather than the two
; values interpolated onto the interval's ends, so a pure side costs
; four copies instead of two interp_store calls. The MIXED arms (max/
; min of pool and record) cannot be one line, so they still interpolate
; onto [cur_x, next_x] and anchor there.
; ALL 28 PROMOTED TO ZERO PAGE 2026-08-22 — the equates are in
; src/zp.inc (they MUST be seen before any code or ca65 sizes the
; operands absolute; codescan gates exactly that).  Measured 2,379
; accesses to this block on the heavy frame, so the promotion is
; worth ~2,379 cycles and one byte per instruction.
; --- verdict-record support (2026-07-13 off-screen-aperture fix) ---
; $091C/$091D free (TFS_*_VERD retired — verdicts tested lazily at the
; consumption points, 2026-07-13)
DCLV_RVY = $061E                        ; pending right-side verdict y ($80 = none)
DCLV_OX1S = $061F                       ; original ox1 stashed at CB entry
DCLV_X0 = $0620                         ; dcl_rec_flat range args
DCLV_X1 = $0621
DCLV_SX = $0622                         ; X save across dcl_rec_flat
DCLV_YV = $0623                         ; verdict y value latch
DCLV_S16VY = $0624
; --- EVICTED FROM ZERO PAGE 2026-08-22 ---------------------------------
; Priced with tools/zpheat.py on the heavy frame: a ZP byte's only honest
; cost is how often it is touched (1 cycle and 1 byte per access to move
; it out).  These are the clipper's coldest ZP residents and all three are
; plain scalars — no (zp),Y, no zp,X — so the move is an address change:
;   zp_cb_top2  18 accesses/frame     zp_cb_bot2  16
;   zp_save1     8
; 42 cycles a frame buys three of the 28 bytes the TFS sweep state needs.
zp_cb_top2 = $0625                      ; u8, span top at cx2
zp_cb_bot2 = $0626                      ; u8, span bot at cx2
zp_save1   = $0627                      ; dcl_boundary_ix's clip_p1 save                      ; s16-clip pending right verdict ($80 = none)


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
; Input:  zp_i_l/zp_i_h = seg column range [ilo, ihi) (HALF-OPEN,
;         pre-clamped u8);
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
; Callers: bsp/defq.s (deferred portal ops, records copied back to
; $0700/$0800 first) via a direct JSR — bank C paged in the
; banked build — and the harness's tighten_from_records.
;
; Python mirror: EndpointClipSpans.tighten in records mode (the only
; live mode — the legacy 'normal'/'unified' modes raise); it snapshots
; the same 4-byte segment records and computes the same sweep.
;
; pseudocode:
;   for span in old list:
;     if span.xend <= ilo or span.xstart >= ihi:   # strict half-open
;         append span unchanged; continue
;     if span.xstart < ilo: emit [xstart, ilo) unchanged  # left fragment
;     cur_x = max(xstart, ilo); x_hi = min(xend, ihi)
;     while cur_x < x_hi:                          # event sweep
;         drop stale records (rec.xr <= cur_x)
;         top_dom = T covers cur_x; bot_dom = B covers cur_x
;         next_x = min(x_hi, T.xl or T.xr, B.xl or B.xr)
;                  #  not-yet-dom → next event is xl; dom → xr
;         top/bot lines for [cur_x, next_x) = record line if dom
;                                             else pool line (interp both ends)
;         merge into pending if same sources and abutting, else flush+start
;         consume records whose xr == next_x; cur_x = next_x
;     if span.xend > ihi: emit [ihi, xend) unchanged      # right fragment
;     free original span
;   flush pending
; Fragments and sweep intervals TILE the span exactly: consecutive
; pieces share their boundary EDGE ([a,b) then [b,c)) — the half-open
; native model has no seam arithmetic (mark_solid tiles the same way).
; ===================================================================
; (the six tfs value helpers that lived here — top/bot x
; pool_interp / rec_interp / vals_mixed — were INLINED into their
; single call sites in the sweep, 2026-08-21.)
SEG_BANKC
tighten_from_records:
.scope
; ---- All-neutral fast-out ----
; Every top record an 'above' flat (yl==0: pool stands) AND every bot
; record a 'below' flat (yl==$FF: pool stands) makes this tighten a
; provable no-op: no interval can change value and no solid verdict can
; fire. Skip the sweep — and as importantly its span re-emission, which
; would split spans at record seams and re-anchor them for nothing (the
; reference model never runs these tightens at all). Real records
; (yl in [Y_BIAS..VIS_YMAX]) and solid flats (top $FF / bot 0) fall
; through to the full sweep. Empty side = vacuously neutral. Skipping
; leaves the pool untouched, so zp_hg_cache stays valid too.
   LDX TOP_RECORDS                         ; count                        ;# |||        0.3
   BEQ tfr_neu_top_ok                                                     ;# ||         0.2
   LDY #2                                  ; first record's yl (1 + 1)    ;# |          0.1
tfr_neu_top:
   LDA TOP_RECORDS,Y                                                      ;# |          0.2
   BNE tfr_do_sweep                        ; in-band value or solid flat  ;# |          0.1
   INY                                                                    ;#            0.0
   INY                                                                    ;#            0.0
   INY                                                                    ;#            0.0
   INY                                                                    ;#            0.0
   DEX                                                                    ;#            0.0
   BNE tfr_neu_top                                                        ;#            0.1
tfr_neu_top_ok:
   LDX BOT_RECORDS                                                        ;# ||         0.2
   BEQ tfr_neutral                                                        ;# |          0.1
   LDY #2                                                                 ;# |          0.1
tfr_neu_bot:
   LDA BOT_RECORDS,Y                                                      ;# ||         0.2
   CMP #$FF                                                               ;# |          0.1
   BNE tfr_do_sweep                                                       ;# |          0.1
   INY
   INY
   INY
   INY
   DEX
   BNE tfr_neu_bot
tfr_neutral:
   RTS                                                                    ;#            0.0
tfr_do_sweep:
; ---- Init: detach the old list and start the new one empty ----
; Invalidate the has_gap coherence cache (see span_mark_solid note).
   ZERO zp_hg_cache                                                       ;# |||        0.3
   LDA zp_head                                                            ;# ||         0.2
   STA zp_old_cur                                                         ;# ||         0.2
   ZERO zp_new_tail, zp_head                                              ;# |||||      0.5

; Reset DCL's portal-continuation state ($FF = inactive) so the next
; draw_clipped_line starts clean. (Write-only from this module.)
   LDA #$FF                                                               ;# |          0.1
   STA zp_tg_cont                                                         ;# ||         0.2

; Init top/bot cursors and buffer-end offsets.
; Cursor = offset of the current record (1 = first; 0 = exhausted/none).
; BUFEND = 1 + count*4 = first invalid offset (via ASL,ASL,+1).
   LDA TOP_RECORDS                                                        ;# ||         0.3
   BEQ tfs_no_top                                                         ;# |          0.2
   LDA #1                                                                 ;# |          0.1
   STA TFS_T_CUR                                                          ;# |          0.1
   JMP tfs_top_be                                                         ;# |          0.1
tfs_no_top:
   ZERO TFS_T_CUR                                                         ;# |          0.2
tfs_top_be:
   LDA TOP_RECORDS                                                        ;# ||         0.3
   ASL A                                                                  ;# |          0.1
   ASL A                                                                  ;# |          0.1
   BUMP_CC                                 ; C=0: count <= 63 (1+4n <= 255) ;# |          0.1
                                           ; so both ASLs shift out 0
   STA TFS_TOP_BUFEND                                                     ;# ||         0.2
   LDA BOT_RECORDS                                                        ;# ||         0.3
   BEQ tfs_no_bot                                                         ;# |          0.1
   LDA #1                                                                 ;# |          0.1
   STA TFS_B_CUR                                                          ;# ||         0.2
   JMP tfs_bot_be                                                         ;# ||         0.2
tfs_no_bot:
   ZERO TFS_B_CUR                                                         ;#            0.0
tfs_bot_be:
   LDA BOT_RECORDS                                                        ;# ||         0.3
   ASL A                                                                  ;# |          0.1
   ASL A                                                                  ;# |          0.1
   BUMP_CC                                 ; C=0: same count-bound proof  ;# |          0.1
   STA TFS_BOT_BUFEND                                                     ;# ||         0.2

; No pending output span yet.
   ZERO TFS_PEND_ACT                                                      ;# |||        0.3

; ---- PREFIX SPLICE (2026-08-22, Eben: "there's a skip to be had") ----
; Spans wholly LEFT of the seg (xend <= ilo) are untouched by it and
; are ALREADY a correctly-linked, sorted chain. Re-appending them one
; at a time through tfs_oor -> flush_pending -> tg_append_x is pure
; tax: measured mean 1.45 such spans per call out of a 3.90-span list
; (only 1.21 actually overlap). So ADOPT the prefix wholesale — new
; head = old head, new tail = the last prefix span — and start the
; sweep at the first span that reaches past ilo.
; The seam is NOT lost: zp_new_tail points at the prefix tail, so the
; next tg_append_x still runs its merge test against it.
   LDX zp_old_cur                                                         ;# ||         0.2
   BEQ tfs_pfx_none                        ; empty list                   ;# |          0.1
   LDA zp_i_l                              ; ilo rides A through the scan ;# ||         0.2
   CMP POOL_XEND,X                                                        ;# ||         0.3
   BCC tfs_pfx_none                        ; head already reaches past ilo ;# |          0.1
   STX zp_head                             ; adopt the prefix as the new list ;# |          0.2
tfs_pfx_loop:                              ; X = a prefix span
   LDY POOL_NEXT,X                                                        ;# |||        0.4
   BEQ tfs_pfx_all                         ; the WHOLE list is prefix     ;# ||         0.2
   CMP POOL_XEND,Y                                                        ;# |||        0.4
   BCC tfs_pfx_split                       ; Y is the first overlapper    ;# ||         0.2
   TYA                                                                    ;# |          0.1
   TAX                                                                    ;# |          0.1
   BNE tfs_pfx_loop                        ; always (a live slot != 0)    ;# |          0.1
tfs_pfx_split:                             ; X = last prefix, Y = sweep start
   STY zp_old_cur                                                         ;# |          0.2
   STX zp_new_tail                                                        ;# |          0.2
   ZERO {POOL_NEXT,X}                      ; terminate the adopted chain — ;# |||        0.4
   JMP tfs_pfx_none                        ; tg_append_x relinks it on the ;# |          0.2
tfs_pfx_all:                               ; first real append
   STX zp_new_tail
   ZERO zp_old_cur                         ; nothing overlaps: sweep is empty
tfs_pfx_none:

; ---- Outer loop: walk the old span list (X = current slot) ----
   LDX zp_old_cur                                                         ;# ||         0.2
tfs_walk:
   BNE tfs_proc                                                           ;# ||         0.2
   JMP tfs_finish
tfs_proc:
; Save NEXT now (this slot is freed/relinked below) and stash the
; current slot in zp_clr_save_x — X is clobbered by every JSR here.
   LDA POOL_NEXT,X                                                        ;# ||||||     0.6
   STA zp_old_cur                                                         ;# ||||       0.5
   STX zp_clr_save_x                                                      ;# ||||       0.5

; Out-of-range check: pixel-center overlap semantics — a span touching
; the seg only at a shared endpoint column (xend == ilo or
; xstart == ihi) does NOT overlap; append it unchanged.
   LDA zp_i_l                              ; INVERTED: C = ilo >= xend —  ;# ||||       0.5
   CMP POOL_XEND,X                         ; one BCS replaces the BCC/BEQ ;# ||||||     0.6
   BCS tfs_oor                             ; pair                         ;# |||        0.3
   LDA POOL_XSTART,X                                                      ;# |||||      0.5
   CMP zp_i_h                                                             ;# |||        0.4
   BCC tfs_in_range_noreload               ; (XSTART rides A through the whole ;# |||        0.3
                                           ; prologue: in_range -> pre_chk ->
                                           ; no_pre all skip their reloads)
; ---- SUFFIX SPLICE (2026-08-22, the prefix argument mirrored) ----
; xstart >= ihi, and the list is SORTED, so every remaining span is
; wholly right of the seg too. Append THIS one (keeping the seam's
; merge test) and then re-attach the whole rest of the chain with one
; store, instead of walking it span by span. zp_old_cur already holds
; the rest — the prologue stashed it. Measured 0.62 spans per call
; beyond the seam.
   JSR tfs_flush_pending                                                  ;# ||         0.2
   LDX zp_clr_save_x                                                      ;# |          0.1
   JSR tg_append_x                         ; may merge X into the tail (and ;# ||         0.2
                                        ; free it) or link it; either way
                                        ; zp_new_tail is the live tail
   LDA zp_old_cur                          ; rest of the old chain        ;# |          0.1
   LDY zp_new_tail                                                        ;# |          0.1
   STA POOL_NEXT,Y                         ; splice it on, terminator intact ;# ||         0.2
   JMP tfs_finish                          ; nothing pending (just flushed) ;# |          0.1
tfs_oor:
; Relink the untouched span. Flush pending first to keep the output
; list in x order (pending always precedes this span).
   JSR tfs_flush_pending                                                  ;# ||         0.2
   LDX zp_clr_save_x                                                      ;# |          0.1
   JSR tg_append_x                                                        ;# ||         0.2
   JMP tfs_continue                                                       ;# |          0.1
; (tfs_in_range reload head DELETED 2026-08-12: zero references — every
;  caller branches to the _noreload twin with XSTART riding A — and the
;  JMP above blocks fall-through; provably unreachable.)

; Single-column span [x..x]: the sweep below is empty (CUR_X == X_HI),
; which used to DROP the span entirely and leave its records unconsumed
; (whose stale xl then drags next_x backwards on the next span, emitting
; reversed/overlapping phantom spans — the 1056,-3616,64 window bug).
; Enter the loop body directly with CUR_X = X_HI = x: the body evaluates
; record dominance at x, emits the one column, and the loop test exits.
tfs_in_range_noreload:
   CMP POOL_XEND,X                                                        ;# |||        0.4
   BNE tfs_pre_chk_noreload                                               ;# ||         0.3
   STA TFS_CUR_X
   STA TFS_X_HI
   JMP tfs_body
; (tfs_pre_chk reload head DELETED 2026-08-12 — same proof as in_range.)

; Pre-fragment [span.xstart, ilo) if span.xstart < ilo.
; Abutting: the fragment's exclusive xend = ilo = the swept region's
; first column — shared EDGE, no shared column. Line def preserved.
tfs_pre_chk_noreload:
   CMP zp_i_l                                                             ;# ||         0.3
   BCS tfs_no_pre_noreload                                                ;# ||         0.2
   JSR tfs_flush_pending                                                  ;# |          0.1
   LDX zp_clr_save_x                                                      ;#            0.1
   LDA POOL_XSTART,X                                                      ;# |          0.1
   STA zp_ox0                                                             ;#            0.1
   LDA zp_i_l                                                             ;#            0.1
   STA zp_ox1                                                             ;#            0.1
   JSR emit_unchanged_subspan                                             ;# |          0.1
   LDA zp_i_l                                                             ;#            0.1
   STA TFS_CUR_X                                                          ;#            0.1
   JMP tfs_xhi_done                                                       ;#            0.1
; (tfs_no_pre reload head DELETED 2026-08-12 — same proof; X =
;  clr_save_x rides in from the BCS site)
tfs_no_pre_noreload:
   STA TFS_CUR_X                                                          ;# ||         0.2
tfs_xhi_done:

; x_hi = min(span.xend, ihi).
   LDX zp_clr_save_x                                                      ;# ||         0.3
   LDA POOL_XEND,X                                                        ;# |||        0.4
   CMP zp_i_h                                                             ;# ||         0.3
   BCC tfs_xhi_xend                                                       ;# ||         0.2
   LDA zp_i_h                                                             ;# ||         0.2
   STA TFS_X_HI                                                           ;# ||         0.2
   JMP tfs_xhi_set                                                        ;# ||         0.2
tfs_xhi_xend:
   STA TFS_X_HI                                                           ;# |          0.1
tfs_xhi_set:

; Fast path: if NEITHER top nor bot record overlaps [cur_x, x_hi],
; emit the pool span unchanged and skip the interp inner loop.
; A record at the cursor doesn't overlap if its xl >= x_hi (segment
; starts past us). T_CUR == 0 also means no overlap.
   LDA TFS_T_CUR                                                          ;# ||         0.3
   BEQ tfs_fp_chk_bot                                                     ;# ||         0.2
   TAY                                                                    ;# |          0.1
   LDA TOP_RECORDS,Y                                                      ;# ||         0.2
   CMP TFS_X_HI                                                           ;# ||         0.2
   BCC tfs_inner                                                          ;# ||         0.2
; T.xl < x_hi → overlap
tfs_fp_chk_bot:
   LDA TFS_B_CUR                                                          ;# |          0.1
   BEQ tfs_fp_emit                                                        ;# |          0.1
   TAY                                                                    ;# |          0.1
   LDA BOT_RECORDS,Y                                                      ;# |          0.1
   CMP TFS_X_HI                                                           ;# |          0.1
   BCC tfs_inner                                                          ;# |          0.1
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
   LDA TFS_CUR_X                                                          ;# |||||      0.5
   CMP TFS_X_HI                                                           ;# |||||      0.5
   BCC tfs_inner_go                                                       ;# ||||       0.5
   JMP tfs_inner_done                                                     ;# ||         0.3
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
   LDA TFS_T_CUR                                                          ;# |||        0.3
   BEQ tfs_st_top_done                                                    ;# ||         0.2
   CLC                                                                    ;# |          0.1
   ADC #2                                                                 ;# |          0.1
   TAY                                                                    ;# |          0.1
   LDA TFS_CUR_X                           ; INVERTED: C = cur >= T.xr    ;# ||         0.2
   CMP TOP_RECORDS,Y                       ; (stale) — one BCC replaces   ;# ||         0.2
   BCC tfs_st_top_done                     ; the BEQ/BCS pair             ;# ||         0.2
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
   LDA TFS_B_CUR                                                          ;# |||        0.3
   BEQ tfs_st_bot_done                                                    ;# ||         0.2
   CLC                                                                    ;# ||         0.2
   ADC #2                                                                 ;# ||         0.2
   TAY                                                                    ;# ||         0.2
   LDA TFS_CUR_X                           ; INVERTED (mirror of st_top)  ;# ||         0.3
   CMP BOT_RECORDS,Y                                                      ;# |||        0.4
   BCC tfs_st_bot_done                                                    ;# ||         0.3
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
   ZERO TFS_TOP_DOM                                                       ;# ||||       0.5
   LDA TFS_T_CUR                                                          ;# |||        0.3
   BEQ tfs_top_dom_done                                                   ;# ||         0.2
   TAY                                                                    ;# |          0.1
   LDA TFS_CUR_X                           ; INVERTED double fold: cur in ;# ||         0.2
   CMP TOP_RECORDS,Y                       ; A — C = cur >= T.xl kills the ;# ||         0.2
; T.xl                                     ; BEQ/BCS pair, and cur RIDES A
   BCC tfs_top_dom_done                    ; through the INYs so the T.xr ;# |          0.1
   INY                                     ; test is a bare CMP (its LDA  ;# |          0.1
   INY                                     ; and BEQ died too)            ;# |          0.1
   CMP TOP_RECORDS,Y                                                      ;# ||         0.2
; T.xr
   BCS tfs_top_dom_done                    ; cur >= xr: not dominating    ;# |          0.1
   DEC TFS_TOP_DOM                         ; 0 -> $FF (ZERO'd above): every ;# |||        0.3
                                        ; reader is BNE/BEQ/ORA-BNE, and
                                        ; the advance gate ANDs the CURSOR
                                        ; through it ($FF-transparent) —
                                        ; keep this 0/$FF, not 0/1
tfs_top_dom_done:

; ---- Determine bot_dom ----
   ZERO TFS_BOT_DOM                                                       ;# ||||       0.5
   LDA TFS_B_CUR                                                          ;# |||        0.3
   BEQ tfs_bot_dom_done                                                   ;# ||         0.2
   TAY                                                                    ;# ||         0.2
   LDA TFS_CUR_X                           ; INVERTED double fold (mirror) ;# ||         0.3
   CMP BOT_RECORDS,Y                                                      ;# |||        0.4
   BCC tfs_bot_dom_done                                                   ;# ||         0.2
   INY                                                                    ;# ||         0.2
   INY                                                                    ;# ||         0.2
   CMP BOT_RECORDS,Y                                                      ;# |||        0.4
   BCS tfs_bot_dom_done                                                   ;# ||         0.2
   DEC TFS_BOT_DOM                         ; 0 -> $FF (mirror; see top)   ;# ||||       0.4
tfs_bot_dom_done:


; ---- next_x = min(x_hi, top event, bot event) ----
; The next event for a side is where its dominance state CHANGES:
;   not yet dominating → the record's xl (segment starts there)
;   dominating         → the record's xr (segment ends there)
; Clamped to x_hi. Dominance is therefore uniform on [cur_x, next_x].
   LDA TFS_X_HI                                                           ;# |||        0.3
   STA TFS_NEXT_X                                                         ;# |||        0.3
   LDA TFS_T_CUR                                                          ;# |||        0.3
   BEQ tfs_skip_top_evt                                                   ;# ||         0.2
   LDA TFS_TOP_DOM                                                        ;# ||         0.2
   BNE tfs_top_evt_xr                                                     ;# ||         0.2
   LDY TFS_T_CUR
   LDA TOP_RECORDS,Y
; not yet dom: candidate = T.xl
   JMP tfs_top_evt_check
tfs_top_evt_xr:
   LDA TFS_T_CUR                                                          ;# ||         0.2
   CLC                                                                    ;# |          0.1
   ADC #2                                                                 ;# |          0.1
   TAY                                                                    ;# |          0.1
; dom: candidate = T.xr
   LDA TOP_RECORDS,Y                                                      ;# ||         0.2
tfs_top_evt_check:
   CMP TFS_NEXT_X                                                         ;# ||         0.2
   BCS tfs_skip_top_evt                                                   ;# ||         0.2
   STA TFS_NEXT_X                                                         ;#            0.0
tfs_skip_top_evt:
   LDA TFS_B_CUR                                                          ;# |||        0.3
   BEQ tfs_skip_bot_evt                                                   ;# ||         0.2
   LDA TFS_BOT_DOM                                                        ;# ||         0.3
   BNE tfs_bot_evt_xr                                                     ;# ||         0.3
   LDY TFS_B_CUR
   LDA BOT_RECORDS,Y
   JMP tfs_bot_evt_check
tfs_bot_evt_xr:
   LDA TFS_B_CUR                                                          ;# ||         0.3
   CLC                                                                    ;# ||         0.2
   ADC #2                                                                 ;# ||         0.2
   TAY                                                                    ;# ||         0.2
   LDA BOT_RECORDS,Y                                                      ;# |||        0.4
tfs_bot_evt_check:
   CMP TFS_NEXT_X                                                         ;# ||         0.3
   BCS tfs_skip_bot_evt                                                   ;# ||         0.3
   STA TFS_NEXT_X
tfs_skip_bot_evt:

; ---- Verdict SOLID (2026-07-13): flat 0/$FF records carry the
; 'above'/'below' verdicts (real 'inside' records are in [Y_BIAS,
; VIS_YMAX] inductively — 0/$FF are reserved). A dominating top record
; with yl==$FF ('below') or bot record with yl==0 ('above') proves the
; aperture empty on [cur_x, next_x]: emit NOTHING — the columns close
; (occlusion restored; the far-west phantom fix). Mirror:
; endpoint_spans.tighten_from_records.
   LDA TFS_TOP_DOM                                                        ;# |||        0.3
   BEQ tfs_ns_top                                                         ;# ||         0.2
   LDY TFS_T_CUR                                                          ;# ||         0.2
   INY                                                                    ;# |          0.1
   LDA TOP_RECORDS,Y                                                      ;# ||         0.2
   CMP #$FF                                                               ;# |          0.1
   BEQ tfs_solid_skip                                                     ;# |          0.1
tfs_ns_top:
   LDA TFS_BOT_DOM                                                        ;# ||         0.3
   BEQ tfs_not_solid                                                      ;# ||         0.2
   LDY TFS_B_CUR                                                          ;# ||         0.3
   INY                                                                    ;# ||         0.2
   LDA BOT_RECORDS,Y                                                      ;# |||        0.4
   BNE tfs_not_solid                                                      ;# ||         0.3
tfs_solid_skip:
   JSR tfs_flush_pending                                                  ;#            0.0
   JMP tfs_advance_curs                                                   ;#            0.0
tfs_not_solid:

; ---- Per-interval fast path: both sides from pool → emit unchanged.
; Saves the 4 interps the normal path would do for a pool/pool sub-
; fragment (the parts of a pool span that records don't dominate).
   LDA TFS_TOP_DOM                                                        ;# ||         0.3
   ORA TFS_BOT_DOM                                                        ;# ||         0.3
   BNE tfs_compute_vals                                                   ;# ||         0.3
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
; NARROW-ONLY (2026-07-13): pool line first, then a dominating record
; RAISES the boundary per endpoint (max) — mirror of the model's
; rt = max(old_t, cy). The old code REPLACED with the record line,
; correct only when records were clipped inside the CURRENT aperture;
; deferred ops of the same subsector move the pool between draw time
; and apply time, so replace could WIDEN (the 1200,-3000,129 852-line
; over-draw). Endpoint-max matches the model's approximation exactly.
   LDA TFS_TOP_DOM                                                        ;# ||         0.3
   BEQ tfs_top_pool                                                       ;# ||         0.2
   LDY TFS_T_CUR                                                          ;# ||         0.2
   INY                                                                    ;# |          0.1
   LDA TOP_RECORDS,Y                                                      ;# ||         0.2
   BEQ tfs_top_pool                        ; 'above' verdict: pool stands ;# |          0.2
; A dominating record IS the boundary — no max() needed (2026-08-22,
; Eben). A top record exists BECAUSE dcl drew that edge inside the
; aperture, so rec >= pool over its range by construction. The old
; narrow-only max() guarded against DEFERRED ops moving the pool
; between draw time and apply time; deferral died in d541b80, so the
; hazard is gone. Measured over 810 frames (suite + 200 corpus
; positions x 4 angles, including 1200,-3000,129 — the very position
; the guard was added for): 240 'mixed' intervals, 240 with the record
; dominating at BOTH ends, ZERO genuine crossings. The extremes
; shortcut and both mixed arms are therefore dead weight and are gone.
; --- tfs_top_rec_interp INLINED 2026-08-21: single call site, so
; inlining deletes the body AND the JSR (-4 bytes, -12
; cycles). The bytes move from main RAM into the clipper
; segment; the flat CLIPF region was grown to suit. ---
; record line -> TOP_L/R directly (pure-record path; setup inlined —
; the JSR/RTS pair was per-interval tax on the hot extremes shortcut)
; SOURCE-ANCHORED: the record IS the line — copy its anchors and its
; endpoint values; no interpolation at all (was two interp_store calls).
   LDY TFS_T_CUR                                                          ;#            0.0
   LDA TOP_RECORDS,Y                       ; xl                           ;#            0.1
   STA TFS_TOP_XL                                                         ;#            0.0
   STA zp_tmp0                                                            ;#            0.0
   INY                                                                    ;#            0.0
   LDA TOP_RECORDS,Y                       ; yl                           ;#            0.1
   STA TFS_TOP_L                                                          ;#            0.0
   INY                                                                    ;#            0.0
   LDA TOP_RECORDS,Y                       ; xr                           ;#            0.1
   SEC                                                                    ;#            0.0
   SBC zp_tmp0                                                            ;#            0.0
   STA TFS_TOP_DEN                                                        ;#            0.0
   INY                                                                    ;#            0.0
   LDA TOP_RECORDS,Y                       ; yr                           ;#            0.1
   STA TFS_TOP_R                                                          ;#            0.0
   JMP tfs_top_tag_rec                                                    ;#            0.0
tfs_top_pool:
; SOURCE-ANCHORED: the pool span's top line is already exactly what we
; want — copy its anchors and endpoint values (was two interp_store
; calls re-anchoring the SAME line onto this interval).
   LDX zp_clr_save_x                                                      ;# ||         0.2
   LDA POOL_TXLO,X                                                        ;# |||        0.3
   STA TFS_TOP_XL                                                         ;# ||         0.2
   LDA POOL_TDEN,X                                                        ;# |||        0.3
   STA TFS_TOP_DEN                                                        ;# ||         0.2
   LDA POOL_TL,X                                                          ;# |||        0.3
   STA TFS_TOP_L                                                          ;# ||         0.2
   LDA POOL_TR,X                                                          ;# |||        0.3
   STA TFS_TOP_R                                                          ;# ||         0.2
   ZERO TFS_TOP_KIND                                                      ;# |||        0.4
   LDA zp_clr_save_x                                                      ;# ||         0.2
   STA TFS_TOP_ID                                                         ;# ||         0.2
   JMP tfs_top_vals_done                                                  ;# ||         0.2
tfs_top_tag_rec:
   LDA #1                                                                 ;#            0.0
   STA TFS_TOP_KIND                                                       ;#            0.0
   LDA TFS_T_CUR                                                          ;#            0.0
   STA TFS_TOP_ID                                                         ;#            0.0
tfs_top_vals_done:

; ---- Compute bot values for [cur_x, next_x] ----
; Mirror of the top block (extremes shortcut vs POOL_IB = min(bl,br)).
   LDA TFS_BOT_DOM                                                        ;# ||         0.3
   BEQ tfs_bot_pool                                                       ;# ||         0.2
   LDY TFS_B_CUR                                                          ;# ||         0.3
   INY                                                                    ;# ||         0.2
   LDA BOT_RECORDS,Y                                                      ;# |||        0.4
   CMP #$FF                                                               ;# ||         0.2
   BEQ tfs_bot_pool                        ; 'below' verdict: pool stands ;# ||         0.2
; (mirror of the top: a dominating record IS the boundary, so the
;  extremes shortcut and the min() arm are gone — see the note there)
tfs_bot_fast2:
; --- tfs_bot_rec_interp INLINED 2026-08-21: single call site, so
; inlining deletes the body AND the JSR (-4 bytes, -12
; cycles). The bytes move from main RAM into the clipper
; segment; the flat CLIPF region was grown to suit. ---
; (setup inlined — see tfs_top_rec_interp note)
; SOURCE-ANCHORED (mirror of the top arm): the record IS the line.
   LDY TFS_B_CUR                                                          ;# ||         0.3
   LDA BOT_RECORDS,Y                       ; xl                           ;# |||        0.4
   STA TFS_BOT_XL                                                         ;# ||         0.3
   STA zp_tmp0                                                            ;# ||         0.3
   INY                                                                    ;# ||         0.2
   LDA BOT_RECORDS,Y                       ; yl                           ;# |||        0.4
   STA TFS_BOT_L                                                          ;# ||         0.3
   INY                                                                    ;# ||         0.2
   LDA BOT_RECORDS,Y                       ; xr                           ;# |||        0.4
   SEC                                                                    ;# ||         0.2
   SBC zp_tmp0                                                            ;# ||         0.3
   STA TFS_BOT_DEN                                                        ;# ||         0.3
   INY                                                                    ;# ||         0.2
   LDA BOT_RECORDS,Y                       ; yr                           ;# |||        0.4
   STA TFS_BOT_R                                                          ;# ||         0.3
   JMP tfs_bot_tag_rec                                                    ;# ||         0.3
tfs_bot_pool:
; SOURCE-ANCHORED (mirror of the top arm): copy the pool span's own
; bottom line rather than re-anchoring it onto this interval.
   LDX zp_clr_save_x
   LDA POOL_BXLO,X
   STA TFS_BOT_XL
   LDA POOL_BDEN,X
   STA TFS_BOT_DEN
   LDA POOL_BL,X
   STA TFS_BOT_L
   LDA POOL_BR,X
   STA TFS_BOT_R
   ZERO TFS_BOT_KIND
   LDA zp_clr_save_x
   STA TFS_BOT_ID
   JMP tfs_bot_vals_done
tfs_bot_tag_rec:
   LDA #1                                                                 ;# ||         0.2
   STA TFS_BOT_KIND                                                       ;# ||         0.3
   LDA TFS_B_CUR                                                          ;# ||         0.3
   STA TFS_BOT_ID                                                         ;# ||         0.3
tfs_bot_vals_done:

; ---- Try to merge with pending ----
; Merge iff the pending interval abuts this one (pend.xr == cur_x) and
; BOTH boundary sources match (top kind+id AND bot kind+id). Same
; source ⇒ same line equation, so extending the interval and re-tagging
; its right-end values is lossless — no geometry is re-derived.
   LDA TFS_PEND_ACT                                                       ;# ||         0.3
   BEQ tfs_start_pend                                                     ;# ||         0.2
   LDA TFS_PEND_XR                                                        ;# |          0.1
   CMP TFS_CUR_X                                                          ;# |          0.1
   BNE tfs_no_merge                                                       ;#            0.1
   LDA TFS_PEND_TKIND                                                     ;# |          0.1
   CMP TFS_TOP_KIND                                                       ;# |          0.1
   BNE tfs_no_merge                                                       ;# |          0.1
   LDA TFS_PEND_TID                                                       ;# |          0.1
   CMP TFS_TOP_ID                                                         ;# |          0.1
   BNE tfs_no_merge                                                       ;# |          0.1
   LDA TFS_PEND_BKIND                                                     ;#            0.0
   CMP TFS_BOT_KIND                                                       ;#            0.0
   BNE tfs_no_merge                                                       ;#            0.0
   LDA TFS_PEND_BID                                                       ;#            0.0
   CMP TFS_BOT_ID                                                         ;#            0.0
   BNE tfs_no_merge                                                       ;#            0.0
; Merge: extend the pending ACTIVE range only. Same sources means the
; same lines at the same anchors, so no value or anchor is re-derived —
; the four stores this used to do died with source anchoring.
   LDA TFS_NEXT_X                                                         ;#            0.0
   STA TFS_PEND_XR                                                        ;#            0.0
   JMP tfs_advance_curs                                                   ;#            0.0
tfs_no_merge:
   JSR tfs_flush_pending                                                  ;# |          0.1
tfs_start_pend:
; Buffer this interval as the new pending span (materialized by
; tfs_flush_pending when the next interval can't merge into it).
   LDA #1                                                                 ;# ||         0.2
   STA TFS_PEND_ACT                                                       ;# ||         0.3
   LDA TFS_CUR_X                                                          ;# ||         0.3
   STA TFS_PEND_XL                                                        ;# ||         0.3
   LDA TFS_NEXT_X                                                         ;# ||         0.3
   STA TFS_PEND_XR                                                        ;# ||         0.3
   LDA TFS_TOP_L                                                          ;# ||         0.3
   STA TFS_PEND_TL                                                        ;# ||         0.3
   LDA TFS_TOP_R                                                          ;# ||         0.3
   STA TFS_PEND_TR                                                        ;# ||         0.3
   LDA TFS_BOT_L                                                          ;# ||         0.3
   STA TFS_PEND_BL                                                        ;# ||         0.3
   LDA TFS_BOT_R                                                          ;# ||         0.3
   STA TFS_PEND_BR                                                        ;# ||         0.3
   LDA TFS_TOP_XL                          ; each side's own anchor       ;# ||         0.3
   STA TFS_PEND_TXL                                                       ;# ||         0.3
   LDA TFS_TOP_DEN                                                        ;# ||         0.3
   STA TFS_PEND_TDEN                                                      ;# ||         0.3
   LDA TFS_BOT_XL                                                         ;# ||         0.3
   STA TFS_PEND_BXL                                                       ;# ||         0.3
   LDA TFS_BOT_DEN                                                        ;# ||         0.3
   STA TFS_PEND_BDEN                                                      ;# ||         0.3
   LDA TFS_TOP_KIND                                                       ;# ||         0.3
   STA TFS_PEND_TKIND                                                     ;# ||         0.3
   LDA TFS_TOP_ID                                                         ;# ||         0.3
   STA TFS_PEND_TID                                                       ;# ||         0.3
   LDA TFS_BOT_KIND                                                       ;# ||         0.3
   STA TFS_PEND_BKIND                                                     ;# ||         0.3
   LDA TFS_BOT_ID                                                         ;# ||         0.3
   STA TFS_PEND_BID                                                       ;# ||         0.3

tfs_advance_curs:
; ---- Consume records whose segment ends exactly at next_x ----
; Only a DOMINATING record can end here (its xr was a next_x candidate).
; Advance the cursor by 4, wrapping to 0 (exhausted) at BUFEND.
; Advance T_CUR if next_x crossed T.xr.
   LDA TFS_T_CUR                                                          ;# |||        0.3
   BEQ tfs_skip_t_adv                                                     ;# ||         0.2
   AND TFS_TOP_DOM                         ; $FF-transparent: A stays CUR ;# ||         0.2
   BEQ tfs_skip_t_adv                      ; (0 iff not dominating) — the ;# |          0.1
   CLC                                     ; reload died (2026-08-11)     ;# |          0.1
   ADC #2                                                                 ;# |          0.1
   TAY                                                                    ;# |          0.1
   LDA TOP_RECORDS,Y                                                      ;# ||         0.2
   CMP TFS_NEXT_X                                                         ;# ||         0.2
   BNE tfs_skip_t_adv                                                     ;# |          0.1
   LDA TFS_T_CUR                                                          ;# |          0.1
   CLC                                                                    ;# |          0.1
   ADC #4                                                                 ;# |          0.1
   CMP TFS_TOP_BUFEND                                                     ;# |          0.1
   BCC tfs_t_adv_ok                                                       ;# |          0.1
   LDA #0                                                                 ;# |          0.1
tfs_t_adv_ok:
   STA TFS_T_CUR                                                          ;# |          0.1
tfs_skip_t_adv:
   LDA TFS_B_CUR                                                          ;# |||        0.3
   BEQ tfs_skip_b_adv                                                     ;# ||         0.2
   AND TFS_BOT_DOM                         ; $FF-transparent (mirror)     ;# ||         0.3
   BEQ tfs_skip_b_adv                                                     ;# ||         0.2
   CLC                                                                    ;# ||         0.2
   ADC #2                                                                 ;# ||         0.2
   TAY                                                                    ;# ||         0.2
   LDA BOT_RECORDS,Y                                                      ;# |||        0.4
   CMP TFS_NEXT_X                                                         ;# ||         0.3
   BNE tfs_skip_b_adv                                                     ;# ||         0.2
   LDA TFS_B_CUR                                                          ;# ||         0.2
   CLC                                                                    ;# |          0.1
   ADC #4                                                                 ;# |          0.1
   CMP TFS_BOT_BUFEND                                                     ;# ||         0.2
   BCC tfs_b_adv_ok                                                       ;# |          0.1
   LDA #0                                                                 ;# |          0.1
tfs_b_adv_ok:
   STA TFS_B_CUR                                                          ;# ||         0.2
tfs_skip_b_adv:

; Step the sweep to the next event.
   LDA TFS_NEXT_X                                                         ;# |||        0.3
   STA TFS_CUR_X                                                          ;# |||        0.3
   JMP tfs_inner                                                          ;# |||        0.3

tfs_inner_done:

; Post-fragment [ihi, span.xend) if span.xend > ihi.
; Abutting: xstart = ihi = the swept region's exclusive end — shared
; EDGE, no shared column.
   LDX zp_clr_save_x                                                      ;# ||         0.3
   LDA zp_i_h                              ; INVERTED: C = ihi >= xend —  ;# ||         0.3
   CMP POOL_XEND,X                         ; one BCS replaces the BCC/BEQ ;# |||        0.4
   BCS tfs_no_post                         ; pair                         ;# ||         0.2
   JSR tfs_flush_pending                                                  ;# |          0.1
; REUSE THE ORIGINAL SLOT (2026-08-22) instead of alloc + 10-byte copy
; + free. The post-fragment is [ihi, xend) of THIS span: its XEND and
; its whole line definition are already right, and this is the span's
; LAST use — the very next thing the old code did was free it. So just
; move XSTART up and append the slot itself. ~146 cycles saved per
; post-fragment (alloc 12, ten field copies 90, range staging 16,
; ues call/return 12, free 11), and the pool-exhaustion arm inside
; emit_unchanged_subspan cannot fire here because nothing is
; allocated. Measured 2.58 post-fragments/frame.
; NB the free below MUST be skipped — the slot is live in the new list.
   LDX zp_clr_save_x                                                      ;#            0.1
   LDA zp_i_h                                                             ;#            0.1
   STA POOL_XSTART,X                       ; [ihi, xend), line untouched  ;# |          0.1
   JSR tg_append_x                         ; may merge+free it: also fine ;# |          0.1
   JMP tfs_continue                        ; SKIP the free                ;#            0.1
tfs_no_post:

; Free original pool span (its replacements are now in the new list).
; free_span INLINED 2026-08-21 (its last two call sites went inline
; together, so the subroutine itself is gone): -12 cyc of JSR/RTS on a
; path that runs once per swept span. A is dead here — tfs_continue
; reloads it.
   LDX zp_clr_save_x                                                      ;# ||         0.2
   LDA zp_free                                                            ;# ||         0.2
   STA POOL_NEXT,X                                                        ;# |||        0.3
   STX zp_free                                                            ;# ||         0.2

tfs_continue:
   LDA zp_old_cur                                                         ;# |||        0.4
   TAX                                                                    ;# ||         0.2
   BEQ tfs_finish                          ; (entry guard bypassed)       ;# ||         0.3
   JMP tfs_proc                                                           ;# ||         0.3
tfs_finish:                                ; (tfsc_finish relay + the
.endscope                                  ;  JMP-to-next-instruction pair
                                        ;  died 2026-08-12: tfs_finish
                                        ;  FALLS into tfs_flush_pending
                                        ;  right below — the tail call
                                        ;  is free now)

; ---- Flush pending output span: alloc, populate fields, append. ----
;
; Input:  TFS_PEND_* (valid only when TFS_PEND_ACT = 1; no-op otherwise).
; Output: pending interval materialized as a pool span and appended via
;         tg_append_x; TFS_PEND_ACT cleared.  The span is DENSE-ANCHORED:
;         line anchors == active range (TXLO = XL, TDEN = XR - XL), with
;         the OT/IT/OB/IB bbox bytes computed from the endpoint values.
;         On pool exhaustion the interval is silently dropped
;         (flush_fail) — columns vanish rather than corrupt the list.
;         Clobbers A,X,Y.
tfs_flush_pending:
.scope
   LDA TFS_PEND_ACT                                                       ;# |||||      0.6
   BNE flush_do                                                           ;# ||||       0.5
   RTS                                                                    ;# ||||||     0.7
flush_do:
   ZERO TFS_PEND_ACT                                                      ;# ||||       0.4
   LDX zp_free                             ; alloc_span INLINED 2026-08-21: ;# ||         0.3
   BEQ flush_fail          ; pool empty -> caller's fail arm              ;# ||         0.2
   LDA POOL_NEXT,X                         ; (the sub's TXA and the caller's ;# |||        0.3
   STA zp_free                             ; BEQ existed only to carry Z  ;# ||         0.3
                                        ; across the JSR — both die)
   LDA TFS_PEND_XL                                                        ;# ||         0.3
   STA POOL_XSTART,X                                                      ;# ||||       0.4
   LDA TFS_PEND_XR                                                        ;# ||         0.3
   STA POOL_XEND,X                                                        ;# ||||       0.4
   LDA TFS_PEND_TXL                        ; each boundary keeps its SOURCE ;# ||         0.3
   STA POOL_TXLO,X                          ; anchor; the active range is ;# ||||       0.4
   LDA TFS_PEND_TDEN                       ; independent of both          ;# ||         0.3
   STA POOL_TDEN,X                                                        ;# ||||       0.4
   LDA TFS_PEND_BXL                                                       ;# ||         0.3
   STA POOL_BXLO,X                                                        ;# ||||       0.4
   LDA TFS_PEND_BDEN                                                      ;# ||         0.3
   STA POOL_BDEN,X                                                        ;# ||||       0.4
   LDA TFS_PEND_TL                                                        ;# ||         0.3
   STA POOL_TL,X                                                          ;# ||||       0.4
   LDA TFS_PEND_TR                                                        ;# ||         0.3
   STA POOL_TR,X                                                          ;# ||||       0.4
   LDA TFS_PEND_BL                                                        ;# ||         0.3
   STA POOL_BL,X                                                          ;# ||||       0.4
   LDA TFS_PEND_BR                                                        ;# ||         0.3
   STA POOL_BR,X                                                          ;# ||||       0.4
; OT = min(TL,TR), IT = max(TL,TR), OB = max(BL,BR), IB = min(BL,BR).
   LDA TFS_PEND_TL                                                        ;# ||         0.3
   CMP TFS_PEND_TR                                                        ;# ||         0.3
   BCC fp_ot                                                              ;# ||         0.2
   LDA TFS_PEND_TR                                                        ;# ||         0.2
fp_ot:
   STA POOL_OT,X                                                          ;# ||||       0.4
   LDA TFS_PEND_TL                                                        ;# ||         0.3
   CMP TFS_PEND_TR                                                        ;# ||         0.3
   BCS fp_it                                                              ;# ||         0.3
   LDA TFS_PEND_TR                                                        ;#            0.0
fp_it:
   STA POOL_IT,X                                                          ;# ||||       0.4
   LDA TFS_PEND_BL                                                        ;# ||         0.3
   CMP TFS_PEND_BR                                                        ;# ||         0.3
   BCS fp_ob                                                              ;# ||         0.2
   LDA TFS_PEND_BR                                                        ;#            0.0
fp_ob:
   STA POOL_OB,X                                                          ;# ||||       0.4
   LDA TFS_PEND_BL                                                        ;# ||         0.3
   CMP TFS_PEND_BR                                                        ;# ||         0.3
   BCC fp_ib                                                              ;# ||         0.2
   LDA TFS_PEND_BR                                                        ;# ||         0.2
fp_ib:
   STA POOL_IB,X                                                          ;# ||||       0.4
   JMP tg_append_x                                                        ;# ||         0.3
flush_fail:
   RTS
.endscope

; Emit unchanged sub-span [zp_ox0, zp_ox1) with old span's line def.
;
; Input:  zp_ox0/zp_ox1 = active range for the fragment (half-open);
;         zp_clr_save_x = source pool slot.
; Output: new slot with the source's line definition copied VERBATIM
;         (TXLO/TDEN/BXLO/BDEN/TL/BL/TR/BR + precomputed OT/OB/IT/IB — no interp,
;         matching the lazy fragments of the Python mirrors) and active
;         range [ox0, ox1), appended via tg_append_x.  Silently dropped
;         on pool exhaustion.  Clobbers A,X,Y.
emit_unchanged_subspan:
   LDX zp_free                             ; alloc_span INLINED 2026-08-21: ;#            0.1
   BEQ ues_fail          ; pool empty -> caller's fail arm                ;#            0.0
   LDA POOL_NEXT,X                         ; (the sub's TXA and the caller's ;# |          0.1
   STA zp_free                             ; BEQ existed only to carry Z  ;#            0.1
                                        ; across the JSR — both die)
   LDY zp_clr_save_x                                                      ;#            0.1
   LDA POOL_TXLO,Y                                                        ;# |          0.1
   STA POOL_TXLO,X                                                        ;# |          0.1
   LDA POOL_TDEN,Y                                                        ;# |          0.1
   STA POOL_TDEN,X                                                        ;# |          0.1
   LDA POOL_BXLO,Y                         ; bottom line's own anchors    ;# |          0.1
   STA POOL_BXLO,X                                                        ;# |          0.1
   LDA POOL_BDEN,Y                                                        ;# |          0.1
   STA POOL_BDEN,X                                                        ;# |          0.1
   LDA POOL_TL,Y                                                          ;# |          0.1
   STA POOL_TL,X                                                          ;# |          0.1
   LDA POOL_BL,Y                                                          ;# |          0.1
   STA POOL_BL,X                                                          ;# |          0.1
   LDA POOL_TR,Y                                                          ;# |          0.1
   STA POOL_TR,X                                                          ;# |          0.1
   LDA POOL_BR,Y                                                          ;# |          0.1
   STA POOL_BR,X                                                          ;# |          0.1
   LDA POOL_OT,Y                                                          ;# |          0.1
   STA POOL_OT,X                                                          ;# |          0.1
   LDA POOL_OB,Y                                                          ;# |          0.1
   STA POOL_OB,X                                                          ;# |          0.1
   LDA POOL_IT,Y                                                          ;# |          0.1
   STA POOL_IT,X                                                          ;# |          0.1
   LDA POOL_IB,Y                                                          ;# |          0.1
   STA POOL_IB,X                                                          ;# |          0.1
   LDA zp_ox0                                                             ;#            0.1
   STA POOL_XSTART,X                                                      ;# |          0.1
   LDA zp_ox1                                                             ;#            0.1
   STA POOL_XEND,X                                                        ;# |          0.1
   JMP tg_append_x                                                        ;#            0.1
ues_fail:
   RTS


; ===================================================================
; s16 line clipper — generic first cut
;
; Wrapper writes 8 bytes of s16 input (4 endpoints × 2 bytes) to the
; zp_line_xl_l..zp_line_yr_h ZP slots, then JSRs draw_clipped_line_s16
; (the "$201E" a previous note named here is a dead pre-relayout slot
; number — resolve entries via the symbol map only). Routine clips the
; line to u8 [0,255]×[0,255], writes u8 result to zp_line_xl_l/yl/xr/yr,
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
LC_OX1_LO = $0638
LC_OX1_HI = $0639
LC_OY1_LO = $063A
LC_OY1_HI = $063B
LC_OX2_LO = $063C
LC_OX2_HI = $063D
LC_OY2_LO = $063E
LC_OY2_HI = $063F
; ---- math working (ZP SWEEP 2026-08-11: the hot subset — the u16
; mul/div workspace dominates the profile — moved to freed zp; cold
; members stay $06xx) ----
LC_DY_NEG = $0646
LC_M_A_LO = $0647
LC_M_A_HI = $0648
LC_M_B_LO = $0649
LC_M_B_HI = $064A
LC_M_R2 = $064D
LC_M_R3 = $064E
LC_TMP_HI = $0654
LC_RES_LO = $0655
LC_RES_HI = $0656
LC_TGT_LO = $0657                       ; clip target value (s16)
LC_TGT_HI = $0658

; ---------------------------------------------------------------------------
SEG_HIGH
; (Relocated to the LO segment 2026-07-13: cold classifier, and the CLIP region is
; at its ceiling — main RAM is always mapped, so bank-C callers are fine.
; Slated for deletion by Part 2 of the aperture fix.)
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
;      SOLID over [ilo, ihi)); C=0 -> genuine no-op (skip).
; Caller: bsp/subsector.s seg-emit tail (direct .import, not a jt slot;
; bank C paged in the banked build). Clobbers A,X.
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
; s16 compare via full SBC pair — NO V-correction (2026-07-17 sweep):
; projections are bounded by construction (sy = HALF_H - rns(h*m9, S),
; |h*m9| <= 127*511, S >= 1 -> |sy| <= 32,577), so value-6 and
; 165-value both stay inside s16 (margins 191 / 26) and N IS the sign.
szr_lt:
   LDA SZR_PROJ,X
   SEC
   SBC #Y_BIAS
   LDA SZR_PROJ+1,X
   SBC #0
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
   LDX #zp_seg_sy1_bot_l - VX1            ; sy1_bot (fb1)
   JSR szr_lt
   BCS szr_b1
   LDA zp_seg_flags
   AND #$08                                ; SF_NEEDBB
   BEQ szr_top
   LDX #zp_seg_sy1_bbot_l - VX1            ; sy1_bbot (bb1)
   JSR szr_lt
   BCC szr_top
szr_b1:
; ... and at endpoint 2?
   LDX #zp_seg_sy2_bot_l - VX1            ; sy2_bot (fb2)
   JSR szr_lt
   BCS szr_closed
   LDA zp_seg_flags
   AND #$08
   BEQ szr_top
   LDX #zp_seg_sy2_bbot_l - VX1            ; sy2_bbot (bb2)
   JSR szr_lt
   BCS szr_closed
szr_top:
; top family: band top below the screen bottom at endpoint 1?
; Band top = max(ft, bt-if-NEEDBT), and max(a,b) > k iff a > k OR
; b > k — the same either-of-two test per endpoint as the bottom
; family above, with szr_gt in place of szr_lt.
   LDX #zp_seg_sy1_top_l - VX1            ; sy1_top (ft1)
   JSR szr_gt
   BCS szr_t1
   LDA zp_seg_flags
   AND #$04                                ; SF_NEEDBT
   BEQ szr_open
   LDX #zp_seg_sy1_btop_l - VX1            ; sy1_btop (bt1)
   JSR szr_gt
   BCC szr_open
szr_t1:
   LDX #zp_seg_sy2_top_l - VX1            ; sy2_top (ft2)
   JSR szr_gt
   BCS szr_closed
   LDA zp_seg_flags
   AND #$04
   BEQ szr_open
   LDX #zp_seg_sy2_btop_l - VX1            ; sy2_btop (bt2)
   JMP szr_gt                              ; TAIL: the last test's carry IS
                                        ; the verdict, so the old
                                        ; BCS szr_closed + fall-into-szr_open
                                        ; pair was just re-encoding szr_gt's
                                        ; own C.  -14 cycles, -5 bytes.
                                        ; The two labels below MUST stay:
                                        ; five other branches target them
                                        ; (szr_closed x3, szr_open x2).
szr_open:
   RTS                                     ; C=0 — every arrival is a
                                        ; BCS-not-taken or a BCC, and the
                                        ; intervening LDA/AND leave C alone
szr_closed:
   SEC
   RTS
.endscope
SEG_BANKC
