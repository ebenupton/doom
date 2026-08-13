
; ============================================================================
; render_subsector — THE SEG LOOP: process one subsector.
;   Input: zp_node_ch_l:hi = subsector id (high bit cleared).
;   Caller: the BSP walk (bsp/walk.s) through the anim_ss_hook JMP below.
;
;   Per-seg order of battle (each stage's owner file in brackets;
;   stages 2-8 live in bsp/seg_emit.s since the 2026-08-09 file split —
;   this file holds the prologue + loop head + back-face dispatch):
;     1. Back-face test [backface.s] — tail-dispatched: JMPs to
;        ::bf_seg_front here or straight to ::s_advance on a back seg.
;     2. Vertex pipeline per endpoint [seg_xform.s]: chain reuse, frame
;        vcache, VXC coherence cache, or full fetch+rotate; results land
;        in the endpoint structs VX1/VX2 (zp.inc, stride 15).
;     3. Near-plane crossing resolution [resolve_crossing.s].
;     4. Fused has_gap range prelude + cull (clipper jt) — culled segs
;        stop HERE: Y is never projected for them (deferral, 2026-07-11).
;     5. y_stage below: PAGE L2 once, project flag-gated sy pairs via
;        do_project_y [seg_project.s] through the VWHC memo [project.s];
;        chain donates the previous v2's front pair when valid.
;     6. apv_stage [lo.s]: aperture-vertical pairs, post-visibility.
;     7. Endpoint canonicalization: THE SEG LAYER OWNS LEFT-TO-RIGHT —
;        seg_swap_vx deep-swaps the structs on the rare reversal and
;        kills the chain key (the s16 clipper no longer sorts).
;     8. Emission: ft/fb/bt/bb horizontals via draw_clipped_line_s16_h (X = the
;        sy-pair struct offset), NOVT/APEDGE-gated verticals, then a
;        deferred solid/tighten op is queued [defq.s].
;
; Python mirror: packed_render_subsector + packed_render_seg
; (doom_wireframe.py). Per-subsector pseudocode:
;   count, hdr_ptr = SS_CNT[idx], SS_PLO/PHI[idx] (baked pointer)
;   defq = []                                  # DEFQ op queue, seg order
;   for si in range(first, first + count):
;     hdr = seg_hdr[si]                        # 16-byte header, ROM
;     if back_face(hdr): continue
;     xform v1, v2 (vcache'd); near-clip; project sx1/sx2 (s16)
;     if both endpoints off one screen side: continue
;     if not has_gap(clamp8(sx), clamp8(sx')): continue
;     project sy pairs (deferred to here); swap endpoints if reversed
;     emit flag-gated lines (draw_clipped_line_s16, records routed via $BC/$BD):
;       front top/bottom horizontals, back-step horizontals,
;       endpoint verticals, aperture-edge verticals
;     defq.append(solid(ilo,ihi) | tighten(ilo,ihi + records snapshot))
;   defq_drain()                               # mark_solid / tighten, in order
;
; Line emission contract (clipper interface):
;   zp_line_xl_l/yl/xr/yr ($A8-$AB) = endpoint lo bytes,
;   $B2-$B5 (zp_line_xl_h..zp_line_yr_h)  = endpoint s16 hi bytes → draw_clipped_line_s16.
;   $BC/$BD (zp_dcl_rec_buf) = per-span records buffer: hi byte $00 =
;   records off, $07 → TOP_RECORDS ($0700), $08 → BOT_RECORDS ($0800).
;   $C2/$C3 (zp_i_l/zp_i_h) = column range for has_gap / defq ops.
;
; Deferral (why not apply at seg end): Python defers both mark_solid and
; tighten to subsector end IN SEG ORDER — applying a tighten immediately
; would mutate spans before an earlier sibling's mark_solid and shift
; span anchors. Records are snapshotted into the queue because later
; segs' DCL emission overwrites TOP/BOT_RECORDS before the drain.
; ============================================================================
render_subsector_entry:                 ; harness entry: bank unknown
   PAGE BANK_WALK                          ; ss SoA pages ride the walk bank
render_subsector:
; (walk callers arrive WALK-paged — near/far child follows page WALK)
.scope
; (The write-only visited-bitmap instrumentation is GONE, 2026-07-15:
; nothing anywhere read it — dead scaffolding taxing every flat
; subsector serve, and the reason $0A80 meant two things across
; builds.)

; --- Read subsector header (SoA pages: count / seg-header pointer) ---
   LDX zp_node_ch_l
   LDA SS_CNT,X
   STA zp_seg_count

; Persistent per-seg pointer, advanced by the loop (+16). The si*16
; shift chain is baked into the SS pointer pages at pack time (first*16,
; loader-rebased onto ROM_SEG_HDR): two indexed loads, no address
; generation (2026-07-15).
   LDA SS_PLO,X
   STA zp_seg_hdr_p
   LDA SS_PHI,X
   STA zp_seg_hdr_p_h
   PAGE BANK_SEG                           ; headers / verts / VWHC bank —
                                        ; held through seg stages 1-4
; Animated-sector hook: anim_init retargets this JMP at anim_hub, which
; lazily patches any dirty mover with segs in this subsector (headers +
; FHCH quads live in bank SEG — the hook runs under it, and BEFORE the
; fh/ch reads below so mover-patched heights are already in place).
; Disabled (default) it falls straight through: 3 cycles.
::anim_ss_hook:
   JMP anim_ss_cont
::anim_ss_cont:
; --- Front heights are SUBSECTOR-CONSTANT (every seg fronts this
; subsector's sector), so read fh/ch + compute the front deltas ONCE
; here instead of per seg (2026-07-10; runs after the anim hub, so
; mover-patched heights are already in place). ---
   LDY #11
   LDA (zp_seg_hdr_p),Y                     ; ch (header +11)
   STA zp_seg_ch
   SEC
   SBC zp_br_vz
   STA zp_seg_top_dlt                       ; top_dlt = ch - vz
   DEY
   LDA (zp_seg_hdr_p),Y                     ; fh (header +10)
   STA zp_seg_fh
   SEC
   SBC zp_br_vz
   STA zp_seg_bot_dlt                       ; bot_dlt = fh - vz
; Subsector eyeline rule (Eben, 2026-08-13): ceiling at/below the
; sightline => NO top edges this subsector; floor at/above => NO
; bottom edges. One byte, BIT-shaped: N ($80) kills ft, V ($40)
; kills fb — the ft/fb arm heads test it in 5 cycles.
   LDX #0
   LDA zp_seg_top_dlt                       ; ch - vz
   BMI ss_esk_t                             ; <= 0: ceiling at/below eye
   BNE ss_esk_tok
ss_esk_t:
   LDX #$80
ss_esk_tok:
   LDA zp_seg_bot_dlt                       ; fh - vz
   BMI ss_esk_done                          ; < 0: floor below eye — live
   TXA
   ORA #$40
   TAX
ss_esk_done:
   STX zp_ss_eskip
; Invalidate the vertex-chain key at the subsector boundary: chained
; front-sy reuse needs the SAME front heights, only guaranteed within
; one subsector.  The chain compares the LO byte only (2026-08-13):
; $FF matches no vertex (pack sentinel reservation).
   LDX #$FF
   STX zp_seg_v_idx_l
   INX
   STX zp_ys_done                           ; no cross-subsector sy donation
   STX zp_ys_v1ok

; (DEFQ retired 2026-07-16: clip ops apply IMMEDIATELY at seg end —
;  convex siblings only collide at shared edge columns, which is
;  exactly the portal-edge-vertical artifact this fixes; the record
;  snapshots died with it. Eben's call.)

; --- Loop over segs ---
seg_loop:
   LDA zp_seg_count
   BNE seg_proc
sl_rts:
   RTS                                     ; empty subsector
; Backface back-exit advance twin (hoisted from seg_emit.s 2026-08-13):
; single entry (backface.s JMPs), never left bank SEG, and it FALLS
; into seg_proc — the 57%-majority arc pays no jump at all now.
::s_advance_l0:
   CLC
   LDA zp_seg_hdr_p
   ADC #16
   STA zp_seg_hdr_p
   DEC zp_seg_count
   BEQ sl_rts
::seg_proc:                             ; global: the advance tails in
                                        ; seg_emit.s loop back here
; (no PAGE: every arrival is L0-proven — the prologue paged L0 for the
;  first seg; s_advance pages L0 on its off-bank arcs; backface culls
;  (the majority back-edge, 57% of iterations) read headers under L0
;  and enter via s_advance_l0 without ever leaving. 2026-07-21 grind.)
; (Records reset MOVED to hg_pass 2026-07-11: the count bytes' only
; reader is ms_dispatch, which runs post-visibility — culled segs paid
; four dead stores each. rec_buf lo is zeroed once per frame in
; br_init_frame (nothing ever writes it non-zero) and the per-seg _h
; disarm is gone: every DCL call site arms/disarms explicitly.)

; --- seg header via the persistent pointer. Flags first; v1/v2 keys
; (offsets 0-3) are only read after the back-face test passes —
; back-facing segs never need them. ---
; 16-byte header layout (wad_packed.py SH_*, stride 16 since 2026-07-11):
;   +0/+1  v1 key: A = idx&255, B = idx>>3 (NOT lo/hi — see seg_xform.s)
;   +2/+3  v2 key (same encoding)
;   +4     back-face form: 0-3 = axis compare (px>C, px<C, py>C, py<C),
;          >= 4 = diagonal, (form-4) indexes the DIR tables
;   +5/+6  axis: C16 compare constant | diagonal: lv1x s16
;   +7     diagonal: lv1y lo (hi is at +9 — split around flags)
;   +8     flags (see below)
;   +9     axis: unused pad | diagonal: lv1y hi
;   +10..15 heights, baked by the packer: fh, ch, then per-form:
;          solid+APEDGE: bfh|apv1_ch, bch|apv1_fh, apv2_ch, apv2_fh
;          portal:       bfh, bch (back floor/ceiling), rest unused
; Flags: $80 SAMEDIR (folded into the DIR sign at PACK time — the test
; itself never reads it), $02 SOLID, $04 NEEDBT (back ceil below front),
; $08 NEEDBB (back floor above front), $10/$20 NOVT1/2 (suppress endpoint
; vertical), $40/$01 APEDGE1/2 (aperture edge at that end).
; Stage ONLY flags (reused all over the seg loop AND across the DCL emit
; calls that clobber registers — it must live in ZP). Everything else is
; read ON DEMAND via (zp_seg_hdr_p),Y — the persistent cursor is already
; a ZP pointer, so no copy into zp_br_p is needed (2026-07-09).
   LDY #8
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_flags

; --- Back-face test: TAIL-DISPATCHED (2026-07-11). Single caller, so
; the test JMPs straight to bf_seg_front / bf_seg_back instead of
; returning a Z verdict — no JSR/RTS, no verdict LDA, no re-branch.
   JMP back_face_test
; (bf_seg_back trampoline deleted 2026-07-12: back-exits in backface.s
; JMP ::s_advance directly — one hop, not two, per back-facing seg)

; --- The seg pipeline CONTINUES in bsp/seg_emit.s --- backface.s JMPs
; into ::bf_seg_front / ::s_advance_l0 there and the advance tails loop
; back to ::seg_proc above. Split 2026-08-09 so the file-level call
; graph is acyclic (subsector -> backface -> seg_emit, edges pure L-R);
; seg_emit.s is included IMMEDIATELY after this file, so the emitted
; bytes are IDENTICAL to the pre-split layout.
.endscope
