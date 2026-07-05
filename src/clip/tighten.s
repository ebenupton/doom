span_tighten:
; Invalidate the has_gap coherence cache (pool slots are about to be
; rebuilt/freed — see span_mark_solid note).
ZERO zp_hg_cache
LDA zp_ihi
CMP zp_ilo
BCS tg_go
; ihi >= ilo: valid range    ; |
RTS
tg_go:
; Save old head, then start building new list
LDA zp_head
STA zp_old_cur
; |
LDA #0
STA zp_new_tail
STA zp_head
; |
; NOTE: do NOT reset LINE_OUT_COUNT here — draw_clipped_line may
; have already written lines to the buffer before tighten was called.
; The buffer is append-only; the rasteriser is called immediately
; for each line, so the buffer is just a log for verification.
LDA #$FF
STA zp_cache_ox1
; invalidate seg value cache            ; |
STA zp_tg_cont                          ; invalidate portal continuation        ; |
LDA #0
STA zp_pre_dom_flags
; pre-dom flags: clear at tighten entry
; Initialize running seg bounds (clamped to [0,159]).
; seg_top_max = max(clamp(yt1), clamp(yt2))
; seg_bot_min = min(clamp(yb1), clamp(yb2))
; bb_flags: $40 = all on-screen (new-dom + narrowing valid), $00 = disabled
; Fast path: all hi bytes zero → no clamping needed
LDA zp_yt1h
ORA zp_yt2h
ORA zp_yb1h
ORA zp_yb2h
; |
BNE tg_go_slow_bounds                   ; |
; All on-screen: simple max/min of lo bytes
LDA zp_yt1
CMP zp_yt2
BCS tg_go_tmax1
LDA zp_yt2
; |
tg_go_tmax1:
STA zp_bb_yt_max
; |
LDA zp_yb1
CMP zp_yb2
BCC tg_go_bmin1
LDA zp_yb2
; |
tg_go_bmin1:
STA zp_bb_yb_min
; |
LDA #$40
STA zp_bb_flags
; new-dom + narrowing valid             ; |
JMP tg_go_bb_done                       ; |
tg_go_slow_bounds:
; At least one hi byte nonzero.
; Sub-path: both yt negative → seg_top_max = 0, compute bot if on-screen.
LDA zp_yt1h
AND zp_yt2h
BPL tg_go_sentinel
; |
; Both yt hi negative → seg_top_max = 0
ZERO zp_bb_yt_max                       ; |
; Check if bot values on-screen (both hi == 0)
LDA zp_yb1h
ORA zp_yb2h
BNE tg_go_sentinel_bot
; |
; Bot on-screen: compute min(yb1, yb2)
LDA zp_yb1
CMP zp_yb2
BCC tg_go_bmin2
LDA zp_yb2
; |
tg_go_bmin2:
STA zp_bb_yb_min
; |
LDA #0
STA zp_bb_flags
; new-dom disabled, but bounds valid    ; |
JMP tg_go_bb_done                       ; |
tg_go_sentinel_bot:
; Bot off-screen: use 0 sentinel (old-dom bot always fails)
LDA #0
STA zp_bb_yb_min
STA zp_bb_flags
; |
JMP tg_go_bb_done                       ; |
tg_go_sentinel:
; Mixed hi bytes: use sentinels (old-dom always fails)
LDA #$FF
STA zp_bb_yt_max
; |
LDA #0
STA zp_bb_yb_min
STA zp_bb_flags
; |
tg_go_bb_done:

tg_walk:
LDX zp_old_cur                          ; |
BNE tg_process                          ; |
RTS                                     ; done walking                       ; |
tg_process:
; Store next span offset directly in old_cur (saves reload later).
; zp_old_cur is not modified by any subroutine during tighten processing.
LDA POOL_NEXT,X
STA zp_old_cur
; ||

; Check overlap of seg [ilo,ihi] against this span's ACTIVE range.
; Pixel-center model: endpoint-only contact is NOT overlap.
; Pre-seg if xend <= ilo (reversed CMP: ilo >= xend → pre-seg)
LDA zp_ilo
CMP POOL_XEND,X
BCC tg_chk2
; ilo < xend → might overlap
; Pre-seg: fast link (skip merge check — pre-seg spans never merge)
tg_pre_link:
LDA #0
STA POOL_NEXT,X
; ||
LDY zp_new_tail
BEQ tg_pre_first
; |
TXA
STA POOL_NEXT,Y
; ||
STX zp_new_tail
JMP tg_walk
; |
tg_pre_first:
STX zp_head
STX zp_new_tail
JMP tg_walk
; |
tg_chk2:
; Post-seg if xstart >= ihi (reversed CMP: xstart >= ihi → post-seg)
LDA POOL_XSTART,X
CMP zp_ihi
BCC tg_overlaps
; |||
; Post-seg: first span goes through tg_append_x (merge check),
; then bulk-link the remaining chain directly.
; old_cur already holds POOL_NEXT,X (set at tg_process), no re-read needed.
JSR tg_append_x                         ; first post-seg (with merge)
LDX zp_old_cur
BEQ tg_post_done
; any more spans?
LDY zp_new_tail
TXA
STA POOL_NEXT,Y
; bulk-link rest
tg_post_done:
RTS

tg_overlaps:
; ox0 = max(xstart, ilo).  A already holds POOL_XSTART,X from tg_chk2's
; CMP (which doesn't modify A). Skip the re-read.
CMP zp_ilo
BCS tg_ox0_set
; |
LDA zp_ilo                              ; |
tg_ox0_set:
STA zp_ox0
; |
; ox1 = min(xend, ihi).  BCC alone suffices: when xend == ihi, the
; fall-through loads ihi which equals xend — result is the same.
LDA POOL_XEND,X
CMP zp_ihi
BCC tg_ox1_set
; |
LDA zp_ihi                              ; |
tg_ox1_set:
STA zp_ox1
; |

; --- Unified tiered dominance check ---
; Uses running narrowed seg bounds (seg_top_max / seg_bot_min) that handle
; all cases (neg-yt, all-on-screen, mixed) without flag dispatch.

; Tier 1: old-dom BB check.
; OT >= seg_top_max (equiv. min(tl,tr) >= seg_top_max)
; seg_bot_min >= OB (equiv. seg_bot_min >= max(bl,br))
LDA POOL_OT,X
CMP zp_bb_yt_max
BCC tg_not_old_bb
; |
; Top passed. Check bot: seg_bot_min >= OB.
LDA zp_bb_yb_min                        ; |
CMP POOL_OB,X
BCC tg_not_old_bb
; |
; Old dominates — skip all interpolation.
; Inline fast link (skip merge check: old-dom spans rarely merge,
; and the merge check costs ~40 cycles per span).
LDA #$FF
STA zp_tg_cont
; break continuation
LDA #0
STA POOL_NEXT,X
; |
LDY zp_new_tail
BEQ tg_od_first
; |
TXA
STA POOL_NEXT,Y
; |
STX zp_new_tail
JMP tg_walk
; |
tg_od_first:
STX zp_head
STX zp_new_tail
JMP tg_walk
; |

tg_not_old_bb:
; --- Portal continuation: cheap new-dom using running bounds ---
; If previous span was non-old-dom AND contiguous, the seg boundary
; is likely still inside the aperture. Check using running bounds
; (cheaper than the full new-dom BB which recomputes min/max).
; New-dom: bb_yt_max > max(tl,tr) AND min(bl,br) > bb_yb_min (strict)
LDA zp_tg_cont
CMP #$FF
BEQ tg_no_cont
CMP POOL_XSTART,X
BNE tg_no_cont
; not contiguous
LDA zp_bb_flags
AND #$40
BEQ tg_no_cont
; need on-screen bounds
; Top: IT < bb_yt_max
LDA POOL_IT,X
CMP zp_bb_yt_max
BCS tg_no_cont
; IT >= seg_top → fail
; Bot: IB > bb_yb_min (strict)
LDA POOL_IB,X
CMP zp_bb_yb_min
BCC tg_no_cont
; IB < seg_bot → fail
BEQ tg_no_cont                          ; equal → old-dom at boundary
; Portal continuation: new dominates. Skip old interp.
JMP tg_newdom_fast
tg_no_cont:

; Tier 2: new-dom BB check (full version with overlap guard).
; Guard: all seg hi bytes zero (bb_flags bit 6 = $40).
LDA zp_bb_flags
AND #$40
BEQ tg_bb_skip
; |
; Guard: overlap covers entire span (xstart >= ilo AND xend <= ihi).
LDA zp_ilo
CMP POOL_XSTART,X
BEQ tg_nd_lo_ok
BCS tg_bb_skip
; |
tg_nd_lo_ok:
LDA POOL_XEND,X
CMP zp_ihi
BEQ tg_nd_hi_ok
BCS tg_bb_skip
; |
tg_nd_hi_ok:
; Check: min(yt1,yt2) > IT (strict: new top inside aperture)
LDA zp_yt1
CMP zp_yt2
BCC tg_nd_tmin
LDA zp_yt2
; |
tg_nd_tmin:
CMP POOL_IT,X
BCC tg_bb_skip
BEQ tg_bb_skip
; |
; Check: IB > max(yb1,yb2) (strict: new bot inside aperture)
LDA zp_yb1
CMP zp_yb2
BCS tg_nd_bmax
LDA zp_yb2
; |
tg_nd_bmax:
STA zp_tmp0                             ; |
LDA POOL_IB,X
CMP zp_tmp0
BCC tg_bb_skip
BEQ tg_bb_skip
; |
; Tier 2 success: new dominates. JMP to newdom_fast (moved after bb_skip
; to keep tg_bb_skip in the same page as the tier 2 branches).
JMP tg_newdom_fast
tg_bb_skip:

; --- Full interpolation pipeline ---
STX zp_save1                            ; save span offset early (interp calls clobber X)  ; |
; ---------- OLD span: fast path when (ox0,ox1) == (xlo,xhi) ----------
; If the overlap endpoints exactly match the span's LINE anchors, the
; stored tl/bl/tr/br are already the y values at those endpoints.
LDA zp_ox0
CMP POOL_XLO,X
BNE old_not_anchor
; |
LDA zp_ox1
SEC
SBC zp_ox0
CMP POOL_DEN,X
BNE old_not_anchor
; |
LDA POOL_TL,X
STA zp_ot_l
; |
LDA POOL_TR,X
STA zp_ot_r
; |
LDA POOL_BL,X
STA zp_ob_l
; |
LDA POOL_BR,X
STA zp_ob_r
; |
JMP old_done                            ; |
old_not_anchor:
; --- Constant-line fast path: tl==tr AND bl==br ---
; Saves 4 interp_store calls when the OLD span has no slope.
LDA POOL_TL,X
CMP POOL_TR,X
BNE old_slow
; |
STA zp_ot_l
STA zp_ot_r
; |
LDA POOL_BL,X
CMP POOL_BR,X
BNE old_slow_reload
; |
STA zp_ob_l
STA zp_ob_r
; |
JMP old_done                            ; |
old_slow_reload:
; BL!=BR: need full interp. Re-read TL for zp_i_y0 (rare path).
LDA POOL_TL,X
old_slow:
; A holds TL on entry (from constant-line check or old_slow_reload).
; Hoisted den setup: den from precomputed POOL_DEN, shared by all 4 calls.
; (The anchor fast path above guards 1-pixel spans, so den > 0.)
STA zp_i_y0                             ; |
LDA POOL_XLO,X
STA zp_i_x0
; |
LDA POOL_DEN,X
STA zp_div_den
; |
; Top: y0 = tl (already in zp_i_y0), y1 = tr
LDA POOL_TR,X
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_ot_l
; |
LDA zp_ox1
JSR interp_store
STA zp_ot_r
; |
; Bot: y0 = bl, y1 = br. Reload X (udiv16_8 in interp_store clobbers X).
LDX zp_save1                            ; |
LDA POOL_BL,X
STA zp_i_y0
LDA POOL_BR,X
STA zp_i_y1
; ||
LDA zp_ox0
JSR interp_store
STA zp_ob_l
; |
LDA zp_ox1
JSR interp_store
STA zp_ob_r
; |
JMP old_done
tg_newdom_fast:
; New dominates everywhere. Set dummy old values so the no-crossover
; path produces the new seg's boundary values in the result span.
; Use Y_BIAS/VIS_YMAX as sentinels so results stay in visible range
; (avoids SBC #Y_BIAS underflow in edge emission rasteriser writes).
LDA #Y_BIAS
STA zp_ot_l
STA zp_ot_r
; |
LDA #VIS_YMAX
STA zp_ob_l
STA zp_ob_r
; |
STX zp_save1                            ; |
LDA #0
STA zp_pre_dom_flags
; clear so tg_pod_skip uses normal path
JMP tg_pod_skip                         ; skip post-old-interp check (dummy values always fail it)
old_done:
; --- Post-old-interp dominance check (extended for one-sided dom) ---
; Uses interpolated ot_l/r and ob_l/r at (ox0, ox1) — more precise than
; tier-1 BB. Three-way fork:
;   both top and bot dominate → full old-dom shortcut (link span unchanged)
;   only top dominates       → set zp_nt_l/r = 0 sentinels, skip top NEW interp
;   only bot dominates       → set zp_nb_l/r = $FF sentinels, skip bot NEW interp
;   neither dominates        → fall through to tg_pod_skip (full interp)
ZERO zp_pre_dom_flags
LDA zp_ot_l
CMP zp_bb_yt_max
BCC tg_top_no_dom
LDA zp_ot_r
CMP zp_bb_yt_max
BCC tg_top_no_dom
; Top dominates. Check bot.
LDA zp_bb_yb_min
CMP zp_ob_l
BCC tg_top_only_dom
CMP zp_ob_r
BCC tg_top_only_dom
; Both dominate — full old-dom shortcut (existing path).
LDA #$FF
STA zp_tg_cont
LDX zp_save1                            ; |
LDA #0
STA POOL_NEXT,X
; |
LDY zp_new_tail
BEQ tg_pod_first
; |
TXA
STA POOL_NEXT,Y
; |
STX zp_new_tail
JMP tg_walk
; |
tg_pod_first:
STX zp_head
STX zp_new_tail
JMP tg_walk
; |
tg_top_only_dom:
; Top dominates, bot doesn't. Set top sentinels: nt_l/r=0 + hi=0 →
; max(ot,0)=ot, no top crossover (signs uniform), c_tl=clamp(0)=Y_BIAS<=ot_l.
LDA #0
STA zp_nt_l
STA zp_nt_r
STA zp_nt_lh
STA zp_nt_rh
LDA #$01
STA zp_pre_dom_flags
JMP tg_pod_skip
tg_top_no_dom:
; Top doesn't dominate. Check bot dominance alone.
LDA zp_bb_yb_min
CMP zp_ob_l
BCC tg_pod_skip
; |
CMP zp_ob_r
BCC tg_pod_skip
; |
; Bot only dom. Set bot sentinels: nb_l/r=$FF + hi=0 →
; min(ob,$FF)=ob, no bot crossover, c_bl=clamp($FF)=VIS_YMAX>=ob_l.
LDA #$FF
STA zp_nb_l
STA zp_nb_r
LDA #0
STA zp_nb_lh
STA zp_nb_rh
LDA #$02
STA zp_pre_dom_flags
; fall through to tg_pod_skip
tg_pod_skip:
; If pre-dom fired, bypass cache + anchor + constant fast paths (which
; would overwrite our sentinels) and go directly to the gated slow path.
; Branch out of range — trampoline through JMP.
LDA zp_pre_dom_flags
BEQ tg_pod_skip_normal
JMP new_slow_gated
tg_pod_skip_normal:
; ---------- NEW seg: cache check for left-endpoint reuse -----------
LDA zp_ox0
CMP zp_cache_ox1
BNE new_no_cache
; Cache hit: reuse left-endpoint seg values from previous span
LDA zp_cache_nt
STA zp_nt_l
LDA zp_cache_nb
STA zp_nb_l
LDA #0
STA zp_nt_lh
STA zp_nb_lh
; | hi bytes = 0
JMP new_right_only
new_no_cache:
; ---------- NEW seg: fast path when (ox0,ox1) == (sx1,sx2) -----------
LDA zp_ox0
CMP zp_sx1
BNE new_not_anchor
; |
LDA zp_ox1
CMP zp_sx2
BNE new_not_anchor
; |
; Copy seg's u8 anchor values verbatim
LDA zp_yt1
STA zp_nt_l
; |
LDA zp_yt2
STA zp_nt_r
; |
LDA zp_yb1
STA zp_nb_l
; |
LDA zp_yb2
STA zp_nb_r
; |
LDA #0
STA zp_nt_lh
STA zp_nt_rh
STA zp_nb_lh
STA zp_nb_rh
; | hi bytes = 0
JMP new_done                            ; |
new_not_anchor:
; --- Constant-line NEW seg fast path: yt1==yt2 AND yb1==yb2 (u8) ---
LDA zp_yt1
CMP zp_yt2
BNE new_slow
; |
LDA zp_yb1
CMP zp_yb2
BNE new_slow
; |
; Constant line: both endpoints identical.
LDA zp_yt1
STA zp_nt_l
STA zp_nt_r
; |
LDA zp_yb1
STA zp_nb_l
STA zp_nb_r
; |
LDA #0
STA zp_nt_lh
STA zp_nt_rh
STA zp_nb_lh
STA zp_nb_rh
; | hi bytes = 0
JMP new_done                            ; |
new_slow:
; Hoisted den setup: den = sx2 - sx1. Guaranteed > 0 by remap.
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
; |
LDA zp_sx1
STA zp_i_x0
; |
; Top: y0 = yt1 (u8 with Y_BIAS), y1 = yt2
LDA zp_yt1
STA zp_i_y0
; |
LDA zp_yt2
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_nt_l
; ||
LDA zp_ox1
JSR interp_store
STA zp_nt_r
; ||
; Bot: y0 = yb1 (u8), y1 = yb2
LDA zp_yb1
STA zp_i_y0
; |
LDA zp_yb2
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_nb_l
; ||
LDA zp_ox1
JSR interp_store
STA zp_nb_r
; ||
LDA #0
STA zp_nt_lh
STA zp_nt_rh
STA zp_nb_lh
STA zp_nb_rh
; | hi bytes = 0
JMP new_done                            ; |
new_slow_gated:
; Pre-dom path: top OR bot interp gated on zp_pre_dom_flags. The
; dominated side has its nt_l/r (top) or nb_l/r (bot) preset to
; sentinels (0 or $FF) by the post-old-interp dom check, plus its
; hi bytes set to 0. Compute only the non-dominated side.
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
; |
LDA zp_sx1
STA zp_i_x0
; |
; Top: skip if zp_pre_dom_flags & $01 (top dominated)
LDA zp_pre_dom_flags
AND #$01
BNE nsg_skip_top
LDA zp_yt1
STA zp_i_y0
; |
LDA zp_yt2
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_nt_l
; |
LDA zp_ox1
JSR interp_store
STA zp_nt_r
; |
LDA #0
STA zp_nt_lh
STA zp_nt_rh
; |
nsg_skip_top:
; Bot: skip if zp_pre_dom_flags & $02 (bot dominated)
LDA zp_pre_dom_flags
AND #$02
BNE nsg_skip_bot
LDA zp_yb1
STA zp_i_y0
; |
LDA zp_yb2
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_nb_l
; |
LDA zp_ox1
JSR interp_store
STA zp_nb_r
; |
LDA #0
STA zp_nb_lh
STA zp_nb_rh
; |
nsg_skip_bot:
JMP new_done                            ; |
new_right_only:
; Cache hit: left-endpoint seg values already set. Compute right only.
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
; |
LDA zp_sx1
STA zp_i_x0
; |
LDA zp_yt1
STA zp_i_y0
; |
LDA zp_yt2
STA zp_i_y1
; |
LDA zp_ox1
JSR interp_store
STA zp_nt_r
; ||
LDA zp_yb1
STA zp_i_y0
; |
LDA zp_yb2
STA zp_i_y1
; |
LDA zp_ox1
JSR interp_store
STA zp_nb_r
; ||
LDA #0
STA zp_nt_rh
STA zp_nb_rh
; | hi bytes = 0
new_done:
; Cache right-endpoint seg values for reuse by next contiguous span.
; If pre-dom fired (one or both sides hold sentinel values that would
; corrupt the next span's left endpoint reuse), invalidate cache_ox1
; AND set cache_nt/nb to off-screen sentinel ($FF) so the running
; seg bound narrowing code below skips this span (its CMP #(VIS_YMAX+1)
; check rejects $FF as off-screen).
LDA zp_pre_dom_flags
BNE new_done_invalidate_cache
LDA zp_nt_r
STA zp_cache_nt
LDA zp_nb_r
STA zp_cache_nb
LDA zp_ox1
STA zp_cache_ox1
JMP new_done_cache_done
new_done_invalidate_cache:
LDA #$FF
STA zp_cache_ox1
STA zp_cache_nt
STA zp_cache_nb
new_done_cache_done:
; Set portal continuation: record span's xend for contiguity check
LDX zp_save1
LDA POOL_XEND,X
STA zp_tg_cont
; --- Narrow running seg bounds using cached right-edge seg values ---
; Only narrow when all-on-screen (bb_flags=$40); cached must be on-screen.
LDA zp_bb_flags
BEQ tg_nd_skip
; |
; Narrow top: seg_top_max = max(cached_nt, yt2)
LDA zp_cache_nt
CMP #(VIS_YMAX + 1)
BCS tg_nd_top_skip
; |
CMP zp_yt2
BCS tg_nd_top_ok
LDA zp_yt2
; |
tg_nd_top_ok:
STA zp_bb_yt_max
; |
tg_nd_top_skip:
; Narrow bot: seg_bot_min = min(cached_nb, yb2)
LDA zp_cache_nb
CMP #(VIS_YMAX + 1)
BCS tg_nd_skip
; |
CMP zp_yb2
BCC tg_nd_bot_ok
LDA zp_yb2
; |
tg_nd_bot_ok:
STA zp_bb_yb_min
; |
tg_nd_skip:

; --- Crossover detection BEFORE clamping (needs unclamped nt/nb values) ---
; Top crossover: fast path when both hi bytes are 0 (common case).
LDA zp_nt_lh
ORA zp_nt_rh
BNE tg_cc_t_slow
; |
; Both hi bytes 0: branch-based sign comparison (saves ROL/EOR chain).
; If both (ot >= nt) or both (ot < nt), no crossover.
LDA zp_ot_l
CMP zp_nt_l
BCS tg_cc_t_lpos
; |
; ot_l < nt_l (carry clear)
LDA zp_ot_r
CMP zp_nt_r
BCS tg_cc_t_check_dt
; signs differ → cx
JMP tg_cc_no_top                        ; both < → no cx
tg_cc_t_lpos:
; ot_l >= nt_l (carry set)
LDA zp_ot_r
CMP zp_nt_r
BCC tg_cc_t_check_dt
; signs differ → cx
JMP tg_cc_no_top                        ; both >= → no cx
tg_cc_t_slow:
; If both nt hi bytes are negative, new top < 0 everywhere.
; Since old top >= 0, dt = ot - nt > 0 always → no top crossover.
LDA zp_nt_lh
AND zp_nt_rh
BPL tg_cc_t_slowentry
JMP tg_cc_no_top
tg_cc_t_slowentry:
; Slow path: per-byte sign detection (handles hi < 0 and hi > 0)
LDA zp_nt_lh
BMI tg_cc_t0p
BNE tg_cc_t0n
; |
LDA zp_ot_l
CMP zp_nt_l
; |
LDA #0
ROL A
BCC tg_cc_t0d
; |
tg_cc_t0p:
LDA #1
.byte $2C
; BIT abs: skip LDA #0
tg_cc_t0n:
LDA #0
; overflow new → negative sign
tg_cc_t0d:
STA zp_tmp1
; |
LDA zp_nt_rh
BMI tg_cc_t1p
BNE tg_cc_t1n
; |
LDA zp_ot_r
CMP zp_nt_r
; |
LDA #0
ROL A
BCC tg_cc_t1d
; |
tg_cc_t1p:
LDA #1
.byte $2C
; BIT abs: skip LDA #0
tg_cc_t1n:
LDA #0
tg_cc_t1d:
EOR zp_tmp1
; |
BEQ tg_cc_no_top                        ; |
tg_cc_t_check_dt:
; Check dt != 0 at each endpoint (avoid calling compute_crossover for
; degenerate touch-at-edge cases). The previous `ORA hi,lo : CMP ot`
; shortcut was buggy — it gave false positives when `hi | lo` ≡ ot
; in u8 (e.g. hi=1, lo=0x9E, OR=0x9F=159). Correct form: if hi ≠ 0
; the s16 value can't equal a u8 ot; else compare low bytes.
LDA zp_nt_lh
BNE tg_cc_t_ne_l
LDA zp_nt_l
CMP zp_ot_l
BEQ tg_cc_no_top
tg_cc_t_ne_l:
LDA zp_nt_rh
BNE tg_cc_t_ne_r
LDA zp_nt_r
CMP zp_ot_r
BEQ tg_cc_no_top
tg_cc_t_ne_r:
; Inlined tg_cc_calc_top: compute |d0|, |d1| as u16, then JSR
; compute_crossover. (Formerly a standalone function with tail-call
; JMP compute_crossover; inlined for -3 bytes since it had 1 caller.)
LDA zp_ot_l
SEC
SBC zp_nt_l
STA zp_tmp0
LDA #0
SBC zp_nt_lh
STA zp_tmp1
BPL ict0p
SEC
LDA #0
SBC zp_tmp0
STA zp_tmp0
LDA #0
SBC zp_tmp1
STA zp_tmp1
ict0p:
LDA zp_ot_r
SEC
SBC zp_nt_r
STA zp_tmp2
LDA #0
SBC zp_nt_rh
STA zp_tmp3
BPL ict1p
SEC
LDA #0
SBC zp_tmp2
STA zp_tmp2
LDA #0
SBC zp_tmp3
STA zp_tmp3
ict1p:
JSR compute_crossover                   ; A = cx column
.byte $2C                               ; BIT abs: skip LDA #0
tg_cc_no_top:
LDA #0                                  ; |
STA zp_cx_top                           ; shared store
tg_cc_chk_bot:
; Bot crossover: fast path when both hi bytes are 0 (common case).
LDA zp_nb_lh
ORA zp_nb_rh
BNE tg_cc_b_slow
; |
; Branch-based sign comparison for bot (same as top fast path).
LDA zp_ob_l
CMP zp_nb_l
BCS tg_cc_b_lpos
; |
; ob_l < nb_l
LDA zp_ob_r
CMP zp_nb_r
BCC tg_cc_no_bot
; both < → no cx
BCS tg_cc_b_check_dt                    ; signs differ → cx
tg_cc_b_lpos:
; ob_l >= nb_l
LDA zp_ob_r
CMP zp_nb_r
BCS tg_cc_no_bot
; both >= → no cx
BCC tg_cc_b_check_dt                    ; signs differ → cx
tg_cc_b_slow:
LDA zp_nb_lh
BMI tg_cc_b0p
BNE tg_cc_b0n
; |
LDA zp_ob_l
CMP zp_nb_l
; |
LDA #0
ROL A
BCC tg_cc_b0d
; |
tg_cc_b0p:
LDA #1
.byte $2C
; BIT abs: skip LDA #0
tg_cc_b0n:
LDA #0
tg_cc_b0d:
STA zp_tmp1
; |
LDA zp_nb_rh
BMI tg_cc_b1p
BNE tg_cc_b1n
; |
LDA zp_ob_r
CMP zp_nb_r
; |
LDA #0
ROL A
BCC tg_cc_b1d
; |
tg_cc_b1p:
LDA #1
.byte $2C
; BIT abs: skip LDA #0
tg_cc_b1n:
LDA #0
tg_cc_b1d:
EOR zp_tmp1
; |
BEQ tg_cc_no_bot                        ; |
tg_cc_b_check_dt:
; Same dt != 0 pre-check as top (see tg_cc_t_ne_l comment).
LDA zp_nb_lh
BNE tg_cc_b_ne_l
; |
LDA zp_nb_l
CMP zp_ob_l
BEQ tg_cc_no_bot
; |
tg_cc_b_ne_l:
LDA zp_nb_rh
BNE tg_cc_b_ne_r
; |
LDA zp_nb_r
CMP zp_ob_r
BEQ tg_cc_no_bot
; |
tg_cc_b_ne_r:
JSR tg_cc_calc_bot                      ; A = cx column
.byte $2C                               ; BIT abs: skip LDA #0
tg_cc_no_bot:
LDA #0                                  ; |
STA zp_cx_bot                           ; shared store
tg_cc_done:

; --- Clamp new s16 values for dominance check ---
; With Y_BIAS, all values reaching here are u8 (hi bytes = 0).
; Skip clamping when all hi bytes are zero.
LDA zp_nt_lh
ORA zp_nt_rh
ORA zp_nb_lh
ORA zp_nb_rh
; |
BEQ tg_clamp_done                       ; | all u8 → no clamp
; (2-byte clamp pad removed)
tg_clamp_slow:
; Fast path: if both top hi bytes are negative, clamp tops to 0 and skip
; to clamping only the bot values.
LDA zp_nt_lh
AND zp_nt_rh
BPL tg_clamp_full
LDA #0
STA zp_nt_l
STA zp_nt_r
; hi bytes already nonzero (negative) → no need to set them
JMP tg_clamp_nb
tg_clamp_full:
; High byte: negative→0, positive overflow (hi>0)→VIS_YMAX, 0→check low
; byte (in [0,255], clamp [VIS_YMAX+1,255] to VIS_YMAX).
; When clamping occurs, set hi byte to nonzero so edge emission guard fires.
LDA zp_nt_lh
BMI tg_cn1z
BNE tg_cn1f
LDA zp_nt_l
CMP #(VIS_YMAX + 1)
BCC tg_cn1s
LDA #1
STA zp_nt_lh
; mark clamped
tg_cn1f:
LDA #VIS_YMAX
.byte $2C
; BIT abs: skip LDA #0
tg_cn1z:
LDA #0
tg_cn1s:
STA zp_nt_l
; |
LDA zp_nt_rh
BMI tg_cn2z
BNE tg_cn2f
LDA zp_nt_r
CMP #(VIS_YMAX + 1)
BCC tg_cn2s
LDA #1
STA zp_nt_rh
; mark clamped
tg_cn2f:
LDA #VIS_YMAX
.byte $2C
; BIT abs: skip LDA #0
tg_cn2z:
LDA #0
tg_cn2s:
STA zp_nt_r
; |
tg_clamp_nb:
LDA zp_nb_lh
BMI tg_cn3z
BNE tg_cn3f
LDA zp_nb_l
CMP #(VIS_YMAX + 1)
BCC tg_cn3s
LDA #1
STA zp_nb_lh
; mark clamped
tg_cn3f:
LDA #VIS_YMAX
.byte $2C
; BIT abs: skip LDA #0
tg_cn3z:
LDA #0
tg_cn3s:
STA zp_nb_l
; |
LDA zp_nb_rh
BMI tg_cn4z
BNE tg_cn4f
LDA zp_nb_r
CMP #(VIS_YMAX + 1)
BCC tg_cn4s
LDA #1
STA zp_nb_rh
; mark clamped
tg_cn4f:
LDA #VIS_YMAX
.byte $2C
; BIT abs: skip LDA #0
tg_cn4z:
LDA #0
tg_cn4s:
STA zp_nb_r
; |
tg_clamp_done:
; Unsigned dominance: new_tl <= old_tl AND new_tr <= old_tr AND ...
; Reversed CMP: swap operands so BCC alone catches the failure case.
LDA zp_ot_l
CMP zp_nt_l
BCC tg_not_old_dom
; |
LDA zp_ot_r
CMP zp_nt_r
BCC tg_not_old_dom
; |
LDA zp_nb_l
CMP zp_ob_l
BCC tg_not_old_dom
; |
LDA zp_nb_r
CMP zp_ob_r
BCC tg_not_old_dom
; |
; Old dominates: keep span unchanged
LDA #$FF
STA zp_tg_cont
LDX zp_save1                            ; |
JSR tg_append_x                         ; |
JMP tg_walk                             ; |

tg_not_old_dom:
; --- Left fragment: if xstart < ilo (active range extends left of seg) ---
; Allocate sibling, copy line params verbatim, set its active range to
; [original xstart, ilo-1]. NO interp_store calls — line is preserved.
; Load old span into Y (preserved across alloc_span, saves a reload).
LDY zp_save1                            ; |
LDA POOL_XSTART,Y
CMP zp_ilo
BCS tg_no_left
; |
JSR alloc_span
BEQ tg_no_left
; |
LDA POOL_XLO,Y
STA POOL_XLO,X
; |
LDA POOL_DEN,Y
STA POOL_DEN,X
; |
LDA POOL_TL,Y
STA POOL_TL,X
; |
LDA POOL_BL,Y
STA POOL_BL,X
; |
LDA POOL_TR,Y
STA POOL_TR,X
; |
LDA POOL_BR,Y
STA POOL_BR,X
; |
LDA POOL_OT,Y
STA POOL_OT,X
; |
LDA POOL_OB,Y
STA POOL_OB,X
; |
LDA POOL_IT,Y
STA POOL_IT,X
; |
LDA POOL_IB,Y
STA POOL_IB,X
; |
LDA POOL_XSTART,Y
STA POOL_XSTART,X
; |
; Abutting model: left fragment includes ilo (shared boundary)
LDA zp_ilo
STA POOL_XEND,X
; |
JSR tg_append_x                         ; |
tg_no_left:

; --- Process overlap with crossover splits ---
LDA zp_cx_top
ORA zp_cx_bot
BEQ ncf_no_splits
; |
JMP tg_has_splits
ncf_no_splits:
; --- No crossover fast path ---
; The dominance check already computed ot_l/ot_r/ob_l/ob_r (u8 via
; interp_store) and nt_l/nt_r/nb_l/nb_r (clamped u8) at (ox0, ox1).
;
; Do max/min + aperture + store inline without re-interpolating.
LDA zp_ot_l
CMP zp_nt_l
BCS ncf_tl_ok
LDA zp_nt_l
; |
ncf_tl_ok:
STA zp_ot_l
; |
LDA zp_ot_r
CMP zp_nt_r
BCS ncf_tr_ok
LDA zp_nt_r
; |
ncf_tr_ok:
STA zp_ot_r
; |
LDA zp_ob_l
CMP zp_nb_l
BCC ncf_bl_ok
LDA zp_nb_l
; |
ncf_bl_ok:
STA zp_ob_l
; |
LDA zp_ob_r
CMP zp_nb_r
BCC ncf_br_ok
LDA zp_nb_r
; |
ncf_br_ok:
STA zp_ob_r
; |
; Aperture check (ox0 < ox1 guaranteed by strict overlap test)
LDA zp_ot_l
CMP zp_ob_l
BCC ncf_has_ap
; |
LDA zp_ot_r
CMP zp_ob_r
BCS ncf_no_ap
ncf_has_ap:
JSR alloc_span
BEQ ncf_no_ap
; |
; Dense-anchored result span (line == active range)
LDA zp_ox0
STA POOL_XLO,X
STA POOL_XSTART,X
; |
LDA zp_ox1
STA POOL_XEND,X
; |
SEC
SBC zp_ox0
STA POOL_DEN,X
; | den = ox1 - ox0
LDA zp_ot_l
STA POOL_TL,X
LDA zp_ob_l
STA POOL_BL,X
; |
LDA zp_ot_r
STA POOL_TR,X
LDA zp_ob_r
STA POOL_BR,X
; |
; OT = min(zp_ot_l, zp_ot_r)
LDA zp_ot_l
CMP zp_ot_r
BCC ncf_ot_ok
LDA zp_ot_r
ncf_ot_ok:
STA POOL_OT,X
; OB = max(zp_ob_l, zp_ob_r)
LDA zp_ob_l
CMP zp_ob_r
BCS ncf_ob_ok
LDA zp_ob_r
ncf_ob_ok:
STA POOL_OB,X
; IT = max(zp_ot_l, zp_ot_r)
LDA zp_ot_l
CMP zp_ot_r
BCS ncf_it_ok
LDA zp_ot_r
ncf_it_ok:
STA POOL_IT,X
; IB = min(zp_ob_l, zp_ob_r)
LDA zp_ob_l
CMP zp_ob_r
BCC ncf_ib_ok
LDA zp_ob_r
ncf_ib_ok:
STA POOL_IB,X
JSR tg_append_x                         ; |
ncf_no_ap:
JMP tg_right_frag                       ; |
tg_has_splits:
LDA zp_ox1
STA zp_final_ox1
; ||
LDA zp_cx_top
BEQ tg_split_bot
; |
LDA zp_cx_bot
BEQ tg_split_top
; Both crossovers. Sort: ensure cx_top <= cx_bot.
LDA zp_cx_top
CMP zp_cx_bot
BCC tg_2sorted
BEQ tg_split_top
LDY zp_cx_bot
STA zp_cx_bot
STY zp_cx_top
tg_2sorted:
; 3 sharing intervals: [ox0, cx_top], [cx_top, cx_bot], [cx_bot, final_ox1]
LDA zp_cx_top
STA zp_ox1
JSR tg_overlap_sub
LDA zp_cx_top
STA zp_ox0
LDA zp_cx_bot
STA zp_ox1
JSR tg_overlap_sub
LDA zp_cx_bot
STA zp_ox0
LDA zp_final_ox1
STA zp_ox1
JSR tg_overlap_sub
JMP tg_right_frag
tg_split_top:
LDA zp_cx_top
JMP tg_split_one
tg_split_bot:
LDA zp_cx_bot                           ; |
tg_split_one:
; A = single crossover X. 2 sharing intervals: [ox0, cx], [cx, final_ox1]
STA zp_tmp3                             ; save cx                             ; |
STA zp_ox1                              ; left sub-interval ends AT cx (shared)  ; |
JSR tg_overlap_sub                      ; |
LDA zp_tmp3
STA zp_ox0
; |
LDA zp_final_ox1
STA zp_ox1
; |
JSR tg_overlap_sub                      ; |

tg_right_frag:
; --- Right fragment: if xend > ihi (active range extends right of seg) ---
; Allocate sibling, copy line params verbatim, set its active range to
; [ihi+1, original xend]. NO interp_store calls.
; Load old span into Y (preserved across alloc_span, saves a reload).
LDY zp_save1                            ; |
LDA zp_ihi
CMP POOL_XEND,Y
BCS tg_no_right
; |
tg_make_right:
JSR alloc_span
BEQ tg_no_right
; |
LDA POOL_XLO,Y
STA POOL_XLO,X
; |
LDA POOL_DEN,Y
STA POOL_DEN,X
; |
LDA POOL_TL,Y
STA POOL_TL,X
; |
LDA POOL_BL,Y
STA POOL_BL,X
; |
LDA POOL_TR,Y
STA POOL_TR,X
; |
LDA POOL_BR,Y
STA POOL_BR,X
; |
LDA POOL_OT,Y
STA POOL_OT,X
; |
LDA POOL_OB,Y
STA POOL_OB,X
; |
LDA POOL_IT,Y
STA POOL_IT,X
; |
LDA POOL_IB,Y
STA POOL_IB,X
; |
; Abutting model: right fragment includes ihi (shared boundary)
LDA zp_ihi
STA POOL_XSTART,X
; |
LDA POOL_XEND,Y
STA POOL_XEND,X
; |
JSR tg_append_x                         ; |
tg_no_right:
LDX zp_save1
JSR free_span
; |
JMP tg_walk                             ; |

; --- TG_APPEND_X: append span X to the new list, with merge optimization ---
;
; Tries to merge X into the tail when both are constant-line spans
; (tl==tr, bl==br) with matching Y values and contiguous X ranges.
; This prevents span-count explosion from crossover splits; ~96% of
; merge candidates are constant-line, so the 6-compare fast path
; resolves quickly.
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

; ======================================================================
; TG_OVERLAP_SUB: process one sub-interval of the tighten overlap
;
; Called 1-3 times per overlapping span (once per crossover sub-interval).
; Interpolates 4 old + 4 new boundary values, clamps new to [0,159],
; checks old-dominance shortcut, then does max/min + aperture check.
; ======================================================================
tg_overlap_sub:
.scope
; --- Old span: constant-line fast path or 4 interp_store calls ---
LDX zp_save1                            ; |
LDA POOL_TL,X
CMP POOL_TR,X
BNE tos_old_slow
; |
STA zp_ot_l
STA zp_ot_r
; |
LDA POOL_BL,X
CMP POOL_BR,X
BNE tos_old_slow_reload
; |
STA zp_ob_l
STA zp_ob_r
; |
JMP tos_old_done                        ; |
tos_old_slow_reload:
; BL!=BR but TL==TR: re-read TL for old_slow (rare path)
LDA POOL_TL,X
tos_old_slow:
; A holds TL on entry from constant-line check
STA zp_i_y0                             ; |
LDA POOL_XLO,X
STA zp_i_x0
; |
LDA POOL_DEN,X
STA zp_div_den
; |
LDA POOL_TR,X
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_ot_l
; |
LDA zp_ox1
JSR interp_store
STA zp_ot_r
; |
LDX zp_save1                            ; |
LDA POOL_BL,X
STA zp_i_y0
LDA POOL_BR,X
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_ob_l
; |
LDA zp_ox1
JSR interp_store
STA zp_ob_r
; |
tos_old_done:
; --- New seg: constant-line fast path or 4 interp_store calls (u8) ---
LDA zp_yt1
CMP zp_yt2
BNE tos_new_slow
; |
LDA zp_yb1
CMP zp_yb2
BNE tos_new_slow
; |
; Constant line: both endpoints identical.
LDA zp_yt1
STA zp_nt_l
STA zp_nt_r
; |
LDA zp_yb1
STA zp_nb_l
STA zp_nb_r
; |
LDA #0
STA zp_nt_lh
STA zp_nt_rh
STA zp_nb_lh
STA zp_nb_rh
; | hi bytes = 0
JMP tos_new_done                        ; |
tos_new_slow:
LDA zp_sx2
SEC
SBC zp_sx1
STA zp_div_den
; |
LDA zp_sx1
STA zp_i_x0
; |
LDA zp_yt1
STA zp_i_y0
; |
LDA zp_yt2
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_nt_l
; |
LDA zp_ox1
JSR interp_store
STA zp_nt_r
; |
LDA zp_yb1
STA zp_i_y0
; |
LDA zp_yb2
STA zp_i_y1
; |
LDA zp_ox0
JSR interp_store
STA zp_nb_l
; |
LDA zp_ox1
JSR interp_store
STA zp_nb_r
; |
LDA #0
STA zp_nt_lh
STA zp_nt_rh
STA zp_nb_lh
STA zp_nb_rh
; | hi bytes = 0
tos_new_done:
; Clamp s16 new values for dominance check.
; With Y_BIAS, all values are u8 (hi bytes = 0). Skip clamping.
LDA zp_nt_lh
ORA zp_nt_rh
ORA zp_nb_lh
ORA zp_nb_rh
; |
BEQ tos_clamp_done                      ; | all u8 → no clamp
tos_clamp_slow:
LDA zp_nt_lh
BMI cn1z
BNE cn1f
LDA zp_nt_l
CMP #(VIS_YMAX + 1)
BCC cn1s
LDA #1
STA zp_nt_lh
; mark clamped
cn1f:
LDA #VIS_YMAX
.byte $2C
; BIT abs: skip LDA #0
cn1z:
LDA #0
cn1s:
STA zp_nt_l
; |
LDA zp_nt_rh
BMI cn2z
BNE cn2f
LDA zp_nt_r
CMP #(VIS_YMAX + 1)
BCC cn2s
LDA #1
STA zp_nt_rh
; mark clamped
cn2f:
LDA #VIS_YMAX
.byte $2C
; BIT abs: skip LDA #0
cn2z:
LDA #0
cn2s:
STA zp_nt_r
; |
LDA zp_nb_lh
BMI cn3z
BNE cn3f
LDA zp_nb_l
CMP #(VIS_YMAX + 1)
BCC cn3s
LDA #1
STA zp_nb_lh
; mark clamped
cn3f:
LDA #VIS_YMAX
.byte $2C
; BIT abs: skip LDA #0
cn3z:
LDA #0
cn3s:
STA zp_nb_l
; |
LDA zp_nb_rh
BMI cn4z
BNE cn4f
LDA zp_nb_r
CMP #(VIS_YMAX + 1)
BCC cn4s
LDA #1
STA zp_nb_rh
; mark clamped
cn4f:
LDA #VIS_YMAX
.byte $2C
; BIT abs: skip LDA #0
cn4z:
LDA #0
cn4s:
STA zp_nb_r
; |
tos_clamp_done:
; Opt 2: if OLD wins top and bot at BOTH sub-interval endpoints, we can
; preserve the old span's line verbatim and just set xstart/xend. This
; typically fires on one side of a crossover-split sub-interval where
; the old span dominates the new seg.
LDA zp_ot_l
CMP zp_nt_l
BCC skip_opt2
; ot_l < nt_l → new wins top-l  ; |
LDA zp_ot_r
CMP zp_nt_r
BCC skip_opt2
; |
LDA zp_nb_l
CMP zp_ob_l
BCC skip_opt2
; nb_l < ob_l → new wins bot-l  ; |
LDA zp_nb_r
CMP zp_ob_r
BCC skip_opt2
; |
; Old wins all four comparisons → copy line verbatim
JSR alloc_span
BEQ opt2_no_ap
; |
LDY zp_save1                            ; |
LDA POOL_XLO,Y
STA POOL_XLO,X
; |
LDA POOL_DEN,Y
STA POOL_DEN,X
; |
LDA POOL_TL,Y
STA POOL_TL,X
; |
LDA POOL_BL,Y
STA POOL_BL,X
; |
LDA POOL_TR,Y
STA POOL_TR,X
; |
LDA POOL_BR,Y
STA POOL_BR,X
; |
LDA POOL_OT,Y
STA POOL_OT,X
; |
LDA POOL_OB,Y
STA POOL_OB,X
; |
LDA POOL_IT,Y
STA POOL_IT,X
; |
LDA POOL_IB,Y
STA POOL_IB,X
; |
LDA zp_ox0
STA POOL_XSTART,X
; |
LDA zp_ox1
STA POOL_XEND,X
; |
JMP tg_append_x                         ; | tail-call (saves 3 cyc)
opt2_no_ap:
RTS                                     ; |
skip_opt2:
; max top, min bot
LDA zp_ot_l
CMP zp_nt_l
BCS tl_ok
LDA zp_nt_l
; |
tl_ok:
STA zp_ot_l
; |
LDA zp_ot_r
CMP zp_nt_r
BCS tr_ok
LDA zp_nt_r
; |
tr_ok:
STA zp_ot_r
; |
LDA zp_ob_l
CMP zp_nb_l
BCC bl_ok
LDA zp_nb_l
; |
bl_ok:
STA zp_ob_l
; |
LDA zp_ob_r
CMP zp_nb_r
BCC br_ok
LDA zp_nb_r
; |
br_ok:
STA zp_ob_r
; |
; Check aperture
LDA zp_ot_l
CMP zp_ob_l
BCC has_ap
; |
LDA zp_ot_r
CMP zp_ob_r
BCS no_ap
has_ap:
JSR alloc_span
BEQ no_ap
; |
; Result span is dense-anchored: line endpoints == active range endpoints
LDA zp_ox0
STA POOL_XLO,X
STA POOL_XSTART,X
; |
LDA zp_ox1
STA POOL_XEND,X
; |
SEC
SBC zp_ox0
STA POOL_DEN,X
; | den = ox1 - ox0
LDA zp_ot_l
STA POOL_TL,X
LDA zp_ob_l
STA POOL_BL,X
; |
LDA zp_ot_r
STA POOL_TR,X
LDA zp_ob_r
STA POOL_BR,X
; |
; OT = min(zp_ot_l, zp_ot_r)
LDA zp_ot_l
CMP zp_ot_r
BCC tos_ot_ok
LDA zp_ot_r
tos_ot_ok:
STA POOL_OT,X
; OB = max(zp_ob_l, zp_ob_r)
LDA zp_ob_l
CMP zp_ob_r
BCS tos_ob_ok
LDA zp_ob_r
tos_ob_ok:
STA POOL_OB,X
; IT = max(zp_ot_l, zp_ot_r)
LDA zp_ot_l
CMP zp_ot_r
BCS tos_it_ok
LDA zp_ot_r
tos_it_ok:
STA POOL_IT,X
; IB = min(zp_ob_l, zp_ob_r)
LDA zp_ob_l
CMP zp_ob_r
BCC tos_ib_ok
LDA zp_ob_r
tos_ib_ok:
STA POOL_IB,X
JMP tg_append_x                         ; | tail-call (saves 3 cyc)
no_ap:
RTS                                     ; |
.endscope

; ======================================================================
; CROSSOVER COMPUTATION SECTION
;
; tg_cc_calc_bot computes |d0|, |d1| as u16 absolute differences of
; (old_bot - new_bot) at each overlap endpoint, then falls through
; to compute_crossover.
;
; compute_crossover finds the column X where the boundary difference
; crosses zero using: cx = ox0 + |d0| * ex / (|d0| + |d1|)
;
; FAST PATH (den fits u8): 8-iter u16/u8 restoring divide (~200 cyc).
; SLOW PATH (den > 255, rare): 8-iter u24/u16 restoring divide.
; Returns 0 if crossover is at edge or outside interval.
; ======================================================================
tg_cc_calc_bot:
.scope
LDA zp_ob_l
SEC
SBC zp_nb_l
STA zp_tmp0
; |
LDA #0
SBC zp_nb_lh
STA zp_tmp1
; |
BPL db0p                                ; |
SEC
LDA #0
SBC zp_tmp0
STA zp_tmp0
; |
LDA #0
SBC zp_tmp1
STA zp_tmp1
; |
db0p:
LDA zp_ob_r
SEC
SBC zp_nb_r
STA zp_tmp2
; |
LDA #0
SBC zp_nb_rh
STA zp_tmp3
; |
BPL db1p                                ; |
SEC
LDA #0
SBC zp_tmp2
STA zp_tmp2
LDA #0
SBC zp_tmp3
STA zp_tmp3
db1p:
; Fall through to compute_crossover
.endscope
