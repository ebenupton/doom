; ============================================================================
; bsp/seg_emit.s — the seg pipeline PAST the back-face verdict, through
; seg advance. Split out of bsp/subsector.s 2026-08-09 (call-graph file
; DAG: subsector -> backface -> HERE; the loop back-edge to ::seg_proc
; is the seg loop itself). Included immediately after subsector.s, so
; the split moved zero bytes.
;
; Entries (all JMP, no fall-through from subsector.s):
;   ::bf_seg_front  — backface.s front verdict: the seg survives; vertex
;                     pipeline, has_gap gate, y projection, canonicalize,
;                     emit cascade, mark_solid/tighten dispatch.
;   ::s_advance     — emit-path arrivals that left bank L0.
;   ::s_advance_l0  — backface back-exits (header reads never paged away).
; Exits: JMP ::seg_proc (subsector.s loop head) / RTS at sa_done when the
; subsector's segs are exhausted.
; Also here: vs_fresh1/vs_fresh2/vsx serve chain (vertex-span descriptor
; verticals) — called only from the emit cascade above them.
; ============================================================================
.scope
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
; slots via zp_seg_ep). Transform v1. Copy the clip verdict so crossing
; dispatch sees both endpoints (crossing COORDS are recovered from the
; vertex keys by cr_recover — EV16 2026-08-09, the s8 evy/evx tier died).
; --- VERTEX CHAIN (2026-07-10): if this seg's v1 is the vertex the LAST
; transform produced (zp_seg_v_idx still holds it, and VX2 still holds
; its outputs), reuse VX2 wholesale: clip always; sx, the front
; sy pair (same subsector => same fh/ch) and rhi/rlo when unclipped.
; The packer chain-orders subsector segs, so this hits ~80% of
; consecutive front-facing pairs. zp_seg_v_idx_b is invalidated at the
; subsector boundary and when a crossing overwrites VX2.
; BYTE ORDER REVERSED (Eben, 2026-07-26): compare B (+1) first, then
; A (+0), walking Y DOWN — every exit arrives with Y = 0, which then
; feeds zp_seg_ep / zp_ys_done / zp_ys_v1ok: the LDY#0/LDX#0/LDA#0
; constants die and the NMOS/C02 hit tails unify. The hit arm stores
; no ep at all (v2's staging overwrites it before any consumer).
; KEY LANDS IN zp_v1i_* AS IT IS READ (Eben, 2026-07-26): the serve
; sites need v1's key banked across the v2 transform anyway — storing
; during the compare kills the 4-op banking block at ch_v1_done_l0 on
; EVERY front-seg arc; zp_seg_v_idx_* is only written on the miss arcs
; (the transform's input — on a hit it already equals the key).
   LDY #1
   LDA (zp_seg_hdr_p),Y
   STA zp_v1i_b
   CMP zp_seg_v_idx_b
   BNE ch_miss_b                           ; A = header idx_b
   DEY                                     ; Y = 0
   LDA (zp_seg_hdr_p),Y
   STA zp_v1i_l
   CMP zp_seg_v_idx_l
   BNE ch_miss_a                           ; A = header idx_l; B equal
; chain hit: the VX2 -> VX1 wholesale copy, IN PLACE (the macro
; indirection retired 2026-07-26 — this is its only site; the LO body
; + JSR tax died 2026-07-17, the MAIN/LO split died in the reshuffle).
.scope
   LDA zp_seg_v2_clipped                   ; (the evy/evx copies DIED with
   STA zp_seg_v1_clipped                   ;  the s8 tier — EV16 2026-08-09)
   BNE ch_reuse_done                       ; clipped: rest undefined
   LDA zp_seg_sx2_l
   STA zp_seg_sx1_l
   LDA zp_seg_sx2_h
   STA zp_seg_sx1_h
; recip carried UNCONDITIONALLY (2026-07-11): the post-has_gap y stage
; projects from the struct-banked recips.
   LDA zp_seg_v2_r_m8
   STA zp_seg_v1_r_m8
   LDA zp_seg_v2_r_s
   STA zp_seg_v1_r_s
; CHAIN SY RECOVERY (2026-07-11): if the PREVIOUS seg ran its y stage
; (zp_ys_done — consumed on chain hits, cleared by chain misses and by
; the cull funnel's v1ok clear regime), VX2 still holds its v2's
; projected FRONT pair, and this seg's v1 is that same vertex under
; the same subsector heights: copy the pair and let the y stage skip
; v1's front projection (zp_ys_v1ok).
   LDA zp_ys_done
   BEQ ch_reuse_done
   STA zp_ys_v1ok                          ; A = ys_done, BEQ-proven nonzero:
                                        ; v1ok is zero/nonzero only (the ys
                                        ; stage LDA/BEQs it) — the old
                                        ; trailing LDA #1 coercion died
   LDA zp_seg_sy2_top_l
   STA zp_seg_sy1_top_l
   LDA zp_seg_sy2_top_h
   STA zp_seg_sy1_top_h
   LDA zp_seg_sy2_bot_l
   STA zp_seg_sy1_bot_l
   LDA zp_seg_sy2_bot_h
   STA zp_seg_sy1_bot_h
ch_reuse_done:
.endscope
   STY zp_ys_done                          ; consumed (chain; Y = 0) — reset
   JMP ch_v1_done_l0                       ; for THIS seg's own y stage; the
                                        ; chain body is pure ZP — this arc
                                        ; NEVER left L0, skips the re-page
                                        ; (STY+JMP: the NMOS/C02 fork died
                                        ; with the reversed-order Y=0)
sxv1_hi:
   JSR sx_vert_hi
   JMP sxv1_done
ch_miss_b:                                 ; A = header idx_b (Y = 1;
   STA zp_seg_v_idx_b                      ;  v1i_b already stored above)
   DEY                                     ; Y = 0
   LDA (zp_seg_hdr_p),Y                    ; header idx_l
   STA zp_v1i_l
ch_miss_a:                                 ; (B-differs falls in; A-differs
   STA zp_seg_v_idx_l                      ;  arrives with B already correct
                                        ;  and both v1i bytes stored)
   STY zp_seg_ep                            ; v1 → struct VX1 (Y = 0)
   STY zp_ys_done                           ; prev-seg donation dies here
   STY zp_ys_v1ok
   LDA zp_seg_v_idx_b                       ; side test at the CALLER
   AND #$20                                 ; (2026-07-27 round 2)
   BNE sxv1_hi                              ; senior: island above
   JSR sx_vert_lo
sxv1_done:                                  ; (the old 'A = B at entry'
                                        ; contract is a FOSSIL: the entry
                                        ; reloads both key bytes from zp —
                                        ; audited 2026-07-26)
; (no marshalling: evy/evx/clip/sx/recip all landed in VX1 directly)
ch_v1_done:
   PAGE BANK_L0                             ; transform arc: br_seg_xform_
; vertex exits L2 on EVERY path (2026-07-21 contract) — the header read
; below needs the L0 window back. Flat: no-op.
ch_v1_done_l0:
; (the v1-key banking block died 2026-07-26: the chain test stores the
; key into zp_v1i_* as it reads it — the serve sites' banked copy is
; ready before the v2 transform ever overwrites zp_seg_v_idx)

; Transform v2.
   LDA #VX_STRIDE
   STA zp_seg_ep                            ; v2 → struct VX2
   LDY #2
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_v_idx_l
   INY
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_v_idx_b
   AND #$20                                 ; side rides the just-loaded byte
   BNE sxv2_hi                              ; senior ~35%: island below
   JSR sx_vert_lo
sxv2_done:
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
   BNE s_some_clipped                      ; rare (15%, census 2026-07-27):
                                           ; the resolution block lives in
                                           ; an island past the hg fast arms
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
   STA zp_i_l                              ; A = sx1_lo = ilo
   LDA zp_seg_sx2_l                        ; ihi rides in A (A-hi ABI)
   JMP hg_query
hg_fast_rev:
   LDX #VX_STRIDE
   LDY zp_seg_sx2_l                        ; ilo = sx2_lo via Y (dead here —
   STY zp_i_l                              ; has_gap clobbers it); A = sx1_lo
   JMP hg_query                            ; = ihi rides through (A-hi ABI)
; --- near-clip resolution island (census 2026-07-27) ---
s_some_clipped:
   LDA zp_seg_v1_clipped
   BEQ s_v2_was_clipped
   LDA zp_seg_v2_clipped
   BNE s_advance_jmp                       ; both clipped
   STA zp_seg_ep                            ; = 0 (the BNE above proves A=0):
   JSR reproject_at_crossing                ; reproject into v1 (struct VX1)
   JMP s_both_have_proj
s_advance_jmp:
   JMP s_advance
sxv2_hi:
   JSR sx_vert_hi
   JMP sxv2_done
s_v2_was_clipped:
   LDA #VX_STRIDE
   STA zp_seg_ep                            ; reproject into v2 (struct VX2)
   JSR reproject_at_crossing
   LDA #$80
   STA zp_seg_v_idx_b                      ; VX2 now holds the CROSSING, not
                                        ; the vertex — kill the chain key.
                                        ; $80, NOT $FF (2026-07-26): the
                                        ; sentinel is also the v2 VDONE
                                        ; probe/mark INDEX — VDONE+$80 =
                                        ; $1BBC sits in the free ex-BCA_WS
                                        ; tail, the sandbox the old $0600
                                        ; page provided ($FF would read
                                        ; AND CORRUPT SQR_LO+$3B — the
                                        ; walkseq phantom-line bug). Any
                                        ; value > 58 kills the chain CMP;
                                        ; keep base+sentinel inside
                                        ; $1B78-$1BFF.
   JMP s_both_have_proj
hg_hi_diff:
; hi bytes differ: signed hi-byte difference gives the order (lo bytes
; only ever break ties, and ties took the equal path above)
; (A = sx1_h from the entry compare; SEC stays — CMP's carry varies)
; V-correction KEPT (2026-07-17 sweep): |sx| reaches +-32,577 (rns
; bound), so the hi bytes span +-127 and their s8 difference CAN
; overflow for a near wall with endpoints at opposite extremes.
   SEC
   SBC zp_seg_sx2_h
   BVC hgd_v_ok
   EOR #$80
hgd_v_ok:
   BPL hg_min2                             ; sx1 >= sx2
; --- min = sx1, max = sx2 --- (A-hi ABI: min lands in zp_i_l first,
; max is computed LAST so ihi ends in A at hg_query. Bail outcomes are
; order-independent: off-right (min >= 256) now bails before the max
; test; off-left (max < 0) pays a dead ilo=0 store first — rare.)
hg_min1:
   LDX #0
   LDA zp_seg_sx1_h                       ; min hi
   BNE hg_lock1                            ; nonzero: neg -> 0 / pos -> bail
   LDA zp_seg_sx1_l
hg_lost1:
   STA zp_i_l
   LDA zp_seg_sx2_h                       ; max hi
   BMI hg_adv                              ; max < 0: off-screen left
   BNE hg_hi255_1                          ; max >= 256: ihi = 255
   LDA zp_seg_sx2_l
   JMP hg_query                            ; ihi rides in A (A-hi ABI)
hg_hi255_1:
   LDA #255
   BNE hg_query                            ; (always: A=255)
hg_lock1:
   BPL hg_adv                              ; min >= 256: off-screen right
   LDA #0
   BEQ hg_lost1                            ; (always: A=0)
hg_adv:
   JMP s_advance
hg_hi255_2:
   LDA #255
   BNE hg_query                            ; (always: A=255)
hg_lock2:
   BPL hg_adv                              ; min >= 256: off-screen right
   LDA #0
   BEQ hg_lost2                            ; (always: A=0)
; --- min = sx2, max = sx1 ---
hg_min2:
   LDX #VX_STRIDE
   LDA zp_seg_sx2_h                       ; min hi
   BNE hg_lock2                            ; nonzero: neg -> 0 / pos -> bail
   LDA zp_seg_sx2_l
hg_lost2:
   STA zp_i_l
   LDA zp_seg_sx1_h                       ; max hi
   BMI hg_adv                              ; max < 0: off-screen left
   BNE hg_hi255_2                          ; max >= 256: ihi = 255
   LDA zp_seg_sx1_l
hg_query:
   STX zp_sx_ord                           ; latch min-endpoint offset
   JSR SC_HAS_GAP                          ; A = ihi (A-hi ABI; ihi stays
                                           ; register-only — ms/tfr get
                                           ; their pair from the emit-path
                                           ; clamp); main-resident — no PAGE
   BCC hg_adv                              ; C-only verdict: C=0 skip ->
                                           ; borrow hg_adv's JMP backward;
                                           ; C=1 gap FALLS THROUGH (was an
                                           ; 80%-taken BCS — census)
hg_pass:
; Records reset for THIS seg (moved from seg_proc): ms_dispatch reads
; the counts only for segs that got here; armed draws re-init them.
.if ::C02
   STZ TOP_RECORDS                        ; counts (symbolic 2026-08-09:
   STZ BOT_RECORDS                        ;  TOP moved to $0B00 for the
.else                                     ;  VXC-planes-to-main shuffle)
   LDA #0
   STA TOP_RECORDS
   STA BOT_RECORDS
.endif
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
   SBC zp_br_vz                             ; no SEC: hg_pass is entered only
                                            ; by falling past BCC hg_adv (C=1)
                                            ; and nothing above touches carry
   STA zp_seg_btop_dlt
   DEY
   LDA (zp_seg_hdr_p),Y                     ; bfh (header +12)
   SEC
   SBC zp_br_vz
   STA zp_seg_bbot_dlt
   PAGE BANK_L2                             ; restore for the projections
                                        ; below (br_project_y no longer
                                        ; re-pages per call)
ys_deltas_done:
; (no PAGE: solid arcs arrive L2 — br_seg_xform_vertex's exit contract
;  is L2-always since 2026-07-21, and nothing between v2's JSR and here
;  pages away (reproject/br_recip end L2; SC_HAS_GAP is main-resident).
;  The portal block above restores L2 itself after its L0 excursion.)
   LDA zp_ys_v1ok
   BEQ ys_v1_full
; chained v1 with a LIVE front sy pair (copied from the emitted prev
; seg) — only a portal's back pair still needs v1's recip
   LDA zp_seg_flags
   AND #$0C
   BEQ ys_v2
   ZERO zp_seg_ep
   LDA zp_seg_v1_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v1_r_s                        ; inlined rns_select (hot site)
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   JSR dpy_back_v1                         ; (chained v1 = struct VX1)
   JMP ys_v2
ys_v1_full:
   ZERO zp_seg_ep                         ; v1 -> struct VX1
   LDA zp_seg_v1_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v1_r_s                        ; inlined rns_select
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   JSR do_project_y_v1
ys_v2:
; (v2-first + select-only fast arc MEASURED 2026-07-25: the crossing
; test + arc split cost what the elided recip loads saved — wash;
; reverted to the single-path restage. The rns vector NEVER survives
; the xform: br_project_x re-patches rns_go on miss arcs.)
   LDA #VX_STRIDE
   STA zp_seg_ep                            ; v2 -> struct VX2
   LDA zp_seg_v2_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v2_r_s                        ; inlined rns_select
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   JSR do_project_y_v2
   LDA #1
   STA zp_ys_done                           ; this seg's VX2 sy is live for
   LDA #0                                   ; the next seg's chain
   STA zp_ys_v1ok
; (apv_stage RETIRED 2026-07-24: the APV overload died with the vertex-
;  span descriptors — solids' +12/+13 now carry the fh/ch alias)
hgp_can:
; Canonicalize: after this point VX1 is ALWAYS the left endpoint, and
; every emit path below is single-path (no ord dispatch anywhere).
   LDA zp_sx_ord
   BEQ hgp_fwd
   JMP s_advance                           ; reversed 1px projection: DROP
                                        ; (2026-07-15: seg_swap_vx retired;
                                        ; python mirror returns likewise)
hgp_fwd:
   PAGE BANK_C                             ; THE emit-cascade page (2026-07-21
                                           ; PAGE grind): one page dominates
                                           ; every arc below — the old per-emit
                                           ; pages at ft/fb/step-top (and the
                                           ; L2 corridor they guarded) die; the
                                           ; two header reads inside re-page
                                           ; around themselves as before.

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
; NEEDBT: emit only if ch > vz. FLIPPED + CMP (Eben, 2026-07-26): the
; old SEC/SBC materialized a diff nobody consumed and needed BMI+BEQ;
; testing vz - ch makes "skip" one BPL (vz >= ch, Z included). Same
; s8 no-overflow assumption as the original sign test.
   LDA zp_br_vz
   CMP zp_seg_ch
   BPL ft_skip
   BMI ft_no_rec                           ; NEEDBT → emit, no records
                                           ; (N = 1: always taken)
ft_no_needbt:
; bch > ch ? (bch on demand from header +13 — the header lives in the
; L0 window and this path runs under BANK_C, so page around the read;
; flat: no-ops)
   PAGE BANK_L0
   LDY #13
   LDA (zp_seg_hdr_p),Y                     ; bch (header +13)
   PAGE_X BANK_C                            ; back to C with bch RIDING A
   CMP zp_seg_ch                            ; verdict AFTER the page (its
   BMI ft_skip                              ; immediate load killed flags);
   BEQ ft_skip                              ; the SEC/TAX/TXA ride died
                                           ; (Eben, 2026-07-26)
ft_emit:
; Portal-lip (the only fall-in: !SOLID, !NEEDBT, bch>ch): ft IS the new
; top of the aperture — arm TOP_RECORDS. The old AND #$06 re-test was
; decidable at every entrant and is gone: solid/NEEDBT branch straight
; to ft_no_rec above.
   LDA #>TOP_RECORDS
   STA zp_dcl_rec_buf_h
   ZERO TOP_RECORDS                        ; count = 0 (arm-time reset;
                                           ; page-aligned → absolute)
   LDA #1
   STA zp_dcl_rec_off
   BNE ft_set_line                         ; A = 1: always taken
ft_no_rec:
   ZERO zp_dcl_rec_buf_h
ft_set_line:
; (rec_buf lo is never non-zero — both record pages are page-aligned;
;  the per-seg prologue zeroes it once. Only _h arms/disarms.)
; Hand off to the horizontal s16 entry: X names the sy pair (same
; offset in both vertex structs); SC_DRAW_S16_H fetches x from
; zp_seg_sx1/sx2 and the y pair from VX1+X/VX2+X itself — no staging
; here at all (the zp_line_* slots don't survive the clipper's
; in-place normalization, so nothing can be seg-hoisted into them).
   LDX #zp_seg_sy1_top_l - VX1            ; sy pair offset (top)
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
; NEEDBB: emit only if fh < vz. FLIPPED + CMP (mirror of the ft test):
; skip iff fh >= vz = one BPL.
   LDA zp_seg_fh
   CMP zp_br_vz
   BPL fb_skip
   BMI fb_no_rec                           ; NEEDBB → emit, no records
                                           ; (N = 1: always taken)
fb_no_needbb:
; bfh < fh ? (bfh on demand from header +12 — L0-window read under
; BANK_C, page around like ft_no_needbt; flat: no-ops)
   PAGE BANK_L0
   LDY #12
   LDA (zp_seg_hdr_p),Y                     ; bfh (header +12)
   PAGE_X BANK_C                            ; back to C with bfh RIDING A
   CMP zp_seg_fh                            ; bfh - fh: skip iff bfh >= fh —
   BPL fb_skip                              ; the operand flip makes it ONE
                                           ; branch (emit iff bfh < fh)
fb_emit:
; Mirror of ft_emit: portal-lip only — arm BOT_RECORDS (the AND #$0A
; re-test was decidable at every entrant; solid/NEEDBB branch straight
; to fb_no_rec above).
   LDA #>BOT_RECORDS
   STA zp_dcl_rec_buf_h
   ZERO BOT_RECORDS                        ; count = 0 (arm-time reset)
   LDA #1
   STA zp_dcl_rec_off
   BNE fb_set_line                         ; A = 1: always taken
fb_no_rec:
   ZERO zp_dcl_rec_buf_h
fb_set_line:
   LDX #zp_seg_sy1_bot_l - VX1            ; sy pair offset (bot)
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
   LDA #>TOP_RECORDS
   STA zp_dcl_rec_buf_h
   ZERO TOP_RECORDS                        ; count = 0 (arm-time reset)
   LDA #1
   STA zp_dcl_rec_off
   JSR SC_DRAW_S16_H
step_no_top:

; Back floor step if NEEDBB (= $08) set: emit (sx1, bb1) → (sx2, bb2).
   LDA zp_seg_flags
   AND #$08
   BEQ step_no_bot
   LDX #zp_seg_sy1_bbot_l - VX1            ; sy pair offset (bbot)
   LDA #>BOT_RECORDS
   STA zp_dcl_rec_buf_h
   ZERO BOT_RECORDS                        ; count = 0 (arm-time reset)
   LDA #1
   STA zp_dcl_rec_off
; BOT_RECORDS = $0800
; (no PAGE: entry here is provably bank-C — since 2026-07-21 the
;  hgp_fwd cascade page dominates everything. Historical note kept:
;  !NEEDBT paths paged C at
;  ft_no_needbt and every fb path preserves it; NEEDBT means the
;  step-top emit just paged C. The ONLY non-C corridor into the
;  cascade — portal + NEEDBT + ch<=vz skipping ft in bank L2 — dies at
;  step-top's PAGE. That corridor is exactly why the step-top and
;  fb_set_line PAGEs above are LOAD-BEARING: do not elide them.
;  Audited 2026-07-15.)
   JSR SC_DRAW_S16_H
step_no_bot:
step_skip:

; --- Emit verticals: PER-VERTEX SPAN DESCRIPTORS (2026-07-24) ---
; The per-seg solid/portal ladders, NOVT tests and the whole APEDGE
; exception path (ap_edges/apv_stage/ap_emit_y) are RETIRED: each
; endpoint's vertex is served ONCE per frame (VDONE bit) by the first
; rendering seg to touch it, from a one-byte descriptor. Codes read
; this seg's already-projected sy slots; explicit refs clamp world
; heights to this seg's front and project at the endpoint recip.
; Probe-first (2026-07-25 lean rework): the VDONE bit is tested INLINE —
; a served (or marked-desc-0) vertex exits in the site's ~20 cycles with
; no JSR and no ZP staging. Only unmarked vertices call the fresh path.
   LDA zp_v1i_l
   AND #7
   TAY
   LDA vc_bit_mask,Y
   LDX zp_v1i_b                            ; B byte IS the bitmap index
   AND VDONE,X
   BNE vs1_done
   JSR vs_fresh1
vs1_done:
; v2's bit mask is STILL LIVE in zp_seg_v_bitm (stored by its transform;
; nothing between writes it — chain v1 hits skip the store, leaving the
; previous seg's v2 = a different vertex, but v2's own xform ALWAYS ran
; last). Saves the AND/TAY/table reload the v1 site still needs.
   LDA zp_seg_v_bitm
   LDX zp_seg_v_idx_b
   AND VDONE,X
   BNE vs2_done
   JSR vs_fresh2
vs2_done:

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
; --- Portal: apply the records tighten IMMEDIATELY (bank C is
;     guaranteed here — the emit-cascade audit — and the records are
;     LIVE in the records buffers: consumed in place, no snapshot).
;     Skip if no records were populated — mirrors Python's wrapper test.
   LDA TOP_RECORDS
   ORA BOT_RECORDS
   BEQ ms_zero_rec
   JSR SC_TIGHTEN_FROM_RECORDS
   JMP ms_skip
ms_zero_rec:
; Zero records: skip only when the aperture genuinely covers the whole
; screen; a wholly off-screen aperture means the columns are all wall ->
; close them (aligns with endpoint_spans' record verdicts; see
; seg_zero_rec_solid in clip/tfr.s).
   JSR seg_zero_rec_solid
   BCC ms_skip
   JSR SC_MARK_SOLID
   JMP ms_skip
ms_solid_path:
; --- Solid wall: mark_solid NOW (bank C held; ilo/ihi staged above) ---
   JSR SC_MARK_SOLID
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

::s_advance:                            ; arrivals that left L0 (emit path
; ends bank C; the mid-loop culls — both-clipped, off-screen, has_gap
; fail, 1px drop — end bank L2): re-page L0 for the next seg's header
; reads, but only on the loop-back arc so the RTS keeps the old
; caller-sees-last-seg's-bank contract.
; ZP_YS_V1OK LEAK (2026-07-25, the 004A.0B jump): a seg that CHAIN-HIT
; (v1ok=1, ys_done consumed) and then culled here never ran its y
; stage — the stale v1ok leaked into the NEXT seg, whose y stage then
; skipped v1's front projection and emitted whatever sy the chain copy
; brought (two-seg-old values: the 21-row wrong ft). Emitted segs
; cleared v1ok in the y stage; ONLY the cull arcs leaked. The backface
; arc (s_advance_l0) never touches the chain and must PRESERVE it.
   LDA #0
   STA zp_ys_v1ok
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
   BEQ sa_done
   PAGE BANK_L0                            ; the old loop-top page, moved to
   JMP seg_proc                            ; the arcs that actually left L0
::s_advance_l0:                         ; backface back-exits: header reads
; never paged away — the advance tail is duplicated (12 bytes) so the
; majority arc pays no PAGE at all (57% of iterations per dfscan).
   CLC
   LDA zp_seg_hdr_p
   ADC #16
   STA zp_seg_hdr_p
   DEC zp_seg_count
   BEQ sa_done                             ; loop rotation: seg_loop's
   JMP seg_proc                            ; LDA/BNE re-test was dead
sa_done:
   RTS                                     ; ops already applied per seg
.endscope

; (seg_swap_vx retired 2026-07-15: reversed 1px projections are DROPPED
; at the hg_query prelude — Eben's call, measured: the only cost is the
; degenerate slivers themselves; no aperture/occlusion regressions.)

; (drain_deferred_ms replaced by defq_drain — see the $0B00 region.)

; ============================================================================
; vs_fresh1/vs_fresh2 — serve a FRESH endpoint vertex (2026-07-25 lean
; rework; the staged vs_vertex entry retired). The call sites probe the
; VDONE bit inline, so only unmarked vertices arrive here.
;   in : Y = idx&7 (bit select), X = idx>>3 (bitmap byte); the vertex
;        key is re-read from its home ZP pair (v1: zp_v1i, v2:
;        zp_seg_v_idx) — no staging slots.
;   The mark is FIRST and unconditional: desc-0 vertices get marked too
;   (nothing can ever draw there — the mark just upgrades every later
;   touch to the site's fast exit; python mirrors this). Clip/column
;   gates are vertex facts (trigger-invariant), so mark-before-gate is
;   safe. Bank C throughout; the explicit path excurses to L2 around
;   br_project_y (VWHC planes) and returns to C.
; ============================================================================
.scope
::vs_fresh1:                                ; v1 endpoint (struct 0)
   LDA vc_bit_mask,Y
   ORA VDONE,X
   STA VDONE,X
; gates BEFORE the descriptor read (both exits are draw-free and the
; mark is already down, so order is unobservable): STATIC zp
; addressing — this entry IS struct 0, no index needed.
   LDA VX1+0                               ; near-clipped endpoint
   BNE f1_rts
   LDA VX1+2                               ; column off-screen
   BNE f1_rts
   LDY zp_v1i_l
   LDA zp_v1i_b
   AND #$20                                ; senior plane (ids 256+)
   BNE f1_hi
   LDA VDESC,Y
   BNE f1_go
f1_rts:
   RTS                                     ; no spans, ever (marked)
f1_hi:
   LDA VDESC+$100,Y
   BNE f1_go
   RTS
f1_go:
   LDX #0
   BEQ vs_go                               ; (always: Z from LDX #0)
::vs_fresh2:                                ; v2 endpoint (struct VX_STRIDE)
   LDA zp_seg_v_bitm                        ; (v2's mask — see the site)
   ORA VDONE,X
   STA VDONE,X
   LDA VX2+0                               ; clip
   BNE f2_rts
   LDA VX2+2                               ; sx_hi
   BNE f2_rts
   LDY zp_seg_v_idx_l
   LDA zp_seg_v_idx_b
   AND #$20
   BNE f2_hi
   LDA VDESC,Y
   BNE f2_go
f2_rts:
   RTS
f2_hi:
   LDA VDESC+$100,Y
   BNE f2_go
   RTS
f2_go:
   LDX #VX_STRIDE
vs_go:                                      ; A = descriptor (nonzero),
   STX zp_vs_x                             ; X = struct (dcl/project
                                           ; clobber X; STX keeps flags)
; dispatch on A directly (zp_vs_d retired) — the incoming N/Z are from
; the LDX above, so test explicitly:
   CMP #$80
   BCS vsx_expl                            ; $80|i: explicit table ref
   CMP #2
   BCC vsx_c1                              ; $01: fh->ch
   BEQ vsx_c2                              ; $02: fh->bfh
   CMP #4
   BCC vsx_c3                              ; $03: bch->ch
; $04 frame pair: top piece then bottom piece
   JSR vsx_do_c3
   LDX zp_vs_x
vsx_c2:                                    ; bottom step: bbot -> bot,
   LDA zp_seg_flags                        ; gated on NEEDBB (a solid or
   AND #$08                                ; stepless trigger self-annuls
   BEQ vsx_rts                             ; the code — world bfh <= fh)
   LDA VX1+9,X
   STA zp_line_yl_l
   LDA VX1+10,X
   STA zp_line_yl_h
   LDA VX1+5,X
   STA zp_line_yr_l
   LDA VX1+6,X
   STA zp_line_yr_h
   JMP vsx_emit
vsx_c3:
   JSR vsx_do_c3
vsx_rts:
   RTS
vsx_c1:                                    ; full corner: top -> bot
   LDA VX1+3,X
   STA zp_line_yl_l
   LDA VX1+4,X
   STA zp_line_yl_h
   LDA VX1+5,X
   STA zp_line_yr_l
   LDA VX1+6,X
   STA zp_line_yr_h
vsx_emit:
   LDA VX1+1,X                             ; column (pre-gated on-screen:
   JMP SC_DCL_VERT_ON                      ; skip the senior-byte check)

vsx_do_c3:                                 ; top step: top -> btop,
   LDA zp_seg_flags                        ; gated on NEEDBT
   AND #$04
   BEQ vsx_c3rts
   LDA VX1+3,X
   STA zp_line_yl_l
   LDA VX1+4,X
   STA zp_line_yl_h
   LDA VX1+7,X
   STA zp_line_yr_l
   LDA VX1+8,X
   STA zp_line_yr_h
   LDA VX1+1,X                             ; (pre-gated on-screen)
   JMP SC_DCL_VERT_ON                      ; tail: RTS to OUR caller
vsx_c3rts:
   RTS

vsx_expl:
; explicit table walk: clamp world heights to this trigger's front
; sector, project at the endpoint's own recip, emit. Rare (86 refs
; map-wide). Lean layout (2026-07-25): recip staging + RNS_SELECT are
; hoisted out of the span loop (every span at this vertex projects at
; the same endpoint recip) and are BANK-FREE (rns tables + the SMC site
; live in CODE, VX is zp); the VEXPL reads + clamps run under the
; ambient bank C; only the two br_project_y calls need the L2 window
; (VWHC planes) — an empty span pays no PAGE at all.
   AND #$7F
   STA zp_vs_i
   LDA VX1+11,X                            ; endpoint recip -> projector
   STA zp_br_r_m8
   LDA VX1+12,X
   STA zp_br_r_s
   RNS_SELECT                              ; (A = S rides in; clobbers X)
vsx_exl:
; VEXPL reads under the ambient bank C (the planes live beside VDESC in
; the C window); the clamp is pure ZP.
   LDY zp_vs_i
; c_lo = max(h_lo, fh)  [signed s8]
   LDA VEXPL_LO,Y
   SEC
   SBC zp_seg_fh
   BVC vsx_lo1
   EOR #$80
vsx_lo1:
   BMI vsx_lofh
   LDA VEXPL_LO,Y
   JMP vsx_lohave
vsx_lofh:
   LDA zp_seg_fh
vsx_lohave:
   STA zp_vs_hl
; c_hi = min(h_hi, ch)  [signed s8]
   LDA VEXPL_HI,Y
   SEC
   SBC zp_seg_ch
   BVC vsx_hi1
   EOR #$80
vsx_hi1:
   BPL vsx_hich
   LDA VEXPL_HI,Y
   JMP vsx_hihave
vsx_hich:
   LDA zp_seg_ch
vsx_hihave:
   STA zp_vs_hh
; empty? (c_hi <= c_lo, signed) — A rides from the STA above (valid
; again: the RNS hoist removed the clobber between clamp and test)
   SEC
   SBC zp_vs_hl
   BVC vsx_em1
   EOR #$80
vsx_em1:
   BMI vsx_enext
   BEQ vsx_enext
; project both ends (deltas vs eye height), emit
   PAGE BANK_L2                            ; br_project_y's VWHC planes
   LDA zp_vs_hh
   SEC
   SBC zp_br_vz
   JSR br_project_y                        ; -> Y = lo, A = hi
   STA zp_line_yl_h
   STY zp_line_yl_l
   LDA zp_vs_hl
   SEC
   SBC zp_br_vz
   JSR br_project_y
   STA zp_line_yr_h
   STY zp_line_yr_l
   PAGE BANK_C
   LDX zp_vs_x
   LDA VX1+1,X                             ; (pre-gated on-screen)
   JSR SC_DCL_VERT_ON
vsx_enext:
   LDY zp_vs_i
   LDA VEXPL_CONT,Y
   BEQ vsx_edone
   INC zp_vs_i
   JMP vsx_exl
vsx_edone:
   RTS
.endscope




; (dcl_rec_arm inlined at the four arm sites — JSR/RTS tax on every
; portal edge arm; semantics unchanged.)
