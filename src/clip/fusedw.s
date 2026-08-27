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
FW_BASE = $9880                         ; bank C tail (2026-08-25 re-cut:
                                        ; code to $97FF, VEXPL_CONT $9800-
                                        ; $987F, cold state here, SINCOS
                                        ; $9900 unmoved). Ex-records pages;
                                        ; the BANKC region boundary keeps
                                        ; code growth a LINK ERROR.
.else
FW_BASE = $1900                         ; low-RAM map 2026-08-26 (ex $2000)
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
   LDA zp_line_xl_l                                                       ;# |          0.1
   CMP zp_line_xr_l                                                       ;# |          0.1
   BNE wl_line                                                            ;# |          0.1
   JMP draw_clipped_line                   ; vertical: plot as today
wl_line:
   STA fwl_xl                                                             ;# |          0.1
   LDA zp_line_yl_l                                                       ;# |          0.1
   STA fwl_yl                                                             ;# |          0.1
   LDA zp_line_xr_l                                                       ;# |          0.1
   STA fwl_xr                                                             ;# |          0.1
   LDA zp_line_yr_l                                                       ;# |          0.1
   STA fwl_yr                                                             ;# |          0.1
::fw_walk_staged:                          ; fast-path entry (fused.s): the
   SEC                                     ; entries stage fwl_* DIRECTLY ;# ||         0.3
   SBC fwl_yl                              ; from VX/sx — A = fwl_yr rides in ;# |||        0.4
   STA fwl_dy                                                             ;# |||        0.4
   LDA fwl_xr                                                             ;# |||        0.4
   SEC                                                                    ;# ||         0.3
   SBC fwl_xl                                                             ;# |||        0.4
   STA fwl_dx                                                             ;# |||        0.4
   LDA fwl_yl                                                             ;# |||        0.4
   LDX fwl_yr                                                             ;# |||        0.4
   CMP fwl_yr                                                             ;# |||        0.4
   BCC wl_min                                                             ;# ||         0.3
   TXA                                                                    ;# ||         0.2
   LDX fwl_yl                                                             ;# |||        0.4
wl_min:
   STA fwl_lo                                                             ;# |||        0.4
   STX fwl_hi                                                             ;# |||        0.4
   LDA #$FF                                                               ;# ||         0.3
   STA fwl_run                             ; no open run                  ;# |||        0.4
; ---- the walk: dcl's two-phase idiom (2026-08-25 grind) ----
; Phase 1 skips spans wholly left of the line with xl riding A through
; an X/Y ping-pong — no SLOT/NEXT staging, no processed-span work.
; Phase 2 never re-tests the left edge: the first survivor has
; xend > xl, and every later span starts at xstart >= that xend, so the
; property is monotone (dcl's proof, dclw_x).
   LDX zp_head                                                            ;# |||        0.4
   BNE wl_skip                                                            ;# |||        0.4
   JMP wl_flush
wl_skip:
   LDA fwl_xl                                                             ;# |||        0.4
wl_sx:
   CMP POOL_XEND,X                                                        ;# |||||||    0.9
   BCC wl_proc                             ; first survivor (X)           ;# ||||       0.5
   LDY POOL_NEXT,X                                                        ;# |||||      0.6
   BNE wl_sy                                                              ;# ||||       0.4
   JMP wl_flush
wl_sy:
   CMP POOL_XEND,Y                                                        ;# |||||      0.6
   BCC wl_found_y                                                         ;# |||        0.3
   LDX POOL_NEXT,Y                                                        ;# |||        0.4
   BNE wl_sx                                                              ;# ||         0.3
   JMP wl_flush
wl_found_y:
   TYA                                                                    ;# |          0.1
   TAX                                                                    ;# |          0.1
wl_proc:
; phase 2: X = span with xend > xl
   LDA POOL_XSTART,X                                                      ;# |||||||||  1.1
   CMP fwl_xr                                                             ;# |||||||    0.8
   BCS wl_flush                            ; xstart >= xr: done (sorted)  ;# |||||      0.6
   STX FW_SLOT                                                            ;# |||||      0.6
   LDY POOL_NEXT,X                         ; Y, not A: XSTART rides A into ;# |||||||    0.8
   STY FW_NEXT                             ; the clip (its ox0 max)       ;# |||||      0.6
   JSR fw_clip_span                                                       ;# |||||||||| 1.3
   LDX FW_NEXT                                                            ;# |||||      0.6
   BNE wl_proc                                                            ;# ||||       0.6
wl_flush:
   LDA fwl_run                                                            ;# |||        0.4
   CMP #$FF                                                               ;# ||         0.3
   BEQ wl_done                                                            ;# ||         0.3
   JSR fw_close_run                                                       ;# |||||      0.6
wl_done:
   RTS                                                                    ;# ||||||     0.8
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
   CMP fwl_xl                                                             ;# |||||      0.6
   BCS cs_ox0                                                             ;# |||||      0.6
   LDA fwl_xl                                                             ;# |          0.1
cs_ox0:
   STA fwl_zx0                                                            ;# |||||      0.6
   LDA POOL_XEND,X                                                        ;# |||||||    0.8
   CMP fwl_xr                                                             ;# |||||      0.6
   BCC cs_ox1                                                             ;# ||||       0.5
   LDA fwl_xr                                                             ;# |||        0.4
cs_ox1:
   STA fwl_zx1                                                            ;# |||||      0.6
; (fwl_leftf / fwl_pend staging moved into fw_cb — the only consumer)
; ---- Tier: inner accept first (dcl_entry_path order) ----
   LDA fwl_lo                                                             ;# |||||      0.6
   CMP POOL_IT,X                                                          ;# |||||||    0.8
   BCC cs_ent_top                          ; ylo < IT: above/ambiguous    ;# ||||       0.5
   LDA POOL_IB,X                                                          ;# ||||       0.6
   CMP fwl_hi                                                             ;# |||        0.4
   BCC cs_ent_bot                          ; yhi > IB: below/ambiguous    ;# ||         0.3
; ---- ACCEPT: visible over the whole overlap ----
   LDA fwl_zx0                                                            ;# |||        0.4
   CMP fwl_xl                                                             ;# |||        0.4
   BEQ cs_acc_yl                                                          ;# |||        0.3
   LDA fwl_dy                                                             ;# |          0.1
   BEQ cs_acc_yl                                                          ;# |          0.1
   JSR fw_line_interp_zx0                  ; entry y (PLOT only)          ;# |          0.1
   JMP cs_acc_have                                                        ;#            0.1
cs_acc_yl:
   LDA fwl_yl                                                             ;# |||        0.3
cs_acc_have:
   STA cp_vy0                                                             ;# |||        0.4
   LDA fwl_zx0                                                            ;# |||        0.4
   STA cp_vx0                                                             ;# |||        0.4
   LDA fwl_zx1                                                            ;# |||        0.4
   STA cp_vx1                                                             ;# |||        0.4
   LDA #$80                                                               ;# ||         0.3
   STA cp_vev                              ; open end                     ;# |||        0.4
   JMP fw_run_visible                                                     ;# |||        0.4
cs_ent_top:
   LDA fwl_hi                                                             ;# ||         0.2
   CMP POOL_OT,X                                                          ;# ||         0.3
   BCC cs_rej_above                        ; yhi < OT: whole overlap above ;# ||         0.2
   JMP fw_cb                                                              ;#            0.0
cs_ent_bot:
   LDA POOL_OB,X                                                          ;#            0.0
   CMP fwl_lo                                                             ;#            0.0
   BCC cs_rej_below                        ; OB < ylo: whole overlap below ;#            0.0
   JMP fw_cb                                                              ;#            0.0
cs_rej_above:                              ; 'above': kills iff BOT side
   LDA #1                                                                 ;# |          0.1
   STA FW_TOUCH                                                           ;# ||         0.3
   LDA fwl_run                             ; guard hoisted 2026-08-27:
   CMP #$FF                                ; 100% of calls found nothing
   BEQ :+                                  ; open (census, 5 poses)
   JSR fw_close_run
:
   BIT FW_SIDE                                                            ;# ||         0.2
   BMI cs_kill                                                            ;# |          0.1
   RTS                                                                    ;# |||        0.4
cs_rej_below:                              ; 'below': kills iff TOP side
   LDA #1                                                                 ;#            0.0
   STA FW_TOUCH                                                           ;#            0.0
   LDA fwl_run                             ; guard hoisted 2026-08-27:
   CMP #$FF                                ; 100% of calls found nothing
   BEQ :+                                  ; open (census, 5 poses)
   JSR fw_close_run
:
   BIT FW_SIDE                                                            ;#            0.0
   BMI cs_neutral                                                         ;#            0.0
cs_kill:
   LDA fwl_zx0                                                            ;#            0.0
   LDY fwl_zx1                                                            ;#            0.0
   JMP fused_kill                                                         ;#            0.0
cs_neutral:
   RTS
.endscope

; (fw_close_if_open DELETED 2026-08-27: guard hoisted to all 6 sites —
;  the callee spent 19 cycles per call discovering nothing was open.)

; line interp at zx0 / at A: stage the LINE into the interp workspace.
; (Clipping still interpolates — the no-interp decree is about SPAN
; CONFIGURATION, which is a pure copy now.)
fw_line_interp_zx0:
   LDA fwl_zx0                                                            ;#            0.1
fw_line_interp_a:
   PHA                                                                    ;#            0.1
   LDA fwl_xl                                                             ;#            0.1
   STA zp_i_x0                                                            ;#            0.1
   LDA fwl_yl                                                             ;#            0.1
   STA zp_i_y0                                                            ;#            0.1
   LDA fwl_yr                                                             ;#            0.1
   STA zp_i_y1                                                            ;#            0.1
   LDA fwl_dx                                                             ;#            0.1
   STA zp_div_den                                                         ;#            0.1
   PLA                                                                    ;# |          0.1
   JMP interp_store                                                       ;#            0.1

; ============================================================================
; fw_cb — the CB trapezoid clip on [zx0, zx1) (dcl_cb_clip transcribed;
; cx in zp_cb_cx1/cx2 for dcl_boundary_ix, cy in zp_cb_cy1/cy2).
; ============================================================================
; --- fw_cb + its private helpers: in MAIN, BANKED ONLY (2026-08-27) —
; JMP-reached, ~1-3 entries/frame; the eviction refills BANKC headroom
; (its ceiling bit again during this grind).  Main RAM is always mapped
; under bank-C paging; the JSR/JMPs back into BANKC stay valid.
.if ::BANKED
SEG_HIGH
.endif
fw_cb:
.scope
   LDA #$80                                                               ;#            0.0
   STA fwl_pend                                                           ;#            0.0
   LDA fwl_zx0                                                            ;#            0.0
   STA fwl_leftf                                                          ;#            0.0
   STA zp_cb_cx1                                                          ;#            0.0
   LDA fwl_zx1                                                            ;#            0.0
   STA zp_cb_cx2                                                          ;#            0.0
; ---- cy1/cy2: line-mode interp workspace staged ONCE (dcl's trick) ----
   LDA fwl_dy                                                             ;#            0.0
   BNE cb_cy_slow                                                         ;#            0.0
   LDA fwl_yl
   STA zp_cb_cy1
   STA zp_cb_cy2
   JMP cb_cy_done
cb_cy_slow:
   LDA fwl_xl                                                             ;#            0.0
   STA zp_i_x0                                                            ;#            0.0
   LDA fwl_yl                                                             ;#            0.0
   STA zp_i_y0                                                            ;#            0.0
   LDA fwl_yr                                                             ;#            0.0
   STA zp_i_y1                                                            ;#            0.0
   LDA fwl_dx                                                             ;#            0.0
   STA zp_div_den                                                         ;#            0.0
   LDA zp_cb_cx1                                                          ;#            0.0
   CMP fwl_xl                                                             ;#            0.0
   BEQ cb_cy1_yl                                                          ;#            0.0
   JSR interp_store                        ; A = cx1 rides in
   JMP cb_cy1_have
cb_cy1_yl:
   LDA fwl_yl                                                             ;#            0.0
cb_cy1_have:
   STA zp_cb_cy1                                                          ;#            0.0
   LDA zp_cb_cx2                                                          ;#            0.0
   CMP fwl_xr                                                             ;#            0.0
   BEQ cb_cy2_yr                                                          ;#            0.0
   JSR interp_store
   JMP cb_cy2_have
cb_cy2_yr:
   LDA fwl_yr                                                             ;#            0.0
cb_cy2_have:
   STA zp_cb_cy2                                                          ;#            0.0
cb_cy_done:
; ---- TOP boundary ----
   LDX FW_SLOT                                                            ;#            0.0
   LDA zp_cb_cy2                                                          ;#            0.0
   CMP POOL_IT,X                                                          ;#            0.0
   BCC cb_top_eval                                                        ;#            0.0
   LDA zp_cb_cy1                                                          ;#            0.0
   CMP POOL_IT,X                                                          ;#            0.0
   BCC cb_top_eval                                                        ;#            0.0
   JMP cb_top_done                         ; both >= IT: skip top         ;#            0.0
cb_top_eval:
   LDA POOL_TL,X                                                          ;#            0.0
   CMP POOL_TR,X                                                          ;#            0.0
   BNE cb_top_interp                                                      ;#            0.0
   STA fw_top1                                                            ;#            0.0
   STA fw_top2                                                            ;#            0.0
   JMP cb_top_evaled                                                      ;#            0.0
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
   LDA zp_cb_cy1                                                          ;#            0.0
   CMP fw_top1                                                            ;#            0.0
   BCS cb_top_p1_ok                                                       ;#            0.0
   LDA zp_cb_cy2                                                          ;#            0.0
   CMP fw_top2                                                            ;#            0.0
   BCS cb_top_clip_p1                                                     ;#            0.0
   JMP cb_whole_above                      ; both above
cb_top_p1_ok:
   LDA zp_cb_cy2                                                          ;#            0.0
   CMP fw_top2                                                            ;#            0.0
   BCS cb_top_done                         ; both inside                  ;#            0.0
; p2-clip (cy1 >= top1, cy2 < top2)
   LDA zp_cb_cy1                                                          ;#            0.0
   SEC                                                                    ;#            0.0
   SBC fw_top1                                                            ;#            0.0
   STA zp_tmp0                             ; d1 >= 0                      ;#            0.0
   LDA zp_cb_cy2                                                          ;#            0.0
   SBC fw_top2                                                            ;#            0.0
   STA zp_tmp1                             ; d2 < 0                       ;#            0.0
   LDA #0                                                                 ;#            0.0
   JSR dcl_boundary_ix                                                    ;#            0.0
   STA zp_cb_cx2                                                          ;#            0.0
   JSR fw_bval_top                         ; A = ix rides in              ;#            0.0
   STA zp_cb_cy2                                                          ;#            0.0
   LDA #0                                                                 ;#            0.0
   STA fwl_pend                            ; right-pend 'above'           ;#            0.0
   JMP cb_top_done                                                        ;#            0.0
cb_top_clip_p1:                            ; cy1 < top1, cy2 >= top2 (C=1)
   LDA zp_cb_cy1                                                          ;#            0.0
   SBC fw_top1                                                            ;#            0.0
   STA zp_tmp0                             ; d1 < 0                       ;#            0.0
   LDA zp_cb_cy2                                                          ;#            0.0
   SEC                                                                    ;#            0.0
   SBC fw_top2                                                            ;#            0.0
   STA zp_tmp1                             ; d2 >= 0                      ;#            0.0
   LDA #1                                                                 ;#            0.0
   JSR dcl_boundary_ix                                                    ;#            0.0
   STA zp_cb_cx1                                                          ;#            0.0
   JSR fw_bval_top                                                        ;#            0.0
   STA zp_cb_cy1                                                          ;#            0.0
; left flat [leftf, cx1) 'above' — kills iff BOT side (site constant)
   LDA fwl_zx0                                                            ;#            0.0
   CMP zp_cb_cx1                                                          ;#            0.0
   BCS cb_top_done                                                        ;#            0.0
   LDA #1                                                                 ;#            0.0
   STA FW_TOUCH                                                           ;#            0.0
   LDA fwl_run                             ; guard hoisted 2026-08-27:
   CMP #$FF                                ; 100% of calls found nothing
   BEQ :+                                  ; open (census, 5 poses)
   JSR fw_close_run
:
   BIT FW_SIDE                                                            ;#            0.0
   BPL cb_tlf_done                         ; top side: neutral            ;#            0.0
   LDA fwl_leftf
   LDY zp_cb_cx1
   JSR fused_kill
cb_tlf_done:
   LDA zp_cb_cx1                                                          ;#            0.0
   STA fwl_leftf                                                          ;#            0.0
cb_top_done:
   LDA zp_cb_cx2                                                          ;#            0.0
   CMP zp_cb_cx1                                                          ;#            0.0
   BCS cb_bot                                                             ;#            0.0
   JMP cb_whole_above                      ; defensive (mirrors dcl)
; ---- BOT boundary (at the top-clipped cx1/cx2) ----
cb_bot:
   LDX FW_SLOT                                                            ;#            0.0
   LDA POOL_IB,X                                                          ;#            0.0
   CMP zp_cb_cy1                                                          ;#            0.0
   BCC cb_bot_eval                                                        ;#            0.0
   CMP zp_cb_cy2                                                          ;#            0.0
   BCC cb_bot_eval                                                        ;#            0.0
   JMP cb_bot_done                         ; both <= IB: skip bot         ;#            0.0
cb_bot_eval:
   LDA POOL_BL,X                                                          ;#            0.0
   CMP POOL_BR,X                                                          ;#            0.0
   BNE cb_bot_interp                                                      ;#            0.0
   STA fw_top1                             ; (slots reused as bot1/bot2)
   STA fw_top2
   JMP cb_bot_evaled
cb_bot_interp:
   LDA POOL_BXLO,X                         ; (mirror of the top inline)   ;#            0.0
   STA zp_i_x0                                                            ;#            0.0
   LDA POOL_BDEN,X                                                        ;#            0.0
   STA zp_div_den                                                         ;#            0.0
   LDA POOL_BL,X                                                          ;#            0.0
   STA zp_i_y0                                                            ;#            0.0
   LDA POOL_BR,X                                                          ;#            0.0
   STA zp_i_y1                                                            ;#            0.0
   LDA zp_cb_cx1                                                          ;#            0.0
   JSR interp_store                                                       ;#            0.0
   STA fw_top1                                                            ;#            0.0
   LDA zp_cb_cx2                                                          ;#            0.0
   JSR interp_store                                                       ;#            0.0
   STA fw_top2                                                            ;#            0.0
cb_bot_evaled:
   LDA fw_top1                                                            ;#            0.0
   CMP zp_cb_cy1                                                          ;#            0.0
   BCS cb_bot_p1_ok                                                       ;#            0.0
   LDA fw_top2
   CMP zp_cb_cy2
   BCS cb_bot_clip_p1
   JMP cb_whole_below                      ; both below
cb_bot_p1_ok:
   LDA fw_top2                                                            ;#            0.0
   CMP zp_cb_cy2                                                          ;#            0.0
   BCS cb_bot_done                         ; both inside                  ;#            0.0
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
   LDA fwl_run                             ; guard hoisted 2026-08-27:
   CMP #$FF                                ; 100% of calls found nothing
   BEQ :+                                  ; open (census, 5 poses)
   JSR fw_close_run
:
   BIT FW_SIDE
   BMI cb_blf_done                         ; bot side: neutral
   LDA fwl_leftf
   LDY zp_cb_cx1
   JSR fused_kill
cb_blf_done:
   LDA zp_cb_cx1
   STA fwl_leftf
cb_bot_done:
   LDA zp_cb_cx2                                                          ;#            0.0
   CMP zp_cb_cx1                                                          ;#            0.0
   BCC cb_whole_below                      ; cx2 < cx1 post-bot -> below  ;#            0.0
; ---- visible piece [cx1, cx2) + optional right-pend flat ----
   LDA zp_cb_cx1                                                          ;#            0.0
   STA cp_vx0                                                             ;#            0.0
   LDA zp_cb_cy1                                                          ;#            0.0
   STA cp_vy0                                                             ;#            0.0
   LDA zp_cb_cx2                                                          ;#            0.0
   STA cp_vx1                                                             ;#            0.0
   LDA #$80                                                               ;#            0.0
   LDY zp_cb_cx2                                                          ;#            0.0
   CPY fwl_zx1                                                            ;#            0.0
   BCS cb_end_open                                                        ;#            0.0
   LDA zp_cb_cy2                           ; crossing value (PLOT end)    ;#            0.0
cb_end_open:
   STA cp_vev                                                             ;#            0.0
   JSR fw_run_visible                                                     ;#            0.1
; right-pend flat [cx2, zx1): pol in fwl_pend (runtime — the two CB
; p2 arms overwrite each other), touch + side-resolved kill
   LDA fwl_pend                                                           ;#            0.0
   CMP #$80                                                               ;#            0.0
   BEQ cb_done                                                            ;#            0.0
   LDY #1                                                                 ;#            0.0
   STY FW_TOUCH                                                           ;#            0.0
   LDA zp_cb_cx2                                                          ;#            0.0
   CMP fwl_zx1                                                            ;#            0.0
   BCS cb_done                             ; empty                        ;#            0.0
; kill iff (top & pend=='below' $FF) or (bot & pend=='above' 0)
   TAY                                     ; Y = cx2 (kill's x0... reload ;#            0.0
   LDA fwl_pend                            ; below; Y freed for the range) ;#            0.0
   BIT FW_SIDE                                                            ;#            0.0
   BMI cb_rp_bot                                                          ;#            0.0
   CMP #$FF                                                               ;#            0.0
   BEQ cb_rp_kill                                                         ;#            0.0
   RTS                                                                    ;#            0.0
cb_rp_bot:
   CMP #0
   BEQ cb_rp_kill
   RTS
cb_rp_kill:
   LDA zp_cb_cx2
   LDY fwl_zx1
   JMP fused_kill
cb_done:
   RTS                                                                    ;#            0.0
cb_whole_above:
; effective: [leftf, zx1) 'above' — kills iff BOT side; discard pend
   LDA #1
   STA FW_TOUCH
   LDA fwl_run                             ; guard hoisted 2026-08-27:
   CMP #$FF                                ; 100% of calls found nothing
   BEQ :+                                  ; open (census, 5 poses)
   JSR fw_close_run
:
   BIT FW_SIDE
   BMI cb_wf_kill
   RTS
cb_whole_below:
; effective: [leftf, zx1) 'below' — kills iff TOP side; discard pend
   LDA #1
   STA FW_TOUCH
   LDA fwl_run                             ; guard hoisted 2026-08-27:
   CMP #$FF                                ; 100% of calls found nothing
   BEQ :+                                  ; open (census, 5 poses)
   JSR fw_close_run
:
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
   LDY fw_top1                                                            ;#            0.0
   CPY fw_top2                                                            ;#            0.0
   BEQ fw_bval_const                                                      ;#            0.0
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
   TYA                                                                    ;#            0.0
   RTS                                                                    ;#            0.0
.if ::BANKED
SEG_BANKC
.endif

; ============================================================================
; fw_run_visible — feed a visible piece (cp_v*) to the run.
; fw_close_run — close it: end y for the PLOT (crossing value, or yr /
; flat-yl / interp — dcl_emit_open's cases), emit via dcl_emit_segment,
; then apply [run, rend) with the FULL-LINE boundary (pure copy).
; ============================================================================
fw_run_visible:
.scope
   LDA cp_vx0                                                             ;# |||        0.4
   CMP cp_vx1                                                             ;# |||        0.4
   BEQ rv_degen                                                           ;# ||         0.3
   LDA fwl_run                                                            ;# |||        0.4
   CMP #$FF                                                               ;# ||         0.3
   BEQ rv_open                                                            ;# |||        0.4
   LDA cp_vx0                                                             ;# |          0.1
   CMP fwl_rend                                                           ;# |          0.1
   BEQ rv_extend                                                          ;# |          0.1
   JSR fw_close_run                        ; noncontiguous: close old
   JMP rv_open
rv_extend:
   LDA cp_vx1                                                             ;# |          0.1
   STA fwl_rend                                                           ;# |          0.1
   LDA cp_vev                                                             ;# |          0.1
   STA fwl_rendv                                                          ;# |          0.1
   RTS                                                                    ;# ||         0.2
rv_open:
   LDA FW_SLOT                                                            ;# ||         0.3
   STA fw_rslot                            ; the apply starts HERE, not at ;# ||         0.3
   LDA cp_vx0                              ; zp_head — the from-head rescan ;# ||         0.3
   STA fwl_run                             ; was the heavy frame's tax    ;# ||         0.3
   LDA cp_vy0                                                             ;# ||         0.3
   STA fwl_ry0                                                            ;# ||         0.3
   LDA cp_vx1                                                             ;# ||         0.3
   STA fwl_rend                                                           ;# ||         0.3
   LDA cp_vev                                                             ;# ||         0.3
   STA fwl_rendv                                                          ;# ||         0.3
   LDA #1                                                                 ;# ||         0.2
   STA FW_TOUCH                                                           ;# |||        0.4
   RTS                                                                    ;# |||||      0.6
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
   LDA fwl_rendv                                                          ;# ||         0.3
   CMP #$80                                                               ;# ||         0.2
   BNE cr_store                                                           ;# ||         0.2
   LDA fwl_rend                                                           ;# ||         0.3
   CMP fwl_xr                                                             ;# ||         0.3
   BEQ cr_yr                                                              ;# ||         0.3
   LDA fwl_dy                                                             ;#            0.0
   BEQ cr_yl                                                              ;#            0.0
   LDA fwl_rend
   JSR fw_line_interp_a
   JMP cr_store
cr_yr:
   LDA fwl_yr                                                             ;# ||         0.3
   JMP cr_store                                                           ;# ||         0.3
cr_yl:
   LDA fwl_yl                                                             ;#            0.0
cr_store:
   STA zp_tmp0                                                            ;# ||         0.3
   LDA fwl_run                                                            ;# ||         0.3
   STA zp_seg_start_x                                                     ;# ||         0.3
   LDA fwl_ry0                                                            ;# ||         0.3
   STA zp_seg_start_y                                                     ;# ||         0.3
   LDA fwl_rend                                                           ;# ||         0.3
   STA zp_ox1                                                             ;# ||         0.3
   JSR dcl_emit_segment                    ; plot (records machinery gone) ;# |||||      0.6
; APPLY [run, rend): full-line boundary, pure copy
   LDA fwl_run                                                            ;# ||         0.3
   STA fw_ax0                                                             ;# ||         0.3
   LDA fwl_rend                                                           ;# ||         0.3
   STA fw_ax1                                                             ;# ||         0.3
   LDA #$FF                                ; clear BEFORE the tail-call
   STA fwl_run                             ; (apply never reads fwl_run)
   JMP fused_apply_run                     ; tail: its RTS is ours
.endscope

SEG_BANKC
; (the apply/flat/split/merge cluster moved MAIN -> BANK C 2026-08-25:
;  every caller — fw_close_run, ms_dispatch, obj_art_done, the s16
;  band-clip wrappers — runs with bank C held, and the fm grind freed
;  the space. Its ~300 main bytes fund the exact banded backface.)

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
   ZERO zp_hg_cache                                                       ;# ||||       0.5
   LDX fw_rslot                            ; run-open slot (see fw_rslot) ;# ||         0.3
ar_walk:
   BNE ar_go                                                              ;# |||||      0.7
   RTS                                                                    ;# |          0.1
ar_go:
   LDA fw_ax0                              ; C = ax0 >= xend -> wholly left ;# |||||      0.6
   CMP POOL_XEND,X                                                        ;# |||||||    0.9
   BCS ar_next                                                            ;# |||        0.4
   LDA POOL_XSTART,X                                                      ;# |||||||    0.9
   CMP fw_ax1                                                             ;# |||||      0.6
   BCC ar_over                                                            ;# ||||       0.6
   RTS                                     ; xstart >= ax1: done (sorted) ;# ||||       0.4
ar_over:
; overlap. Left split needed? (xstart < ax0)
   CMP fw_ax0                                                             ;# |||        0.4
   BCS ar_no_lsplit                                                       ;# |||        0.4
   LDA fw_ax0                                                             ;# |          0.1
   STA fw_split_at                                                        ;# |          0.1
   JSR fw_split_r                          ; X keeps [xstart, ax0)        ;# |          0.1
   LDY POOL_NEXT,X                                                        ;# |          0.1
   BEQ ar_stay                             ; exhaustion: boundary lands on ;#            0.0
   TYA                                     ; the whole span (conservative) ;#            0.0
   TAX                                                                    ;#            0.0
ar_stay:
ar_no_lsplit:
; Right split needed? (xend > ax1)
   LDA fw_ax1                                                             ;# |||        0.4
   CMP POOL_XEND,X                                                        ;# ||||       0.6
   BCS ar_no_rsplit                                                       ;# |||        0.4
   STA fw_split_at                                                        ;# |          0.1
   JSR fw_split_r                          ; X keeps [xstart, ax1)        ;# |          0.2
ar_no_rsplit:
; SIX PURE COPIES — the full line becomes the side's boundary
   BIT FW_SIDE                                                            ;# |||        0.4
   BMI ar_bot                                                             ;# |||        0.4
   LDA fwl_xl                                                             ;#            0.1
   STA POOL_TXLO,X                                                        ;# |          0.1
   LDA fwl_dx                                                             ;#            0.1
   STA POOL_TDEN,X                                                        ;# |          0.1
   LDA fwl_yl                                                             ;#            0.1
   STA POOL_TL,X                                                          ;# |          0.1
   LDA fwl_yr                                                             ;#            0.1
   STA POOL_TR,X                                                          ;# |          0.1
   LDA fwl_lo                                                             ;#            0.1
   STA POOL_OT,X                                                          ;# |          0.1
   LDA fwl_hi                                                             ;#            0.1
   STA POOL_IT,X                                                          ;# |          0.1
   JMP ar_next                                                            ;#            0.1
ar_bot:
   LDA fwl_xl                                                             ;# |||        0.4
   STA POOL_BXLO,X                                                        ;# |||||      0.6
   LDA fwl_dx                                                             ;# |||        0.4
   STA POOL_BDEN,X                                                        ;# |||||      0.6
   LDA fwl_yl                                                             ;# |||        0.4
   STA POOL_BL,X                                                          ;# |||||      0.6
   LDA fwl_yr                                                             ;# |||        0.4
   STA POOL_BR,X                                                          ;# |||||      0.6
   LDA fwl_hi                                                             ;# |||        0.4
   STA POOL_OB,X                                                          ;# |||||      0.6
   LDA fwl_lo                                                             ;# |||        0.4
   STA POOL_IB,X                                                          ;# |||||      0.6
ar_next:
   LDA POOL_NEXT,X                                                        ;# ||||       0.6
   TAX                                                                    ;# ||         0.3
   JMP ar_walk                                                            ;# |||        0.4
.endscope

; --- fw_split_r: split span X at fw_split_at: X keeps [xstart, at),
; a fresh sibling takes [at, xend) with ALL fields copied verbatim,
; linked after X. Exhaustion: no-op (caller handles). X preserved. ---
fw_split_r:
.scope
   LDY zp_free                                                            ;# |          0.2
   BEQ fsr_fail                                                           ;# |          0.1
   LDA POOL_NEXT,Y                                                        ;# ||         0.2
   STA zp_free                                                            ;# |          0.2
   LDA POOL_TXLO,X                                                        ;# ||         0.2
   STA POOL_TXLO,Y                                                        ;# ||         0.3
   LDA POOL_TDEN,X                                                        ;# ||         0.2
   STA POOL_TDEN,Y                                                        ;# ||         0.3
   LDA POOL_BXLO,X                                                        ;# ||         0.2
   STA POOL_BXLO,Y                                                        ;# ||         0.3
   LDA POOL_BDEN,X                                                        ;# ||         0.2
   STA POOL_BDEN,Y                                                        ;# ||         0.3
   LDA POOL_TL,X                                                          ;# ||         0.2
   STA POOL_TL,Y                                                          ;# ||         0.3
   LDA POOL_TR,X                                                          ;# ||         0.2
   STA POOL_TR,Y                                                          ;# ||         0.3
   LDA POOL_BL,X                                                          ;# ||         0.2
   STA POOL_BL,Y                                                          ;# ||         0.3
   LDA POOL_BR,X                                                          ;# ||         0.2
   STA POOL_BR,Y                                                          ;# ||         0.3
   LDA POOL_OT,X                                                          ;# ||         0.2
   STA POOL_OT,Y                                                          ;# ||         0.3
   LDA POOL_IT,X                                                          ;# ||         0.2
   STA POOL_IT,Y                                                          ;# ||         0.3
   LDA POOL_OB,X                                                          ;# ||         0.2
   STA POOL_OB,Y                                                          ;# ||         0.3
   LDA POOL_IB,X                                                          ;# ||         0.2
   STA POOL_IB,Y                                                          ;# ||         0.3
   LDA POOL_XEND,X                                                        ;# ||         0.2
   STA POOL_XEND,Y                                                        ;# ||         0.3
   LDA fw_split_at                                                        ;# ||         0.2
   STA POOL_XSTART,Y                                                      ;# ||         0.3
   STA POOL_XEND,X                                                        ;# ||         0.3
   LDA POOL_NEXT,X                                                        ;# ||         0.2
   STA POOL_NEXT,Y                                                        ;# ||         0.3
   TYA                                                                    ;# |          0.1
   STA POOL_NEXT,X                                                        ;# ||         0.3
fsr_fail:
   RTS                                                                    ;# ||         0.3
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
   STA fw_fx0                                                             ;#            0.0
   STY fw_fx1                                                             ;#            0.0
   LDA zp_i_l                                                             ;#            0.0
   STA FW_ISAVE0                                                          ;#            0.0
   LDA zp_i_h                                                             ;#            0.0
   STA FW_ISAVE1                                                          ;#            0.0
   LDA fw_fx0                                                             ;#            0.0
   STA zp_i_l                                                             ;#            0.0
   LDA fw_fx1                                                             ;#            0.0
   STA zp_i_h                                                             ;#            0.0
   JSR span_mark_solid                                                    ;#            0.0
   LDA FW_ISAVE0                                                          ;#            0.0
   STA zp_i_l                                                             ;#            0.0
   LDA FW_ISAVE1                                                          ;#            0.0
   STA zp_i_h                                                             ;#            0.0
   RTS                                                                    ;#            0.0
.endscope

; fused_flat — runtime polarity (fw_pol), [A, Y): touch + side-resolved
; kill. Only dcl_rec_flat (band flats) comes here now.
fused_flat:
.scope
   STA ff_x0                                                              ;#            0.0
   STY ff_y1                                                              ;#            0.0
   LDA #1                                                                 ;#            0.0
   STA FW_TOUCH                                                           ;#            0.0
   BIT FW_SIDE                                                            ;#            0.0
   BMI ff_bot                                                             ;#            0.0
   LDA fw_pol                              ; top side: $FF ('below') kills ;#            0.0
   CMP #$FF                                                               ;#            0.0
   BEQ ff_kill                                                            ;#            0.0
   RTS                                                                    ;#            0.0
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
   LDX zp_head                                                            ;# ||         0.3
   BNE fm_go                                                              ;# ||         0.3
   RTS                                                                    ;#            0.0
fm_go:
; seek: first span with xend > ilo. GRIND (2026-08-25): ilo rides A the
; whole loop (it was reloaded per step) and the ping-pong carries the
; PREDECESSOR in the idle register — the per-step STX fm_prev died with
; the entry ZERO. Same shape as fw_walk_line's wl_sx skip.
   LDA zp_i_l                                                             ;# ||         0.3
   CMP POOL_XEND,X                                                        ;# |||        0.4
   BCC fm_found0                           ; found at the head: no P      ;# ||         0.2
fm_sx:
   LDY POOL_NEXT,X                                                        ;# ||||       0.5
   BEQ fm_rts                                                             ;# ||         0.2
   CMP POOL_XEND,Y                                                        ;# ||||       0.5
   BCC fm_pair                             ; found: P = X, Q = Y — already ;# ||         0.3
                                        ; the pair contract, no shuffle
   LDX POOL_NEXT,Y                                                        ;# ||         0.3
   BEQ fm_rts                                                             ;# |          0.2
   CMP POOL_XEND,X                                                        ;# ||         0.3
   BCS fm_sx                                                              ;# |          0.2
; found with the roles swapped (P = Y, Q = X): exchange via the stash
   STX fm_prev                                                            ;# |          0.1
   TYA                                                                    ;# |          0.1
   TAX                                                                    ;# |          0.1
   LDY fm_prev                                                            ;# |          0.1
   JMP fm_pair                                                            ;# |          0.1
fm_rts:
   RTS                                                                    ;#            0.0
fm_found0:
   LDA POOL_NEXT,X                         ; no predecessor: the window is ;#            0.1
   TAY                                     ; (head, head.next), entering at ;#            0.0
   BNE fm_chk                              ; the range check              ;#            0.0
   RTS                                                                    ;#            0.0
fm_pair:
; P = X, Q = Y: abut + 8 line fields. ORDER (2026-08-25 grind): the B
; chain runs FIRST — the heat showed pairs surviving the whole T chain
; and dying at BXLO (a seg's spans share the top line's anchor, so the
; T fields match trivially); most-discriminating-first saves four
; wasted compares on the failing majority.
   LDA POOL_XEND,X                                                        ;# ||||||     0.7
   CMP POOL_XSTART,Y                                                      ;# ||||||     0.7
   BNE fm_stepq                                                           ;# |||        0.4
   LDA POOL_BXLO,X                                                        ;# |||||      0.7
   CMP POOL_BXLO,Y                                                        ;# |||||      0.7
   BNE fm_stepq                                                           ;# ||||       0.5
   LDA POOL_TXLO,X                                                        ;# |          0.2
   CMP POOL_TXLO,Y                                                        ;# |          0.2
   BNE fm_stepq                                                           ;# |          0.1
   LDA POOL_TDEN,X                                                        ;# |          0.1
   CMP POOL_TDEN,Y                                                        ;# |          0.1
   BNE fm_stepq                                                           ;# |          0.1
   LDA POOL_TL,X                                                          ;# |          0.1
   CMP POOL_TL,Y                                                          ;# |          0.1
   BNE fm_stepq                                                           ;# |          0.1
   LDA POOL_TR,X                                                          ;# |          0.1
   CMP POOL_TR,Y                                                          ;# |          0.1
   BNE fm_stepq                                                           ;# |          0.1
   LDA POOL_BDEN,X                                                        ;# |          0.1
   CMP POOL_BDEN,Y                                                        ;# |          0.1
   BNE fm_stepq                                                           ;# |          0.1
   LDA POOL_BL,X                                                          ;# |          0.1
   CMP POOL_BL,Y                                                          ;# |          0.1
   BNE fm_stepq                                                           ;#            0.1
   LDA POOL_BR,X                                                          ;# |          0.1
   CMP POOL_BR,Y                                                          ;# |          0.1
   BNE fm_stepq                                                           ;#            0.1
; merge Q into P; keep P as the candidate against Q's successor
   LDA POOL_XEND,Y                                                        ;# |          0.1
   STA POOL_XEND,X                                                        ;# |          0.2
   LDA POOL_NEXT,Y                                                        ;# |          0.1
   STA POOL_NEXT,X                                                        ;# |          0.2
   PHA                                                                    ;# |          0.1
   LDA zp_free                                                            ;# |          0.1
   STA POOL_NEXT,Y                                                        ;# |          0.2
   STY zp_free                                                            ;# |          0.1
   ZERO zp_hg_cache                                                       ;# |          0.2
   PLA                                                                    ;# |          0.1
   TAY                                                                    ;#            0.1
   BNE fm_chk                                                             ;# |          0.1
   RTS                                                                    ;#            0.0
fm_stepq:
   TYA                                                                    ;# ||         0.3
   TAX                                                                    ;# ||         0.3
   LDA POOL_NEXT,Y                                                        ;# |||||      0.6
   TAY                                                                    ;# ||         0.3
   BNE fm_chk                                                             ;# |||        0.4
   RTS                                                                    ;# ||         0.2
fm_chk:
; keep going while Q.xstart <= ihi (the seam pair past the range is
; the last one tested)
   LDA zp_i_h                                                             ;# |||        0.4
   CMP POOL_XSTART,Y                                                      ;# |||||      0.6
   BCS fm_pair                                                            ;# |||        0.4
   RTS                                                                    ;# ||         0.3
.endscope

SEG_BANKC

; ============================================================================
; dcl_rec_flat — the flat-verdict handler (moved from dcl.s at the
; cutover: the s16 band-clip wrappers call it; in fused mode it applies
; the flat immediately, else it is a no-op).
; ============================================================================
dcl_rec_flat:
   STA DCLV_YV                                                            ;#            0.0
dcl_rec_flat_v:                            ; post-latch entry (DCLV_YV
   BIT FW_MODE                             ; already written by wrappers) ;#            0.0
   BMI rf_go                               ; FUSED (2026-08-25): the flat ;#            0.0
   RTS                                     ; applies IMMEDIATELY (records ;#            0.0
rf_go:                                     ; are gone; sequential decree)
   STX DCLV_SX                             ; X preserved (old contract)   ;#            0.0
   LDA DCLV_X0                                                            ;#            0.0
   CMP DCLV_X1                                                            ;#            0.0
   BCS rf_out                              ; empty                        ;#            0.0
   LDA DCLV_YV                                                            ;#            0.0
   STA fw_pol                                                             ;#            0.0
   LDA DCLV_X0                                                            ;#            0.0
   LDY DCLV_X1                                                            ;#            0.0
   JSR fused_flat                                                         ;#            0.0
rf_out:
   LDX DCLV_SX                                                            ;#            0.0
   RTS                                                                    ;#            0.0

