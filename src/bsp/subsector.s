
; ============================================================================
; br_render_subsector — process one subsector.
;   Input: zp_node_chlo:hi = subsector id (high bit cleared).
;
;   Reads subsector header (count, first_seg). Loops through segs:
;     1. Mark visited (test instrumentation).
;     2. Read seg header (v1/v2/lv1x/lv1y/ldx/ldy/flags).
;     3. Read fh/ch from FHCH table; compute height deltas.
;     4. Back-face test; skip if back-facing.
;     5. Transform v1, v2; project to screen X and to Y for top+bot edges.
;     6. Emit top + bottom horizontals (and L+R verticals).
;
; Python mirror: packed_render_subsector + packed_render_seg
; (doom_wireframe.py). Per-subsector pseudocode:
;   count, first = SS_CNT[idx], SS_FLO/FHI[idx]
;   defq = []                                  # DEFQ op queue, seg order
;   for si in range(first, first + count):
;     reset_records()                          # TOP/BOT_RECORDS counts = 0
;     hdr = seg_hdr[si]                        # 12-byte header, ROM
;     if back_face(hdr): continue
;     xform v1, v2 (vcache'd); near-clip; project sx1/sx2 (s16)
;     if both endpoints off one screen side: continue
;     if not has_gap(clamp8(sx), clamp8(sx')): continue
;     emit flag-gated lines (SC_DRAW_S16, records routed via $BC/$BD):
;       front top/bottom horizontals, back-step horizontals,
;       endpoint verticals, aperture-edge verticals
;     defq.append(solid(ilo,ihi) | tighten(ilo,ihi + records snapshot))
;   defq_drain()                               # mark_solid / tighten, in order
;
; Line emission contract (clipper interface):
;   zp_line_xl_lo/yl/xr/yr ($A8-$AB) = endpoint lo bytes,
;   $B2-$B5 (zp_line_xl_hi..zp_line_yr_hi)  = endpoint s16 hi bytes → SC_DRAW_S16.
;   $BC/$BD (zp_dcl_rec_buf) = per-span records buffer: hi byte $00 =
;   records off, $07 → TOP_RECORDS ($0700), $08 → BOT_RECORDS ($0800).
;   $C2/$C3 (zp_ilo/zp_ihi) = column range for has_gap / defq ops.
;
; Deferral (why not apply at seg end): Python defers both mark_solid and
; tighten to subsector end IN SEG ORDER — applying a tighten immediately
; would mutate spans before an earlier sibling's mark_solid and shift
; span anchors. Records are snapshotted into the queue because later
; segs' DCL emission overwrites TOP/BOT_RECORDS before the drain.
; ============================================================================
br_render_subsector:
   PAGE BANK_L0                            ; ss / seg_hdr / verts / sincos live in bank L0
; Animated-sector hook: anim_init retargets this JMP at anim_hub, which
; lazily patches any dirty mover with segs in this subsector (see
; src/bsp/anim.s). Disabled (default) it falls straight through: 3 cycles.
anim_ss_hook:
   JMP anim_ss_cont
anim_ss_cont:
.scope
; --- Mark visited (test instrumentation, FLAT BUILD ONLY) ---
; SS_VISITED_BITMAP[id >> 3] |= bit_mask[id & 7] — regression harnesses
; diff this against the Python walk's subsector set. The banked build
; compiles it out (nothing on the disc reads it; ~44 bytes of MAIN back).
.if .not ::BANKED
   LDA zp_node_chlo
   STA zp_br_t0
   LDA zp_node_chhi
   STA zp_br_t1
   LSR zp_br_t1
   ROR zp_br_t0
   LSR zp_br_t1
   ROR zp_br_t0
   LSR zp_br_t1
   ROR zp_br_t0
   LDA zp_node_chlo
   AND #7
   TAX
   LDA #<SS_VISITED_BITMAP
   CLC
   ADC zp_br_t0
   STA zp_br_p
   LDA #>SS_VISITED_BITMAP
   ADC zp_br_t1
   STA zp_br_p_h
   LDY #0
   LDA vc_bit_mask,X                       ; X survived the pointer build —
   ORA (zp_br_p),Y                         ; reload beats the old PHA/PLA
   STA (zp_br_p),Y
.endif

; --- Read subsector header (SoA pages: count / first_lo / first_hi) ---
   LDX zp_node_chlo
   LDA SS_CNT,X
   STA zp_seg_count

; Persistent per-seg pointers, computed once here and advanced by the
; loop (+12 header, +6 FHCH). si*6 = (si*3) << 1 — one add beats the
; old *2-stash-*4-add chain — reading SS_FLO/FHI straight through X
; (the zp_seg_first staging had no other reader and is GONE; $5A/$5B
; freed). Hi byte rides A into the base adds; Y stashes it across the
; lo-half adds. si_hi <= 2 (660 segs), so the hi arithmetic is exact.
   LDA SS_FLO,X
   ASL A                                   ; C = lo.b7
   STA zp_br_t0                            ; lo(si*2)
   LDA SS_FHI,X
   ROL A                                   ; A = hi(si*2)
   TAY
   CLC
   LDA zp_br_t0
   ADC SS_FLO,X                            ; lo(si*3)
   STA zp_br_t0
   TYA
   ADC SS_FHI,X                            ; hi(si*3) (+ carry)
   ASL zp_br_t0
   ROL A                                   ; (A : t0) = si*6
   TAY                                     ; stash hi6 for the si*12 shift
   CLC
   LDA #<ROM_FHCH_C                        ; layout.inc constant — the ROM
   ADC zp_br_t0                            ; pointer block is retired for
   STA zp_fhch_p                           ; the static-layout bases
   TYA
   ADC #>ROM_FHCH_C
   STA zp_fhch_p_h
; si*12 = si*6 << 1, done NOW while Y still holds hi6 (the FHCH hoist
; below clobbers Y with its own LDY/DEY indexing).
   ASL zp_br_t0                            ; C = lo6.b7
   TYA
   ROL A                                   ; A = hi12
   TAY
   CLC
   LDA #<ROM_SEG_HDR_C
   ADC zp_br_t0
   STA zp_seg_hdr_p
   TYA
   ADC #>ROM_SEG_HDR_C
   STA zp_seg_hdr_p_h
; --- Front heights are SUBSECTOR-CONSTANT (every seg fronts this
; subsector's sector), so read fh/ch + compute the front deltas ONCE
; here instead of per seg (2026-07-10; runs after the anim hub, so
; mover-patched heights are already in place). ---
   LDY #1
   LDA (zp_fhch_p),Y
   STA zp_seg_ch
   SEC
   SBC zp_br_vz
   STA zp_seg_top_dlt                       ; top_dlt = ch - vz
   DEY
   LDA (zp_fhch_p),Y
   STA zp_seg_fh
   SEC
   SBC zp_br_vz
   STA zp_seg_bot_dlt                       ; bot_dlt = fh - vz
; Invalidate the vertex-chain key at the subsector boundary: chained
; front-sy reuse needs the SAME front heights, only guaranteed within
; one subsector. idx < 481, so $FF never matches a real hi byte.
   LDA #$FF
   STA zp_seg_v_idx_hi

; Reset deferred op queue for this subsector.
   LDA #0
   STA DEFQ_TAIL

; --- Loop over segs ---
seg_loop:
   LDA zp_seg_count
   BNE seg_proc
   PAGE BANK_C                             ; defq_drain only does clip ops (bank C)
   JMP defq_drain                          ; subsector done — apply deferred ops
seg_proc:
   PAGE BANK_L0                            ; re-page L0 each seg (prev seg ended in bank C)
; Reset DCL records buffers (used by portal tighten). Python's
; packed_render_seg calls _span_clip_6502.reset_records() at the
; top of each seg, mirrored here.
   LDA #0
   STA $0700                               ; TOP_RECORDS count
   STA $0800                               ; BOT_RECORDS count
   STA zp_dcl_rec_buf                                 ; ZP_DCL_REC_BUF lo
   STA zp_dcl_rec_buf_h                                 ; ZP_DCL_REC_BUF hi (= "no records buffer")

; --- seg header via the persistent pointer. Back-face inputs first
; (offsets 4-10: lv1x/lv1y/ldx/ldy/flags); v1/v2 (offsets 0-3) are only
; read after the test passes — back-facing segs never need them. ---
; 12-byte header layout (wad_packed.py SH_*): +0/+2 v1/v2 vertex idx u16,
; +4/+6 linedef v1 x/y s16, +8/+9 linedef dx/dy s8, +10 flags, +11 len.
; Flags: $80 SAMEDIR (INVERTED direction bit: set = seg runs with its
; linedef; applied branchlessly by EOR/AND in the back-face test),
; $02 SOLID, $04 NEEDBT (back ceil below front), $08 NEEDBB (back floor
; above front), $10/$20 NOVT1/2 (suppress endpoint vertical),
; $40/$01 APEDGE1/2 (aperture edge there).
; Stage ONLY flags (reused all over the seg loop AND across the DCL emit
; calls that clobber registers — it must live in ZP). ldx/ldy AND lv1x/
; lv1y are read ON DEMAND by the back-face test straight from the header
; via (zp_seg_hdr_p),Y — the persistent cursor is already a ZP pointer, so
; no copy into zp_br_p is needed (2026-07-09).
   LDY #10
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_flags

; --- Back-face test (returns Z: BEQ = back-facing) ---
   JSR br_back_face_test
   BNE bf_passed
   JMP s_advance
bf_passed:
; front-facing: fetch v1/v2 straight from the header via zp_seg_hdr_p.

; --- FHCH per-seg: front fh/ch + deltas were HOISTED to the subsector
; prologue (subsector-constant). Only the back heights remain per seg:
;     [fh, ch, bfh|apv1_ch, bch|apv1_fh, apv2_ch, apv2_fh].
; Back deltas are consumed ONLY by do_project_y, which reads them only when
; NEEDBT($04)/NEEDBB($08)/APEDGE1($40) is set. Skip the 2 subtractions for
; plain solids/portals (the common case) — conservative: this superset
; never skips a delta do_project_y will read. bch/bfh read on demand
; (FHCH+3/+2) — never staged.
   LDA zp_seg_flags
   AND #$4C
   BEQ skip_bdlt
   LDY #3
   LDA (zp_fhch_p),Y                        ; bch
   SEC
   SBC zp_br_vz
   STA zp_seg_btop_dlt
   LDY #2
   LDA (zp_fhch_p),Y                        ; bfh
   SEC
   SBC zp_br_vz
   STA zp_seg_bbot_dlt
skip_bdlt:

; --- Transform + project both endpoints (br_seg_xform_vertex:
; vcache-backed br_to_view, near-plane test, X projection, Y projections
; for the edges this seg's flags need; sets zp_seg_skip=1 if the vertex
; is behind the near plane, else writes sx/sy straight into this endpoint's
; slots via zp_seg_ep). Transform v1. Always copy evy/evx/clipped so both
; endpoints are available for near-plane crossing math even when clipped.
   LDA #0
   STA zp_seg_ep                            ; v1 → struct VX1
; --- VERTEX CHAIN (2026-07-10): if this seg's v1 is the vertex the LAST
; transform produced (zp_seg_v_idx still holds it, and VX2 still holds
; its outputs), reuse VX2 wholesale: evy/evx/clip always; sx, the front
; sy pair (same subsector => same fh/ch) and rhi/rlo when unclipped.
; The packer chain-orders subsector segs, so this hits ~80% of
; consecutive front-facing pairs. zp_seg_v_idx_hi is invalidated at the
; subsector boundary and when a crossing overwrites VX2.
   LDY #0
   LDA (zp_seg_hdr_p),Y
   CMP zp_seg_v_idx_lo
   BNE ch_miss
   INY
   LDA (zp_seg_hdr_p),Y
   CMP zp_seg_v_idx_hi
   BNE ch_miss
; chain hit: the copy + back-pair body lives in LO (MAIN is at its
; ceiling); ~12 cyc JSR/RTS tax on a ~200-cyc win.
   JSR chain_reuse_v1
   JMP ch_v1_done
ch_miss:
   LDY #0
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_v_idx_lo
   INY
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_v_idx_hi                      ; CONTRACT: A = idx_hi at entry —
   JSR br_seg_xform_vertex                  ; keep this STA immediately before
; (no marshalling: evy/evx/clip/sx/sy/recip all landed in VX1 directly)
ch_v1_done:

; Transform v2.
   LDA #VX_STRIDE
   STA zp_seg_ep                            ; v2 → struct VX2
   PAGE BANK_L0                             ; v1's projection paged L2 (br_
; project_y / br_recip) unless v1 was near-clipped — the header read below
; needs the L0 window back. Flat: no-op.
   LDY #2
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_v_idx_lo
   INY
   LDA (zp_seg_hdr_p),Y
   STA zp_seg_v_idx_hi                      ; CONTRACT: A = idx_hi at entry —
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
   STA zp_seg_v_idx_hi                      ; VX2 now holds the CROSSING, not
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
   LDA zp_seg_sx1_hi
   CMP zp_seg_sx2_hi
   BNE hg_hi_diff
   TAX                                     ; shared hi byte
   BNE hg_adv                              ; nonzero: off one side entirely
   LDA zp_seg_sx1_lo
   CMP zp_seg_sx2_lo
   BCS hg_fast_rev                         ; sx1 >= sx2 (ties -> rev, as before)
   LDX #0
   STA zp_ilo                              ; A = sx1_lo
   LDA zp_seg_sx2_lo
   STA zp_ihi
   JMP hg_query
hg_fast_rev:
   LDX #VX_STRIDE
   LDA zp_seg_sx2_lo
   STA zp_ilo
   LDA zp_seg_sx1_lo
   STA zp_ihi
   JMP hg_query
hg_hi_diff:
; hi bytes differ: signed hi-byte difference gives the order (lo bytes
; only ever break ties, and ties took the equal path above)
   LDA zp_seg_sx1_hi
   SEC
   SBC zp_seg_sx2_hi
   BVC hgd_v_ok
   EOR #$80
hgd_v_ok:
   BPL hg_min2                             ; sx1 >= sx2
; --- min = sx1, max = sx2 ---
hg_min1:
   LDX #0
   LDA zp_seg_sx2_hi                       ; max hi
   BMI hg_adv                              ; max < 0: off-screen left
   BNE hg_hi255_1                          ; max >= 256: ihi = 255
   LDA zp_seg_sx2_lo
hg_hist1:
   STA zp_ihi
   LDA zp_seg_sx1_hi                       ; min hi
   BNE hg_lock1                            ; nonzero: neg -> 0 / pos -> bail
   LDA zp_seg_sx1_lo
hg_lost1:
   STA zp_ilo
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
   LDA zp_seg_sx1_hi                       ; max hi
   BMI hg_adv                              ; max < 0: off-screen left
   BNE hg_hi255_2                          ; max >= 256: ihi = 255
   LDA zp_seg_sx1_lo
hg_hist2:
   STA zp_ihi
   LDA zp_seg_sx2_hi                       ; min hi
   BNE hg_lock2                            ; nonzero: neg -> 0 / pos -> bail
   LDA zp_seg_sx2_lo
hg_lost2:
   STA zp_ilo
hg_query:
   STX zp_sx_ord                           ; latch min-endpoint offset
   PAGE BANK_C
   JSR SC_HAS_GAP
   BNE hg_pass
   JMP s_advance
hg_pass:

; --- Emit top horizontal (front-sector ceiling): (sx1,ft1)→(sx2,ft2) ---
; Solid wall:        always.
; Portal w/ NEEDBT:  iff ch > vz (face above eyeline, ft visible).
; Portal w/o NEEDBT: iff bch > ch (back ceiling above front; step visible).
; (Python: solid lines[] always includes ft; need_bt inserts ft only when
; ch > vz — the "secondary" front-ceiling above the bt step; the
; bch > ch portal-lip case draws ft with roles={0: TOP_RECORDS}.)
   LDA zp_seg_flags
   AND #$02
   BNE ft_emit
; SF_SOLID → emit
   LDA zp_seg_flags
   AND #$04
   BEQ ft_no_needbt
; NEEDBT: emit only if ch > vz (s8 compare via signed test on ch - vz).
   LDA zp_seg_ch
   SEC
   SBC zp_br_vz
   BMI ft_skip
   BEQ ft_skip
   JMP ft_emit
ft_no_needbt:
; bch > ch ? (bch on demand from FHCH+3 — FHCH lives in the L0 window
; since the 2026-07-10 reshuffle and this path runs under BANK_C, so
; page around the read; flat: no-ops)
   PAGE BANK_L0
   LDY #3
   LDA (zp_fhch_p),Y
   SEC
   SBC zp_seg_ch
   TAX                                     ; verdict rides in X: PAGE (banked)
   PAGE BANK_C                             ; is LDA #bank — clobbers A + flags
   TXA
   BMI ft_skip
   BEQ ft_skip
ft_emit:
; If portal-lip case (!SOLID, !NEEDBT, bch>ch reached here), ft IS the
; new top of the aperture and needs TOP_RECORDS. Solid walls and
; NEEDBT segs (where bt has the role) get no records.
   LDA zp_seg_flags
   AND #$06
   BNE ft_no_rec
; SOLID or NEEDBT → no rec
   LDA #$07
   STA zp_dcl_rec_buf_h
; portal-lip → TOP_RECORDS
   JMP ft_set_line
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
   LDX #zp_seg_sy1_top_lo - VX1            ; sy pair offset (top)
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
   BNE fb_emit
   LDA zp_seg_flags
   AND #$08
   BEQ fb_no_needbb
; NEEDBB: emit only if fh < vz (vz - fh > 0).
   LDA zp_br_vz
   SEC
   SBC zp_seg_fh
   BMI fb_skip
   BEQ fb_skip
   JMP fb_emit
fb_no_needbb:
; bfh < fh ? (bfh on demand from FHCH+2 — L0-window read under BANK_C,
; page around like ft_no_needbt; flat: no-ops)
   PAGE BANK_L0
   LDY #2
   LDA zp_seg_fh
   SEC
   SBC (zp_fhch_p),Y
   TAX                                     ; verdict rides in X across the
   PAGE BANK_C                             ; A-clobbering PAGE (see ft above)
   TXA
   BMI fb_skip
   BEQ fb_skip
fb_emit:
; Mirror of ft_emit: fb gets BOT_RECORDS in the portal-lip case
; (!SOLID, !NEEDBB, bfh<fh reached here).
   LDA zp_seg_flags
   AND #$0A
   BNE fb_no_rec
; SOLID or NEEDBB → no rec
   LDA #$08
   STA zp_dcl_rec_buf_h
; portal-lip → BOT_RECORDS
   JMP fb_set_line
fb_no_rec:
   LDA #0
   STA zp_dcl_rec_buf_h
fb_set_line:
   LDX #zp_seg_sy1_bot_lo - VX1            ; sy pair offset (bot)
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
   LDX #zp_seg_sy1_btop_lo - VX1            ; sy pair offset (btop)
   LDA #$07
   STA zp_dcl_rec_buf_h
; TOP_RECORDS = $0700
   PAGE BANK_C
   JSR SC_DRAW_S16_H
step_no_top:

; Back floor step if NEEDBB (= $08) set: emit (sx1, bb1) → (sx2, bb2).
   LDA zp_seg_flags
   AND #$08
   BEQ step_no_bot
   LDX #zp_seg_sy1_bbot_lo - VX1            ; sy pair offset (bbot)
   LDA #$08
   STA zp_dcl_rec_buf_h
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
   LDA zp_seg_sx1_hi
   BNE skip_lvert
; sx1 off-screen → skip vertical
   LDA zp_seg_flags
   AND #$02
   BEQ lvert_portal
; Solid: ft1 → fb1
   LDA zp_seg_sy1_top_lo
   STA zp_line_yl_lo
   LDA zp_seg_sy1_top_hi
   STA zp_line_yl_hi
   LDA zp_seg_sy1_bot_lo
   STA zp_line_yr_lo
   LDA zp_seg_sy1_bot_hi
   STA zp_line_yr_hi
   JSR emit_vert_sx1
   JMP skip_lvert
lvert_portal:
; NEEDBT? top piece ft1 → bt1
   LDA zp_seg_flags
   AND #$04
   BEQ lvert_no_top
   LDA zp_seg_sy1_top_lo
   STA zp_line_yl_lo
   LDA zp_seg_sy1_top_hi
   STA zp_line_yl_hi
   LDA zp_seg_sy1_btop_lo
   STA zp_line_yr_lo
   LDA zp_seg_sy1_btop_hi
   STA zp_line_yr_hi
   JSR emit_vert_sx1
lvert_no_top:
; NEEDBB? bottom piece bb1 → fb1
   LDA zp_seg_flags
   AND #$08
   BEQ skip_lvert
   LDA zp_seg_sy1_bbot_lo
   STA zp_line_yl_lo
   LDA zp_seg_sy1_bbot_hi
   STA zp_line_yl_hi
   LDA zp_seg_sy1_bot_lo
   STA zp_line_yr_lo
   LDA zp_seg_sy1_bot_hi
   STA zp_line_yr_hi
   JSR emit_vert_sx1
skip_lvert:

; Right vertical (sx2).
   LDA zp_seg_flags
   AND #$20
   BNE skip_rvert
   LDA zp_seg_sx2_hi
   BNE skip_rvert
; sx2 off-screen → skip vertical
   LDA zp_seg_flags
   AND #$02
   BEQ rvert_portal
   LDA zp_seg_sy2_top_lo
   STA zp_line_yl_lo
   LDA zp_seg_sy2_top_hi
   STA zp_line_yl_hi
   LDA zp_seg_sy2_bot_lo
   STA zp_line_yr_lo
   LDA zp_seg_sy2_bot_hi
   STA zp_line_yr_hi
   JSR emit_vert_sx2
   JMP skip_rvert
rvert_portal:
   LDA zp_seg_flags
   AND #$04
   BEQ rvert_no_top
   LDA zp_seg_sy2_top_lo
   STA zp_line_yl_lo
   LDA zp_seg_sy2_top_hi
   STA zp_line_yl_hi
   LDA zp_seg_sy2_btop_lo
   STA zp_line_yr_lo
   LDA zp_seg_sy2_btop_hi
   STA zp_line_yr_hi
   JSR emit_vert_sx2
rvert_no_top:
   LDA zp_seg_flags
   AND #$08
   BEQ skip_rvert
   LDA zp_seg_sy2_bbot_lo
   STA zp_line_yl_lo
   LDA zp_seg_sy2_bbot_hi
   STA zp_line_yl_hi
   LDA zp_seg_sy2_bot_lo
   STA zp_line_yr_lo
   LDA zp_seg_sy2_bot_hi
   STA zp_line_yr_hi
   JSR emit_vert_sx2
skip_rvert:

; --- NOVT aperture-edge verticals (SF_APEDGE1/2) ---
; A NOVT endpoint suppresses the seg's own vertical, but a colinear
; portal's aperture still needs its edge drawn there. ap_edges (lo.s)
; emits (sxK, aperture_top) → (sxK, aperture_bot) per flagged endpoint;
; solid segs take the APV heights packed into FHCH bytes 2-5.
   JSR ap_edges

; --- Compute clamped u8 ilo/ihi for both solid (mark_solid) and
;     portal (tighten) cases.
; Same clamp as the has_gap prelude (Python: ilo = max(0, min(sx1,sx2)),
; ihi = min(255, max(sx1,sx2))), recomputed from the sx slots — the
; $C2/$C3 scratch does not survive the emissions above, but the s16
; ORDER does: zp_sx_ord (latched at hg_query) picks the ladder, and the
; prelude's bails guarantee max >= 0 (no off-left seg gets here) and
; min < 256 (no off-right seg) — so each endpoint needs ONE hi-byte test.
   LDA zp_sx_ord
   BNE ms_min2
; --- min = sx1, max = sx2 ---
   LDA zp_seg_sx2_hi                       ; max hi: 0 = in range
   BNE ms_hi255_1                          ; >= 256 (BMI impossible): 255
   LDA zp_seg_sx2_lo
ms_hist1:
   STA zp_ihi
   LDA zp_seg_sx1_hi                       ; min hi: 0 = in range
   BMI ms_lo0_1                            ; < 0 (pos-nonzero impossible): 0
   LDA zp_seg_sx1_lo
ms_lost1:
   STA zp_ilo
   JMP ms_dispatch
ms_hi255_1:
   LDA #255
   BNE ms_hist1                            ; (always: A=255)
ms_lo0_1:
   LDA #0
   BEQ ms_lost1                            ; (always: A=0)
ms_hi255_2:
   LDA #255
   BNE ms_hist2                            ; (always: A=255)
ms_lo0_2:
   LDA #0
   BEQ ms_lost2                            ; (always: A=0)
; --- min = sx2, max = sx1 ---
ms_min2:
   LDA zp_seg_sx1_hi                       ; max hi
   BNE ms_hi255_2
   LDA zp_seg_sx1_lo
ms_hist2:
   STA zp_ihi
   LDA zp_seg_sx2_hi                       ; min hi
   BMI ms_lo0_2
   LDA zp_seg_sx2_lo
ms_lost2:
   STA zp_ilo
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

; --- Advance to the next seg: clear the skip flag, bump the seg index
;     (u16) and the two persistent ROM cursors (+12 header, +6 FHCH). ---
s_advance:
; (no zp_seg_skip reset needed: the back-face test returns in A now, and
; br_seg_xform_vertex ZEROs the slot at entry before every consumer read)
; (zp_seg_first is NOT advanced per seg: its only reader is the subsector
; prologue's cursor derivation — the loop lives off zp_seg_hdr_p/zp_fhch_p.
; The old INC pair was ~8 cyc/seg of dead work, removed 2026-07-10.)
   CLC
   LDA zp_seg_hdr_p
   ADC #12
   STA zp_seg_hdr_p
   BCC sa_h_nc                             ; BCC/INC: page cross every ~21 segs
   INC zp_seg_hdr_p_h
sa_h_nc:
   CLC
   LDA zp_fhch_p
   ADC #6
   STA zp_fhch_p
   BCC sa_f_nc                             ; BCC/INC: page cross every ~42 segs
   INC zp_fhch_p_h
sa_f_nc:
   DEC zp_seg_count
   JMP seg_loop
.endscope

; (drain_deferred_ms replaced by defq_drain — see the $0B00 region.)

; ============================================================================
; emit_vert_sx1 / emit_vert_sx2 — draw a vertical at endpoint 1 / 2.
; Caller has set yl/yh/yr/yh in zp_line_yl_lo/$B3/zp_line_yr_lo/$B5.
; Fills xl/xh/xr/xh from sx1 (resp. sx2), clears records hi byte
; (verticals never populate tighten records), pages bank C and
; tail-calls SC_DRAW_S16. Clobbers A.
; NOTE: callers have already verified sx_hi == 0 (on-screen column), so
; loading the hi bytes here keeps the s16 fast path.
; ============================================================================
emit_vert_sx1:
   LDA zp_seg_sx1_lo
   STA zp_line_xl_lo
   LDA zp_seg_sx1_hi
   STA zp_line_xl_hi
   LDA zp_seg_sx1_lo
   STA zp_line_xr_lo
   LDA zp_seg_sx1_hi
   STA zp_line_xr_hi
   LDA #0
   STA zp_dcl_rec_buf_h
   PAGE BANK_C
   JMP SC_DRAW_S16

; (see banner above emit_vert_sx1)
emit_vert_sx2:
   LDA zp_seg_sx2_lo
   STA zp_line_xl_lo
   LDA zp_seg_sx2_hi
   STA zp_line_xl_hi
   LDA zp_seg_sx2_lo
   STA zp_line_xr_lo
   LDA zp_seg_sx2_hi
   STA zp_line_xr_hi
   LDA #0
   STA zp_dcl_rec_buf_h
   PAGE BANK_C
   JMP SC_DRAW_S16


