; ============================================================================
; clip/fusedw.s — the FUSED draw+tighten walker (2026-08-25 campaign,
; SIMPLIFIED to Eben's ruling the same night: "keep it simple, stupid").
;
; Two functions, no records intermediate:
;
;   fused_above_h / fused_below_h   (X = sy pair offset, seg cascade)
;   fused_below_raw                 (line in zp_line_*, object arcs)
;
; Each clips its armed line against the span list ONCE, plotting the
; visible fragments as it goes (the never-split-a-line deferred-run
; emit, via dcl_emit_segment) and applying the tighten IMMEDIATELY:
;
;   visible run [x0,x1) -> the side's boundary on every covered span
;        becomes the FULL LINE being clipped: anchor = (line.xl,
;        line.xr - line.xl), values = (line.yl, line.yr), extremes =
;        min/max of the same two bytes. A PURE COPY of six bytes — NO
;        interpolation when configuring spans, by decree. (The old
;        records re-anchored on fragment endpoints, whose values came
;        out of interp — double-rounded and more code.)
;   'below' flat on the top side / 'above' flat on the bot side
;        -> the columns close (span_mark_solid — the far-west fix's
;        verdict semantics, unchanged)
;   neutral flats -> no pool touch, but they COUNT (FW_TOUCH): a seg
;        whose armed lines produced nothing at all still takes the
;        seg_zero_rec_solid dispatch, exactly as a zero record count did.
;
; SEQUENTIAL BY DECREE: a seg's top line applies before its bottom line
; is clipped (and an object's arc lines apply one after another). The
; pool a later line sees can therefore differ from the old batch
; semantics by a crossing-quantization pixel (the CB clip evaluates
; boundaries at ox0/ox1 = f(span edges), so an earlier apply's splits
; and merges can move a later crossing by one column — the 216,77
; witness). Eben accepted this class explicitly — the simplicity is
; worth more than batch equivalence.
;
; MERGES: the applies never merge (an apply runs while its own line's
; walk is suspended, and a merge could free or absorb the walk's resume
; slot). fused_merge_range runs ONCE at seg / object end and coalesces
; every value-equal abutting pair in the range — the full-line anchors
; make it effective: two spans tightened by the same line carry
; byte-identical boundary sources.
;
; Python mirror: the pixel-exact reference drives THIS code and syncs
; its twin from the pool (read_spans); the pure-python pipeline models
; the same sequential/full-line-anchor semantics. The batch tighten
; model is dead on both sides.
; ============================================================================

; --- walker state ------------------------------------------------------
; HOMED ON THE FREED RECORD PAGE (2026-08-25). The first cut used the
; $069C-$06E6 run of the $06xx scratch page, ASSUMED free — it is not:
; PB_XL/XH/YL/YH ($0680-$06BF, the bbox corner staging, written by every
; bbox visibility test) and PB_TS/TC/PREV_AB sit right across it, so a
; single bbox check sprayed corner coordinates over FW_MODE and the
; whole walker state (3-line frames). The record page is free BY
; CONSTRUCTION — this campaign emptied it — and it is in the clipper's
; own bank context (bank C banked; the flat exception window flat).
.if ::BANKED
FW_BASE = $9700                         ; ex-BOT_RECORDS (bank C)
.else
FW_BASE = $2000                         ; ex-BOT_RECORDS (exception window)
.endif
; COLD walker bytes only — the hot set was promoted to zero page
; (src/zp.inc FUSED block, 2026-08-25 grind; the freed TFS bytes).
FW_TOUCH   = FW_BASE+$00                ; any flat or run this seg/object
FW_ISAVE0  = FW_BASE+$03                ; zp_i_l/h save around mark_solid
FW_ISAVE1  = FW_BASE+$04
fw_split_at = FW_BASE+$21
fw_fx0 = FW_BASE+$22
fw_fx1 = FW_BASE+$23
fm_prev = FW_BASE+$24
.export FW_TOUCH                        ; the cascade + harness read it

SEG_BANKC

; ============================================================================
; fw_walk_line — the s16 dispatch lands here in FW_MODE with the
; clipped u8 line in zp_line_*: stage it, walk the span list, clip /
; plot / apply. Verticals (xl == xr) keep their plot-only semantics via
; the real core (they carry no tighten information — as ever).
; ============================================================================
fw_walk_line:
.scope
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BNE wl_line
   JMP draw_clipped_line                   ; vertical: plot as today
wl_line:
   STA fwl_xl
   LDA zp_line_yl_l
   STA fwl_yl
   LDA zp_line_xr_l
   STA fwl_xr
   LDA zp_line_yr_l
   STA fwl_yr
::fw_walk_staged:                          ; fast-path entry (fused.s): the
   SEC                                     ; entries stage fwl_* DIRECTLY
   SBC fwl_yl                              ; from VX/sx — A = fwl_yr rides in
   STA fwl_dy
   LDA fwl_xr
   SEC
   SBC fwl_xl
   STA fwl_dx
   LDA fwl_yl
   LDX fwl_yr
   CMP fwl_yr
   BCC wl_min
   TXA
   LDX fwl_yl
wl_min:
   STA fwl_lo
   STX fwl_hi
   LDA #$FF
   STA fwl_run                             ; no open run
; ---- the walk: dcl's two-phase idiom (2026-08-25 grind) ----
; Phase 1 skips spans wholly left of the line with xl riding A through
; an X/Y ping-pong — no SLOT/NEXT staging, no processed-span work.
; Phase 2 never re-tests the left edge: the first survivor has
; xend > xl, and every later span starts at xstart >= that xend, so the
; property is monotone (dcl's proof, dclw_x).
   LDX zp_head
   BNE wl_skip
   JMP wl_flush
wl_skip:
   LDA fwl_xl
wl_sx:
   CMP POOL_XEND,X
   BCC wl_proc                             ; first survivor (X)
   LDY POOL_NEXT,X
   BNE wl_sy
   JMP wl_flush
wl_sy:
   CMP POOL_XEND,Y
   BCC wl_found_y
   LDX POOL_NEXT,Y
   BNE wl_sx
   JMP wl_flush
wl_found_y:
   TYA
   TAX
wl_proc:
; phase 2: X = span with xend > xl
   LDA POOL_XSTART,X
   CMP fwl_xr
   BCS wl_flush                            ; xstart >= xr: done (sorted)
   STX FW_SLOT
   LDY POOL_NEXT,X                         ; Y, not A: XSTART rides A into
   STY FW_NEXT                             ; the clip (its ox0 max)
   JSR fw_clip_span
   LDX FW_NEXT
   BNE wl_proc
wl_flush:
   LDA fwl_run
   CMP #$FF
   BEQ wl_done
   JSR fw_close_run
wl_done:
   RTS
.endscope

; ============================================================================
; fw_clip_span — classify the line on span FW_SLOT's overlap [zx0, zx1),
; plot / apply. Transcribed compare-for-compare from dcl.s; the flats
; and run closes apply IMMEDIATELY (sequential semantics by decree).
; GRIND (2026-08-25): flat polarity is a SITE CONSTANT — the side test
; inlines at each site, so a neutral flat is touch-and-return and only
; genuine kills pay the fused_kill call.
; ============================================================================
fw_clip_span:
.scope
; entry: A = POOL_XSTART,X (the walk's test load rides), X = slot
   CMP fwl_xl
   BCS cs_ox0
   LDA fwl_xl
cs_ox0:
   STA fwl_zx0
   LDA POOL_XEND,X
   CMP fwl_xr
   BCC cs_ox1
   LDA fwl_xr
cs_ox1:
   STA fwl_zx1
; (fwl_leftf / fwl_pend staging moved into fw_cb — the only consumer)
; ---- Tier: inner accept first (dcl_entry_path order) ----
   LDA fwl_lo
   CMP POOL_IT,X
   BCC cs_ent_top                          ; ylo < IT: above/ambiguous
   LDA POOL_IB,X
   CMP fwl_hi
   BCC cs_ent_bot                          ; yhi > IB: below/ambiguous
; ---- ACCEPT: visible over the whole overlap ----
   LDA fwl_zx0
   CMP fwl_xl
   BEQ cs_acc_yl
   LDA fwl_dy
   BEQ cs_acc_yl
   JSR fw_line_interp_zx0                  ; entry y (PLOT only)
   JMP cs_acc_have
cs_acc_yl:
   LDA fwl_yl
cs_acc_have:
   STA cp_vy0
   LDA fwl_zx0
   STA cp_vx0
   LDA fwl_zx1
   STA cp_vx1
   LDA #$80
   STA cp_vev                              ; open end
   JMP fw_run_visible
cs_ent_top:
   LDA fwl_hi
   CMP POOL_OT,X
   BCC cs_rej_above                        ; yhi < OT: whole overlap above
   JMP fw_cb
cs_ent_bot:
   LDA POOL_OB,X
   CMP fwl_lo
   BCC cs_rej_below                        ; OB < ylo: whole overlap below
   JMP fw_cb
cs_rej_above:                              ; 'above': kills iff BOT side
   LDA #1
   STA FW_TOUCH
   JSR fw_close_if_open                    ; run genuinely ended here
   BIT FW_SIDE
   BMI cs_kill
   RTS
cs_rej_below:                              ; 'below': kills iff TOP side
   LDA #1
   STA FW_TOUCH
   JSR fw_close_if_open
   BIT FW_SIDE
   BMI cs_neutral
cs_kill:
   LDA fwl_zx0
   LDY fwl_zx1
   JMP fused_kill
cs_neutral:
   RTS
.endscope

; close any open run (the flat/reject paths' preamble)
fw_close_if_open:
   LDA fwl_run
   CMP #$FF
   BNE fw_close_run_j
   RTS
fw_close_run_j:
   JMP fw_close_run

; line interp at zx0 / at A: stage the LINE into the interp workspace.
; (Clipping still interpolates — the no-interp decree is about SPAN
; CONFIGURATION, which is a pure copy now.)
fw_line_interp_zx0:
   LDA fwl_zx0
fw_line_interp_a:
   PHA
   LDA fwl_xl
   STA zp_i_x0
   LDA fwl_yl
   STA zp_i_y0
   LDA fwl_yr
   STA zp_i_y1
   LDA fwl_dx
   STA zp_div_den
   PLA
   JMP interp_store

; ============================================================================
; fw_cb — the CB trapezoid clip on [zx0, zx1) (dcl_cb_clip transcribed;
; cx in zp_cb_cx1/cx2 for dcl_boundary_ix, cy in zp_cb_cy1/cy2).
; ============================================================================
fw_cb:
.scope
   LDA #$80
   STA fwl_pend
   LDA fwl_zx0
   STA fwl_leftf
   STA zp_cb_cx1
   LDA fwl_zx1
   STA zp_cb_cx2
; ---- cy1/cy2: line-mode interp workspace staged ONCE (dcl's trick) ----
   LDA fwl_dy
   BNE cb_cy_slow
   LDA fwl_yl
   STA zp_cb_cy1
   STA zp_cb_cy2
   JMP cb_cy_done
cb_cy_slow:
   LDA fwl_xl
   STA zp_i_x0
   LDA fwl_yl
   STA zp_i_y0
   LDA fwl_yr
   STA zp_i_y1
   LDA fwl_dx
   STA zp_div_den
   LDA zp_cb_cx1
   CMP fwl_xl
   BEQ cb_cy1_yl
   JSR interp_store                        ; A = cx1 rides in
   JMP cb_cy1_have
cb_cy1_yl:
   LDA fwl_yl
cb_cy1_have:
   STA zp_cb_cy1
   LDA zp_cb_cx2
   CMP fwl_xr
   BEQ cb_cy2_yr
   JSR interp_store
   JMP cb_cy2_have
cb_cy2_yr:
   LDA fwl_yr
cb_cy2_have:
   STA zp_cb_cy2
cb_cy_done:
; ---- TOP boundary ----
   LDX FW_SLOT
   LDA zp_cb_cy2
   CMP POOL_IT,X
   BCC cb_top_eval
   LDA zp_cb_cy1
   CMP POOL_IT,X
   BCC cb_top_eval
   JMP cb_top_done                         ; both >= IT: skip top
cb_top_eval:
   LDA POOL_TL,X
   CMP POOL_TR,X
   BNE cb_top_interp
   STA fw_top1
   STA fw_top2
   JMP cb_top_evaled
cb_top_interp:
   LDA POOL_TXLO,X                         ; staging inlined (2026-08-25
   STA zp_i_x0                             ; grind): the JSR/RTS pair was
   LDA POOL_TDEN,X                         ; per-evaluation tax
   STA zp_div_den
   LDA POOL_TL,X
   STA zp_i_y0
   LDA POOL_TR,X
   STA zp_i_y1
   LDA zp_cb_cx1
   JSR interp_store
   STA fw_top1
   LDA zp_cb_cx2
   JSR interp_store
   STA fw_top2
cb_top_evaled:
   LDA zp_cb_cy1
   CMP fw_top1
   BCS cb_top_p1_ok
   LDA zp_cb_cy2
   CMP fw_top2
   BCS cb_top_clip_p1
   JMP cb_whole_above                      ; both above
cb_top_p1_ok:
   LDA zp_cb_cy2
   CMP fw_top2
   BCS cb_top_done                         ; both inside
; p2-clip (cy1 >= top1, cy2 < top2)
   LDA zp_cb_cy1
   SEC
   SBC fw_top1
   STA zp_tmp0                             ; d1 >= 0
   LDA zp_cb_cy2
   SBC fw_top2
   STA zp_tmp1                             ; d2 < 0
   LDA #0
   JSR dcl_boundary_ix
   STA zp_cb_cx2
   JSR fw_bval_top                         ; A = ix rides in
   STA zp_cb_cy2
   LDA #0
   STA fwl_pend                            ; right-pend 'above'
   JMP cb_top_done
cb_top_clip_p1:                            ; cy1 < top1, cy2 >= top2 (C=1)
   LDA zp_cb_cy1
   SBC fw_top1
   STA zp_tmp0                             ; d1 < 0
   LDA zp_cb_cy2
   SEC
   SBC fw_top2
   STA zp_tmp1                             ; d2 >= 0
   LDA #1
   JSR dcl_boundary_ix
   STA zp_cb_cx1
   JSR fw_bval_top
   STA zp_cb_cy1
; left flat [leftf, cx1) 'above' — kills iff BOT side (site constant)
   LDA fwl_zx0
   CMP zp_cb_cx1
   BCS cb_top_done
   LDA #1
   STA FW_TOUCH
   JSR fw_close_if_open
   BIT FW_SIDE
   BPL cb_tlf_done                         ; top side: neutral
   LDA fwl_leftf
   LDY zp_cb_cx1
   JSR fused_kill
cb_tlf_done:
   LDA zp_cb_cx1
   STA fwl_leftf
cb_top_done:
   LDA zp_cb_cx2
   CMP zp_cb_cx1
   BCS cb_bot
   JMP cb_whole_above                      ; defensive (mirrors dcl)
; ---- BOT boundary (at the top-clipped cx1/cx2) ----
cb_bot:
   LDX FW_SLOT
   LDA POOL_IB,X
   CMP zp_cb_cy1
   BCC cb_bot_eval
   CMP zp_cb_cy2
   BCC cb_bot_eval
   JMP cb_bot_done                         ; both <= IB: skip bot
cb_bot_eval:
   LDA POOL_BL,X
   CMP POOL_BR,X
   BNE cb_bot_interp
   STA fw_top1                             ; (slots reused as bot1/bot2)
   STA fw_top2
   JMP cb_bot_evaled
cb_bot_interp:
   LDA POOL_BXLO,X                         ; (mirror of the top inline)
   STA zp_i_x0
   LDA POOL_BDEN,X
   STA zp_div_den
   LDA POOL_BL,X
   STA zp_i_y0
   LDA POOL_BR,X
   STA zp_i_y1
   LDA zp_cb_cx1
   JSR interp_store
   STA fw_top1
   LDA zp_cb_cx2
   JSR interp_store
   STA fw_top2
cb_bot_evaled:
   LDA fw_top1
   CMP zp_cb_cy1
   BCS cb_bot_p1_ok
   LDA fw_top2
   CMP zp_cb_cy2
   BCS cb_bot_clip_p1
   JMP cb_whole_below                      ; both below
cb_bot_p1_ok:
   LDA fw_top2
   CMP zp_cb_cy2
   BCS cb_bot_done                         ; both inside
; p2-clip (cy1 <= bot1, cy2 > bot2)
   LDA zp_cb_cy1
   SEC
   SBC fw_top1
   STA zp_tmp0                             ; d1 <= 0
   LDA zp_cb_cy2
   SEC
   SBC fw_top2
   STA zp_tmp1                             ; d2 > 0
   LDA #0
   JSR dcl_boundary_ix
   STA zp_cb_cx2
   JSR fw_bval_bot
   STA zp_cb_cy2
   LDA #$FF
   STA fwl_pend                            ; right-pend 'below' (overwrites)
   JMP cb_bot_done
cb_bot_clip_p1:                            ; bot1 < cy1, bot2 >= cy2 (C=1)
   LDA zp_cb_cy1
   SBC fw_top1
   STA zp_tmp0                             ; d1 > 0 (C=1 again)
   LDA zp_cb_cy2
   SBC fw_top2
   STA zp_tmp1                             ; d2 <= 0
   LDA #1
   JSR dcl_boundary_ix
   STA zp_cb_cx1
   JSR fw_bval_bot
   STA zp_cb_cy1
; left flat [leftf, cx1) 'below' — kills iff TOP side (site constant)
   LDA fwl_zx0
   CMP zp_cb_cx1
   BCS cb_bot_done
   LDA #1
   STA FW_TOUCH
   JSR fw_close_if_open
   BIT FW_SIDE
   BMI cb_blf_done                         ; bot side: neutral
   LDA fwl_leftf
   LDY zp_cb_cx1
   JSR fused_kill
cb_blf_done:
   LDA zp_cb_cx1
   STA fwl_leftf
cb_bot_done:
   LDA zp_cb_cx2
   CMP zp_cb_cx1
   BCC cb_whole_below                      ; cx2 < cx1 post-bot -> below
; ---- visible piece [cx1, cx2) + optional right-pend flat ----
   LDA zp_cb_cx1
   STA cp_vx0
   LDA zp_cb_cy1
   STA cp_vy0
   LDA zp_cb_cx2
   STA cp_vx1
   LDA #$80
   LDY zp_cb_cx2
   CPY fwl_zx1
   BCS cb_end_open
   LDA zp_cb_cy2                           ; crossing value (PLOT end)
cb_end_open:
   STA cp_vev
   JSR fw_run_visible
; right-pend flat [cx2, zx1): pol in fwl_pend (runtime — the two CB
; p2 arms overwrite each other), touch + side-resolved kill
   LDA fwl_pend
   CMP #$80
   BEQ cb_done
   LDY #1
   STY FW_TOUCH
   LDA zp_cb_cx2
   CMP fwl_zx1
   BCS cb_done                             ; empty
; kill iff (top & pend=='below' $FF) or (bot & pend=='above' 0)
   TAY                                     ; Y = cx2 (kill's x0... reload
   LDA fwl_pend                            ; below; Y freed for the range)
   BIT FW_SIDE
   BMI cb_rp_bot
   CMP #$FF
   BEQ cb_rp_kill
   RTS
cb_rp_bot:
   CMP #0
   BEQ cb_rp_kill
   RTS
cb_rp_kill:
   LDA zp_cb_cx2
   LDY fwl_zx1
   JMP fused_kill
cb_done:
   RTS
cb_whole_above:
; effective: [leftf, zx1) 'above' — kills iff BOT side; discard pend
   LDA #1
   STA FW_TOUCH
   JSR fw_close_if_open
   BIT FW_SIDE
   BMI cb_wf_kill
   RTS
cb_whole_below:
; effective: [leftf, zx1) 'below' — kills iff TOP side; discard pend
   LDA #1
   STA FW_TOUCH
   JSR fw_close_if_open
   BIT FW_SIDE
   BMI cb_wf_neutral
cb_wf_kill:
   LDA fwl_leftf
   CMP fwl_zx1
   BCS cb_wf_neutral                       ; nothing left to kill
   LDY fwl_zx1
   JMP fused_kill
cb_wf_neutral:
   RTS
.endscope

; boundary interp workspace staging (top / bot lines of span FW_SLOT)
fw_stage_top_ws:
   LDX FW_SLOT
   LDA POOL_TXLO,X
   STA zp_i_x0
   LDA POOL_TDEN,X
   STA zp_div_den
   LDA POOL_TL,X
   STA zp_i_y0
   LDA POOL_TR,X
   STA zp_i_y1
   RTS
fw_stage_bot_ws:
   LDX FW_SLOT
   LDA POOL_BXLO,X
   STA zp_i_x0
   LDA POOL_BDEN,X
   STA zp_div_den
   LDA POOL_BL,X
   STA zp_i_y0
   LDA POOL_BR,X
   STA zp_i_y1
   RTS
; boundary value at crossing: A = ix -> A = value (const fast path when
; the endpoint evaluations were equal)
fw_bval_top:
   LDY fw_top1
   CPY fw_top2
   BEQ fw_bval_const
   PHA
   JSR fw_stage_top_ws
   PLA
   JMP interp_store
fw_bval_bot:
   LDY fw_top1
   CPY fw_top2
   BEQ fw_bval_const
   PHA
   JSR fw_stage_bot_ws
   PLA
   JMP interp_store
fw_bval_const:
   TYA
   RTS

; ============================================================================
; fw_run_visible — feed a visible piece (cp_v*) to the run.
; fw_close_run — close it: end y for the PLOT (crossing value, or yr /
; flat-yl / interp — dcl_emit_open's cases), emit via dcl_emit_segment,
; then apply [run, rend) with the FULL-LINE boundary (pure copy).
; ============================================================================
fw_run_visible:
.scope
   LDA cp_vx0
   CMP cp_vx1
   BEQ rv_degen
   LDA fwl_run
   CMP #$FF
   BEQ rv_open
   LDA cp_vx0
   CMP fwl_rend
   BEQ rv_extend
   JSR fw_close_run                        ; noncontiguous: close old
   JMP rv_open
rv_extend:
   LDA cp_vx1
   STA fwl_rend
   LDA cp_vev
   STA fwl_rendv
   RTS
rv_open:
   LDA FW_SLOT
   STA fw_rslot                            ; the apply starts HERE, not at
   LDA cp_vx0                              ; zp_head — the from-head rescan
   STA fwl_run                             ; was the heavy frame's tax
   LDA cp_vy0
   STA fwl_ry0
   LDA cp_vx1
   STA fwl_rend
   LDA cp_vev
   STA fwl_rendv
   LDA #1
   STA FW_TOUCH
   RTS
rv_degen:
; contiguous degenerate piece: the run closes AT its current end with
; the crossing value; noncontiguous: close old as-is; no new run.
   LDA fwl_run
   CMP #$FF
   BEQ rv_none
   LDA cp_vx0
   CMP fwl_rend
   BNE rv_close_old
   LDA cp_vev
   STA fwl_rendv
rv_close_old:
   JMP fw_close_run
rv_none:
   RTS
.endscope

fw_close_run:
.scope
; PLOT end y: crossing value if staged, else yr / flat-yl / interp
   LDA fwl_rendv
   CMP #$80
   BNE cr_store
   LDA fwl_rend
   CMP fwl_xr
   BEQ cr_yr
   LDA fwl_dy
   BEQ cr_yl
   LDA fwl_rend
   JSR fw_line_interp_a
   JMP cr_store
cr_yr:
   LDA fwl_yr
   JMP cr_store
cr_yl:
   LDA fwl_yl
cr_store:
   STA zp_tmp0
   LDA fwl_run
   STA zp_seg_start_x
   LDA fwl_ry0
   STA zp_seg_start_y
   LDA fwl_rend
   STA zp_ox1
   JSR dcl_emit_segment                    ; plot (records machinery gone)
; APPLY [run, rend): full-line boundary, pure copy
   LDA fwl_run
   STA fw_ax0
   LDA fwl_rend
   STA fw_ax1
   JSR fused_apply_run
   LDA #$FF
   STA fwl_run
   RTS
.endscope

SEG_HIGH
; (the apply/flat/split/merge cluster lives in MAIN — always mapped, so
;  the bank-C walker JSRs here at no cost: the pattern tg_append_x used;
;  tg_append_x's death paid for the space.)

; ============================================================================
; fused_apply_run — install the FULL LINE as the FW_SIDE boundary on
; every span overlapping [fw_ax0, fw_ax1): split partial edges (pieces
; copy all fields verbatim — mark_solid's discipline), then SIX PURE
; COPIES: anchor (fwl_xl, fwl_dx), values (fwl_yl, fwl_yr), extremes
; (fwl_lo, fwl_hi). No interpolation, by decree. No merging (the walk
; is suspended; fused_merge_range coalesces at seg end). Invalidates
; zp_hg_cache. Pool exhaustion on a split: the split is skipped and the
; whole span takes the boundary (conservative; the corpus never
; exhausts).
; ============================================================================
fused_apply_run:
.scope
   ZERO zp_hg_cache
   LDX fw_rslot                            ; run-open slot (see fw_rslot)
ar_walk:
   BNE ar_go
   RTS
ar_go:
   LDA fw_ax0                              ; C = ax0 >= xend -> wholly left
   CMP POOL_XEND,X
   BCS ar_next
   LDA POOL_XSTART,X
   CMP fw_ax1
   BCC ar_over
   RTS                                     ; xstart >= ax1: done (sorted)
ar_over:
; overlap. Left split needed? (xstart < ax0)
   CMP fw_ax0
   BCS ar_no_lsplit
   LDA fw_ax0
   STA fw_split_at
   JSR fw_split_r                          ; X keeps [xstart, ax0)
   LDY POOL_NEXT,X
   BEQ ar_stay                             ; exhaustion: boundary lands on
   TYA                                     ; the whole span (conservative)
   TAX
ar_stay:
ar_no_lsplit:
; Right split needed? (xend > ax1)
   LDA fw_ax1
   CMP POOL_XEND,X
   BCS ar_no_rsplit
   STA fw_split_at
   JSR fw_split_r                          ; X keeps [xstart, ax1)
ar_no_rsplit:
; SIX PURE COPIES — the full line becomes the side's boundary
   BIT FW_SIDE
   BMI ar_bot
   LDA fwl_xl
   STA POOL_TXLO,X
   LDA fwl_dx
   STA POOL_TDEN,X
   LDA fwl_yl
   STA POOL_TL,X
   LDA fwl_yr
   STA POOL_TR,X
   LDA fwl_lo
   STA POOL_OT,X
   LDA fwl_hi
   STA POOL_IT,X
   JMP ar_next
ar_bot:
   LDA fwl_xl
   STA POOL_BXLO,X
   LDA fwl_dx
   STA POOL_BDEN,X
   LDA fwl_yl
   STA POOL_BL,X
   LDA fwl_yr
   STA POOL_BR,X
   LDA fwl_hi
   STA POOL_OB,X
   LDA fwl_lo
   STA POOL_IB,X
ar_next:
   LDA POOL_NEXT,X
   TAX
   JMP ar_walk
.endscope

; --- fw_split_r: split span X at fw_split_at: X keeps [xstart, at),
; a fresh sibling takes [at, xend) with ALL fields copied verbatim,
; linked after X. Exhaustion: no-op (caller handles). X preserved. ---
fw_split_r:
.scope
   LDY zp_free
   BEQ fsr_fail
   LDA POOL_NEXT,Y
   STA zp_free
   LDA POOL_TXLO,X
   STA POOL_TXLO,Y
   LDA POOL_TDEN,X
   STA POOL_TDEN,Y
   LDA POOL_BXLO,X
   STA POOL_BXLO,Y
   LDA POOL_BDEN,X
   STA POOL_BDEN,Y
   LDA POOL_TL,X
   STA POOL_TL,Y
   LDA POOL_TR,X
   STA POOL_TR,Y
   LDA POOL_BL,X
   STA POOL_BL,Y
   LDA POOL_BR,X
   STA POOL_BR,Y
   LDA POOL_OT,X
   STA POOL_OT,Y
   LDA POOL_IT,X
   STA POOL_IT,Y
   LDA POOL_OB,X
   STA POOL_OB,Y
   LDA POOL_IB,X
   STA POOL_IB,Y
   LDA POOL_XEND,X
   STA POOL_XEND,Y
   LDA fw_split_at
   STA POOL_XSTART,Y
   STA POOL_XEND,X
   LDA POOL_NEXT,X
   STA POOL_NEXT,Y
   TYA
   STA POOL_NEXT,X
fsr_fail:
   RTS
.endscope

; ============================================================================
; fused_kill — close columns [A, Y): the kill half of a flat verdict,
; via span_mark_solid with the cascade's zp_i range saved. The walk's
; flat sites call this DIRECTLY (their polarity is a site constant);
; fused_flat below keeps the runtime-pol interface for dcl_rec_flat
; (the s16 band-clip wrappers).
; ============================================================================
fused_kill:
.scope
   STA fw_fx0
   STY fw_fx1
   LDA zp_i_l
   STA FW_ISAVE0
   LDA zp_i_h
   STA FW_ISAVE1
   LDA fw_fx0
   STA zp_i_l
   LDA fw_fx1
   STA zp_i_h
   JSR span_mark_solid
   LDA FW_ISAVE0
   STA zp_i_l
   LDA FW_ISAVE1
   STA zp_i_h
   RTS
.endscope

; fused_flat — runtime polarity (fw_pol), [A, Y): touch + side-resolved
; kill. Only dcl_rec_flat (band flats) comes here now.
fused_flat:
.scope
   STA ff_x0
   STY ff_y1
   LDA #1
   STA FW_TOUCH
   BIT FW_SIDE
   BMI ff_bot
   LDA fw_pol                              ; top side: $FF ('below') kills
   CMP #$FF
   BEQ ff_kill
   RTS
ff_bot:
   LDA fw_pol                              ; bot side: 0 ('above') kills
   BEQ ff_kill
   RTS
ff_kill:
   LDA ff_x0
   LDY ff_y1
   JMP fused_kill
ff_x0 = FW_BASE+$27
ff_y1 = FW_BASE+$28
.endscope

SEG_BANKC
; ============================================================================
; fused_merge_range — coalesce every value-equal abutting pair over
; [zp_i_l, zp_i_h) (seams included) — tg_append_x's 8-field test. Runs
; once at seg / object end, when no walk is suspended.
; ============================================================================
fused_merge_range:
.scope
   ZERO fm_prev
   LDX zp_head
   BNE fm_seek
   RTS
fm_seek:
   LDA zp_i_l
   CMP POOL_XEND,X
   BCC fm_found                            ; xend > ilo
   LDY POOL_NEXT,X
   BEQ fm_rts
   STX fm_prev
   TYA
   TAX
   JMP fm_seek
fm_rts:
   RTS
fm_found:
   TXA
   TAY                                     ; Y = first overlapping span (Q)
   LDX fm_prev                             ; X = its predecessor (P), or 0
   BNE fm_pair
   TYA
   TAX
   LDA POOL_NEXT,Y
   TAY
   BNE fm_chk
   RTS
fm_pair:
; P = X, Q = Y: abut + 8 line fields
   LDA POOL_XEND,X
   CMP POOL_XSTART,Y
   BNE fm_stepq
   LDA POOL_TXLO,X
   CMP POOL_TXLO,Y
   BNE fm_stepq
   LDA POOL_TDEN,X
   CMP POOL_TDEN,Y
   BNE fm_stepq
   LDA POOL_TL,X
   CMP POOL_TL,Y
   BNE fm_stepq
   LDA POOL_TR,X
   CMP POOL_TR,Y
   BNE fm_stepq
   LDA POOL_BXLO,X
   CMP POOL_BXLO,Y
   BNE fm_stepq
   LDA POOL_BDEN,X
   CMP POOL_BDEN,Y
   BNE fm_stepq
   LDA POOL_BL,X
   CMP POOL_BL,Y
   BNE fm_stepq
   LDA POOL_BR,X
   CMP POOL_BR,Y
   BNE fm_stepq
; merge Q into P; keep P as the candidate against Q's successor
   LDA POOL_XEND,Y
   STA POOL_XEND,X
   LDA POOL_NEXT,Y
   STA POOL_NEXT,X
   PHA
   LDA zp_free
   STA POOL_NEXT,Y
   STY zp_free
   ZERO zp_hg_cache
   PLA
   TAY
   BNE fm_chk
   RTS
fm_stepq:
   TYA
   TAX
   LDA POOL_NEXT,Y
   TAY
   BNE fm_chk
   RTS
fm_chk:
; keep going while Q.xstart <= ihi (the seam pair past the range is
; the last one tested)
   LDA zp_i_h
   CMP POOL_XSTART,Y
   BCS fm_pair
   RTS
.endscope

SEG_BANKC

; ============================================================================
; dcl_rec_flat — the flat-verdict handler (moved from dcl.s at the
; cutover: the s16 band-clip wrappers call it; in fused mode it applies
; the flat immediately, else it is a no-op).
; ============================================================================
dcl_rec_flat:
   STA DCLV_YV
dcl_rec_flat_v:                            ; post-latch entry (DCLV_YV
   BIT FW_MODE                             ; already written by wrappers)
   BMI rf_go                               ; FUSED (2026-08-25): the flat
   RTS                                     ; applies IMMEDIATELY (records
rf_go:                                     ; are gone; sequential decree)
   STX DCLV_SX                             ; X preserved (old contract)
   LDA DCLV_X0
   CMP DCLV_X1
   BCS rf_out                              ; empty
   LDA DCLV_YV
   STA fw_pol
   LDA DCLV_X0
   LDY DCLV_X1
   JSR fused_flat
rf_out:
   LDX DCLV_SX
   RTS

