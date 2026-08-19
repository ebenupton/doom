; ============================================================================
; bsp/seg_emit.s — the per-seg pipeline from the front-face verdict to
; the seg advance.
;
; PIPELINE (one pass per front-facing seg):
;
;   1  TRANSFORM   v1 (chain-served ~80%) and v2: world -> view -> sx
;   2  NEAR CLIP   0 clipped: continue; 1: reproject at crossing; 2: cull
;   3  RANGE GATE  compare sx1/sx2, DROP reversed, clamp, has_gap [ilo,ihi]
;   4  Y STAGE     project the seg's sy pairs (front always; back by flags)
;   5  CASCADE PAGE one BANK_C page for the emit cascade
;   6  EMIT        top/bottom horizontals + portal step edges
;   7  VERTICALS   per-vertex span descriptors, once per vertex per frame
;   8  OCCLUSION   solid -> mark_solid; portal -> tighten_from_records
;   9  ADVANCE     bump header cursor, loop or return
;
; Pseudocode (mirrors packed_render_seg in doom_wireframe.py):
;
;   def render_seg(seg):
;       v1 = chain_or_transform(seg.v1); v2 = transform(seg.v2)   # 1
;       if v1.clipped and v2.clipped: return                      # 2
;       if v1.clipped != v2.clipped: reproject_at_crossing()
;       if sx1 > sx2: return    # reversed 1px sliver: drop      # 3
;       ilo, ihi = clamp8(sx1, sx2)
;       if empty or not has_gap(ilo, ihi): return
;       project_sy_pairs(front always, btop/bbot by NEEDBT/NEEDBB) # 4
;       emit ft, fb, bt-step, bb-step (by flags, vz tests)        # 6
;       for v in (v1, v2): serve_vertex_descriptor_once(v)        # 7
;       if SOLID: mark_solid(ilo, ihi)                            # 8
;       else:     tighten_from_records(ilo, ihi)
;       advance()                                                 # 9
;
; ENTRIES (JMP only, no fall-through from other files):
;   ::bf_seg_front   backface.s front verdict — run stages 1-9
;   ::s_advance      cull arrivals that left bank L0 (re-pages L0)
;   ::s_advance_l0   backface back-exits (L0 never left)
; EXITS: JMP ::seg_proc (subsector.s loop head); RTS when seg count hits 0.
;
; SEG HEADER (9 B, via zp_seg_hdr_p, bank L0):
;   +0/+1 v1 idx lo/b   +2/+3 v2 idx lo/b   +8 flags
;   +8 back-pair palette id -> ROM_BPAL_BFH_C/BCH_C (solids' entry carries
;   the fh/ch alias). Front fh/ch are PER SUBSECTOR — ROM_SS_FH_C/ROM_SS_CH_C,
;   read in the subsector prologue. 9 B stride since 2026-08-17.
; FLAGS (wad_packed single source):
;   $80 SAMEDIR  $40 SOLID  $20/$10 (novt, ship 0)  $08 NEEDBB
;   $04 NEEDBT   $02/$01 (apedge, ship 0)
;   SOLID and NEEDBT/NEEDBB are mutually exclusive by construction
;   (baker + anim worker both derive them in exclusive arms).
; VERTEX STRUCTS (zp): VX1 / VX2 = VX1+VX_STRIDE:
;   +0 clipped  +1 sx_lo  +2 sx_hi  +3/4 sy_top  +5/6 sy_bot
;   +7/8 sy_btop  +9/10 sy_bbot  +11 recip m8  +12 recip s
; BANKS: transforms end L2; emit cascade runs under ONE BANK_C page at
;   stage 5 (header reads inside page around themselves); the tighten/
;   mark dispatch inherits C.  Flat build: PAGE macros are no-ops.
; ============================================================================
.scope

; ============================================================================
; STAGE 1 — TRANSFORM.  v1 goes through the chain probe first: if this
; seg's v1 is the vertex the previous transform produced (the packer
; chain-orders subsector segs, ~80% hit on consecutive front pairs),
; VX2 is copied wholesale into VX1 and the transform is skipped.
;
;   if hdr.v1_idx == last_idx:           # chain hit
;       VX1 <- VX2 (clip; and if unclipped: sx, recips)
;       if prev seg ran its y stage: VX1.front_sy <- VX2.front_sy
;                                    (v1ok: stage 4 then skips v1 front)
;   else:                                # miss
;       last_idx = hdr.v1_idx; transform v1 into VX1
;   transform v2 into VX2 (always)
;
; The chain compare is ONE byte (2026-08-13): the packer guarantees no
; two vertices of a subsector share an id low byte, and the key is
; invalidated (lo := $FF, matched by no vertex) at subsector
; boundaries and crossings — so lo equality PROVES identity, and the
; hit arm recovers the B byte from the live key instead of the header.
; The lo byte is banked into zp_v1i_l as it is read — stage 7's v1
; probe needs the key after the v2 transform overwrites zp_seg_v_idx.
; The transform (br_seg_xform_vertex, seg_xform.s) is side-baked:
; sx_vert_lo / sx_vert_hi by bit 5 of the idx B byte (senior plane).
; It writes clip/sx/recip directly into the struct named by zp_seg_ep
; and exits in bank L2 on every path.
; ============================================================================
::bf_seg_front:
.if ::C02
   LDA (zp_seg_hdr_p)                      ; v1 idx lo
.else
   LDY #0
   LDA (zp_seg_hdr_p),Y                    ; v1 idx lo
.endif
   STA zp_v1i_l
   CMP zp_seg_v_idx_l                      ; ONE compare: lo equality
   BNE chain_miss                          ; PROVES identity (pack invariant)
   LDA zp_seg_v_idx_b                      ; B byte recovered from the live
   STA zp_v1i_b                            ; key (same vertex — no header
                                        ; read)
; --- chain hit: VX2 -> VX1, in place ---
.scope
   LDA zp_seg_v2_clipped
   STA zp_seg_v1_clipped
   BNE hit_done                            ; clipped: rest undefined
   LDA zp_seg_sx2_l
   STA zp_seg_sx1_l
   LDA zp_seg_sx2_h
   STA zp_seg_sx1_h
   LDA zp_seg_v2_r_m8                      ; recips carried unconditionally:
   STA zp_seg_v1_r_m8                      ; stage 4 projects from the
   LDA zp_seg_v2_r_s                       ; struct-banked pair
   STA zp_seg_v1_r_s
; front sy donation: only valid if the PREVIOUS seg ran its y stage
; (zp_ys_done); same vertex + same subsector heights => same front pair.
   LDA zp_ys_done
   BEQ hit_done
   STA zp_ys_v1ok                          ; nonzero (BEQ-proven) = stage 4
   LDA zp_seg_sy2_top_l                    ; may skip v1's front projection
   STA zp_seg_sy1_top_l
   LDA zp_seg_sy2_top_h
   STA zp_seg_sy1_top_h
   LDA zp_seg_sy2_bot_l
   STA zp_seg_sy1_bot_l
   LDA zp_seg_sy2_bot_h
   STA zp_seg_sy1_bot_h
hit_done:
.endscope
.if ::C02
   STZ zp_ys_done                          ; donation consumed
.else
   STY zp_ys_done                          ; donation consumed (Y = 0)
.endif
   JMP v1_done_l0                          ; chain arc is pure ZP — L0 was
                                        ; never left, skip the re-page

; --- stage-1 island ---
chain_miss:                                ; A = header lo (banked in v1i_l)
   STA zp_seg_v_idx_l
.if ::C02
   STZ zp_seg_ep                           ; ep = 0: v1 -> VX1; any prev-seg
   STZ zp_ys_done                          ; donation dies here
   STZ zp_ys_v1ok
   LDY #1                                  ; (C02 probe leaves Y undefined)
.else
   STY zp_seg_ep                           ; (Y = 0 from the probe load)
   STY zp_ys_done
   STY zp_ys_v1ok
   INY                                     ; Y = 1 (rides the probe's 0 —
                                        ;  one byte cheaper than LDY #1)
.endif
   LDA (zp_seg_hdr_p),Y                    ; v1 idx B
   STA zp_v1i_b
                                        ; (SXV bank contract: bank SEG in —
                                        ; already held for the header reads)
   JSR sx_vert                             ; ABI: A = idx_b
v1_done:
v1_done_l0:
   LDA #VX_STRIDE
   STA zp_seg_ep                           ; v2 -> VX2
   LDY #2
   LDA (zp_seg_hdr_p),Y                    ; v2 idx lo
   STA zp_seg_v_idx_l
   INY
   LDA (zp_seg_hdr_p),Y                    ; v2 idx B
   STA zp_seg_v_idx_b                      ; the seg-level record: chain key,
                                        ; stage-7 VDONE, crossing recovery
                                        ; all read V2's B from here
   JSR sx_vert                             ; ABI: A = idx_b

; ============================================================================
; STAGE 2 — NEAR-CLIP RESOLUTION (mirrors fp_near_clip in fp.py).
;
;   if v1.clipped and v2.clipped: cull
;   elif one clipped: reproject that endpoint at the vy=NEAR crossing
;   (solid walls reproject too: their clamped mark_solid range comes
;    from the crossing projection — bailing solids loses occlusion)
;
; Common case (85%): neither clipped — one ORA falls through.
; The resolution block is an island past the stage-3 fast arms.
; ============================================================================
   LDA zp_seg_v1_clipped
   ORA zp_seg_v2_clipped
   BNE clip_resolve
clip_none:

; ============================================================================
; STAGE 3 — RANGE GATE.  Order the s16 sx pair, clamp to u8, bail if
; empty, then has_gap over the clamped range:
;
;   ilo = max(0, min(sx1, sx2)); ihi = min(255, max(sx1, sx2))
;   if whole seg off-screen: cull
;   if not has_gap(ilo, ihi):  cull        # every column occluded
;
; A REVERSED pair (sx2 < sx1) is dropped HERE: winding + monotone
; projection guarantee sx1 <= sx2 in exact arithmetic, so a reversal is
; a 1px sliver inverted by rounding — drop it (the swap machinery is
; retired; the python mirror returns likewise).  Everything below this
; stage may assume sx1 <= sx2.
; Order-then-clamp equals clamp-then-order (clamp8 is monotone), so the
; hi bytes drive everything:
;   equal hi bytes (common):  zero -> both in [0,255]: lo bytes are the
;       range and one lo compare decides forward/tie vs reversed;
;       nonzero -> both endpoints share an off-screen side: cull.
;   differing hi bytes: signed order test — reversed drops; else the
;       min = sx1 clamp ladder.
; ABI into hg_query: A = ihi (register-only), zp_i_l = ilo.
; span_has_gap: C=1 gap / C=0 occluded.  The clamped pair PERSISTS to
; stage 8 (zp_i_l here, zp_i_h banked at hg_pass) — nothing in the
; emit arcs writes either byte.
; Carry note: stage 4's with-back arc relies on C=1 from the BCS-fall
; at hg_query (nothing between touches carry).
; ============================================================================
   LDA zp_seg_sx1_h
   CMP zp_seg_sx2_h
   BNE range_straddle                      ; hi bytes differ: slow ladder
   TAX                                     ; shared hi byte (X: flags only)
   BNE range_cull                          ; both off one side: cull
   LDA zp_seg_sx1_l
   CMP zp_seg_sx2_l
   BEQ range_fwd                           ; tie: one-column seg is FORWARD
                                        ; (KEEP: measured 2026-08-13 — ties
                                        ; are occlusion workhorses; dropping
                                        ; them = +652/fr MEAN and 1px leaks.
                                        ; TODO revisit (Eben): the drop is
                                        ; one instruction — BCS cull_jmp
                                        ; replacing this BEQ+BCS pair; a
                                        ; play build lives in
                                        ; doom_walk_notie.ssd. If the leaks
                                        ; don't offend in play, the honest
                                        ; version needs the tie dropped in
                                        ; the python mirrors + float ref
                                        ; too, and the +652/fr paid or
                                        ; clawed back)
   BCS cull_jmp                            ; sx1 > sx2: reversed sliver, drop
range_fwd:
   STA zp_i_l                              ; ilo = sx1_lo
   LDA zp_seg_sx2_l                        ; ihi rides A
   JMP hg_query

; --- stage-2 island: near-clip resolution ---
clip_resolve:
   LDA zp_seg_v1_clipped
   BEQ clip_v2
   LDA zp_seg_v2_clipped
   BNE cull_jmp                            ; both clipped
   STA zp_seg_ep                           ; = 0 (BNE proves A=0): v1 <- xing
   JSR reproject_at_crossing
   JMP clip_none
cull_jmp:
   JMP s_advance
clip_v2:
   LDA #VX_STRIDE
   STA zp_seg_ep                           ; v2 <- crossing
   JSR reproject_at_crossing
   LDA #$80
   STA zp_seg_v_idx_b                      ; VX2 = the CROSSING, not the
                                        ; vertex.  B := $80 keeps stage
                                        ; 7's VDONE probe in the $07BC
                                        ; sentinel gap ($FF would mark
                                        ; inside RCACHE_COMPUTED).
   LDA #$FF
   STA zp_seg_v_idx_l                      ; lo := $FF kills the CHAIN (no
                                        ; vertex has lo $FF — the pack
                                        ; sentinel reservation)
   JMP clip_none

; --- stage-3 slow path: hi bytes differ (page-straddling seg) ---
; Signed hi-byte difference gives the order (lo bytes only break ties,
; and ties took the equal-hi path).  V-correction is required: |sx|
; reaches +-32577, so the s8 difference can overflow.
range_straddle:
   SEC                                     ; (CMP left carry unknown)
   SBC zp_seg_sx2_h
   BVC rs_v_ok
   EOR #$80
rs_v_ok:
   BPL range_cull                          ; sx1 > sx2 (ties took the fast
                                        ; path): reversed sliver, drop
; --- clamp ladder (min = sx1 — reversal was dropped above) ---
; Each endpoint: hi byte 0 -> lo byte used as-is; min: neg -> 0,
; pos -> whole seg off right, cull; max: neg -> off left, cull,
; pos -> 255.  ihi ends in A (the hg_query ABI).
   LDA zp_seg_sx1_h
   BEQ rm1_ilo_lo                          ; in range: lo IS ilo
   BPL range_cull                          ; min >= 256: off right
   LDA #0                                  ; min < 0: ilo = 0
   BEQ rm1_ilo_have
rm1_ilo_lo:
   LDA zp_seg_sx1_l
rm1_ilo_have:
   STA zp_i_l
   LDA zp_seg_sx2_h
   BMI range_cull                          ; max < 0: off left
   BEQ rm1_ihi_lo                          ; in range: lo IS ihi
   LDA #255
   BNE hg_query                            ; (always)
rm1_ihi_lo:
   LDA zp_seg_sx2_l
   JMP hg_query
range_cull:
   JMP s_advance
hg_query:
   JSR span_has_gap                          ; in: A = ihi, zp_i_l = ilo
   BCC range_cull                          ; C=0: no visible column, cull
hg_pass:
   STA zp_i_h                              ; bank ihi for stage 8 (A = ihi,
                                        ; UNTOUCHED by span_has_gap — its
                                        ; documented contract; STA keeps
                                        ; the C=1 the with-back arc rides).
                                        ; zp_i_l already holds ilo and
                                        ; nothing between here and stage 8
                                        ; writes either byte (the bca_ilo
                                        ; alias writes are walk-context)
; (records counts reset moved BELOW the stage-5 PAGE BANK_C 2026-08-14:
; the arenas live in bank C now; nothing reads them before the cascade)

; ============================================================================
; STAGE 4 — Y PROJECTION.  All sy pairs project HERE (post-has_gap:
; culled segs never pay), each endpoint at its own struct-banked recip
; (for a near-clipped endpoint that is the crossing recip).  Runs
; before stage 5 so struct identity still equals seg-endpoint identity.
;
;   if not (NEEDBT or NEEDBB):            # solids + stepless portals
;       for v in (v1 unless chained, v2): project front top/bot
;   else:                                 # >= 1 back pair needed
;       stage back deltas (bch-vz, bfh-vz) from the header
;       for v in (v1 [chained: back only], v2):
;           project front top/bot
;           if NEEDBT: project btop
;           if NEEDBB: project bbot       # BT miss => BB guaranteed
;
; flags & $0C is BOTH the back-deltas gate AND the per-endpoint back-
; pair predicate (SOLID is exclusive with NEEDBT/NEEDBB), so ONE test
; forks the whole stage.  The with-back arc is an island past the
; advance tail (the no-back majority falls straight through the stage
; tail into stage 5); it enters with >= 1 back flag PROVEN, so each
; endpoint opens at the NEEDBT dispatch and a BT miss means BB fires.
; project_y ABI: h in A -> Y = sy lo, A = sy hi (Y_BIAS folded,
; VWHC-memoised).  Each endpoint stages its recip + rns kernel select
; (zp_br_r_m8/r_s + rns_go_op) before its projections.
; ============================================================================
   LDA zp_seg_flags
   AND #$0C
   BEQ ys_noback
   JMP ys_withback
ys_noback:
; (bank note: solid arcs arrive L2 — the transform's exit contract —
; and nothing here pages.  THIS ARC IS the exit-L2 contract's consumer:
; project_y's VWHC planes are $B100/$B200 = bank L2 in the banked
; build (poison bisect 2026-08-13).  The with-back island manages its
; own L0 excursion and restores L2 itself.)
   LDA zp_ys_v1ok
   BNE ysnb_v2                             ; chained: VX1 front pair live
   ZERO zp_seg_ep                          ; v1 -> VX1
   LDA zp_seg_v1_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v1_r_s
   STX zp_br_r_s
   LDA rns_vec_l-1,X                       ; inlined rns select
   STA rns_go_op
   LDA zp_seg_top_dlt
   JSR project_y
   STA VX1+4
   STY VX1+3                               ; sy_top
   LDA zp_seg_bot_dlt
   JSR project_y
   STA VX1+6
   STY VX1+5                               ; sy_bot
ysnb_v2:
   LDA #VX_STRIDE
   STA zp_seg_ep                           ; v2 -> VX2
   LDA zp_seg_v2_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v2_r_s
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   LDA zp_seg_top_dlt
   JSR project_y
   STA VX2+4
   STY VX2+3                               ; sy_top
   LDA zp_seg_bot_dlt
   JSR project_y
   STA VX2+6
   STY VX2+5                               ; sy_bot
ys_done:
   LDA #1
   STA zp_ys_done                          ; VX2's sy pair is live for the
   ZERO zp_ys_v1ok                         ; next seg's chain donation

; ============================================================================
; STAGE 5 — CASCADE PAGE.  VX1 is the left endpoint (stage 3 dropped
; reversals), so every emit below is single-path.
; ============================================================================
hgp_fwd:
   PAGE BANK_C                             ; THE emit-cascade page: one page
   ZERO TOP_RECORDS, BOT_RECORDS           ; records counts reset for THIS
                                        ; seg (arenas are bank C; stage 8
                                        ; reads them only for segs that
                                        ; got here; arms re-arm below)
                                        ; dominates every arc below

; ============================================================================
; STAGE 5b — SOLID/PORTAL FORK (Eben's five-path split, 2026-08-13).
; Solids (the majority arc) FALL THROUGH into a dedicated straight-line
; cascade: two eyeline-gated no-record draws, verticals, mark_solid —
; no flag ladders, no step arms, no stage-8 dispatch.  Portals branch
; to the four-class arm cascade below (top/bottom x step-up/step-down),
; which loses its solid tests in exchange.
; ============================================================================
   BIT zp_seg_flags
   BVC portal_cascade                      ; V clear: two-sided seg
solid_cascade:
   ZERO zp_dcl_rec_buf_h                   ; records off for the whole path
; Eyeline dispatch exploits ONE-HOT bits (Eben): the prologue writes
; {0, $40, $80} BY CONSTRUCTION since 2026-08-19 — a top-kill discards
; any pending fb bit ($C0 cannot occur). The both-suppressed slab case
; (fh == ch == vz, a closed sector at exact eye height) leans on the
; clipper: its segs sit behind the closed boundary's solid-promoted
; columns, so a let-through fb dies in has_gap. Nonzero therefore means
; exactly one edge suppressed: skip the first => draw the second.
   LDA zp_ss_eskip
   BNE sc_esk                              ; one edge suppressed: island
   LDX #zp_seg_sy1_top_l - VX1
   JSR draw_clipped_line_s16_h
sc_fb:
   LDX #zp_seg_sy1_bot_l - VX1
   JSR draw_clipped_line_s16_h
sc_no_fb:
; verticals (stage-7 twin — same probe, straight-lined)
   LDA zp_v1i_l
   AND #7
   TAY
   LDA vc_bit_mask,Y
   LDX zp_v1i_b
   AND VDONE,X
   BNE sc_vs1
   JSR vs_fresh1
sc_vs1:
   LDA zp_seg_v_bitm
   LDX zp_seg_v_idx_b
   AND VDONE,X
   BNE sc_vs2
   JSR vs_fresh2
sc_vs2:
   JSR span_mark_solid                     ; zp_i clamps persisted (stage 3)
   JMP s_advance
sc_esk:
   BMI sc_fb                               ; N rides from the fork's LDA:
                                        ; $80 = top gone, bottom LIVE
   LDX #zp_seg_sy1_top_l - VX1             ; $40: bottom gone, top LIVE
   JSR draw_clipped_line_s16_h
   JMP sc_no_fb
portal_cascade:

; ============================================================================
; STAGE 6 — EMIT CASCADE.  Horizontal edges via draw_clipped_line_s16_h: X names
; the sy pair offset (same in both structs); it fetches x from
; zp_seg_sx1/sx2 and y from VX1+X/VX2+X itself.  zp_dcl_rec_buf_h arms
; (page hi) or disarms (0) record capture for the draw; the record page
; count byte is reset at arm time.  Both record pages are page-aligned
; (buf lo stays 0, zeroed once per frame).
;
;   (solids never arrive — the stage-5b fork owns them)
;   ft (front ceiling):  NEEDBT: emit, no records (self-clips if ch <= vz)
;                        else:   emit iff STEPUP_T (baked bch > ch), recorded
;   fb (front floor):    NEEDBB: emit, no records (self-clips if fh >= vz)
;                        else:   emit iff STEPUP_B (baked bfh < fh), recorded
;   bt step (bch line):  portals with NEEDBT, TOP_RECORDS armed
;   bb step (bfh line):  portals with NEEDBB, BOT_RECORDS armed
;
; The armed portal-lip arms are the ONLY fall-ins to ft_emit/fb_emit:
; solid and NEEDBT/NEEDBB entrants branch straight to their no-record
; arms, so no re-test is needed at the arm point.
; ============================================================================
; Step edges FUSED into their flag-owning arms (Eben, 2026-08-14):
; each side tests its NEEDB* bit ONCE and draws both its lines — the
; separate step-arm block (and its two retests) died; the records
; arming is duplicated per recorded draw (the lip and the step-up
; front line arm the same page).
; --- top side: NEEDBT => front-ceil (no-rec, eyeline) + bt lip
;               STEPUP_T => recorded front line; else nothing ---
   LDA zp_seg_flags
   AND #$04                                ; NEEDBT?
   BEQ ft_chk_up
; LIP FIRST (clipper-feedback abort, Eben 2026-08-14): the recorded bt
; draw accumulates its outcome in zp_dcl_out; if it emitted nothing and
; every rejection was off-TOP (or the range was solid — has_gap already
; proved a gap exists, so the pure-solid class is vestigial for these
; full-range lines), then the HIGHER front-ceil line is provably dead.
   ZERO zp_dcl_out
   LDA #>TOP_RECORDS                       ; bt lip: the aperture's new
   STA zp_dcl_rec_buf_h                    ; top — TOP_RECORDS armed
   ZERO TOP_RECORDS
   LDA #1
   STA zp_dcl_rec_off
   LDX #zp_seg_sy1_btop_l - VX1
   JSR draw_clipped_line_s16_h
   LDA zp_dcl_out
   AND #$41                                ; emitted, or off-BOTTOM seen?
   BEQ ft_top_done                         ; neither: ft is dead
   BIT zp_ss_eskip                         ; eyeline: no top edges
   BMI ft_top_done
   ZERO zp_dcl_rec_buf_h
   LDX #zp_seg_sy1_top_l - VX1             ; front-ceil, no records
   JSR draw_clipped_line_s16_h
ft_top_done:
   JMP fb_arm
ft_chk_up:
   LDA zp_seg_flags
   AND #$10                                ; SF_STEPUP_T (baked bch > ch)
   BEQ fb_arm
   LDA #>TOP_RECORDS                       ; recorded front line: it IS
   STA zp_dcl_rec_buf_h                    ; the aperture top here
   ZERO TOP_RECORDS
   LDA #1
   STA zp_dcl_rec_off
   LDX #zp_seg_sy1_top_l - VX1
   JSR draw_clipped_line_s16_h
fb_arm:
; --- bottom side: ft's mirror (NEEDBB / STEPUP_B) ---
   LDA zp_seg_flags
   AND #$08                                ; NEEDBB?
   BEQ fb_chk_up
; lip first, bottom mirror: bb zero-emission with only off-BOTTOM (or
; solid) rejections proves the LOWER front-floor line dead.
   ZERO zp_dcl_out
   LDA #>BOT_RECORDS
   STA zp_dcl_rec_buf_h
   ZERO BOT_RECORDS
   LDA #1
   STA zp_dcl_rec_off
   LDX #zp_seg_sy1_bbot_l - VX1
   JSR draw_clipped_line_s16_h
   LDA zp_dcl_out
   AND #$81                                ; emitted, or off-TOP seen?
   BEQ fb_bot_done                         ; neither: fb is dead
   BIT zp_ss_eskip                         ; eyeline: no bottom edges
   BVS fb_bot_done
   ZERO zp_dcl_rec_buf_h
   LDX #zp_seg_sy1_bot_l - VX1             ; front-floor, no records
   JSR draw_clipped_line_s16_h
fb_bot_done:
   JMP vert_stage
fb_chk_up:
   LDA zp_seg_flags
   AND #$20                                ; SF_STEPUP_B (baked bfh < fh)
   BEQ vert_stage
   LDA #>BOT_RECORDS
   STA zp_dcl_rec_buf_h
   ZERO BOT_RECORDS
   LDA #1
   STA zp_dcl_rec_off
   LDX #zp_seg_sy1_bot_l - VX1
   JSR draw_clipped_line_s16_h
vert_stage:

; ============================================================================
; STAGE 7 — VERTICALS.  Each endpoint's vertex is served ONCE per frame
; (VDONE bit) by the first rendering seg that touches it, from a
; one-byte descriptor (VDESC, senior plane at +$100).  The probe is
; inline: a served vertex exits in ~20 cycles with no JSR.
;
;   for v in (v1, v2):
;       if VDONE[v]: continue
;       vs_fresh(v)          # mark; gate; dispatch descriptor
;
; v1's probe rebuilds mask/index from the banked key (zp_v1i_*); v2's
; mask is still live in zp_seg_v_bitm (its transform stored it and
; nothing since writes it — chain hits skip v1's store, and v2's own
; transform always ran last).
; ============================================================================
   LDA zp_v1i_l
   AND #7
   TAY
   LDA vc_bit_mask,Y
   LDX zp_v1i_b                            ; B byte IS the bitmap index
   AND VDONE,X
   BNE vs1_done
   JSR vs_fresh1
vs1_done:
   LDA zp_seg_v_bitm
   LDX zp_seg_v_idx_b
   AND VDONE,X
   BNE vs2_done
   JSR vs_fresh2
vs2_done:

; ============================================================================
; STAGE 8 — OCCLUSION.  zp_i_l/zp_i_h still hold stage 3's clamped
; range: the only other writers of the pair are the bca_ilo/bca_ihi
; aliases (bbox visibility — walk context, never inside the seg loop),
; and stage 3 stores ilo directly while hg_pass banks ihi off the
; has_gap ABI ride.  (The recompute + its clamp_sat islands died
; 2026-08-13 — the "scratch does not survive" note was a DEFQ fossil.)
;
;   if SOLID:        mark_solid(ilo, ihi)
;   elif records:    tighten_from_records(ilo, ihi)
;   elif not seg_zero_rec_solid(): pass   # aperture covers the screen
;   else:            mark_solid(ilo, ihi) # aperture wholly off-screen:
;                                         # every column is wall
; ============================================================================
ms_dispatch:
   LDA TOP_RECORDS                         ; (solids took the stage-5b path:
                                        ; only portals arrive here)                         ; portal: tighten iff any records
   ORA BOT_RECORDS                         ; were captured (consumed in
   BEQ ms_zero_rec                         ; place, bank C guaranteed)
   JSR tighten_from_records
   JMP ms_advance
; --- stage-8 island (this seam costs nothing: the JSR/JMP above) ---
ms_zero_rec:
; no records: if the aperture covers the whole screen there is nothing
; to close; wholly off-screen means every column is wall (tfr.s)
   JSR seg_zero_rec_solid
   BCC ms_advance
ms_solid:
   JSR span_mark_solid
ms_advance:

; ============================================================================
; STAGE 9 — ADVANCE.  Two entries: ::s_advance re-pages L0 for the next
; header read (emit arcs end bank C; mid-loop culls end L2);
; ::s_advance_l0 is the backface back-exit twin that never left L0 (the
; 12-byte duplication keeps the majority arc page-free).
; zp_ys_v1ok MUST be cleared on the cull arcs: a chain-hit seg that
; culls here never consumed its donation, and the stale flag would make
; the NEXT seg's y stage skip v1 with two-seg-old sy values.  The
; backface arc never touches the chain and must NOT clear it.
; ============================================================================
::s_advance:
   ZERO zp_ys_v1ok
   CLC
   LDA zp_seg_hdr_p
   ADC #LAY_HDR_STRIDE                     ; headers are page-slotted: a run
   STA zp_seg_hdr_p                        ; never crosses its page (packer
   DEC zp_seg_count                        ; assert) — hi byte is constant
   BMI sa_done                             ; count holds cnt-1 (2026-08-19)
   PAGE BANK_SEG
   JMP seg_proc
sa_done:
   RTS
; (::s_advance_l0 hoisted into subsector.s 2026-08-13 — it sits right
;  above seg_proc and FALLS into it, killing its JMP on the majority
;  backface arc; this s_advance keeps the ms_advance fall-in and the
;  cull_jmp entries, so it stays here with its page + jump.)

; ============================================================================
; STAGE 4 ISLAND — the with-back y-projection arc.  Entered with
; >= 1 of NEEDBT/NEEDBB PROVEN (the stage-4 fork) and C = 1 (the
; hg_query BCS-fall; nothing between touches carry — the fork's
; LDA/AND/BEQ/JMP included, so the first SBC needs no SEC).
;
;   stage btop_dlt = bch - vz, bbot_dlt = bfh - vz   (header, bank L0)
;   v1: chained -> back pair only; else front pair too
;   v2: front pair + back pair
;   per endpoint: NEEDBT ? project btop : (BB guaranteed)
;                 NEEDBB ? project bbot
; ============================================================================
ys_withback:
                                        ; (bank SEG held since stage 1 —
                                        ; the fork and hg_query touch no
                                        ; ROMSEL; header reads are safe)
; The back pair is a PALETTE ENTRY since 2026-08-17 (96 entries for 649 segs):
; read the u8 id, then index the two planes. Y is free here (the old code left
; it clobbered too) and X must not be touched — the caller reloads it below,
; but only after this block. None of LDY/LDA/TAY disturbs the C=1 that
; hg_query left, which the first SBC still rides.
   LDY #LAY_SH_BPAL
   LDA (zp_seg_hdr_p),Y
   TAY                                     ; Y = back-pair palette id
   LDA ROM_BPAL_BCH_C,Y                    ; bch
   SBC zp_br_vz                            ; (no SEC: C=1 from hg_query)
   STA zp_seg_btop_dlt
   LDA ROM_BPAL_BFH_C,Y                    ; bfh
   SEC
   SBC zp_br_vz
   STA zp_seg_bbot_dlt
                                        ; (projections read VWHC — bank SEG,
                                        ; still held from the header reads)
   LDA zp_ys_v1ok
   BEQ ysb_v1_full
   ZERO zp_seg_ep                          ; chained v1: front pair is live,
   LDA zp_seg_v1_r_m8                      ; stage recip + kernel and go
   STA zp_br_r_m8                          ; straight to the back pair
   LDX zp_seg_v1_r_s
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   JMP ysb_v1_back
ysb_v1_full:
   ZERO zp_seg_ep                          ; v1 -> VX1
   LDA zp_seg_v1_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v1_r_s
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   LDA zp_seg_top_dlt                      ; front pair
   JSR project_y
   STA VX1+4
   STY VX1+3                               ; sy_top
   LDA zp_seg_bot_dlt
   JSR project_y
   STA VX1+6
   STY VX1+5                               ; sy_bot
ysb_v1_back:
   LDA zp_seg_flags                        ; >= 1 back flag proven:
   AND #$04                                ; open at the NEEDBT dispatch
   BEQ ysb_v1_bb                           ; no BT -> BB is GUARANTEED
   LDA zp_seg_btop_dlt
   JSR project_y
   STA VX1+8
   STY VX1+7                               ; sy_btop
   LDA zp_seg_flags
   AND #$08
   BEQ ysb_v2
ysb_v1_bb:
   LDA zp_seg_bbot_dlt
   JSR project_y
   STA VX1+10
   STY VX1+9                               ; sy_bbot
ysb_v2:
   LDA #VX_STRIDE
   STA zp_seg_ep                           ; v2 -> VX2
   LDA zp_seg_v2_r_m8
   STA zp_br_r_m8
   LDX zp_seg_v2_r_s
   STX zp_br_r_s
   LDA rns_vec_l-1,X
   STA rns_go_op
   LDA zp_seg_top_dlt                      ; front pair
   JSR project_y
   STA VX2+4
   STY VX2+3                               ; sy_top
   LDA zp_seg_bot_dlt
   JSR project_y
   STA VX2+6
   STY VX2+5                               ; sy_bot
   LDA zp_seg_flags                        ; back pair (mirror of v1)
   AND #$04
   BEQ ysb_v2_bb
   LDA zp_seg_btop_dlt
   JSR project_y
   STA VX2+8
   STY VX2+7                               ; sy_btop
   LDA zp_seg_flags
   AND #$08
   BEQ ysb_done
ysb_v2_bb:
   LDA zp_seg_bbot_dlt
   JSR project_y
   STA VX2+10
   STY VX2+9                               ; sy_bbot
ysb_done:
   JMP ys_done
.endscope

; ============================================================================
; STAGE 7 SUBROUTINES — vs_fresh1 / vs_fresh2: serve a fresh vertex.
;
;   mark VDONE (unconditional and FIRST: desc-0 vertices get marked
;       too — nothing can ever draw there, and the mark upgrades every
;       later touch to the probe's fast exit)
;   if clipped or column off-screen: return   (vertex facts —
;       trigger-invariant, so marking before the gates is safe)
;   desc = VDESC[idx]  (senior plane at +$100 by idx bit 13)
;   if desc == 0: return
;   dispatch:
;     $01       full corner:  top -> bot
;     $02       bottom step:  bbot -> bot   [gated NEEDBB]
;     $03       top step:     top -> btop   [gated NEEDBT]
;     $04       frame pair:   top step then bottom step
;     $80|i     explicit span table walk (VEXPL, rare)
;   The NEEDBT/NEEDBB gates make solid/stepless triggers self-annul
;   (their world bch/bfh alias fh/ch — the codes never fire).
;
; in: v1 site: Y = idx & 7, X = idx B byte (probe leftovers, reused for
;     the mark); key re-read from zp_v1i_*.  v2 site: mask in A via
;     zp_seg_v_bitm, X = idx B; key from zp_seg_v_idx_*.
; Verticals draw via dcl_vert_on with zp_line_yl/yr staged and the
; column in A (pre-gated on-screen — the +2 test above).  Bank C
; throughout; the explicit path excurses to L2 around project_y.
; ============================================================================
.scope
::vs_fresh1:
   LDA vc_bit_mask,Y                       ; mark
   ORA VDONE,X
   STA VDONE,X
   LDA VX1+0                               ; clipped?
   ORA VX1+2                               ; column off-screen?
   BNE f1_rts
   LDY zp_v1i_l
   LDA zp_v1i_b
   AND #$20                                ; senior plane (ids 256+)
   BNE f1_hi
   LDA VDESC,Y
   BNE f1_go
f1_rts:
   RTS
f1_hi:
   LDA VDESC+$100,Y
   BNE f1_go
   RTS
f1_go:
   LDX #0                                  ; struct VX1.  (X is LIVE in the
   BEQ vs_go                               ; vsx arms — indexes VX1+n,X —
                                        ; so no C02 STZ pull here; branch
                                        ; always: Z from LDX)
::vs_fresh2:
   LDA zp_seg_v_bitm                       ; mark (mask still live — see
   ORA VDONE,X                             ; the stage-7 site note)
   STA VDONE,X
   LDA VX2+0                               ; clipped?
   ORA VX2+2                               ; column off-screen?
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
   LDX #VX_STRIDE                          ; struct VX2
vs_go:
   STX zp_vs_x                             ; struct offset banked (dcl and
                                        ; the projector clobber X)
   CMP #2                                  ; A = descriptor (nonzero);
   BCC vsx_c1                              ; $01 first (12.3/fr census
   BEQ vsx_c2                              ; 2026-08-14 — was 3rd) / $02
   CMP #$80
   BCS vsx_expl                            ; $80|i: explicit table (5.0/fr)
   CMP #4
   BCC vsx_c3                              ; $03
   JSR vsx_do_c3                           ; $04: top piece...
   LDX zp_vs_x
vsx_c2:                                    ; bottom step: bbot -> bot
   LDA zp_seg_flags
   AND #$08                                ; NEEDBB gate (self-annul)
   BEQ vsx_rts
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
   LDA VX1+1,X                             ; column (pre-gated on-screen)
   JMP dcl_vert_on                      ; tail: RTS to our caller

::vsx_do_c3:                               ; top step: top -> btop
   LDA zp_seg_flags
   AND #$04                                ; NEEDBT gate (self-annul)
   BEQ c3_rts
   LDA VX1+3,X
   STA zp_line_yl_l
   LDA VX1+4,X
   STA zp_line_yl_h
   LDA VX1+7,X
   STA zp_line_yr_l
   LDA VX1+8,X
   STA zp_line_yr_h
   LDA VX1+1,X                             ; column (pre-gated on-screen)
   JMP dcl_vert_on                      ; tail: RTS to our caller
c3_rts:
   RTS

; --- explicit span table walk ($80|i): each span clamps its world
; height pair to this trigger's front sector, projects at the
; endpoint's own recip, and emits.  Recip + kernel select are hoisted
; out of the span loop (one recip per vertex).  VEXPL reads run under
; the ambient bank C; only the projections need the L2 window. ---
vsx_expl:
   AND #$7F
   STA zp_vs_i                             ; span index
   LDA VX1+11,X                            ; endpoint recip -> projector
   STA zp_br_r_m8
   LDA VX1+12,X
   STA zp_br_r_s
   RNS_SELECT                              ; (A = S in; clobbers X)
vsx_span:
   LDY zp_vs_i
; c_lo = max(h_lo, fh); c_hi = min(h_hi, ch)   [signed s8, V-corrected]
   LDA VEXPL_LO,Y
   SEC
   SBC zp_seg_fh
   BVC el_v_ok
   EOR #$80
el_v_ok:
   BMI el_use_fh
   LDA VEXPL_LO,Y
   JMP el_have
el_use_fh:
   LDA zp_seg_fh
el_have:
   STA zp_vs_hl
   LDA VEXPL_HI,Y
   SEC
   SBC zp_seg_ch
   BVC eh_v_ok
   EOR #$80
eh_v_ok:
   BPL eh_use_ch
   LDA VEXPL_HI,Y
   JMP eh_have
eh_use_ch:
   LDA zp_seg_ch
eh_have:
   STA zp_vs_hh
   SEC                                     ; empty? (c_hi <= c_lo, signed;
   SBC zp_vs_hl                            ; A rides from the STA)
   BVC em_v_ok
   EOR #$80
em_v_ok:
   BMI vsx_next
   BEQ vsx_next
   PAGE BANK_SEG                           ; project both ends vs eye height
                                        ; (project_y reads VWHC, bank SEG)
   LDA zp_vs_hh
   SEC
   SBC zp_br_vz
   JSR project_y
   STA zp_line_yl_h
   STY zp_line_yl_l
   LDA zp_vs_hl
   SEC
   SBC zp_br_vz
   JSR project_y
   STA zp_line_yr_h
   STY zp_line_yr_l
   PAGE BANK_C
   LDX zp_vs_x
   LDA VX1+1,X                             ; column (pre-gated on-screen)
   JSR dcl_vert_on
vsx_next:
   LDY zp_vs_i
   LDA VEXPL_CONT,Y                        ; continuation flag
   BEQ vsx_done
   INC zp_vs_i
   JMP vsx_span
vsx_done:
   RTS
.endscope
