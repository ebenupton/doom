
; ============================================================================
; do_project_y — project the four per-seg heights (top/bot/btop/bbot)
; with the current reciprocal into the zp_seg_sy_* slots. Global so the
; crossing reprojection can tail-call it instead of duplicating it.
;
;   Inputs:  zp_br_r_m8/rlo    = current vertex's (M8, S) reciprocal
;            zp_seg_top_dlt   = ch  - vz (s8)  front ceiling delta
;            zp_seg_bot_dlt   = fh  - vz (s8)  front floor delta
;            zp_seg_btop_dlt  = bch - vz (s8)  back ceiling (or APV1_FH)
;            zp_seg_bbot_dlt  = bfh - vz (s8)  back floor   (or APV1_CH)
;            zp_seg_flags     = seg header flags
;                               (SOLID=$02 NEEDBT=$04 NEEDBB=$08 APEDGE1=$40)
;   Outputs: the endpoint struct sy pairs (VX1+5..12,X, X = zp_seg_ep):
;            top/bot always, btop/bbot when the flags gate them in
;            All s16 screen y, pre-biased by Y_BIAS (br_project_y folds it).
;   Uses:    br_project_y (project.s) — the VWHC-memoised projection
;            (raw body inlined 2026-07-12); mirrors Python's _py(h) =
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
; (unscoped: dpy_back is a public entry for the chain path; dpy_* label
; names are globally unique)
do_project_y:
; --- Project Y for top edge (height = ch - vz) ---
   LDA zp_seg_top_dlt                       ; h rides A into the cache front
   JSR br_project_y                        ; -> Y = sy lo, A = sy hi
   LDX zp_seg_ep                            ; re-establish endpoint offset
   STA VX1+6,X ; --- Project Y for bottom edge (height = fh - vz) ---
   TYA
   STA VX1+5,X ; sy_top (struct)
   LDA zp_seg_bot_dlt                       ; h rides A into the cache front
   JSR br_project_y                        ; -> Y = sy lo, A = sy hi
   LDX zp_seg_ep
   STA VX1+8,X ; --- Back-pair projections only when a consumer exists: every use of
   TYA
   STA VX1+7,X ; sy_bot
; sy_btop/sy_bbot is gated on (SOLID & APEDGE1) — the APV1 aperture
; vertical — or (portal & NEEDBT/NEEDBB). Skipping unused projections
; is output-identical and saves 2 projections (4 muls) per vertex on
; plain solid walls.
; dpy_back is ALSO a public entry (2026-07-10): the seg loop's vertex-
; CHAIN path reuses the previous v2's front sy pair verbatim (same
; vertex, same subsector heights) and calls in here for just the
; flag-gated back pair, with the vertex's recip restored to zp_br_r_m8/
; rlo + rns_select re-vectored by the caller. ---
dpy_back:
; SOLIDS: no aperture work here any more (2026-07-11). The APV pairs
; are projected POST-visibility by apv_stage (lo.s) — has_gap-culled
; segs pay nothing (this path used to speculate APV1 for every
; front-facing solid+APEDGE1 seg), and the struct becomes fully
; endpoint-self-contained before any canonicalizing swap.
   LDA zp_seg_flags
   AND #$02
   BNE dpy_done_s
   LDA zp_seg_flags
   AND #$04
   BEQ dpy_chk_bb
; NEEDBT?
dpy_btop:
; --- Project Y for back ceiling (height = bch - vz) ---
   LDA zp_seg_btop_dlt                       ; h rides A into the cache front
   JSR br_project_y                        ; -> Y = sy lo, A = sy hi
   LDX zp_seg_ep
   STA VX1+10,X ;
   TYA
   STA VX1+9,X ; sy_btop
dpy_chk_bb:
   LDA zp_seg_flags
   AND #$08
   BEQ dpy_done
; NEEDBB?
dpy_bbot:
; --- Project Y for back floor (height = bfh - vz) ---
   LDA zp_seg_bbot_dlt                       ; h rides A into the cache front
   JSR br_project_y                        ; -> Y = sy lo, A = sy hi
   LDX zp_seg_ep
   STA VX1+12,X ;
   TYA
   STA VX1+11,X ; sy_bbot
dpy_done:
   RTS
dpy_done_s:
   RTS
