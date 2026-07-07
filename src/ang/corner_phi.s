
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
; s16 sign of a subtract that may overflow: if V is set the N flag is
; inverted, so EOR #$80 recovers the true sign (standard signed-compare
; idiom; same BVC/EOR pattern at c2/c3/c4 below).
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

; ============================================================================
; corner_phi — signed view-relative angle (phi) of one box corner.
;   in : pa_dx/pa_dy (s16 = corner - viewer int pos, loaded by the caller),
;        bca_afn (a_fine, frame-constant)
;   out: pa_res = phi (s16 in [-2048,2048))
;        clobbers sd_num/sd_den/sd_q, pa_sx/pa_sy/pa_oct/pa_ptr
;   phi = sign_extend((a_fine - psi) & 4095), psi = point_to_angle(dx,dy).
; point_to_angle (angle_bbox.py) is INLINED below — corner_phi is its sole
; caller. pseudocode:
;   if dx == 0 and dy == 0: psi = 0
;   num = min(|dx|,|dy|) ; den = max(|dx|,|dy|)       # first-octant fold
;   oct = (dx<0)*4 | (dy<0)*2 | (|dx|>|dy|)
;   ta  = tantoangle[slope_div(num,den)]              # sd_q==1024 -> ANG45
;   psi = (base[oct] +/- ta) & 4095                   # tables in header_div.s
; ============================================================================
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
.endscope
; --- afn - psi, mask & sign-extend to s16 (file-global: reused by the
;     rotation cache's warm path to re-derive phi from cached psi) ---
;   in : pa_res = psi (u12 fineangle), bca_afn = a_fine (frame-constant)
;   out: pa_res = phi (s16 in [-2048,2048))
;   phi = (a_fine - psi) & 4095 ; if phi >= 2048: phi -= 4096
; The AND #$0F masks to 12 bits; hi-nibble >= 8 means phi >= 2048, and
; SBC #$10 (carry known set from the CMP) subtracts 4096 from the hi byte.
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

; checkcoord[boxpos*4]: indices into (top=0,bot=1,left=2,right=3).
; rows 3,7,11 and 5 unused (5=inside handled earlier).
; checkcoord indices PRE-DOUBLED (byte offsets into the s16 box: top=0,
; bot=2, left=4, right=6) so the corner loads index (bca_boxp),Y directly.
; Row layout: 4 bytes per boxpos = (c1x,c1y, c2x,c2y); corner1 = LEFT
; silhouette, corner2 = RIGHT (angle_bbox._CHECKCOORD, DOOM checkcoord).
; boxpos = boxy*4 + boxx: row 0-2 viewer above top, 4/6 level, 8-10 below.
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

