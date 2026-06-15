\ SlopeDiv for the angle-space pipeline (M3 primitive, unit-tested standalone).
\ Computes floor(num * 2^SLOPEBITS / den) clamped to SLOPERANGE, for num <= den.
\ SLOPEBITS=10, SLOPERANGE=1024. num,den are u16 (bbox/seg deltas, <= ~660).
\
\   in : sd_num (u16 $70/$71), sd_den (u16 $72/$73)   [caller ensures num<=den]
\   out: sd_q   (u16 $74/$75)  in [0, 1024]
\
\ num>=den -> 1024 (the exact-divide remainder never reaches 0; matches the
\ Python clamp). Otherwise a 10-iteration restoring divide: r=num; 10x
\ { r<<=1; q<<=1; if r>=den { r-=den; q+=1 } } yields floor(num*2^10/den).

sd_num = $70
sd_den = $72
sd_q   = $74
sd_r   = $76

ORG $2000
.slope_div
{
    \ if num >= den -> SLOPERANGE (1024)
    LDA sd_num+1 : CMP sd_den+1 : BCC lt
    BNE ge
    LDA sd_num   : CMP sd_den   : BCC lt
.ge
    LDA #<1024 : STA sd_q
    LDA #>1024 : STA sd_q+1
    RTS
.lt
    LDA sd_num   : STA sd_r
    LDA sd_num+1 : STA sd_r+1
    LDA #0 : STA sd_q : STA sd_q+1
    LDX #10
.loop
    ASL sd_r : ROL sd_r+1            \ r <<= 1
    ASL sd_q : ROL sd_q+1            \ q <<= 1 (bit0 = 0)
    \ if r >= den: r -= den; q++
    LDA sd_r+1 : CMP sd_den+1 : BCC no
    BNE yes
    LDA sd_r   : CMP sd_den   : BCC no
.yes
    LDA sd_r   : SEC : SBC sd_den   : STA sd_r
    LDA sd_r+1 :       SBC sd_den+1 : STA sd_r+1
    INC sd_q                          \ q |= 1
.no
    DEX : BNE loop
    RTS
}

\ point_to_angle(dx,dy) -> fineangle [0,4096). 8 octants; each does
\ slope_div(min(|dx|,|dy|), max(...)) -> tantoangle, then base +/- ta.
\ tantoangle table: TA_LO/TA_HI (1025 entries) loaded by the harness.
pa_dx  = $78          \ s16 in
pa_dy  = $7A          \ s16 in
pa_res = $7C          \ u16 out (fineangle)
pa_adx = $7E
pa_ady = $80
pa_sx  = $82
pa_sy  = $83
pa_oct = $84
pa_ptr = $86          \ 16-bit table pointer
TA_LO  = $3000        \ 1025 entries ($3000-$3400)
TA_HI  = $3800        \ 1025 entries ($3800-$3C00)

.point_to_angle
{
    LDA pa_dx : ORA pa_dx+1 : ORA pa_dy : ORA pa_dy+1 : BNE nz
    LDA #0 : STA pa_res : STA pa_res+1 : RTS
.nz
    \ adx = |dx|, sx = (dx<0)
    LDA #0 : STA pa_sx
    LDA pa_dx+1 : BPL dxp
    INC pa_sx
    LDA #0 : SEC : SBC pa_dx : STA pa_adx
    LDA #0 :       SBC pa_dx+1 : STA pa_adx+1 : JMP dxd
.dxp
    LDA pa_dx : STA pa_adx : LDA pa_dx+1 : STA pa_adx+1
.dxd
    \ ady = |dy|, sy = (dy<0)
    LDA #0 : STA pa_sy
    LDA pa_dy+1 : BPL dyp
    INC pa_sy
    LDA #0 : SEC : SBC pa_dy : STA pa_ady
    LDA #0 :       SBC pa_dy+1 : STA pa_ady+1 : JMP dyd
.dyp
    LDA pa_dy : STA pa_ady : LDA pa_dy+1 : STA pa_ady+1
.dyd
    \ axgt = (adx > ady) ; num=min, den=max
    LDA pa_ady+1 : CMP pa_adx+1 : BCC axgt   \ ady<adx -> adx>ady
    BNE axle
    LDA pa_ady   : CMP pa_adx   : BCS axle    \ ady>=adx -> not axgt
.axgt
    \ adx > ady : num=ady, den=adx, axgt bit=1
    LDA pa_ady : STA sd_num : LDA pa_ady+1 : STA sd_num+1
    LDA pa_adx : STA sd_den : LDA pa_adx+1 : STA sd_den+1
    LDA #1 : JMP haveax
.axle
    \ adx <= ady : num=adx, den=ady, axgt bit=0
    LDA pa_adx : STA sd_num : LDA pa_adx+1 : STA sd_num+1
    LDA pa_ady : STA sd_den : LDA pa_ady+1 : STA sd_den+1
    LDA #0
.haveax
    \ oct = (sx<<2)|(sy<<1)|axgt
    STA pa_oct
    LDA pa_sy : ASL A : ORA pa_oct : STA pa_oct
    LDA pa_sx : ASL A : ASL A : ORA pa_oct : STA pa_oct
    JSR slope_div            \ -> sd_q (0..1024)
    \ ta = tantoangle[sd_q] via 16-bit index (sd_q can be up to 1024)
    LDY #0
    CLC : LDA #<TA_LO : ADC sd_q : STA pa_ptr
          LDA #>TA_LO : ADC sd_q+1 : STA pa_ptr+1
    LDA (pa_ptr),Y : STA pa_res
    CLC : LDA #<TA_HI : ADC sd_q : STA pa_ptr
          LDA #>TA_HI : ADC sd_q+1 : STA pa_ptr+1
    LDA (pa_ptr),Y : STA pa_res+1
.comb
    \ res = base[oct] +/- ta  (& MASK)
    LDX pa_oct
    LDA pa_sign,X : BMI sub
    \ add: res = base + ta
    CLC
    LDA pa_base_lo,X : ADC pa_res   : STA pa_res
    LDA pa_base_hi,X : ADC pa_res+1 : STA pa_res+1
    JMP mask
.sub
    \ res = base - ta
    SEC
    LDA pa_base_lo,X : SBC pa_res   : STA pa_res
    LDA pa_base_hi,X : SBC pa_res+1 : STA pa_res+1
.mask
    LDA pa_res+1 : AND #$0F : STA pa_res+1     \ & 4095
    RTS
}

\ per-octant base (0/ANG90=1024/ANG180=2048/ANG270=3072) and sign (+ / $80=-)
.pa_base_lo EQUB 0,0,0,0, 0,0,0,0
.pa_base_hi EQUB 4,0,12,0, 4,8,12,8     \ /256: ANG90=>4, ANG180=>8, ANG270=>12
.pa_sign    EQUB $80,0,0,$80, 0,$80,$80,0

.end
SAVE "slope_div.bin", $2000, end, $2000
