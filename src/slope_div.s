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


; Integration build: loaded at $E940 (bsp_render_ang.bin). Tables: TA_LO in the
; reclaimed rotation-cache RAM ($DC00-$DFFF, 1024 entries), TA_HI/VATOX in the
; $E940 region after the code. Fixed entry jump table for bsp_render to call.
; Angle module code: flat @ $E940 (above renderer); banked (BBC) -> low RAM
; ($3400, in the clipper-vacated space) since $C000+ is MOS ROM on a Model B.
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
LDA sd_num
STA sd_r
LDA sd_num+1
STA sd_r+1
LDA #0
STA sd_q
STA sd_q+1
LDX #10
loop:
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
DEX
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
.if BANKED
BCA_WS = $3A00
.else
BCA_WS = $FA00
.endif
bca_top = BCA_WS+$10                    ; s16; bot $8A, left $8C, right $8E (contiguous = val[])
bca_bot = BCA_WS+$12
bca_left = BCA_WS+$14
bca_right = BCA_WS+$16
; px/py aliased to the live renderer's player-int ZP (frame-persistent);
; ab + outputs in the BBOX-vars region the old br_bbox_visible freed.
bca_ab = BCA_WS+$2F
bca_ilo = BCA_WS+$30
bca_ihi = BCA_WS+$31
bca_vis = BCA_WS+$32
bca_p1 = BCA_WS+$1E                     ; phi1 (s16)
bca_p2 = BCA_WS+$20                     ; phi2 (s16)
; Hottest body vars in spare scavenged ZP (conflict-free) to cut the
; absolute-access tax across box_pos / corner_phi / sort / clip / clamp / VATOX.
; (top,bot,left,right s16) and we read via (bca_boxp),Y
; instead of copying it into a work area each check.
t0 = BCA_WS+$2A
t1 = BCA_WS+$2B
val_lo = BCA_WS+$2C
val_hi = BCA_WS+$2D
bca_ccsave = BCA_WS+$2E
.if BANKED
VATOX = $8900                           ; bank L2: viewangletox, 1025 entries (phi+512)
.else
VATOX = $F601                           ; viewangletox, 1025 entries (phi+512), $F601-$FA01
.endif

bbox_check_angle:
.scope
LDA #0
STA bca_vis
; bca_pxs/bca_pys (px,py sign-extended to s16) are precomputed once/frame
; by br_view_setup — frame-constant. Direct unit-test callers set them.
; bca_px/bca_py (s8) are still read below by ins_test/box_pos.
; inside test: left<=px<=right and bot<=py<=top  -> full (0,255)
; left<=px : px-left >= 0
; a_fine (bca_afn) is precomputed once/frame by the caller
; (br_view_setup), not recomputed here — it is frame-constant. Direct
; unit-test callers (test_bca, check_angle_calls) set bca_afn themselves.
; inside test + boxx/boxy classification share one set of subtractions:
JSR box_classify                        ; -> X = boxpos (inside: full-exit)
; cc = checkcoord + boxpos*4
TXA
ASL A
ASL A
TAX
; corner1 = (val[cc0], val[cc1]); load_val inlined -> cx/cy directly
; (Y = val index*2 into the box at bca_top; X unchanged by the load).
; corner load folds straight into the phi subtraction: pa_dx = box[cc0]-pxs,
; pa_dy = box[cc1]-pys (the bca_cx/cy staging is gone).
LDY bca_cc,X
SEC
LDA (bca_boxp),Y
SBC bca_pxs
STA pa_dx
INY
LDA (bca_boxp),Y
SBC bca_pxs+1
STA pa_dx+1
LDY bca_cc+1,X
SEC
LDA (bca_boxp),Y
SBC bca_pys
STA pa_dy
INY
LDA (bca_boxp),Y
SBC bca_pys+1
STA pa_dy+1
STX bca_ccsave
JSR corner_phi
LDA pa_res
STA bca_p1
LDA pa_res+1
STA bca_p1+1
LDX bca_ccsave
; corner2 = (val[cc2], val[cc3])
LDY bca_cc+2,X
SEC
LDA (bca_boxp),Y
SBC bca_pxs
STA pa_dx
INY
LDA (bca_boxp),Y
SBC bca_pxs+1
STA pa_dx+1
LDY bca_cc+3,X
SEC
LDA (bca_boxp),Y
SBC bca_pys
STA pa_dy
INY
LDA (bca_boxp),Y
SBC bca_pys+1
STA pa_dy+1
JSR corner_phi
LDA pa_res
STA bca_p2
LDA pa_res+1
STA bca_p2+1
; --- Faithful DOOM R_CheckBBox, unsigned-BAM wraparound (FINEANGLES=4096).
; Our phi = -(DOOM view-relative angle), so DOOM angle1=-p1 (p1 = LEFT
; silhouette, checkcoord order), angle2=-p2 (RIGHT). All arithmetic is
; mod-4096 wraparound, which natively handles a silhouette corner behind
; the view plane — the case the old signed-sort logic mis-narrowed
; (over-culled straddling boxes -> far rooms drawn through walls).
; p1/p2 are s16 whose low 12 bits ARE the BAM value (sign extension adds
; multiples of 4096), so 16-bit sub/add + AND #$0F on the hi byte = BAM.
;
; span = (p2 - p1) & 4095 ; span >= ANG180(2048) -> viewer inside the
; box's angular span -> visible full-width.
SEC
LDA bca_p2
SBC bca_p1
STA t0
LDA bca_p2+1
SBC bca_p1+1
AND #$0F
STA t1
CMP #8
BCC ck_left
JMP full_vis                            ; span >= 2048
ck_left:
; left clip: tspan = (CLIPANGLE - p1) & 4095 ; if tspan > 2*CLIPANGLE:
;   wholly off left when tspan - 2*CLIPANGLE >= span, else p1 = -CLIPANGLE
SEC
LDA #<512
SBC bca_p1
TAX                                     ; tspan lo
LDA #>512
SBC bca_p1+1
AND #$0F                                ; tspan hi (12-bit)
CMP #4
BCC ck_right                            ; tspan < 1024 -> in range
BNE ck_left_out
CPX #0
BEQ ck_right                            ; tspan == 1024 exactly -> in range
ck_left_out:
STX pa_sx                               ; (corner_phi scratch, dead here)
SEC
SBC #4                                  ; tspan hi -= 4  (tspan - 1024)
STA pa_sy
LDA pa_sx
CMP t0
LDA pa_sy
SBC t1
BCC ck_left_clip
JMP cull                                ; (tspan-2*CLIP) >= span: off left
ck_left_clip:
LDA #$00                                ; p1 = -CLIPANGLE = -512 = $FE00
STA bca_p1
LDA #$FE
STA bca_p1+1
ck_right:
; right clip: tspan = (CLIPANGLE + p2) & 4095 ; same, clamping p2 = +512
CLC
LDA #<512
ADC bca_p2
TAX
LDA #>512
ADC bca_p2+1
AND #$0F
CMP #4
BCC ck_done
BNE ck_right_out
CPX #0
BEQ ck_done
ck_right_out:
STX pa_sx
SEC
SBC #4
STA pa_sy
LDA pa_sx
CMP t0
LDA pa_sy
SBC t1
BCC ck_right_clip
JMP cull                                ; off right
ck_right_clip:
LDA #<512                               ; p2 = +CLIPANGLE
STA bca_p2
LDA #>512
STA bca_p2+1
ck_done:
; feed the VATOX tail: lo := p1 (left), hi := p2 (right), both in [-512,512]
LDA bca_p1
STA bca_lo
LDA bca_p1+1
STA bca_lo+1
LDA bca_p2
STA bca_hi
LDA bca_p2+1
STA bca_hi+1
; ilo = VATOX[lo+512]-1 ; ihi = VATOX[hi+512]+1 ; clamp [0,255].
; VATOX holds only the used range (phi in [-512,512] -> index [0,1024]),
; so the bias is +512 (not +1024); the R_CheckBBox clip above guarantees
; lo/hi land in [-512,512].
; address = (VATOX+512) + lo : fold the +512 bias into the base so it's a
; single add (lo is signed s16; two's-complement add lands in range).
CLC
LDA #<(VATOX+512)
ADC bca_lo
STA pa_ptr
LDA #>(VATOX+512)
ADC bca_lo+1
STA pa_ptr+1
LDY #0
LDA (pa_ptr),Y
; vatox[lo]
SEC
SBC #1
BCS il1
LDA #0
il1:
STA bca_ilo
CLC
LDA #<(VATOX+512)
ADC bca_hi
STA pa_ptr
LDA #>(VATOX+512)
ADC bca_hi+1
STA pa_ptr+1
LDA (pa_ptr),Y                          ; vatox[hi]
CLC
ADC #1
BCC ih1
LDA #255
ih1:
CMP #255
BCC ih2
LDA #255
ih2:
STA bca_ihi
; if ilo > ihi: cull
LDA bca_ilo
CMP bca_ihi
BEQ visok
BCS cull
visok:
LDA #1
STA bca_vis
RTS
full_vis:                               ; span >= ANG180: full width
LDA #1
STA bca_vis
LDA #0
STA bca_ilo
LDA #255
STA bca_ihi
RTS
cull:
LDA #0
STA bca_vis
RTS
.endscope

; ============================================================================
; box_classify — ONE pass of box-vs-viewer subtractions yields both the
; inside test and the checkcoord classification (the old ins_test + box_pos
; pair recomputed the same comparisons in opposite directions: 8 s16
; subtracts; this does at most 4).
;
;   X <- boxpos = boxy*4 + boxx
;     boxx: 0 if px<=left,  1 if px<right,  else 2   (px==right -> 1,
;     boxy: 0 if py>=top,   1 if py>bot,    else 2    py==bot  -> 1 —
;     both preserved from the original box_pos exactly)
;   inside (px-left>=0 && right-px>=0 && py-bot>=0 && top-py>=0):
;     sets vis=1/ilo=0/ihi=255 and returns STRAIGHT to
;     bbox_check_angle's caller (double-RTS pull), like the old ins_test.
;
; Derivation (d = px-left, e = right-px, f = py-top, g = py-bot):
;   boxx = 0 iff d<=0 ; 2 iff e<0 ; else 1.   inside-x iff d>=0 && e>=0
;     (d==0 implies e>0 since left<right, so the d==0 arm skips e).
;   boxy = 0 iff f>=0 ; 2 iff g<0 ; else 1.   inside-y iff f<=0 && g>=0
;     (f==0 implies g>0 since bot<top).
; ============================================================================
box_classify:
.scope
; box via (bca_boxp),Y : top@0, bot@2, left@4, right@6.
LDA #0
STA t1                                  ; outside flag
; --- d = px - left (sign via V fix; 16-bit zero via raw bytes) ---
LDY #4
SEC
LDA bca_pxs
SBC (bca_boxp),Y
STA val_lo
INY
LDA bca_pxs+1
SBC (bca_boxp),Y
TAX                                     ; raw hi (zero test)
BVC c1
EOR #$80
c1:
BMI cx_x0_out                           ; d<0: px<left -> boxx=0, outside
CPX #0
BNE cx_x_pos
LDA val_lo
BNE cx_x_pos
LDA #0                                  ; d==0: boxx=0, inside-x ok
BEQ cx_have_x
cx_x0_out:
INC t1
LDA #0
BEQ cx_have_x
cx_x_pos:
; --- e = right - px (sign only) ---
LDY #6
SEC
LDA (bca_boxp),Y
SBC bca_pxs
INY
LDA (bca_boxp),Y
SBC bca_pxs+1
BVC c2
EOR #$80
c2:
BMI cx_x2_out
LDA #1                                  ; e>=0: boxx=1, inside-x ok
BNE cx_have_x
cx_x2_out:
INC t1                                  ; e<0: px>right -> boxx=2, outside
LDA #2
cx_have_x:
STA t0                                  ; boxx
; --- f = py - top ---
LDY #0
SEC
LDA bca_pys
SBC (bca_boxp),Y
STA val_lo
INY
LDA bca_pys+1
SBC (bca_boxp),Y
TAX
BVC c3
EOR #$80
c3:
BMI cx_y_low                            ; f<0: py<top -> boxy 1/2, inside-hi ok
CPX #0
BNE cx_y0_out
LDA val_lo
BNE cx_y0_out
LDA #0                                  ; f==0: boxy=0, inside-y ok
BEQ cx_have_y
cx_y0_out:
INC t1                                  ; f>0: py>top -> boxy=0, outside
LDA #0
BEQ cx_have_y
cx_y_low:
; --- g = py - bot (sign only) ---
LDY #2
SEC
LDA bca_pys
SBC (bca_boxp),Y
INY
LDA bca_pys+1
SBC (bca_boxp),Y
BVC c4
EOR #$80
c4:
BMI cx_y2_out
LDA #1                                  ; g>=0: boxy=1, inside-y ok
BNE cx_have_y
cx_y2_out:
INC t1                                  ; g<0: py<bot -> boxy=2, outside
LDA #2
cx_have_y:
; X = boxy*4 + boxx
ASL A
ASL A
CLC
ADC t0
TAX
LDA t1
BEQ cx_inside
RTS
cx_inside:
; inside -> full result; discard box_classify's return, exit to
; bbox_check_angle's caller.
LDA #1
STA bca_vis
LDA #0
STA bca_ilo
LDA #255
STA bca_ihi
PLA
PLA
RTS
.endscope

; (load_val removed: inlined at the corner loads.)

; corner_phi: dx=cx-pxs, dy=cy-pys; point_to_angle; pa_res=(afn-psi)&MASK signed
; corner_phi: callers load pa_dx/pa_dy directly (box corner minus viewer).
corner_phi:
.scope
; --- inlined point_to_angle(pa_dx,pa_dy) -> pa_res (psi) ---
; .pa_entry: unit-test hook -- jump here with pa_dx/pa_dy set and
; bca_afn=0 to read back (-psi)&signed in pa_res (see test_slope_div).
pa_entry:
LDA pa_dx
ORA pa_dx+1
ORA pa_dy
ORA pa_dy+1
BNE nz
LDA #0
STA pa_res
STA pa_res+1
JMP cp_havepsi
; zero -> psi=0 (was RTS)
nz:
; |dx| -> sd_num, sx = (dx<0)  (abs written straight to the divide operands;
; if |dx|>|dy| we swap below so sd_num=min, sd_den=max -- no separate copy).
LDA #0
STA pa_sx
LDA pa_dx+1
BPL dxp
LDA #4                                  ; sx pre-shifted for the oct fold
STA pa_sx
LDA #0
SEC
SBC pa_dx
STA sd_num
LDA #0
SBC pa_dx+1
STA sd_num+1
JMP dxd
dxp:
LDA pa_dx
STA sd_num
LDA pa_dx+1
STA sd_num+1
dxd:
; |dy| -> sd_den, sy = (dy<0)
LDA #0
STA pa_sy
LDA pa_dy+1
BPL dyp
LDA #2                                  ; sy pre-shifted for the oct fold
STA pa_sy
LDA #0
SEC
SBC pa_dy
STA sd_den
LDA #0
SBC pa_dy+1
STA sd_den+1
JMP dyd
dyp:
LDA pa_dy
STA sd_den
LDA pa_dy+1
STA sd_den+1
dyd:
; axgt = (|dx| > |dy|): now sd_num=|dx|, sd_den=|dy|.
LDA sd_den+1
CMP sd_num+1
BCC axgt
; |dy|<|dx| -> |dx|>|dy|
BNE axle
LDA sd_den
CMP sd_num
BCS axle
; |dy|>=|dx| -> not axgt
axgt:
; |dx| > |dy|: swap so sd_num=|dy|(min), sd_den=|dx|(max); axgt bit=1
LDA sd_num
LDX sd_den
STA sd_den
STX sd_num
LDA sd_num+1
LDX sd_den+1
STA sd_den+1
STX sd_num+1
LDA #1
JMP haveax
axle:
; |dx| <= |dy|: sd_num=|dx|(min), sd_den=|dy|(max) already; axgt bit=0
LDA #0
haveax:
; oct = sx(0/4) | sy(0/2) | axgt(0/1) — signs stored pre-shifted
ORA pa_sy
ORA pa_sx
STA pa_oct
JSR slope_div                           ; -> sd_q (0..1024)
; tantoangle has 1024 entries (0..1023); the exact diagonal sd_q==1024
; (hi byte == 4) maps to ANG45 = 512 directly (no table entry).
LDA sd_q+1
CMP #4
BNE pa_lookup
LDA #<512
STA pa_res
LDA #>512
STA pa_res+1
JMP comb
pa_lookup:
; ta = tantoangle[sd_q] via 16-bit index. TA_HI = TA_LO + (TA_HI-TA_LO),
; so reach the hi-byte table by adding the page delta to the pointer high
; byte instead of recomputing the whole pointer.
LDY #0
CLC
LDA #<TA_LO
ADC sd_q
STA pa_ptr
LDA #>TA_LO
ADC sd_q+1
STA pa_ptr+1
LDA (pa_ptr),Y
STA pa_res
LDA pa_ptr+1
CLC
ADC #(>TA_HI - >TA_LO)
STA pa_ptr+1
LDA (pa_ptr),Y
STA pa_res+1
comb:
; res = base[oct] +/- ta  (& MASK). The octant bases are multiples of 256
; (0/1024/2048/3072), so base_lo is always 0.
LDX pa_oct
LDA pa_sign,X
BMI sub
; add: res = base + ta ; low byte (= ta) unchanged since base_lo = 0
CLC
LDA pa_base_hi,X
ADC pa_res+1
STA pa_res+1
JMP mask
sub:
; sub: res = base - ta ; base_lo = 0
SEC
LDA #0
SBC pa_res
STA pa_res
LDA pa_base_hi,X
SBC pa_res+1
STA pa_res+1
mask:
LDA pa_res+1
AND #$0F
STA pa_res+1
; & 4095 (psi ready; was RTS->fall through)
; --- afn - psi, mask & sign-extend to s16 ---
cp_havepsi:
SEC
LDA bca_afn
SBC pa_res
STA pa_res
LDA bca_afn+1
SBC pa_res+1
AND #$0F                                ; phi & 4095 (hi nibble)
CMP #8
BCC cp_store
; < 2048 -> keep; else C=1 for the wrap
SBC #$10                                ; -= 4096 (hi -= $10) -> signed [-2048,2048)
cp_store:
STA pa_res+1
RTS
.endscope

; checkcoord[boxpos*4]: indices into (top=0,bot=1,left=2,right=3).
; rows 3,7,11 and 5 unused (5=inside handled earlier).
; checkcoord indices PRE-DOUBLED (byte offsets into the s16 box: top=0,
; bot=2, left=4, right=6) so the corner loads index (bca_boxp),Y directly.
bca_cc:
.byte 6,0,4,2,  6,0,4,0,  6,2,4,0,  0,0,0,0
.byte 4,0,4,2,  0,0,0,0,  6,2,6,0,  0,0,0,0
.byte 4,0,6,2,  4,2,6,2,  4,2,6,0,  0,0,0,0


end:
.if BANKED
; (ld65 writes this: SAVE "bsp_render_ang_bk.bin", $3400, end, $3400)
.else
.assert end <= TA_HI, error             ; code must not grow into the relocated tables ($F200+)
; (ld65 writes this: SAVE "bsp_render_ang.bin", $E940, end, $E940)
.endif
