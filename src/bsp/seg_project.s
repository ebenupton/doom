
; ============================================================================
; do_project_y_v1 / _v2 — project the four per-seg heights (top/bot/
; btop/bbot) with the current reciprocal into the endpoint struct's sy
; slots. PER-ENDPOINT INSTANTIATIONS (2026-07-19): the three call sites
; know the endpoint statically, so the struct stores are absolute zp
; (VX1/VX2 baked) and every post-JSR LDX zp_seg_ep reload is gone.
;
;   Inputs:  zp_br_r_m8/rlo    = current vertex's (M8, S) reciprocal
;            zp_seg_top_dlt   = ch  - vz (s8)  front ceiling delta
;            zp_seg_bot_dlt   = fh  - vz (s8)  front floor delta
;            zp_seg_btop_dlt  = bch - vz (s8)  back ceiling (or APV1_FH)
;            zp_seg_bbot_dlt  = bfh - vz (s8)  back floor   (or APV1_CH)
;            zp_seg_flags     = seg header flags
;                               (SOLID=$02 NEEDBT=$04 NEEDBB=$08 APEDGE1=$40)
;   Outputs: the endpoint struct sy pairs (base+5..12), s16 screen y,
;            pre-biased by Y_BIAS (br_project_y folds it):
;            top/bot always, btop/bbot when the flags gate them in.
;   Uses:    br_project_y (project.s) — the VWHC-memoised projection;
;            mirrors Python's _py(h) = fp_project_y(h - vz, ryh, ryl)
;            with the VWH cache in packed_render_seg.
;
;   Pseudocode (gating note: skips are output-identical):
;     sy_top = project_y(top_dlt)                 # ft = _py(ch)
;     sy_bot = project_y(bot_dlt)                 # fb = _py(fh)
;     if solid: return                            # APV pairs project
;     else:                                       #   post-vis (apv_stage)
;         if NEEDBT:  sy_btop = project_y(btop_dlt)
;         if NEEDBB:  sy_bbot = project_y(bbot_dlt)
;
;   dpy_back_v1 is the chain path's public entry: the seg loop reuses
;   the previous v2's front sy pair verbatim (same vertex, same
;   subsector heights) and enters here for just the flag-gated back
;   pair, with the vertex's recip restored + rns re-vectored by the
;   caller. (The old "crossing tail-call" note was stale: the crossing
;   banks its recip in the struct and the deferred y stage projects.)
; ============================================================================
.macro DPY_BODY base, backentry
.local dpy_chk_bb, dpy_done
   LDA zp_seg_top_dlt                       ; h rides A into the cache front
   JSR br_project_y                        ; -> Y = sy lo, A = sy hi
   STA base+6
   TYA
   STA base+5                              ; sy_top
   LDA zp_seg_bot_dlt
   JSR br_project_y
   STA base+8
   TYA
   STA base+7                              ; sy_bot
backentry:
   LDA zp_seg_flags
   AND #$02
   BNE dpy_done                            ; solid: APV pairs are post-vis
   LDA zp_seg_flags
   AND #$04
   BEQ dpy_chk_bb
   LDA zp_seg_btop_dlt
   JSR br_project_y
   STA base+10
   TYA
   STA base+9                              ; sy_btop
dpy_chk_bb:
   LDA zp_seg_flags
   AND #$08
   BEQ dpy_done
   LDA zp_seg_bbot_dlt
   JSR br_project_y
   STA base+12
   TYA
   STA base+11                             ; sy_bbot
dpy_done:
   RTS
.endmacro

do_project_y_v1:
DPY_BODY VX1, dpy_back_v1
do_project_y_v2:
DPY_BODY VX2, dpy_back_v2
