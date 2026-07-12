.include "layout.inc"
.include "zp.inc"
; CPU target: every builder MUST pass -D C02=0 (6502) or -D C02=1 (65C02 opcodes).
.if C02
.setcpu "65C02"
.endif
; SlopeDiv for the angle-space pipeline (M3 primitive, unit-tested standalone).
; Computes floor(num * 2^SLOPEBITS / den) clamped to SLOPERANGE, for num <= den.
; SLOPEBITS=10, SLOPERANGE=1024. num,den are u16 (bbox/seg deltas, <= ~660).
;
;   in : sd_num (u16 $70/$71), sd_den (u16 $72/$73)   [caller ensures num<=den]
;   out: sd_q   (u16 $74/$75)  in [0, 1024]
;
; num>=den -> 1024 (the exact-divide remainder never reaches 0; matches the
; Python clamp). Otherwise a 10-iteration restoring divide: r=num; 10x
; { r<<=1; q<<=1; if r>=den { r-=den; q+=1 } } yields floor(num*2^10/den).


; PLACEMENT: flat = the ANG region $E940-$F1FF (bsp_render_ang.bin; the
; module physically cannot join the flat CODE region — total code
; exceeds any contiguous flat window). Banked = the ANG segment floats
; inside the one CODE region $2C00-$57FF like everything else. Tables:
; flat TA_LO $DC00, TA_HI $F200, VATOX $F601 (harness-seeded); banked =
; the L2 window ($8000/$8400/$8900, loader-seeded). Fixed entry jump
; table below (jt_slope_div/jt_bca_check) for bsp_render to import.
.if BANKED
.segment "ANG_BK"
.else
.segment "ANG"
.endif
.export jt_slope_div, jt_bca_check
jt_slope_div: JMP slope_div                           ; entry+0
jt_bca_check: JMP bbox_check_angle                    ; entry+3   (point_to_angle inlined into corner_phi -> 1 fewer entry)
slope_div:
.scope
; if num >= den -> SLOPERANGE (1024)
   LDA sd_num+1
   CMP sd_den+1
   BCC lt
   BNE ge
   LDA sd_num
   CMP sd_den
   BCC lt
ge:
   LDA #<1024
   STA sd_q
   LDA #>1024
   STA sd_q+1
   RTS
; slope_div_le — entry for callers that GUARANTEE num < den strictly
; (corner_phi: the axgt fold swaps to num<=den and diverts the num==den
; diagonal to ANG45 before calling). Skips the 16-bit num>=den entry
; proof above (~19 cycles when both hi bytes match). q <= 1023 here, so
; the caller needs no q==1024 check either. Preserves X.
::slope_div_le:
lt:
; 98% of divides have den < 256 (so num < den < 256): 8-bit restoring
; divide, r in A, no high byte. The quotient is <= 1024 (11 bits); after 8
; iterations q holds the top 8 bits (quotient>>2 <= 255), so q's high byte
; is only needed for the last 2 iterations -- phase A shifts the low byte
; only, phase B both. The quotient bit (carry = "2r >= den") is folded into
; q via ROL, so no INC.
   LDA sd_den+1
   BEQ den_fits
   JMP slow
; (trampoline: .slow now >127 away)
den_fits:
   LDA #0
   STA sd_q
   STA sd_q+1
; Second operand leading zero: if den < 128 too, then 2r < 256 always, so
; the bit-8 overflow case can't happen -- drop the BCS test and the SEC
; fixup (the SBC after CMP-ge already leaves carry set). 69% of divides.
   LDA sd_den
   BMI hi128
; Unrolled (no DEX:BNE). BCC P%+4 skips the 2-byte SBC with no label.
   LDA sd_num                              ; r in A
.repeat (8)-(1)+1                       ; phase A: low byte of q only
   ASL A
   CMP sd_den
   BCC *+4
   SBC sd_den
   ROL sd_q
.endrepeat
.repeat (2)-(1)+1                       ; phase B: both bytes of q
   ASL A
   CMP sd_den
   BCC *+4
   SBC sd_den
   ROL sd_q
   ROL sd_q+1
.endrepeat
   RTS
hi128:
; 128 <= den < 256: 2r can reach 9 bits, keep overflow handling. Unrolled:
; BCS P%+6 -> SBC (overflow, qbit=1); BCC P%+5 -> ROL (r<den, qbit=0).
   LDA sd_num                              ; remainder r lives in A throughout
.repeat (8)-(1)+1
   ASL A
   BCS *+6
   CMP sd_den
   BCC *+5
   SBC sd_den
   SEC
   ROL sd_q
.endrepeat
.repeat (2)-(1)+1
   ASL A
   BCS *+6
   CMP sd_den
   BCC *+5
   SBC sd_den
   SEC
   ROL sd_q
   ROL sd_q+1
.endrepeat
   RTS
slow:
; Generic path (den >= 256, ~2% of divides): classic 16-bit restoring divide
; with the remainder in ZP (sd_r). 10 iterations of
;   { r<<=1; q<<=1; if r>=den { r-=den; q|=1 } }  ->  q = floor(num*1024/den).
   LDA sd_num
   STA sd_r
   LDA sd_num+1
   STA sd_r+1
   LDA #0
   STA sd_q
   STA sd_q+1
   LDY #10                                 ; counter in Y: slope_div must
loop:                                      ; preserve X (oct rides it)
   ASL sd_r
   ROL sd_r+1
; r <<= 1
   ASL sd_q
   ROL sd_q+1
; q <<= 1 (bit0 = 0)
; if r >= den: r -= den; q++
   LDA sd_r+1
   CMP sd_den+1
   BCC no
   BNE yes
   LDA sd_r
   CMP sd_den
   BCC no
yes:
   LDA sd_r
   SEC
   SBC sd_den
   STA sd_r
   LDA sd_r+1
   SBC sd_den+1
   STA sd_r+1
   INC sd_q                                ; q |= 1
no:
   DEY
   BNE loop
   RTS
.endscope

; point_to_angle(dx,dy) -> fineangle [0,4096). 8 octants; each does
; slope_div(min(|dx|,|dy|), max(...)) -> tantoangle, then base +/- ta.
; tantoangle table: TA_LO/TA_HI (1025 entries) loaded by the harness.
; ($3B/$3C, $71/$72 freed: abs now writes the divide operands directly --
;  reused below for bca_afn / bca_cy)
.if BANKED
TA_LO = $8000                           ; bank L2 window: tantoangle lo (1024)
TA_HI = $8400                           ; bank L2: tantoangle hi (1025)
.else
TA_LO = $DC00                           ; 1024 entries (reclaimed rotation-cache RAM)
TA_HI = $F200                           ; 1025 entries ($F200-$F600, above the grown code <$F200)
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
bca_ilo = $BB
bca_ihi = $BF
bca_vis = $64                           ; sole owner (see zp.inc $64 note)
bca_p1 = $C8                            ; phi1 (s16, pair $C8/$C9)
bca_p2 = $CA                            ; phi2 (s16, pair $CA/$CB)
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
VATOX = $8900                           ; bank L2: viewangletox, 1025 entries (phi+512)
.else
VATOX = $F601                           ; viewangletox, 1025 entries (phi+512), $F601-$FA01
.endif
