.include "layout.inc"
.include "zp.inc"
; CPU target: every builder MUST pass -D C02=0 (6502) or -D C02=1 (65C02 opcodes).
.if C02
.setcpu "65C02"
.endif
; ZERO addr: zero a byte. 65C02 = STZ (A preserved); 6502 = LDA #0:STA (A
; clobbered) — only use where A is dead afterwards. (Same macro as the
; bsp/clip headers; the angle module grew C02 sites 2026-07-21.)
.macro ZERO addr
.if ::C02
STZ addr
.else
   LDA #0
   STA addr
.endif
.endmacro
; SlopeDiv for the angle-space pipeline (M3 primitive, unit-tested standalone).
; Computes floor(num * 2^SLOPEBITS / den) clamped to SLOPERANGE, for num <= den.
; SLOPEBITS=10, SLOPERANGE=1024. num,den are u16 (bbox/seg deltas, <= ~660).
;
;   in : (historical: the retired slope_div took num/den here; the
;        sd_* names died 2026-07-19 — corners use pa_dx/pa_dy direct)
;   out: sd_q   (u16 $74/$75)  in [0, 1024]
;
; num>=den -> 1024 (the exact-divide remainder never reaches 0; matches the
; Python clamp). Otherwise a 10-iteration restoring divide: r=num; 10x
; { r<<=1; q<<=1; if r>=den { r-=den; q+=1 } } yields floor(num*2^10/den).


; PLACEMENT: flat = the ANG region $E940-$F1FF (bsp_render_ang.bin; the
; module physically cannot join the flat CODE region — total code
; exceeds any contiguous flat window). Banked = the ANG segment floats
; inside the one CODE region $2C00-$57FF like everything else. Tables:
; flat TA_LO $DC00, TA_HI $F200, VATOX $F600 (harness-seeded); banked =
; the L2 window ($8000/$8400/$8900, loader-seeded). The entry jump
; table that lived here is GONE (2026-07-16): bsp_render .imports
; slope_div / bbox_check_angle directly (linker-resolved); ang_head
; marks the region head for engine_load.py's ang-bin placement.
.if BANKED
SEG_CODE
.else
SEG_HIGH
.endif
.export bbox_check_angle
.import span_has_gap                    ; fused visible exits (bca.s) chain
SC_HAS_GAP = span_has_gap               ; into has_gap (main-resident)
ang_head:
; (slope_div is GONE — option F, 2026-07-17: the corner pipeline reads
;  ATANEXP[L8[den]-L8[num]] instead of dividing; tools/atanexp_cert.py
;  certifies the tables and EPSILON. ~450 bytes of ANG freed, and the
;  tantoangle tables died with it.)

; point_to_angle(dx,dy) -> fineangle [0,4096). 8 octants; each stages
; min/max magnitudes and reads ta' = ATANEXP[L8[max] - L8[min]] (option
; F). Tables harness/loader-seeded from tools/atanexp_cert.py output.
; ($3B/$3C, $71/$72 freed: abs now writes the divide operands directly --
;  reused below for bca_afn / bca_cy)
.if BANKED
L8_TAB = $8000                          ; bank L2 TABLES group (2026-07-21
AE_LO  = $8100                          ; regroup): L8, AE lo/hi, VATOX
AE_HI  = $8200                          ; $8300, recip $8800 — all math
                                        ; tables contiguous ($8000-$8BFF).
                                        ; ONE source: tools/atanexp_cert.py
.else
L8_TAB = $D900                          ; flat TABLES block (2026-07-21 map)
AE_LO  = $DA00
AE_HI  = $DB00
.endif

; point_to_angle: INLINED into corner_phi (its sole caller); see below.

; per-octant base (0/ANG90=1024/ANG180=2048/ANG270=3072) and sign (+ / $80=-).
; base_lo is always 0 (bases are multiples of 256) so the table is omitted.
;
; Octant index oct = sx | sy | axgt (stored pre-shifted by corner_phi):
;   sx = 4 if dx<0, sy = 2 if dy<0, axgt = 1 if |dx|>|dy|.
; psi = (base[oct] +/- ta) & 4095, ta = tantoangle[slope_div(min,max)],
; matching angle_bbox.point_to_angle octant-for-octant:
;   oct  quadrant/fold               psi            base_hi  sign
;   0    dx>=0 dy>=0 |dx|<=|dy|      ANG90  - ta        4     -
;   1    dx>=0 dy>=0 |dx|> |dy|      0      + ta        0     +
;   2    dx>=0 dy<0  |dx|<=|dy|      ANG270 + ta       12     +
;   3    dx>=0 dy<0  |dx|> |dy|      0      - ta        0     -  (= -ta & 4095)
;   4    dx<0  dy>=0 |dx|<=|dy|      ANG90  + ta        4     +
;   5    dx<0  dy>=0 |dx|> |dy|      ANG180 - ta        8     -
;   6    dx<0  dy<0  |dx|<=|dy|      ANG270 - ta       12     -
;   7    dx<0  dy<0  |dx|> |dy|      ANG180 + ta        8     +
pa_base_hi:
   .byte 4,0,12,0, 4,8,12,8
; /256: ANG90=>4, ANG180=>8, ANG270=>12
pa_sign:
   .byte $80,0,0,$80, 0,$80,$80,0

; ============================================================================
; bbox_check_angle: angle-space bbox visibility (FINEANGLES=4096, ANG90=1024,
; ANG45=CLIPANGLE=512, ANGMASK=4095). Mirrors angle_bbox.bbox_check_angle.
;   in : bca_top/bot/left/right (s16 contiguous $88..$8F), bca_px/py (s8),
;        bca_ab (u8)
;   out: bca_vis (1=visible/0=cull), bca_ilo, bca_ihi (u8 columns)
; ============================================================================
; bca workspace block ($FA10-$FA32) — flat sits in the BBOX-vars region; banked
; (BBC) relocates it to low RAM (the $FA00 page is MOS/IO on a real Model B).
; (BCA_WS comes from abi.inc — the old triplet is dead)
bca_top = BCA_WS+$10                    ; s16; bot $8A, left $8C, right $8E (contiguous = val[])
bca_bot = BCA_WS+$12
bca_left = BCA_WS+$14
bca_right = BCA_WS+$16
; px/py aliased to the live renderer's player-int ZP (frame-persistent);
; ab + outputs in the BBOX-vars region the old br_bbox_visible freed.
bca_ab = BCA_WS+$2F
; Outputs + hottest body vars now in ZERO PAGE (2026-07-08: measured
; ~3,650 absolute accesses/frame across these slots — the ZP move is a
; straight 1-cycle-per-access cut). Registered in zp.inc.
bca_ilo = zp_i_l                        ; ALIASED to the clipper interval
bca_ihi = zp_i_h                        ; (2026-07-18): the tail writes the
                                        ; has_gap operands DIRECTLY — the
                                        ; bv_anglevis staging copy is gone.
                                        ; Safe: every consumer (has_gap,
                                        ; the D store, the SAP serve) runs
                                        ; against a freshly-written pair;
                                        ; culls may leave a torn pair but
                                        ; every read follows a visible
                                        ; check. $BB/$BF freed.
.assert (VATOX & $FF) = 0, error, "VATOX must be page-aligned (bca_tail rides the index lo byte in Y)"
.assert (VATOX >> 8) + 4 <= $FF, error, "VATOX hi +4 must not wrap (bca_tail's pointer ADCs assume carry-out 0)"
; (EPSILON_F moved to zp.inc 2026-07-19: the afn hoist in view.s —
;  a different assembly unit — folds +EPS once per frame.)
; (bca_vis RETIRED 2026-07-20: the verdict rides the A/Z/C exit
;  signature — $64 is FREE)
bca_p1 = $C8                            ; r1 = (phi1+512)&4095 u12 pair $C8/$C9 (afn pre-biased; NOT sign-extended)
; $CA FREE (zp_cpm_s2 died 2026-07-20: store-at-birth ended the
; rcache's memo-slot scavenge; bca_p2 died 2026-07-19: p2 rides
; registers through the whole tail). $CB = zp_rc_moved (zp.inc)
; Hottest body vars in spare scavenged ZP (conflict-free) to cut the
; absolute-access tax across box_pos / corner_phi / sort / clip / clamp / VATOX.
; (top,bot,left,right s16) and we read via (bca_boxp),Y
; instead of copying it into a work area each check.
t0 = $CC
t1 = $CD
; $CE free (was val_lo — box_classify's lo bytes ride X now, 2026-07-11)
val_hi = $CF                            ; only user: rcache's rc_bytehi alias
bca_ccsave = $65                        ; sole owner (see zp.inc $65 note)
.if BANKED
VATOX = $8300                           ; bank L2 TABLES group: viewangletox, 1025 entries (phi+512), $8300-$8701
.else
VATOX = $E000                           ; viewangletox, 1025 entries (phi+512),
                                        ; $F600-$FA00 (moved down 1 into the
                                        ; TA_HI gap byte 2026-07-16: page-
                                        ; aligned so bca_tail rides the index
                                        ; lo byte in Y; overlap with the dead
                                        ; BCA_WS byte 0 shrinks to $FA00 only)
.endif
