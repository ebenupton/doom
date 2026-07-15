
; ============================================================================
; br_render_subsector — THE SEG LOOP: process one subsector.
;   Input: zp_node_ch_l:hi = subsector id (high bit cleared).
;   Caller: the BSP walk (bsp/walk.s) through the anim_ss_hook JMP below.
;
;   Per-seg order of battle (each stage's owner file in brackets):
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
;     8. Emission: ft/fb/bt/bb horizontals via SC_DRAW_S16_H (X = the
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
;     emit flag-gated lines (SC_DRAW_S16, records routed via $BC/$BD):
;       front top/bottom horizontals, back-step horizontals,
;       endpoint verticals, aperture-edge verticals
;     defq.append(solid(ilo,ihi) | tighten(ilo,ihi + records snapshot))
;   defq_drain()                               # mark_solid / tighten, in order
;
; Line emission contract (clipper interface):
;   zp_line_xl_l/yl/xr/yr ($A8-$AB) = endpoint lo bytes,
;   $B2-$B5 (zp_line_xl_h..zp_line_yr_h)  = endpoint s16 hi bytes → SC_DRAW_S16.
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
br_render_subsector_jt:                 ; harness entry: bank unknown
   PAGE BANK_L0                            ; ss / seg_hdr / verts / sincos live in bank L0
br_render_subsector:
; (walk callers arrive L0-paged — near/far child follows page L0)
; Animated-sector hook: anim_init retargets this JMP at anim_hub, which
; lazily patches any dirty mover with segs in this subsector (see
; src/bsp/anim.s). Disabled (default) it falls straight through: 3 cycles.
anim_ss_hook:
   JMP anim_ss_cont
anim_ss_cont:
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
; Invalidate the vertex-chain key at the subsector boundary: chained
; front-sy reuse needs the SAME front heights, only guaranteed within
; one subsector. B = idx>>3 <= 58, so $FF never matches a real B byte.
   LDX #$FF
   STX zp_seg_v_idx_b
   INX
   STX zp_ys_done                           ; no cross-subsector sy donation
   STX zp_ys_v1ok

; Reset deferred op queue for this subsector.
   STX DEFQ_TAIL

; --- Loop over segs ---
seg_loop:
   LDA zp_seg_count
   BNE seg_proc
   PAGE BANK_C                             ; defq_drain only does clip ops (bank C)
   JMP defq_drain                          ; subsector done — apply deferred ops
seg_proc:
   PAGE BANK_L0                            ; re-page L0 each seg (prev seg ended in bank C)
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
   JMP br_back_face_test
; (bf_seg_back trampoline deleted 2026-07-12: back-exits in backface.s
; JMP ::s_advance directly — one hop, not two, per back-facing seg)
::bf_seg_front:
; front-facing: fetch v1/v2 straight from the header via zp_seg_hdr_p.

; --- Heights: front fh/ch + deltas were HOISTED to the subsector
; prologue (subsector-constant; every seg fronts this sector). The back
; heights live INLINE in the header at +12..15 (the separate FHCH
; stream retired 2026-07-11):
;     [+10 fh, +11 ch, +12 bfh|apv1_ch, +13 bch|apv1_fh,
;      +14 apv2_ch, +15 apv2_fh].
; Back-delta staging is DEFERRED into the post-has_gap y stage
; (2026-07-11) — culled portals never pay the header reads. ---

; --- Transform + project both endpoints (br_seg_xform_vertex:
; vcache-backed br_to_view, near-plane test, X projection, Y projections
; for the edges this seg's flags need; sets zp_seg_skip=1 if the vertex
; is behind the near plane, else writes sx/sy straight into this endpoint's
; slots via zp_seg_ep). Transform v1. Always copy evy/evx/clipped so both
; endpoints are available for near-plane crossing math even when clipped.
   LDY #0
   STY zp_seg_ep                            ; v1 → struct VX1
; --- VERTEX CHAIN (2026-07-10): if this seg's v1 is the vertex the LAST
; transform produced (zp_seg_v_idx still holds it, and VX2 still holds
; its outputs), reuse VX2 wholesale: evy/evx/clip always; sx, the front
; sy pair (same subsector => same fh/ch) and rhi/rlo when unclipped.
; The packer chain-orders subsector segs, so this hits ~80% of
; consecutive front-facing pairs. zp_seg_v_idx_b is invalidated at the
; subsector boundary and when a crossing overwrites VX2.
   LDA (zp_seg_hdr_p),Y
   CMP zp_seg_v_idx_l
   BNE ch_miss1                            ; A = header idx_l
   INY
   LDA (zp_seg_hdr_p),Y
   CMP zp_seg_v_idx_b
   BNE ch_miss2                            ; A = header idx_b; idx_l equal
; chain hit: the copy + back-pair body lives in LO (MAIN is at its
; ceiling); ~12 cyc JSR/RTS tax. chain_reuse_v1 consumes zp_ys_done
; (prev seg y-staged => VX2's front sy pair is live => copy it and set
; zp_ys_v1ok so the y stage skips v1's front projection).
   JSR chain_reuse_v1
   LDA #0
   STA zp_ys_done                           ; consumed (chain) — reset for
   BEQ ch_v1_done                           ; THIS seg's own y stage
ch_miss1:                                  ; A = header idx_l (Y = 0)
   STA zp_seg_v_idx_l
   INY
   LDA (zp_seg_hdr_p),Y
ch_miss2:                                  ; A = header idx_b
   LDX #0
   STX zp_ys_done                           ; prev-seg donation dies here
   STX zp_ys_v1ok
   STA zp_seg_v_idx_b                      ; CONTRACT: A = B at entry —
   JSR br_seg_xform_vertex                  ; keep this STA immediately before
; (no marshalling: evy/evx/clip/sx/recip all landed in VX1 directly)
ch_v1_done:

; Transform v2.
   LDA #VX_STRIDE
   STA zp_seg_ep                            ; v2 → struct VX2
   PAGE BANK_L0                             ; v1's projection paged L2 (br_
; project_y / br_recip) unless v1 was near-clipped — the header read below
; needs the L0 window back. Flat: no-op.
   LDY #2
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_v_idx_l
   INY
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_v_idx_b                      ; CONTRACT: A = B at entry —
   JSR br_seg_xform_vertex                  ; keep this STA immediately before
; (no marshalling — see v1)

; --- Near-plane clip resolution (mirrors fp_near_clip in fp.py) ---
; Both vertices xform'd. If both clipped → bail. If exactly one clipped,
; reproject from crossing point and copy into that vertex's slots.
; (reproject_at_crossing computes the vy=NEAR crossing from the saved
; v1/v2 view coords and projects it straight into that endpoint's slots
; via zp_seg_ep.)
; Python near-clips ALL front-facing segs (fp_near_clip), so solid
; walls reproject too — their clamped mark_solid range comes from the
; crossing projection (e.g. mark_solid(0,81) from sx=-2176 at
; (800,-3400,96); bailing solids loses that occlusion entirely).
   LDA zp_seg_v1_clipped
   ORA zp_seg_v2_clipped
   BEQ s_both_have_proj
   LDA zp_seg_v1_clipped
   BEQ s_v2_was_clipped
   LDA zp_seg_v2_clipped
   BNE s_advance_jmp                       ; both clipped
   LDA #0
   STA zp_seg_ep                            ; reproject into v1 (struct VX1)
   JSR reproject_at_crossing
   JMP s_both_have_proj
s_advance_jmp:
   JMP s_advance
s_v2_was_clipped:
   LDA #VX_STRIDE
   STA zp_seg_ep                            ; reproject into v2 (struct VX2)
   JSR reproject_at_crossing
   LDA #$FF
   STA zp_seg_v_idx_b                      ; VX2 now holds the CROSSING, not
                                        ; the vertex — kill the chain key
s_both_have_proj:

; Match Python's has_gap wrapper:
;   ilo = max(0, min(sx1,sx2)); ihi = min(255, max(sx1,sx2))
;   bail if the range is empty (whole seg off one side of the screen)
; Order the s16 endpoints FIRST — clamp8 is monotone, so order-then-clamp
; equals clamp-then-order — then ONE hi-byte test per endpoint does both
; the off-screen bail and the clamp:
;   max hi: BMI = whole seg left of screen; BNE = ihi clamps 255; else
;           the low byte IS ihi.
;   min hi: zero = low byte IS ilo; BMI = ilo clamps 0; else min >= 256,
;           whole seg right of screen (matches the old both-hi>=1 bail,
;           since min >= 256 forces max >= 256).
; The min endpoint's struct offset (0 = sx1, VX_STRIDE = sx2) is latched
; in zp_sx_ord at hg_query so the mark_solid/tighten range below the
; emits can re-derive its clamps without repeating the s16 compare
; (sx1/sx2 survive the emits; the u8 scratch does not). X is dead here:
; nothing carries X across the SC_HAS_GAP JSR.
; FUSED order + clamp analysis (2026-07-11): both decisions key off the
; hi bytes. EQUAL hi bytes (the common case) collapse everything:
;   zero    -> both endpoints in [0,255]: the lo bytes ARE the range and
;              one unsigned lo compare is the order;
;   nonzero -> both endpoints share an off-screen page (both < 0 or both
;              >= 256): bail, no clamps needed.
; Only page-straddling segs (hi bytes differ) take the full s16 order +
; per-endpoint ladder path below.
   LDA zp_seg_sx1_h
   CMP zp_seg_sx2_h
   BNE hg_hi_diff
   TAX                                     ; shared hi byte
   BNE hg_adv                              ; nonzero: off one side entirely
   LDA zp_seg_sx1_l
   CMP zp_seg_sx2_l
   BEQ hg_fast_fwd                         ; TIE: a one-column seg is NOT
                                        ; reversed (it must draw + record;
                                        ; the old ties->rev was harmless
                                        ; only while rev meant SWAP)
   BCS hg_fast_rev                         ; sx1 > sx2: reversed -> DROP
hg_fast_fwd:
; X = 0 already: the TAX above saw A = 0 (BNE not taken)
   STA zp_i_l                              ; A = sx1_lo
   LDA zp_seg_sx2_l
   STA zp_i_h
   JMP hg_query
hg_fast_rev:
   LDX #VX_STRIDE
   STA zp_i_h                              ; A = sx1_lo from the compare
   LDA zp_seg_sx2_l
   STA zp_i_l
   JMP hg_query
hg_hi_diff:
; hi bytes differ: signed hi-byte difference gives the order (lo bytes
; only ever break ties, and ties took the equal path above)
; (A = sx1_h from the entry compare; SEC stays — CMP's carry varies)
   SEC
   SBC zp_seg_sx2_h
   BVC hgd_v_ok
   EOR #$80
hgd_v_ok:
   BPL hg_min2                             ; sx1 >= sx2
; --- min = sx1, max = sx2 ---
hg_min1:
   LDX #0
   LDA zp_seg_sx2_h                       ; max hi
   BMI hg_adv                              ; max < 0: off-screen left
   BNE hg_hi255_1                          ; max >= 256: ihi = 255
   LDA zp_seg_sx2_l
hg_hist1:
   STA zp_i_h
   LDA zp_seg_sx1_h                       ; min hi
   BNE hg_lock1                            ; nonzero: neg -> 0 / pos -> bail
   LDA zp_seg_sx1_l
hg_lost1:
   STA zp_i_l
   JMP hg_query
hg_hi255_1:
   LDA #255
   BNE hg_hist1                            ; (always: A=255)
hg_lock1:
   BPL hg_adv                              ; min >= 256: off-screen right
   LDA #0
   BEQ hg_lost1                            ; (always: A=0)
hg_adv:
   JMP s_advance
hg_hi255_2:
   LDA #255
   BNE hg_hist2                            ; (always: A=255)
hg_lock2:
   BPL hg_adv                              ; min >= 256: off-screen right
   LDA #0
   BEQ hg_lost2                            ; (always: A=0)
; --- min = sx2, max = sx1 ---
hg_min2:
   LDX #VX_STRIDE
   LDA zp_seg_sx1_h                       ; max hi
   BMI hg_adv                              ; max < 0: off-screen left
   BNE hg_hi255_2                          ; max >= 256: ihi = 255
   LDA zp_seg_sx1_l
hg_hist2:
   STA zp_i_h
   LDA zp_seg_sx2_h                       ; min hi
   BNE hg_lock2                            ; nonzero: neg -> 0 / pos -> bail
   LDA zp_seg_sx2_l
hg_lost2:
   STA zp_i_l
hg_query:
   STX zp_sx_ord                           ; latch min-endpoint offset
   JSR SC_HAS_GAP                          ; (main-resident — no PAGE)
   BNE hg_pass
   JMP s_advance
hg_pass:
; Records reset for THIS seg (moved from seg_proc): ms_dispatch reads
; the counts only for segs that got here; armed draws re-init them.
   LDA #0
   STA $0700                               ; TOP_RECORDS count
   STA $0800                               ; BOT_RECORDS count
; --- DEFERRED Y PROJECTION (2026-07-11): ALL sy pairs are projected
; HERE, only for segs that passed has_gap — the transform phase now
; computes evy/evx/clip/sx/recip only (measured 11.5k cyc/frame of
; culled-seg projections deleted). Front deltas are subsector-constant;
; portal back deltas are staged just below; each endpoint projects via
; do_project_y with its OWN struct-banked recip (for a near-clipped
; endpoint that is the crossing recip). Runs BEFORE the canonicalizing
; swap so struct identity still equals seg-endpoint identity.
   LDA zp_seg_flags
   AND #$0C                                ; portal steps need back deltas
   BEQ ys_deltas_done
   PAGE BANK_L0
   LDY #13
   LDA (zp_seg_hdr_p),Y                     ; bch (header +13)
   SEC
   SBC zp_br_vz
   STA zp_seg_btop_dlt
   DEY
   LDA (zp_seg_hdr_p),Y                     ; bfh (header +12)
   SEC
   SBC zp_br_vz
   STA zp_seg_bbot_dlt
ys_deltas_done:
   PAGE BANK_L2                             ; ONE page-in serves every
                                        ; projection below (br_project_y
                                        ; no longer re-pages per call)
   LDA zp_ys_v1ok
   BEQ ys_v1_full
; chained v1 with a LIVE front sy pair (copied from the emitted prev
; seg) — only a portal's back pair still needs v1's recip
   LDA zp_seg_flags
   AND #$0C
   BEQ ys_v2
   LDA #0
   STA zp_seg_ep
   LDA zp_seg_v1_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v1_r_s                        ; inlined rns_select (hot site)
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   JSR dpy_back
   JMP ys_v2
ys_v1_full:
   LDA #0
   STA zp_seg_ep                            ; v1 -> struct VX1
   LDA zp_seg_v1_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v1_r_s                        ; inlined rns_select
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   JSR do_project_y
ys_v2:
   LDA #VX_STRIDE
   STA zp_seg_ep                            ; v2 -> struct VX2
   LDA zp_seg_v2_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v2_r_s                        ; inlined rns_select
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   JSR do_project_y
   LDA #1
   STA zp_ys_done                           ; this seg's VX2 sy is live for
   LDA #0                                   ; the next seg's chain
   STA zp_ys_v1ok
; --- Post-visibility APV staging, then endpoint canonicalization ---
   LDA zp_seg_flags
   AND #$02
   BEQ hgp_can                             ; portal: pairs staged above
   LDA zp_seg_flags
   AND #$41                                ; APEDGE1|APEDGE2
   BEQ hgp_can
   JSR apv_stage
hgp_can:
; Canonicalize: after this point VX1 is ALWAYS the left endpoint, and
; every emit path below is single-path (no ord dispatch anywhere).
   LDA zp_sx_ord
   BEQ hgp_fwd
   JMP s_advance                           ; reversed 1px projection: DROP
                                        ; (2026-07-15: seg_swap_vx retired;
                                        ; python mirror returns likewise)
hgp_fwd:

; --- Emit top horizontal (front-sector ceiling): (sx1,ft1)→(sx2,ft2) ---
; Solid wall:        always.
; Portal w/ NEEDBT:  iff ch > vz (face above eyeline, ft visible).
; Portal w/o NEEDBT: iff bch > ch (back ceiling above front; step visible).
; (Python: solid lines[] always includes ft; need_bt inserts ft only when
; ch > vz — the "secondary" front-ceiling above the bt step; the
; bch > ch portal-lip case draws ft with roles={0: TOP_RECORDS}.)
   LDA zp_seg_flags
   AND #$02
   BNE ft_no_rec                           ; SOLID → emit, no records
   LDA zp_seg_flags
   AND #$04
   BEQ ft_no_needbt
; NEEDBT: emit only if ch > vz (s8 compare via signed test on ch - vz).
   LDA zp_seg_ch
   SEC
   SBC zp_br_vz
   BMI ft_skip
   BEQ ft_skip
   BNE ft_no_rec                           ; NEEDBT → emit, no records
                                           ; (A > 0: always taken)
ft_no_needbt:
; bch > ch ? (bch on demand from header +13 — the header lives in the
; L0 window and this path runs under BANK_C, so page around the read;
; flat: no-ops)
   PAGE BANK_L0
   LDY #13
   LDA (zp_seg_hdr_p),Y                     ; bch (header +13)
   SEC
   SBC zp_seg_ch
   TAX                                     ; verdict rides in X: PAGE (banked)
   PAGE BANK_C                             ; is LDA #bank — clobbers A + flags
   TXA
   BMI ft_skip
   BEQ ft_skip
ft_emit:
; Portal-lip (the only fall-in: !SOLID, !NEEDBT, bch>ch): ft IS the new
; top of the aperture — arm TOP_RECORDS. The old AND #$06 re-test was
; decidable at every entrant and is gone: solid/NEEDBT branch straight
; to ft_no_rec above.
   LDA #$07
   STA zp_dcl_rec_buf_h
   LDA #0
   STA $0700                               ; count = 0 (arm-time reset;
                                           ; page-aligned → absolute)
   LDA #1
   STA zp_dcl_rec_off
   BNE ft_set_line                         ; A = 1: always taken
ft_no_rec:
   LDA #0
   STA zp_dcl_rec_buf_h
ft_set_line:
; (rec_buf lo is never non-zero — both record pages are page-aligned;
;  the per-seg prologue zeroes it once. Only _h arms/disarms.)
; Hand off to the horizontal s16 entry: X names the sy pair (same
; offset in both vertex structs); SC_DRAW_S16_H fetches x from
; zp_seg_sx1/sx2 and the y pair from VX1+X/VX2+X itself — no staging
; here at all (the zp_line_* slots don't survive the clipper's
; in-place normalization, so nothing can be seg-hoisted into them).
   LDX #zp_seg_sy1_top_l - VX1            ; sy pair offset (top)
   PAGE BANK_C
   JSR SC_DRAW_S16_H
; (no disarm: every later DCL entry in this seg sets _h itself, and the
;  defq snapshot reads the $0700/$0800 COUNTS, not the pointer)
ft_skip:

; --- Emit bottom horizontal (front-sector floor): (sx1,fb1)→(sx2,fb2) ---
; Solid:             always.
; Portal w/ NEEDBB:  iff fh < vz (face below eyeline, fb visible).
; Portal w/o NEEDBB: iff bfh < fh (back floor below front; step visible).
; (Exact mirror of the top-horizontal logic with floor/bottom roles.)
   LDA zp_seg_flags
   AND #$02
   BNE fb_no_rec                           ; SOLID → emit, no records
   LDA zp_seg_flags
   AND #$08
   BEQ fb_no_needbb
; NEEDBB: emit only if fh < vz (vz - fh > 0).
   LDA zp_br_vz
   SEC
   SBC zp_seg_fh
   BMI fb_skip
   BEQ fb_skip
   BNE fb_no_rec                           ; NEEDBB → emit, no records
                                           ; (A > 0: always taken)
fb_no_needbb:
; bfh < fh ? (bfh on demand from header +12 — L0-window read under
; BANK_C, page around like ft_no_needbt; flat: no-ops)
   PAGE BANK_L0
   LDY #12
   LDA zp_seg_fh
   SEC
   SBC (zp_seg_hdr_p),Y                     ; bfh (header +12)
   TAX                                     ; verdict rides in X across the
   PAGE BANK_C                             ; A-clobbering PAGE (see ft above)
   TXA
   BMI fb_skip
   BEQ fb_skip
fb_emit:
; Mirror of ft_emit: portal-lip only — arm BOT_RECORDS (the AND #$0A
; re-test was decidable at every entrant; solid/NEEDBB branch straight
; to fb_no_rec above).
   LDA #$08
   STA zp_dcl_rec_buf_h
   LDA #0
   STA $0800                               ; count = 0 (arm-time reset)
   LDA #1
   STA zp_dcl_rec_off
   BNE fb_set_line                         ; A = 1: always taken
fb_no_rec:
   LDA #0
   STA zp_dcl_rec_buf_h
fb_set_line:
   LDX #zp_seg_sy1_bot_l - VX1            ; sy pair offset (bot)
   PAGE BANK_C
   JSR SC_DRAW_S16_H
fb_skip:

; --- Portal step edges (back ceiling / floor) ---
; Solid walls have no back sector — skip the step emits.
   LDA zp_seg_flags
   AND #$02
   BEQ step_cont
; SF_SOLID set → skip steps
   JMP step_skip                           ; (trampoline: PAGE inserts
step_cont:                              ;  pushed the branch out of range)

; Back ceiling step if NEEDBT (= $04) set: emit (sx1, bt1) → (sx2, bt2).
; bt is the new TOP of the aperture — populate TOP_RECORDS so the
; tighten_from_records call at end of seg has the right per-span
; verdict data. Matches Python's roles={yt_idx: TOP_RECORDS}.
   LDA zp_seg_flags
   AND #$04
   BEQ step_no_top
   LDX #zp_seg_sy1_btop_l - VX1            ; sy pair offset (btop)
   LDA #$07
   STA zp_dcl_rec_buf_h
   LDA #0
   STA $0700                               ; count = 0 (arm-time reset)
   LDA #1
   STA zp_dcl_rec_off
; TOP_RECORDS = $0700
   PAGE BANK_C
   JSR SC_DRAW_S16_H
step_no_top:

; Back floor step if NEEDBB (= $08) set: emit (sx1, bb1) → (sx2, bb2).
   LDA zp_seg_flags
   AND #$08
   BEQ step_no_bot
   LDX #zp_seg_sy1_bbot_l - VX1            ; sy pair offset (bbot)
   LDA #$08
   STA zp_dcl_rec_buf_h
   LDA #0
   STA $0800                               ; count = 0 (arm-time reset)
   LDA #1
   STA zp_dcl_rec_off
; BOT_RECORDS = $0800
   PAGE BANK_C
   JSR SC_DRAW_S16_H
step_no_bot:
step_skip:

; --- Emit verticals ---
; Solid wall: full ft-to-fb on both sides.
; Portal: ft-to-bt for NEEDBT (top doorframe edge),
;         bb-to-fb for NEEDBB (bottom doorframe edge).
;         Both for NEEDBT+NEEDBB. Otherwise no vertical.
; SF_NOVT1/NOVT2 still suppress verticals at BSP-internal split vertices.
; (Back inline in MAIN since the RNS vectoring moved to the stack page —
; the CEMIT eviction and its per-seg PAGE+JSR cost are gone.)

; Left vertical (sx1).
   LDA zp_seg_flags
   AND #$10
   BNE skip_lvert
   LDA zp_seg_sx1_h
   BNE skip_lvert
; sx1 off-screen → skip vertical
   LDA zp_seg_flags
   AND #$02
   BEQ lvert_portal
; Solid: ft1 → fb1
   LDA zp_seg_sy1_top_l
   STA zp_line_yl_l
   LDA zp_seg_sy1_top_h
   STA zp_line_yl_h
   LDA zp_seg_sy1_bot_l
   STA zp_line_yr_l
   LDA zp_seg_sy1_bot_h
   STA zp_line_yr_h
   JSR emit_vert_sx1
   JMP skip_lvert
lvert_portal:
; NEEDBT? top piece ft1 → bt1
   LDA zp_seg_flags
   AND #$04
   BEQ lvert_no_top
   LDA zp_seg_sy1_top_l
   STA zp_line_yl_l
   LDA zp_seg_sy1_top_h
   STA zp_line_yl_h
   LDA zp_seg_sy1_btop_l
   STA zp_line_yr_l
   LDA zp_seg_sy1_btop_h
   STA zp_line_yr_h
   JSR emit_vert_sx1
lvert_no_top:
; NEEDBB? bottom piece bb1 → fb1
   LDA zp_seg_flags
   AND #$08
   BEQ skip_lvert
   LDA zp_seg_sy1_bbot_l
   STA zp_line_yl_l
   LDA zp_seg_sy1_bbot_h
   STA zp_line_yl_h
   LDA zp_seg_sy1_bot_l
   STA zp_line_yr_l
   LDA zp_seg_sy1_bot_h
   STA zp_line_yr_h
   JSR emit_vert_sx1
skip_lvert:

; Right vertical (sx2).
   LDA zp_seg_flags
   AND #$20
   BNE skip_rvert
   LDA zp_seg_sx2_h
   BNE skip_rvert
; sx2 off-screen → skip vertical
   LDA zp_seg_flags
   AND #$02
   BEQ rvert_portal
   LDA zp_seg_sy2_top_l
   STA zp_line_yl_l
   LDA zp_seg_sy2_top_h
   STA zp_line_yl_h
   LDA zp_seg_sy2_bot_l
   STA zp_line_yr_l
   LDA zp_seg_sy2_bot_h
   STA zp_line_yr_h
   JSR emit_vert_sx2
   JMP skip_rvert
rvert_portal:
   LDA zp_seg_flags
   AND #$04
   BEQ rvert_no_top
   LDA zp_seg_sy2_top_l
   STA zp_line_yl_l
   LDA zp_seg_sy2_top_h
   STA zp_line_yl_h
   LDA zp_seg_sy2_btop_l
   STA zp_line_yr_l
   LDA zp_seg_sy2_btop_h
   STA zp_line_yr_h
   JSR emit_vert_sx2
rvert_no_top:
   LDA zp_seg_flags
   AND #$08
   BEQ skip_rvert
   LDA zp_seg_sy2_bbot_l
   STA zp_line_yl_l
   LDA zp_seg_sy2_bbot_h
   STA zp_line_yl_h
   LDA zp_seg_sy2_bot_l
   STA zp_line_yr_l
   LDA zp_seg_sy2_bot_h
   STA zp_line_yr_h
   JSR emit_vert_sx2
skip_rvert:

; --- NOVT aperture-edge verticals (SF_APEDGE1/2) ---
; A NOVT endpoint suppresses the seg's own vertical, but a colinear
; portal's aperture still needs its edge drawn there. ap_edges (lo.s)
; emits (sxK, aperture_top) → (sxK, aperture_bot) per flagged endpoint;
; solid segs take the APV heights packed into header bytes +12..15.
   LDA zp_seg_flags                        ; spectrack (warm) 2026-07-12:
   AND #$41                                ; every seg paid a 28-cycle no-op
   BEQ ape_skip                            ; call — gate APEDGE1|2 here
   JSR ap_edges
ape_skip:

; --- Compute clamped u8 ilo/ihi for both solid (mark_solid) and
;     portal (tighten) cases.
; Same clamp as the has_gap prelude (Python: ilo = max(0, min(sx1,sx2)),
; ihi = min(255, max(sx1,sx2))), recomputed from the sx slots — the
; $C2/$C3 scratch does not survive the emissions above. The seg was
; CANONICALIZED at hg_pass (sx1 <= sx2 always), and the prelude's bails
; guarantee max >= 0 and min < 256 — one hi-byte test per endpoint,
; single path.
   LDA zp_seg_sx2_h                       ; max hi: 0 = in range
   BNE ms_hi255                            ; >= 256 (BMI impossible): 255
   LDA zp_seg_sx2_l
ms_hist:
   STA zp_i_h
   LDA zp_seg_sx1_h                       ; min hi: 0 = in range
   BMI ms_lo0                              ; < 0 (pos-nonzero impossible): 0
   LDA zp_seg_sx1_l
ms_lost:
   STA zp_i_l
; (clamp fixups relocated below ms_skip: the in-range path — every seg —
; falls straight through; the rare saturations pay the branch back)
ms_dispatch:
   LDA zp_seg_flags
   AND #$02
   BNE ms_solid_path
; --- Portal: DEFER the tighten to the subsector drain (Python defers
;     both solids and tightens in seg order — applying the tighten at
;     seg end mutates spans BEFORE an earlier sibling's mark_solid,
;     producing off-by-one span anchors). Records are snapshotted into
;     the queue because later segs' DCL emission overwrites
;     TOP_RECORDS/BOT_RECORDS before the drain. Skip if no records
;     were populated — mirrors Python's wrapper test
;     `if mem[TOP_RECORDS] == 0 and mem[BOT_RECORDS] == 0: return`.
   LDA $0700
   ORA $0800
   BEQ ms_zero_rec
   JSR defq_append_tighten
   JMP ms_skip
ms_zero_rec:
; Zero records: skip only when the aperture genuinely covers the whole
; screen; a wholly off-screen aperture means the columns are all wall ->
; close them (aligns with endpoint_spans' record verdicts; see
; seg_zero_rec_solid in clip/tfr.s).
   JSR seg_zero_rec_solid
   BCC ms_skip
   JSR defq_append_solid
   JMP ms_skip
ms_solid_path:
; --- Solid wall: defer mark_solid (Python collects them per subsector
;     and applies at the end). ---
   JSR defq_append_solid
ms_skip:
   JMP ms_advance
ms_hi255:
   LDA #255
   BNE ms_hist                             ; (always: A=255)
ms_lo0:
   LDA #0
   BEQ ms_lost                             ; (always: A=0)
ms_advance:

; --- Advance to the next seg: clear the skip flag, bump the seg index
;     (u16) and the two persistent ROM cursors (+12 header, +6 FHCH). ---

::s_advance:                            ; global: backface.s back-exits land here
; (no zp_seg_skip reset needed: the back-face test returns in A now, and
; br_seg_xform_vertex ZEROs the slot at entry before every consumer read)
; (zp_seg_first is NOT advanced per seg: its only reader is the subsector
; prologue's cursor derivation — the loop lives off zp_seg_hdr_p.
; The old INC pair was ~8 cyc/seg of dead work, removed 2026-07-10.)
   CLC
   LDA zp_seg_hdr_p
   ADC #16
   STA zp_seg_hdr_p                        ; page-slotted (packer assert):
                                        ; a run never crosses its page, so
                                        ; the hi byte is ss-constant
   DEC zp_seg_count
   BEQ sa_drain                            ; loop rotation: seg_loop's
   JMP seg_proc                            ; LDA/BNE re-test was dead
sa_drain:
   PAGE BANK_C
   JMP defq_drain
.endscope

; (seg_swap_vx retired 2026-07-15: reversed 1px projections are DROPPED
; at the hg_query prelude — Eben's call, measured: the only cost is the
; degenerate slivers themselves; no aperture/occlusion regressions.)

; (drain_deferred_ms replaced by defq_drain — see the $0B00 region.)

; ============================================================================
; emit_vert_sx1 / emit_vert_sx2 — draw a vertical at endpoint 1 / 2.
; Caller has set yl/yh/yr/yh in zp_line_yl_l/$B3/zp_line_yr_l/$B5.
; Fills xl/xh/xr/xh from sx1 (resp. sx2), clears records hi byte
; (verticals never populate tighten records), pages bank C and
; tail-calls SC_DRAW_S16. Clobbers A.
; NOTE: callers have already verified sx_hi == 0 (on-screen column), so
; loading the hi bytes here keeps the s16 fast path.
; ============================================================================
emit_vert_sx1:
   LDA zp_seg_sx1_l
   STA zp_line_xl_l
   STA zp_line_xr_l
   LDA zp_seg_sx1_h
   STA zp_line_xl_h
   STA zp_line_xr_h
   LDA #0
   STA zp_dcl_rec_buf_h
   PAGE BANK_C
   JMP SC_DRAW_S16

; (see banner above emit_vert_sx1)
emit_vert_sx2:
   LDA zp_seg_sx2_l
   STA zp_line_xl_l
   STA zp_line_xr_l
   LDA zp_seg_sx2_h
   STA zp_line_xl_h
   STA zp_line_xr_h
   LDA #0
   STA zp_dcl_rec_buf_h
   PAGE BANK_C
   JMP SC_DRAW_S16




; (dcl_rec_arm inlined at the four arm sites — JSR/RTS tax on every
; portal edge arm; semantics unchanged.)
