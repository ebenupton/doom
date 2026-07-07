
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
; --- Mark visited (test instrumentation) ---
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
LDA vc_bit_mask,X
PHA
LDA #<SS_VISITED_BITMAP
CLC
ADC zp_br_t0
STA zp_br_p
LDA #>SS_VISITED_BITMAP
ADC zp_br_t1
STA zp_br_p_h
LDY #0
PLA
ORA (zp_br_p),Y
STA (zp_br_p),Y

; --- Read subsector header from ROM_SS + id*4 ---
LDA zp_node_chlo
STA zp_br_t0
LDA zp_node_chhi
STA zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
CLC
LDA zp_rom_ss_lo
ADC zp_br_t0
STA zp_br_p
LDA zp_rom_ss_hi
ADC zp_br_t1
STA zp_br_p_h
LDY #0
LDA (zp_br_p),Y
STA zp_seg_count
LDY #2
LDA (zp_br_p),Y
STA zp_seg_first_lo
LDY #3
LDA (zp_br_p),Y
STA zp_seg_first_hi

; Persistent per-seg pointers: computed once here, advanced by the
; loop (+12 header, +6 FHCH) — the old code re-multiplied si*12 and
; si*6 on every seg. fhch_ptr_si6 leaves si*6 in t0/t1; one more
; shift gives si*12.
JSR fhch_ptr_si6
LDA zp_br_p
STA zp_fhch_p
LDA zp_br_p_h
STA zp_fhch_p_h
ASL zp_br_t0
ROL zp_br_t1
; si*12
CLC
LDA zp_rom_seg_hdr_lo
ADC zp_br_t0
STA zp_seg_hdr_p
LDA zp_rom_seg_hdr_hi
ADC zp_br_t1
STA zp_seg_hdr_p_h

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
STA $BC                                 ; ZP_DCL_REC_BUF lo
STA $BD                                 ; ZP_DCL_REC_BUF hi (= "no records buffer")

; --- seg header via the persistent pointer. Back-face inputs first
; (offsets 4-10: lv1x/lv1y/ldx/ldy/flags); v1/v2 (offsets 0-3) are only
; read after the test passes — back-facing segs never need them. ---
LDA zp_seg_hdr_p
STA zp_br_p
LDA zp_seg_hdr_p_h
STA zp_br_p_h
LDY #4
LDA (zp_br_p),Y
STA zp_seg_lv1x_lo
INY
LDA (zp_br_p),Y
STA zp_seg_lv1x_hi
INY
LDA (zp_br_p),Y
STA zp_seg_lv1y_lo
INY
LDA (zp_br_p),Y
STA zp_seg_lv1y_hi
INY
LDA (zp_br_p),Y
STA zp_seg_ldx
INY
LDA (zp_br_p),Y
STA zp_seg_ldy
INY
LDA (zp_br_p),Y
STA zp_seg_flags

; --- Back-face test ---
JSR br_back_face_test
LDA zp_seg_skip
BEQ bf_passed
JMP s_advance
bf_passed:
; front-facing: fetch v1/v2 (the test clobbers zp_br_p — reload)
LDA zp_seg_hdr_p
STA zp_br_p
LDA zp_seg_hdr_p_h
STA zp_br_p_h
LDY #0
LDA (zp_br_p),Y
STA zp_seg_v1_lo
INY
LDA (zp_br_p),Y
STA zp_seg_v1_hi
INY
LDA (zp_br_p),Y
STA zp_seg_v2_lo
INY
LDA (zp_br_p),Y
STA zp_seg_v2_hi

; --- Read fh, ch, bfh, bch from the 6-byte/seg FHCH table:
;     [fh, ch, bfh|apv1_ch, bch|apv1_fh, apv2_ch, apv2_fh].
;     Bytes 4/5 carry the solid-seg APV2 aperture heights (the seg
;     detail ROM is not resident on the 6502). ---
LDA zp_fhch_p
STA zp_br_p
LDA zp_fhch_p_h
STA zp_br_p_h
LDY #0
LDA (zp_br_p),Y
STA zp_seg_fh
INY
LDA (zp_br_p),Y
STA zp_seg_ch
INY
LDA (zp_br_p),Y
STA zp_seg_bfh
INY
LDA (zp_br_p),Y
STA zp_seg_bch
; Height deltas (all s8). Front: top_dlt = ch - vz, bot_dlt = fh - vz.
; Back: btop_dlt = bch - vz, bbot_dlt = bfh - vz.
LDA zp_seg_ch
SEC
SBC zp_br_vz
STA zp_seg_top_dlt
LDA zp_seg_fh
SEC
SBC zp_br_vz
STA zp_seg_bot_dlt
; Back deltas are consumed ONLY by do_project_y, which reads them only when
; NEEDBT($04)/NEEDBB($08)/APEDGE1($40) is set. Skip the 2 subtractions for
; plain solids/portals (the common case) — conservative: this superset
; never skips a delta do_project_y will read.
LDA zp_seg_flags
AND #$4C
BEQ skip_bdlt
LDA zp_seg_bch
SEC
SBC zp_br_vz
STA zp_seg_btop_dlt
LDA zp_seg_bfh
SEC
SBC zp_br_vz
STA zp_seg_bbot_dlt
skip_bdlt:

; Transform v1. Always copy evy/evx/clipped so both endpoints are
; available for near-plane crossing math even when one side is clipped.
LDA zp_seg_v1_lo
STA zp_br_t0
LDA zp_seg_v1_hi
STA zp_br_t1
JSR br_seg_xform_vertex
LDA zp_seg_cur_evy
STA zp_seg_v1_evy
LDA zp_seg_cur_evx
STA zp_seg_v1_evx
LDA zp_seg_skip
STA zp_seg_v1_clipped
BNE s_v1_skipped
JSR copy_seg_to_v1
s_v1_skipped:

; Transform v2.
LDA zp_seg_v2_lo
STA zp_br_t0
LDA zp_seg_v2_hi
STA zp_br_t1
JSR br_seg_xform_vertex
LDA zp_seg_cur_evy
STA zp_seg_v2_evy
LDA zp_seg_cur_evx
STA zp_seg_v2_evx
LDA zp_seg_skip
STA zp_seg_v2_clipped
BNE s_v2_skipped
JSR copy_seg_to_v2
s_v2_skipped:

; Both vertices xform'd. If both clipped → bail. If exactly one clipped,
; reproject from crossing point and copy into that vertex's slots.
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
JSR reproject_at_crossing
JSR copy_seg_to_v1
JMP s_both_have_proj
s_advance_jmp:
JMP s_advance
s_v2_was_clipped:
JSR reproject_at_crossing
JSR copy_seg_to_v2
s_both_have_proj:

; Match Python's has_gap wrapper:
;   ilo = max(0, lo); ihi = min(255, hi); if ihi < ilo: return False
; The wrapper-side off-screen test bails BEFORE the 6502 has_gap call,
; so we replicate it here. Both endpoints off-screen-left  (both s16 hi
; negative) → ihi = -lo_min (negative), ilo = 0  → ihi < ilo, bail.
; Both off-screen-right (both s16 hi > 0)         → ilo = lo_max > 255,
; clamped to 255; ihi clamped to 255 too — borderline; let has_gap run.
; Only the left/negative case bails cleanly with a sign test.
LDA zp_seg_sx1_hi
BPL hg_sx1_nonneg
LDA zp_seg_sx2_hi
BPL hg_sx1_nonneg
JMP s_advance                           ; both s16 hi < 0 → off-screen left
hg_sx1_nonneg:
; Both off-screen right? Need BOTH hi bytes strictly positive (>= 1).
LDA zp_seg_sx1_hi
BMI hg_check_x
; one negative → mixed, don't bail
BEQ hg_check_x                          ; one zero → in u8 range, don't bail
LDA zp_seg_sx2_hi
BMI hg_check_x
BEQ hg_check_x
JMP s_advance                           ; both s16 hi > 0 → off-screen right
hg_check_x:

; Compute clamped u8 ilo/ihi from sx1/sx2.
LDA zp_seg_sx1_hi
BMI hg_sx1_neg
BEQ hg_sx1_lo
LDA #$FF
STA zp_br_t2
JMP hg_sx2
hg_sx1_neg:
LDA #0
STA zp_br_t2
JMP hg_sx2
hg_sx1_lo:
LDA zp_seg_sx1_lo
STA zp_br_t2
hg_sx2:
LDA zp_seg_sx2_hi
BMI hg_sx2_neg
BEQ hg_sx2_lo
LDA #$FF
STA zp_br_t3
JMP hg_setrange
hg_sx2_neg:
LDA #0
STA zp_br_t3
JMP hg_setrange
hg_sx2_lo:
LDA zp_seg_sx2_lo
STA zp_br_t3
hg_setrange:
LDA zp_br_t2
CMP zp_br_t3
BCC hg_t2lt
LDA zp_br_t3
STA $C2
LDA zp_br_t2
STA $C3
JMP hg_query
hg_t2lt:
LDA zp_br_t2
STA $C2
LDA zp_br_t3
STA $C3
hg_query:
PAGE BANK_C
JSR SC_HAS_GAP
BNE hg_pass
JMP s_advance
hg_pass:

; --- Emit top horizontal (front-sector ceiling) ---
; Solid wall:        always.
; Portal w/ NEEDBT:  iff ch > vz (face above eyeline, ft visible).
; Portal w/o NEEDBT: iff bch > ch (back ceiling above front; step visible).
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
; bch > ch ?
LDA zp_seg_bch
SEC
SBC zp_seg_ch
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
STA $BD
; portal-lip → TOP_RECORDS
JMP ft_set_line
ft_no_rec:
LDA #0
STA $BD
ft_set_line:
LDA #0
STA $BC
LDA zp_seg_sx1_lo
STA zp_line_xl
LDA zp_seg_sx1_hi
STA $B2
LDA zp_seg_sy1_top_lo
STA zp_line_yl
LDA zp_seg_sy1_top_hi
STA $B3
LDA zp_seg_sx2_lo
STA zp_line_xr
LDA zp_seg_sx2_hi
STA $B4
LDA zp_seg_sy2_top_lo
STA zp_line_yr
LDA zp_seg_sy2_top_hi
STA $B5
PAGE BANK_C
JSR SC_DRAW_S16
LDA #0
STA $BC
STA $BD
ft_skip:

; --- Emit bottom horizontal (front-sector floor) ---
; Solid:             always.
; Portal w/ NEEDBB:  iff fh < vz (face below eyeline, fb visible).
; Portal w/o NEEDBB: iff bfh < fh (back floor below front; step visible).
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
; bfh < fh ?
LDA zp_seg_fh
SEC
SBC zp_seg_bfh
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
STA $BD
; portal-lip → BOT_RECORDS
JMP fb_set_line
fb_no_rec:
LDA #0
STA $BD
fb_set_line:
LDA #0
STA $BC
LDA zp_seg_sx1_lo
STA zp_line_xl
LDA zp_seg_sx1_hi
STA $B2
LDA zp_seg_sy1_bot_lo
STA zp_line_yl
LDA zp_seg_sy1_bot_hi
STA $B3
LDA zp_seg_sx2_lo
STA zp_line_xr
LDA zp_seg_sx2_hi
STA $B4
LDA zp_seg_sy2_bot_lo
STA zp_line_yr
LDA zp_seg_sy2_bot_hi
STA $B5
PAGE BANK_C
JSR SC_DRAW_S16
LDA #0
STA $BC
STA $BD
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
LDA zp_seg_sx1_lo
STA zp_line_xl
LDA zp_seg_sx1_hi
STA $B2
LDA zp_seg_sy1_btop_lo
STA zp_line_yl
LDA zp_seg_sy1_btop_hi
STA $B3
LDA zp_seg_sx2_lo
STA zp_line_xr
LDA zp_seg_sx2_hi
STA $B4
LDA zp_seg_sy2_btop_lo
STA zp_line_yr
LDA zp_seg_sy2_btop_hi
STA $B5
LDA #0
STA $BC
LDA #$07
STA $BD
; TOP_RECORDS = $0700
PAGE BANK_C
JSR SC_DRAW_S16
LDA #0
STA $BC
STA $BD
; reset records pointer
step_no_top:

; Back floor step if NEEDBB (= $08) set: emit (sx1, bb1) → (sx2, bb2).
LDA zp_seg_flags
AND #$08
BEQ step_no_bot
LDA zp_seg_sx1_lo
STA zp_line_xl
LDA zp_seg_sx1_hi
STA $B2
LDA zp_seg_sy1_bbot_lo
STA zp_line_yl
LDA zp_seg_sy1_bbot_hi
STA $B3
LDA zp_seg_sx2_lo
STA zp_line_xr
LDA zp_seg_sx2_hi
STA $B4
LDA zp_seg_sy2_bbot_lo
STA zp_line_yr
LDA zp_seg_sy2_bbot_hi
STA $B5
LDA #0
STA $BC
LDA #$08
STA $BD
; BOT_RECORDS = $0800
PAGE BANK_C
JSR SC_DRAW_S16
LDA #0
STA $BC
STA $BD
step_no_bot:
step_skip:

; --- Emit verticals ---
; Solid wall: full ft-to-fb on both sides.
; Portal: ft-to-bt for NEEDBT (top doorframe edge),
;         bb-to-fb for NEEDBB (bottom doorframe edge).
;         Both for NEEDBT+NEEDBB. Otherwise no vertical.
; SF_NOVT1/NOVT2 still suppress verticals at BSP-internal split vertices.

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
STA zp_line_yl
LDA zp_seg_sy1_top_hi
STA $B3
LDA zp_seg_sy1_bot_lo
STA zp_line_yr
LDA zp_seg_sy1_bot_hi
STA $B5
JSR emit_vert_sx1
JMP skip_lvert
lvert_portal:
; NEEDBT? top piece ft1 → bt1
LDA zp_seg_flags
AND #$04
BEQ lvert_no_top
LDA zp_seg_sy1_top_lo
STA zp_line_yl
LDA zp_seg_sy1_top_hi
STA $B3
LDA zp_seg_sy1_btop_lo
STA zp_line_yr
LDA zp_seg_sy1_btop_hi
STA $B5
JSR emit_vert_sx1
lvert_no_top:
; NEEDBB? bottom piece bb1 → fb1
LDA zp_seg_flags
AND #$08
BEQ skip_lvert
LDA zp_seg_sy1_bbot_lo
STA zp_line_yl
LDA zp_seg_sy1_bbot_hi
STA $B3
LDA zp_seg_sy1_bot_lo
STA zp_line_yr
LDA zp_seg_sy1_bot_hi
STA $B5
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
STA zp_line_yl
LDA zp_seg_sy2_top_hi
STA $B3
LDA zp_seg_sy2_bot_lo
STA zp_line_yr
LDA zp_seg_sy2_bot_hi
STA $B5
JSR emit_vert_sx2
JMP skip_rvert
rvert_portal:
LDA zp_seg_flags
AND #$04
BEQ rvert_no_top
LDA zp_seg_sy2_top_lo
STA zp_line_yl
LDA zp_seg_sy2_top_hi
STA $B3
LDA zp_seg_sy2_btop_lo
STA zp_line_yr
LDA zp_seg_sy2_btop_hi
STA $B5
JSR emit_vert_sx2
rvert_no_top:
LDA zp_seg_flags
AND #$08
BEQ skip_rvert
LDA zp_seg_sy2_bbot_lo
STA zp_line_yl
LDA zp_seg_sy2_bbot_hi
STA $B3
LDA zp_seg_sy2_bot_lo
STA zp_line_yr
LDA zp_seg_sy2_bot_hi
STA $B5
JSR emit_vert_sx2
skip_rvert:

; --- NOVT aperture-edge verticals (SF_APEDGE1/2) ---
JSR ap_edges

; --- Compute clamped u8 ilo/ihi for both solid (mark_solid) and
;     portal (tighten) cases.
; Clamp sx1 to u8 → zp_br_t2
LDA zp_seg_sx1_hi
BMI ms_sx1_neg
BEQ ms_sx1_lo
LDA #$FF
STA zp_br_t2
JMP ms_sx2
ms_sx1_neg:
LDA #0
STA zp_br_t2
JMP ms_sx2
ms_sx1_lo:
LDA zp_seg_sx1_lo
STA zp_br_t2
ms_sx2:
; Clamp sx2 to u8 → zp_br_t3
LDA zp_seg_sx2_hi
BMI ms_sx2_neg
BEQ ms_sx2_lo
LDA #$FF
STA zp_br_t3
JMP ms_setrange
ms_sx2_neg:
LDA #0
STA zp_br_t3
JMP ms_setrange
ms_sx2_lo:
LDA zp_seg_sx2_lo
STA zp_br_t3
ms_setrange:
; ilo = min(t2, t3), ihi = max(t2, t3)
LDA zp_br_t2
CMP zp_br_t3
BCC ms_t2lt
LDA zp_br_t3
STA $C2
; ilo = t3
LDA zp_br_t2
STA $C3
; ihi = t2
JMP ms_dispatch
ms_t2lt:
LDA zp_br_t2
STA $C2
; ilo = t2
LDA zp_br_t3
STA $C3
; ihi = t3
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

s_advance:
LDA #0
STA zp_seg_skip
INC zp_seg_first_lo
BNE s_no_carry
INC zp_seg_first_hi
s_no_carry:
CLC
LDA zp_seg_hdr_p
ADC #12
STA zp_seg_hdr_p
LDA zp_seg_hdr_p_h
ADC #0
STA zp_seg_hdr_p_h
CLC
LDA zp_fhch_p
ADC #6
STA zp_fhch_p
LDA zp_fhch_p_h
ADC #0
STA zp_fhch_p_h
DEC zp_seg_count
JMP seg_loop
.endscope

; (drain_deferred_ms replaced by defq_drain — see the $0B00 region.)

; emit_vert_sx1 — caller has set yl/yh/yr/yh in zp_line_yl/$B3/zp_line_yr/$B5.
; Fills xl/xh/xr/xh from sx1, clears records hi byte, calls SC_DRAW_S16.
emit_vert_sx1:
LDA zp_seg_sx1_lo
STA zp_line_xl
LDA zp_seg_sx1_hi
STA $B2
LDA zp_seg_sx1_lo
STA zp_line_xr
LDA zp_seg_sx1_hi
STA $B4
LDA #0
STA $BD
PAGE BANK_C
JMP SC_DRAW_S16

emit_vert_sx2:
LDA zp_seg_sx2_lo
STA zp_line_xl
LDA zp_seg_sx2_hi
STA $B2
LDA zp_seg_sx2_lo
STA zp_line_xr
LDA zp_seg_sx2_hi
STA $B4
LDA #0
STA $BD
PAGE BANK_C
JMP SC_DRAW_S16
