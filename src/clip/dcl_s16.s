
; ============================================================================
; clip/dcl_s16.s — clipper fragment 10 of 13 (module map:
; clip/header.s). Contents: the s16 pre-clip entries
; draw_clipped_line_s16 / draw_clipped_line_s16_h, which clip to the u8 box and dispatch into
; draw_clipped_line (clip/dcl.s). LC_* working-set addresses are
; declared in clip/tfr.s. (s16_interp and the inlined wide-arithmetic
; notes moved to clip/arith.s 2026-08-09 — dcl.s calls it too, and the
; call-graph file DAG wants no dcl -> dcl_s16 back edge.)
; ============================================================================


; ===================================================================
; draw_clipped_line_s16 — clip s16 line to u8 then dispatch to DCL.
; Reads zp_line_xl_l..zp_line_yr_h (8 bytes of s16 input).
; Writes u8 to zp_line_xl_l, zp_line_yl_l, zp_line_xr_l, zp_line_yr_l and
; falls through to draw_clipped_line. If line fully off-screen,
; degenerate, or otherwise rejected, RTS without invoking DCL.
;
; Python mirror: the wrapper side of span_clip_6502.draw_clipped_line
; plus _clip_to_screen semantics.  The CALLER has already ordered the
; endpoints left-to-right (x1 <= x2), rejected zero-length input, and
; written the LO bytes — which alias zp_line_xl_l/yl/xr/yr — so the
; all-in-u8 fast path is a single 4-byte OR test and a JMP.
;
; Pseudocode (slow path):
;   if HI(x1)|HI(y1)|HI(x2)|HI(y2) == 0: goto draw_clipped_line
;   if both x < 0 or both x > 255: reject     # same-side quick reject
;   if both y < 0 or both y > 255: reject
;   if either x out of [0,255]:               # X clip (per endpoint)
;       y_at = s16_interp(x = 0 or 255)       # UNCLAMPED s16 result —
;       (x, y) = (edge, y_at)                 # y may still be out of
;                                             # range for the y-clip
;   if both y < 0 or both y > 255: reject     # re-check after x-clip
;   if either y out of [0,255]:               # Y clip, axes swapped
;       x_at = s16_interp(y = 0 or 255)       # (clamped u8 is fine:
;       (x, y) = (x_at, edge)                 #  x already in [0,255])
;   if xl > xr: swap endpoints                # clip can reorder (rare)
;   if xl == xr and yl == yr: reject          # clipped to a point
;   goto draw_clipped_line
; --- draw_clipped_line_s16_h: horizontal-emit entry -------------------
; In: X = offset of the s16 y coord inside EACH vertex struct (the four
;     sy pairs sit at the same offsets in VX1 and VX2, so one offset
;     names the line: +5 top, +7 bot, +9 btop, +11 bbot; lo at VX+X,
;     hi at VX+X+1). The x pair comes straight from zp_seg_sx1/sx2.
; THE SEG LAYER OWNS THE LEFT-TO-RIGHT CONTRACT: the seg loop
; CANONICALIZES on the rare 1px edge-on reversal (seg_swap_vx exchanges
; the endpoint structs post-visibility), so VX1 is ALWAYS the left
; endpoint here — no ord dispatch, no mirrored staging, and the
; clipper's per-draw swap machinery stays GONE (see main_clip).
; All four hi bytes are tested BEFORE any staging: the common all-in-u8
; case stages just the four lo bytes the u8 DCL reads (the hi slots
; overlay the u8 DCL's zp_cb_* workspace, written before every read).
draw_clipped_line_s16_h:
   LDA VX1+1,X                             ; y1 hi
   ORA VX2+1,X                             ; y2 hi
   ORA zp_seg_sx1_h
   ORA zp_seg_sx2_h
   BNE dclh_slow
   LDA zp_seg_sx1_l
   STA zp_line_xl_l
   LDA zp_seg_sx2_l
   STA zp_line_xr_l
   LDA VX1,X
   STA zp_line_yl_l
   LDA VX2,X
   STA zp_line_yr_l
   JMP dcl16_fastu8
; (dclh_slow MOVED 2026-08-12 into the fp_degen seam below: its stage
;  now FALLS into dcl16_mainclip — the +29 tail hop died)

draw_clipped_line_s16:
.scope
; ---- Order endpoints / reject the degenerate point ----
; This entry OWNS the ordering contract (swap when x1 > x2, reject the
; zero-length point), mirroring the harness wrapper's Python prelude.
; It used to be caller-side only: the harness wrapper did it, but the
; NATIVE seg emitters (bsp/subsector.s) stage sx1/sx2 raw — and a
; nearly-edge-on seg can project REVERSED by one pixel (sub-pixel
; rounding inverts the 1px order). A reversed line walked the span
; list without emitting or recording, the portal's tighten record was
; lost, and the aperture stayed open — far subtrees leaked through
; (the 8F.1F/0F.DB/84 "solid bars": 1891px over-draw, 4x frame cost).
; Records counts need no handling on the reject path: the seg emitter
; pre-zeroes TOP/BOT_RECORDS counts (and the wrapper zeroes its buffer)
; before any edge is staged.
;
; ---- Fast path: all 4 endpoints already in u8 range ----
; HI bytes all zero ⇔ all coords in [0, 255]; u8 compares suffice for
; the ordering contract here.  zp_line_xl_l/yl/xr/yr (shared with the u8 path via
; alias) are already written by the caller.
   LDA zp_line_xl_h
   ORA zp_line_yl_h
   ORA zp_line_xr_h
   ORA zp_line_yr_h
   BNE main_clip
::dcl16_fastu8:
; input contract: xl <= xr (seg layer / wrapper ordered) — equality is
; the only case left to classify (vertical vs zero-length point)
; (the FW_MODE test died 2026-08-25: the fused entries stage their own
;  fast path and never route armed lines here — this is the DISARMED
;  fast lane, pure and simple)
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BEQ fp_x_eq
   JMP draw_clipped_line
fp_x_eq:
; x1 == x2: vertical unless y1 == y2 (zero-length point → reject)
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BEQ fp_degen
   JMP draw_clipped_line
fp_degen:
   RTS

::dclh_slow:                               ; (:: — moved inside the _s16 scope)
; some coord outside u8: stage the full s16 line for the classic clip
   LDA zp_seg_sx1_l
   STA zp_line_xl_l
   LDA zp_seg_sx1_h
   STA zp_line_xl_h
   LDA zp_seg_sx2_l
   STA zp_line_xr_l
   LDA zp_seg_sx2_h
   STA zp_line_xr_h
   LDA VX1,X
   STA zp_line_yl_l
   LDA VX1+1,X
   STA zp_line_yl_h
   LDA VX2,X
   STA zp_line_yr_l
   LDA VX2+1,X
   STA zp_line_yr_h
; (falls into dcl16_mainclip — moved 2026-08-12)
main_clip:
::dcl16_mainclip:
; no pending right-side band verdict yet ($80 = none)
   LDA #$80
   STA DCLV_S16VY
; ---- Slow path. INPUT CONTRACT: x1 <= x2 as s16 — ordering is owned
; by the CALLERS now (the seg layer stages via zp_sx_ord, the Python
; wrapper orders in its prelude, verticals are trivially ordered).
; The old in-clipper swap existed for the 8F.1F 1px edge-on reversal;
; that case now arrives pre-mirrored from draw_clipped_line_s16_h.
; Only the zero-length reject remains ----
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BNE mc_ordered
   LDA zp_line_xl_h
   CMP zp_line_xr_h
   BNE mc_ordered_noreload
; x1 == x2 (s16): degenerate iff y1 == y2 too, else a VERTICAL — the
; clamp fast path below (the generic path staged anchors and ran
; s16_interp twice just to hand back x unchanged)
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BNE mc_vertical
   LDA zp_line_yl_h
   CMP zp_line_yr_h
   BNE mc_vertical
   RTS                                     ; zero-length point → reject

mc_vertical:
; Vertical clamp (2026-07-15). Clipping a vertical to the u8 box is a
; y-clamp: the x at any y-boundary IS x (s16_interp's dy==0 early-out
; returned exactly that, ~700 cycles later). Bit-exact vs the generic
; path by construction; the engine's vertical emitters are the only
; live callers of this entry and always arrive disarmed. ARMED lines
; (harness wrapper only) keep the generic path — its y-census emits
; flat verdict records this fast path doesn't model.
   BIT FW_MODE                             ; armed (FUSED) verticals keep
   BMI mc_ordered                          ; the generic path's band census
; x1 == x2, so off-screen x is same-side by definition: reject unless
; x in [0,255] (hi == 0)
   LDA zp_line_xl_h
   BNE mcv_rej
; clamp y1 (s16: in-band iff hi == 0; hi < 0 → above; hi > 0 → below),
; rejecting the same-side-out pairs the generic quick-reject catches
   LDA zp_line_yl_h
   BEQ mcv_y1_done                         ; y1 in band
   BMI mcv_y1_neg
   LDA zp_line_yr_h                        ; y1 below: y2 also below → out
   BMI mcv_y1_cl
   BNE mcv_rej
mcv_y1_cl:
   LDA #$FF
   STA zp_line_yl_l
.if ::C02
   STZ zp_line_yl_h
   BRA mcv_y1_done                        ; always
.else
   LDA #0
   STA zp_line_yl_h
   BEQ mcv_y1_done
.endif
mcv_y1_neg:
   LDA zp_line_yr_h                        ; y1 above: y2 also above → out
   BMI mcv_rej
   ZERO zp_line_yl_l, zp_line_yl_h

mcv_y1_done:
; clamp y2
   LDA zp_line_yr_h
   BEQ mcv_y2_done
   BMI mcv_y2_neg
   LDA #$FF
   STA zp_line_yr_l
.if ::C02
   STZ zp_line_yr_h
   BRA mcv_y2_done                        ; always
.else
   LDA #0
   STA zp_line_yr_h
   BEQ mcv_y2_done
.endif
mcv_y2_neg:
   ZERO zp_line_yr_l, zp_line_yr_h

mcv_y2_done:
; clamped to a point (one end was AT the boundary) → reject, exactly
; as the generic post-clip degen check does
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BEQ mcv_rej
; all-u8 vertical; disarmed, so no flush is owed (DCLV_S16VY holds the
; $80 written at entry — same state the fast-u8 path leaves)
   JMP draw_clipped_line
mcv_rej:
   RTS

mc_ordered:
; ---- Quick reject: both endpoints on the same side of any edge ----
; Both x < 0?  hi byte negative for both means both < 0 (s16).
   LDA zp_line_xl_h                        ; (lo-differ path reloads; the
mc_ordered_noreload:                       ; hi-differ BNE has xl_h live)
   BPL x1_in_or_big
   LDA zp_line_xr_h
   BPL not_both_xneg
   JMP dcl_rec_s16r_flush
x1_in_or_big:
; zp_line_xl_h ≥ 0. Check if zp_line_xl_l/HI > 255 (i.e. HI != 0).
   BEQ not_both_xbig                       ; HI = 0 → in [0, 255] (low byte)
; HI > 0 → x1 > 255. Is x2 also > 255?
   LDA zp_line_xr_h
   BMI not_both_xbig
; x2 < 0 → not both > 255
   BEQ not_both_xbig                       ; x2 in [0, 255] → not both > 255
; both > 255
   JMP dcl_rec_s16r_flush
not_both_xneg:
not_both_xbig:
; ---- OFF-IN-X-ONLY LEAN LANE (2026-08-25, Eben's spot; census 67% of
; slow-path lines). Both ys already u8: every crossing y is BOUNDED by
; the endpoint ys (a rounded convex combination of two u8s stays in
; u8), so the y-clip machinery — re-snap, band tests, verdict flats,
; the S16VY pend, the post-clip rechecks — provably cannot fire. Clip
; x with the same s16_interp arithmetic and dispatch straight to u8.
   LDA zp_line_yl_h
   ORA zp_line_yr_h
   BNE mc_notxonly
   JMP mc_xonly
mc_notxonly:
; same for y — RECORDS-OFF ONLY: with records on, a both-out line falls
; through so the post-x-clip census emits its flat verdict record with
; u8 x values (aperture fix part 2); records-off keeps the cheap reject.
   LDA zp_line_yl_h
   BPL y1_in_or_big
   LDA zp_line_yr_h
   BPL not_both_yneg
   BIT FW_MODE                             ; armed: keep the flat verdict
   BMI not_both_yneg
   JMP dcl_rec_s16r_flush
y1_in_or_big:
   BEQ not_both_ybig
   LDA zp_line_yr_h
   BMI not_both_ybig
   BEQ not_both_ybig
   BIT FW_MODE
   BMI not_both_ybig
   JMP dcl_rec_s16r_flush
not_both_yneg:
not_both_ybig:

; ---- Skip x-clip path entirely if both x already in u8 ----
; (We got here because at least one HI byte is non-zero; might be y.)
   LDA zp_line_xl_h
   ORA zp_line_xr_h
   BNE need_xclip
   JMP skip_xclip
need_xclip:

; ---- Save originals for x-clip interp (only when needed) ----
   LDA zp_line_xl_l
   STA LC_OX1_LO
   LDA zp_line_xl_h
   STA LC_OX1_HI
   LDA zp_line_yl_l
   STA LC_OY1_LO
   LDA zp_line_yl_h
   STA LC_OY1_HI
   LDA zp_line_xr_l
   STA LC_OX2_LO
   LDA zp_line_xr_h
   STA LC_OX2_HI
   LDA zp_line_yr_l
   STA LC_OY2_LO
   LDA zp_line_yr_h
   STA LC_OY2_HI

; ---- X clip ----
; If x1 < 0, replace y1 with y at x=0; x1 = 0.
; Else if x1 > 255, replace y1 with y at x=255; x1 = 255.
   LDA zp_line_xl_h
   BPL x1_not_neg
   ZERO LC_TGT_LO

   JSR s16_interp
; store the UNCLAMPED crossing Y (LC_RES), not the u8-clamped A: if the
; y-crossing at the x-boundary is itself out of [0,255] the later y-clip
; must still fire. Storing clamped A here zeroed Y_HI, skipped the y-clip,
; and emitted the screen CORNER (wrong slope) — 994,-3291,237 bottom seg.
   LDA LC_RES_LO
   STA zp_line_yl_l
   LDA LC_RES_HI
   STA zp_line_yl_h
   ZERO zp_line_xl_l, zp_line_xl_h

   JMP x1_done
x1_not_neg:
   BEQ x1_done                             ; HI=0 → in u8 range, no clip
   LDA #$FF
   STA LC_TGT_LO
   JSR s16_interp
; store the UNCLAMPED crossing Y (LC_RES), not the u8-clamped A: if the
; y-crossing at the x-boundary is itself out of [0,255] the later y-clip
; must still fire. Storing clamped A here zeroed Y_HI, skipped the y-clip,
; and emitted the screen CORNER (wrong slope) — 994,-3291,237 bottom seg.
   LDA LC_RES_LO
   STA zp_line_yl_l
   LDA LC_RES_HI
   STA zp_line_yl_h
   LDA #$FF
   STA zp_line_xl_l
   ZERO zp_line_xl_h
x1_done:
; same for x2
   LDA zp_line_xr_h
   BPL x2_not_neg
   ZERO LC_TGT_LO

   JSR s16_interp
; store UNCLAMPED crossing Y (see zp_line_yl_l note above).
   LDA LC_RES_LO
   STA zp_line_yr_l
   LDA LC_RES_HI
   STA zp_line_yr_h
   ZERO zp_line_xr_l, zp_line_xr_h

   JMP x2_done
x2_not_neg:
   BEQ x2_done
   LDA #$FF
   STA LC_TGT_LO
   JSR s16_interp
; store UNCLAMPED crossing Y (see zp_line_yl_l note above).
   LDA LC_RES_LO
   STA zp_line_yr_l
   LDA LC_RES_HI
   STA zp_line_yr_h
   LDA #$FF
   STA zp_line_xr_l
   ZERO zp_line_xr_h
x2_done:
skip_xclip:

; ---- Quick reject after x-clip (y might still be out same side) ----
   LDA zp_line_yl_h
   BPL y1_after_in_or_big
   LDA zp_line_yr_h
   BPL not_both_yneg2
   LDA #0                                  ; whole line above the band
   JSR dcl_rec_flat_line
   JMP dcl_rec_s16r_flush
y1_after_in_or_big:
   BEQ not_both_ybig2
   LDA zp_line_yr_h
   BMI not_both_ybig2
   BEQ not_both_ybig2
   LDA #$FF                                ; whole line below the band
   JSR dcl_rec_flat_line
   JMP dcl_rec_s16r_flush
not_both_yneg2:
not_both_ybig2:

; ---- If both y already in u8, skip y-clip ----
   LDA zp_line_yl_h                        ; OR-fused zero pair (2026-08-11,
   ORA zp_line_yr_h                        ;  the vs_fresh idiom): both u8
   BNE need_yclip                          ;  iff the OR is zero; A dead on
   JMP y_in_range                          ;  both arms (y_in_range out of
need_yclip:                                ;  BEQ range by 53 — measured)
; Re-snap originals to post-x-clip values; for y-clip, axes swap:
; OX* now holds the FREE axis (y), OY* the TARGET (x).
   LDA zp_line_yl_l
   STA LC_OX1_LO
   LDA zp_line_yl_h
   STA LC_OX1_HI
   LDA zp_line_xl_l
   STA LC_OY1_LO
   LDA zp_line_xl_h
   STA LC_OY1_HI
   LDA zp_line_yr_l
   STA LC_OX2_LO
   LDA zp_line_yr_h
   STA LC_OX2_HI
   LDA zp_line_xr_l
   STA LC_OY2_LO
   LDA zp_line_xr_h
   STA LC_OY2_HI

; y1 clip
   LDA zp_line_yl_h
   BPL y1c_not_neg
   ZERO LC_TGT_LO

   JSR s16_interp
   STA zp_line_xl_l
   ZERO zp_line_xl_h, zp_line_yl_l, zp_line_yl_h                          ; A still 0

   BIT FW_MODE
   BPL y1c_done
   LDA #0                                  ; [orig xl, xl] exited via TOP
   JSR dcl_rec_flat_y1
   JMP y1c_done
y1c_not_neg:
   BEQ y1c_done
   LDA #$FF
   STA LC_TGT_LO
   JSR s16_interp
   STA zp_line_xl_l
   ZERO zp_line_xl_h
   LDA #$FF
   STA zp_line_yl_l
   ZERO zp_line_yl_h
   BIT FW_MODE
   BPL y1c_done
   LDA #$FF                                ; [orig xl, xl] exited via BOTTOM
   JSR dcl_rec_flat_y1
y1c_done:
; y2 clip
   LDA zp_line_yr_h
   BPL y2c_not_neg
   ZERO LC_TGT_LO

   JSR s16_interp
   STA zp_line_xr_l
   ZERO zp_line_xr_h, zp_line_yr_l, zp_line_yr_h, DCLV_S16VY                          ; A still 0...

                                        ; pend 0 (order: after walk recs)
   JMP y2c_done
y2c_not_neg:
   BEQ y2c_done
   LDA #$FF
   STA LC_TGT_LO
   JSR s16_interp
   STA zp_line_xr_l
   ZERO zp_line_xr_h
   LDA #$FF
   STA zp_line_yr_l
   ZERO zp_line_yr_h
   LDA #$FF                                ; [xr, orig xr] exited via BOTTOM
   STA DCLV_S16VY
y2c_done:
y_in_range:

; ---- Order/copy/degen handled by wrapper for input; clipping in
; this slow path could shrink the line to a point, so check that
; one case before dispatching. zp_line_* already holds the clipped
; values (written in place by the clip steps above — the old LC_*_LO
; alias layer was removed 2026-07-10).
; NB the "bail" margin note on the BNE below is stale (2026-07-12):
; rsac_noreload SWAPS the endpoints and still emits — see
; its own comment.
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BCC dispatch_dcl
   BNE rsac_noreload                       ; clipping reordered: bail (rare)
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BEQ rejected
dispatch_dcl:
   BIT FW_MODE
   BMI dd_fused
   JSR draw_clipped_line
   JMP dcl_rec_s16r_flush
dd_fused:
   JSR fw_walk_line
   JMP dcl_rec_s16r_flush
; Post-clip x1 > x2 — would require swap; just emit reordered. (The
; rejected_swap_after_clip reload head DELETED 2026-08-12: zero
; references — the BNE enters at rsac_noreload with xl_l riding A —
; and the JMP above blocks fall-through.)
rsac_noreload:
   LDX zp_line_xr_l
   STX zp_line_xl_l
   STA zp_line_xr_l
   LDA zp_line_yl_l
   LDX zp_line_yr_l
   STX zp_line_yl_l
   STA zp_line_yr_l
   BIT FW_MODE
   BMI rsac_fused
   JSR draw_clipped_line
   JMP dcl_rec_s16r_flush
rsac_fused:
   JSR fw_walk_line
   JMP dcl_rec_s16r_flush
; `rejected` is now reached ONLY by the BEQ above — a branch cannot span
; the distance to dcl_rec_s16r_flush, so the trampoline stays for it.
; Its six JMP callers were retargeted straight at the destination
; (tools/jumpscan.py: JMP landing on another JMP), saving 3 cycles each.
; The reason it exists is unchanged: pending may be armed even when the
; in-band piece degenerated.
rejected:
   JMP dcl_rec_s16r_flush                  ; pending may be armed even when
                                        ; the in-band piece degenerated
.endscope

; ============================================================================
; mc_xonly — the off-in-x-only lean lane. Entry: ordered s16 line, both
; y hi bytes ZERO, at least one x hi byte nonzero, not both-left/right
; (the quick rejects above ran). Same save-originals + s16_interp
; arithmetic as the general arms; the result y stores are LEAN (A is
; the crossing y, provably u8; the hi bytes are already zero).
; ============================================================================
mc_xonly:
.scope
   LDA zp_line_xl_l                        ; originals for BOTH interps
   STA LC_OX1_LO                           ; (clipping x1 overwrites the
   LDA zp_line_xl_h                        ;  line x2's interp still needs)
   STA LC_OX1_HI
   LDA zp_line_yl_l
   STA LC_OY1_LO
   ZERO LC_OY1_HI
   LDA zp_line_xr_l
   STA LC_OX2_LO
   LDA zp_line_xr_h
   STA LC_OX2_HI
   LDA zp_line_yr_l
   STA LC_OY2_LO
   ZERO LC_OY2_HI
; x1 arm
   LDA zp_line_xl_h
   BPL xo_x1_notneg
   ZERO LC_TGT_LO
   JSR s16_interp                          ; A = y at x=0 (u8: bounded)
   STA zp_line_yl_l
   ZERO zp_line_xl_l, zp_line_xl_h
   JMP xo_x2
xo_x1_notneg:
   BEQ xo_x2                               ; hi 0: x1 in range
   LDA #$FF
   STA LC_TGT_LO
   JSR s16_interp
   STA zp_line_yl_l
   LDA #$FF
   STA zp_line_xl_l
   ZERO zp_line_xl_h
xo_x2:
   LDA zp_line_xr_h
   BPL xo_x2_notneg
   ZERO LC_TGT_LO
   JSR s16_interp
   STA zp_line_yr_l
   ZERO zp_line_xr_l, zp_line_xr_h
   JMP xo_disp
xo_x2_notneg:
   BEQ xo_disp
   LDA #$FF
   STA LC_TGT_LO
   JSR s16_interp
   STA zp_line_yr_l
   LDA #$FF
   STA zp_line_xr_l
   ZERO zp_line_xr_h
xo_disp:
; all-u8 now; order preserved (0 <= u8 <= 255 cannot reverse). The
; degenerate/vertical classify is dcl16_fastu8's, armed or not
; (verticals are plot-only either way); no pend is owed here.
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BNE xo_line
   JMP dcl16_fastu8                        ; vertical/point classify
xo_line:
   BIT FW_MODE
   BMI xo_armed
   JMP draw_clipped_line
xo_armed:
   JMP fw_walk_line
.endscope

; ============================================================================
; Part 2 of the off-screen-aperture fix (2026-07-13): the s16 band clip
; emits FLAT VERDICT records (0 'above' / $FF 'below') for the y-band-
; clipped-away portions of an aperture edge, so the tighten keeps the
; memory that the edge exists out there. Wrappers live in LO (main RAM,
; always mapped); dcl_rec_flat gates on records mode and merges.
; ============================================================================
SEG_HIGH
dcl_rec_flat_line:                         ; whole clipped line [xl_l, xr_l]
   STA DCLV_YV
   LDA zp_line_xl_l
   STA DCLV_X0
   LDA zp_line_xr_l
   STA DCLV_X1
   LDA DCLV_YV
   JMP dcl_rec_flat

dcl_rec_flat_y1:                           ; left clip-off [orig xl, new xl]
   STA DCLV_YV
   LDA LC_OY1_LO
   STA DCLV_X0
   LDA zp_line_xl_l
   STA DCLV_X1
   LDA DCLV_YV
   JMP dcl_rec_flat

dcl_rec_s16r_flush:                        ; right clip-off [new xr, orig xr]
   LDA DCLV_S16VY
   CMP #$80
   BEQ s16r_done
   STA DCLV_YV
   LDA #$80
   STA DCLV_S16VY                          ; consume the pending
   LDA zp_line_xr_l
   STA DCLV_X0
   LDA LC_OY2_LO
   STA DCLV_X1
   LDA DCLV_YV
   JMP dcl_rec_flat
s16r_done:
   RTS
SEG_BANKC
end_code:
.if ::BANKED
; (output file: ld65 writes the CLIP_BK region ($8000) to
;  span_clip_bankc.bin — engine_banked.cfg MEMORY entry; the SAVE
;  directive of the old beebasm build is gone)
.else
; (output file: ld65 writes the CLIPJT+CLIP regions ($2000/$2030) to
;  span_clip.bin — engine_flat.cfg MEMORY entries)
.endif
