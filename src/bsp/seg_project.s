
; ============================================================================
; do_project_y — project the four per-seg heights (top/bot/btop/bbot)
; with the current reciprocal into the zp_seg_sy_* slots. Global so the
; crossing reprojection can tail-call it instead of duplicating it.
;
;   Inputs:  zp_br_rhi/rlo    = current vertex's 8.8 reciprocal
;            zp_seg_top_dlt   = ch  - vz (s8)  front ceiling delta
;            zp_seg_bot_dlt   = fh  - vz (s8)  front floor delta
;            zp_seg_btop_dlt  = bch - vz (s8)  back ceiling (or APV1_FH)
;            zp_seg_bbot_dlt  = bfh - vz (s8)  back floor   (or APV1_CH)
;            zp_seg_flags     = seg header flags
;                               (SOLID=$02 NEEDBT=$04 NEEDBB=$08 APEDGE1=$40)
;   Outputs: zp_seg_sy_top_lo/hi, zp_seg_sy_bot_lo/hi   (always)
;            zp_seg_sy_btop_lo/hi, zp_seg_sy_bbot_lo/hi (when gated in)
;            All s16 screen y, pre-biased by Y_BIAS (br_project_y folds it).
;   Uses:    br_project_y — the VWHC-cached front (ycache.s) over
;            br_project_y_raw; mirrors Python's per-endpoint _py(h) =
;            fp_project_y(h - vz, ryh, ryl) with the VWH cache in
;            packed_render_seg.
;
;   Pseudocode (see the gating note below — skips are output-identical):
;     sy_top = project_y(top_dlt)                 # ft = _py(ch)
;     sy_bot = project_y(bot_dlt)                 # fb = _py(fh)
;     if solid:
;         if APEDGE1: sy_btop = project_y(btop_dlt)   # APV1 aperture pair
;                     sy_bbot = project_y(bbot_dlt)
;     else:
;         if NEEDBT:  sy_btop = project_y(btop_dlt)   # bt = _py(bch)
;         if NEEDBB:  sy_bbot = project_y(bbot_dlt)   # bb = _py(bfh)
; ============================================================================
do_project_y:
.scope
; --- Project Y for top edge (height = ch - vz) ---
LDA zp_seg_top_dlt
STA zp_br_t0
JSR br_project_y
LDA zp_br_resl
STA zp_seg_sy_top_lo
LDA zp_br_resh
STA zp_seg_sy_top_hi

; --- Project Y for bottom edge (height = fh - vz) ---
LDA zp_seg_bot_dlt
STA zp_br_t0
JSR br_project_y
LDA zp_br_resl
STA zp_seg_sy_bot_lo
LDA zp_br_resh
STA zp_seg_sy_bot_hi

; --- Back-pair projections only when a consumer exists: every use of
; sy_btop/sy_bbot is gated on (SOLID & APEDGE1) — the APV1 aperture
; vertical — or (portal & NEEDBT/NEEDBB). Skipping unused projections
; is output-identical and saves 2 projections (4 muls) per vertex on
; plain solid walls. ---
LDA zp_seg_flags
AND #$02
BEQ dpy_portal
LDA zp_seg_flags
AND #$40
BNE dpy_btop
; solid + APEDGE1 → both
RTS                                     ; plain solid → neither
dpy_portal:
LDA zp_seg_flags
AND #$04
BEQ dpy_chk_bb
; NEEDBT?
dpy_btop:
; --- Project Y for back ceiling (height = bch - vz) ---
LDA zp_seg_btop_dlt
STA zp_br_t0
JSR br_project_y
LDA zp_br_resl
STA zp_seg_sy_btop_lo
LDA zp_br_resh
STA zp_seg_sy_btop_hi
LDA zp_seg_flags
AND #$02
BNE dpy_bbot
; solid+APEDGE1 → both
dpy_chk_bb:
LDA zp_seg_flags
AND #$08
BEQ dpy_done
; NEEDBB?
dpy_bbot:
; --- Project Y for back floor (height = bfh - vz) ---
LDA zp_seg_bbot_dlt
STA zp_br_t0
JSR br_project_y
LDA zp_br_resl
STA zp_seg_sy_bbot_lo
LDA zp_br_resh
STA zp_seg_sy_bbot_hi
dpy_done:
RTS
.endscope
