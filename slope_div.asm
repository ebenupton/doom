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

sd_num = $44
sd_den = $46
sd_q   = $48
sd_r   = $4A

\ Integration build: loaded at $E940 (bsp_render_ang.bin). Tables: TA_LO in the
\ reclaimed rotation-cache RAM ($DC00-$DFFF, 1024 entries), TA_HI/VATOX in the
\ $E940 region after the code. Fixed entry jump table for bsp_render to call.
ORG $E940
    JMP slope_div            \ $E940
    JMP point_to_angle       \ $E943
    JMP bbox_check_angle     \ $E946
    JMP cos_fine             \ $E949  (option-2b seg projection helper)
    JMP seg_depth            \ $E94C  (option-2b: depth = c*cos(phi)/cos(den))
    JMP proj_yd              \ $E94F  (option-2b: yt = HALF_H - (hd<<11)/depth)
    JMP seg_c               \ $E952  (option-2b: c = (cross<<4)/L, perp distance)
    JMP seg_project         \ $E955  (option-2b: endpoint -> sx + depth)
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
    \ 98% of divides have den < 256 (so num < den < 256): 8-bit restoring
    \ divide, r in A, no high byte. The quotient is <= 1024 (11 bits); after 8
    \ iterations q holds the top 8 bits (quotient>>2 <= 255), so q's high byte
    \ is only needed for the last 2 iterations -- phase A shifts the low byte
    \ only, phase B both. The quotient bit (carry = "2r >= den") is folded into
    \ q via ROL, so no INC.
    LDA sd_den+1 : BEQ den_fits : JMP slow   \ (trampoline: .slow now >127 away)
.den_fits
    LDA #0 : STA sd_q : STA sd_q+1
    \ Second operand leading zero: if den < 128 too, then 2r < 256 always, so
    \ the bit-8 overflow case can't happen -- drop the BCS test and the SEC
    \ fixup (the SBC after CMP-ge already leaves carry set). 69% of divides.
    LDA sd_den : BMI hi128
    \ Unrolled (no DEX:BNE). BCC P%+4 skips the 2-byte SBC with no label.
    LDA sd_num                        \ r in A
    FOR i,1,8                         \ phase A: low byte of q only
    ASL A : CMP sd_den : BCC P%+4 : SBC sd_den
    ROL sd_q
    NEXT
    FOR i,1,2                         \ phase B: both bytes of q
    ASL A : CMP sd_den : BCC P%+4 : SBC sd_den
    ROL sd_q : ROL sd_q+1
    NEXT
    RTS
.hi128
    \ 128 <= den < 256: 2r can reach 9 bits, keep overflow handling. Unrolled:
    \ BCS P%+6 -> SBC (overflow, qbit=1); BCC P%+5 -> ROL (r<den, qbit=0).
    LDA sd_num                        \ remainder r lives in A throughout
    FOR i,1,8
    ASL A : BCS P%+6 : CMP sd_den : BCC P%+5 : SBC sd_den : SEC
    ROL sd_q
    NEXT
    FOR i,1,2
    ASL A : BCS P%+6 : CMP sd_den : BCC P%+5 : SBC sd_den : SEC
    ROL sd_q : ROL sd_q+1
    NEXT
    RTS
.slow
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
pa_dx  = $30          \ s16 in
pa_dy  = $32          \ s16 in
pa_res = $39          \ u16 out (fineangle)
\ ($3B/$3C, $71/$72 freed: abs now writes the divide operands directly --
\  reused below for bca_afn / bca_cy)
pa_sx  = $73
pa_sy  = $89
pa_oct = $8A
pa_ptr = $40          \ 16-bit table pointer
TA_LO  = $DC00        \ 1024 entries (reclaimed rotation-cache RAM)
TA_HI  = $F200        \ 1025 entries ($F200-$F600, above the grown code <$F200)

.point_to_angle
{
    LDA pa_dx : ORA pa_dx+1 : ORA pa_dy : ORA pa_dy+1 : BNE nz
    LDA #0 : STA pa_res : STA pa_res+1 : RTS
.nz
    \ |dx| -> sd_num, sx = (dx<0)  (abs written straight to the divide operands;
    \ if |dx|>|dy| we swap below so sd_num=min, sd_den=max -- no separate copy).
    LDA #0 : STA pa_sx
    LDA pa_dx+1 : BPL dxp
    INC pa_sx
    LDA #0 : SEC : SBC pa_dx : STA sd_num
    LDA #0 :       SBC pa_dx+1 : STA sd_num+1 : JMP dxd
.dxp
    LDA pa_dx : STA sd_num : LDA pa_dx+1 : STA sd_num+1
.dxd
    \ |dy| -> sd_den, sy = (dy<0)
    LDA #0 : STA pa_sy
    LDA pa_dy+1 : BPL dyp
    INC pa_sy
    LDA #0 : SEC : SBC pa_dy : STA sd_den
    LDA #0 :       SBC pa_dy+1 : STA sd_den+1 : JMP dyd
.dyp
    LDA pa_dy : STA sd_den : LDA pa_dy+1 : STA sd_den+1
.dyd
    \ axgt = (|dx| > |dy|): now sd_num=|dx|, sd_den=|dy|.
    LDA sd_den+1 : CMP sd_num+1 : BCC axgt   \ |dy|<|dx| -> |dx|>|dy|
    BNE axle
    LDA sd_den   : CMP sd_num   : BCS axle    \ |dy|>=|dx| -> not axgt
.axgt
    \ |dx| > |dy|: swap so sd_num=|dy|(min), sd_den=|dx|(max); axgt bit=1
    LDA sd_num   : LDX sd_den   : STA sd_den   : STX sd_num
    LDA sd_num+1 : LDX sd_den+1 : STA sd_den+1 : STX sd_num+1
    LDA #1 : JMP haveax
.axle
    \ |dx| <= |dy|: sd_num=|dx|(min), sd_den=|dy|(max) already; axgt bit=0
    LDA #0
.haveax
    \ oct = (sx<<2)|(sy<<1)|axgt
    STA pa_oct
    LDA pa_sy : ASL A : ORA pa_oct : STA pa_oct
    LDA pa_sx : ASL A : ASL A : ORA pa_oct : STA pa_oct
    JSR slope_div            \ -> sd_q (0..1024)
    \ tantoangle has 1024 entries (0..1023); the exact diagonal sd_q==1024
    \ (hi byte == 4) maps to ANG45 = 512 directly (no table entry).
    LDA sd_q+1 : CMP #4 : BNE pa_lookup
    LDA #<512 : STA pa_res : LDA #>512 : STA pa_res+1
    JMP comb
.pa_lookup
    \ ta = tantoangle[sd_q] via 16-bit index. TA_HI = TA_LO + (TA_HI-TA_LO),
    \ so reach the hi-byte table by adding the page delta to the pointer high
    \ byte instead of recomputing the whole pointer.
    LDY #0
    CLC : LDA #<TA_LO : ADC sd_q : STA pa_ptr
          LDA #>TA_LO : ADC sd_q+1 : STA pa_ptr+1
    LDA (pa_ptr),Y : STA pa_res
    LDA pa_ptr+1 : CLC : ADC #(>TA_HI - >TA_LO) : STA pa_ptr+1
    LDA (pa_ptr),Y : STA pa_res+1
.comb
    \ res = base[oct] +/- ta  (& MASK). The octant bases are multiples of 256
    \ (0/1024/2048/3072), so base_lo is always 0.
    LDX pa_oct
    LDA pa_sign,X : BMI sub
    \ add: res = base + ta ; low byte (= ta) unchanged since base_lo = 0
    CLC
    LDA pa_base_hi,X : ADC pa_res+1 : STA pa_res+1
    JMP mask
.sub
    \ sub: res = base - ta ; base_lo = 0
    SEC
    LDA #0           : SBC pa_res   : STA pa_res
    LDA pa_base_hi,X : SBC pa_res+1 : STA pa_res+1
.mask
    LDA pa_res+1 : AND #$0F : STA pa_res+1     \ & 4095
    RTS
}

\ per-octant base (0/ANG90=1024/ANG180=2048/ANG270=3072) and sign (+ / $80=-).
\ base_lo is always 0 (bases are multiples of 256) so the table is omitted.
.pa_base_hi EQUB 4,0,12,0, 4,8,12,8     \ /256: ANG90=>4, ANG180=>8, ANG270=>12
.pa_sign    EQUB $80,0,0,$80, 0,$80,$80,0

\ ============================================================================
\ bbox_check_angle: angle-space bbox visibility (FINEANGLES=4096, ANG90=1024,
\ ANG45=CLIPANGLE=512, ANGMASK=4095). Mirrors angle_bbox.bbox_check_angle.
\   in : bca_top/bot/left/right (s16 contiguous $88..$8F), bca_px/py (s8),
\        bca_ab (u8)
\   out: bca_vis (1=visible/0=cull), bca_ilo, bca_ihi (u8 columns)
\ ============================================================================
bca_top  = $FA10        \ s16; bot $8A, left $8C, right $8E (contiguous = val[])
bca_bot  = $FA12
bca_left = $FA14
bca_right = $FA16
\ px/py aliased to the live renderer's player-int ZP (frame-persistent);
\ ab + outputs in the BBOX-vars region the old br_bbox_visible freed.
bca_px   = $01        \ zp_br_px_h (player int x, s8)
bca_py   = $03        \ zp_br_py_h
bca_ab   = $FA2F
bca_ilo  = $FA30
bca_ihi  = $FA31
bca_vis  = $FA32
bca_afn  = $3B          \ a_fine (s16) -- ZP (freed from pa_adx); hot in corner_phi
bca_cy   = $71          \ corner y (s16) -- ZP (freed from pa_ady); hot in corner_phi
bca_p1   = $FA1E        \ phi1 (s16)
bca_p2   = $FA20        \ phi2 (s16)
\ Hottest body vars in spare scavenged ZP (conflict-free) to cut the
\ absolute-access tax across box_pos / corner_phi / sort / clip / clamp / VATOX.
bca_lo   = $1E          \ lo_phi (s16)
bca_hi   = $8B          \ hi_phi (s16)
bca_pxs  = $8D          \ px sign-extended (s16)
bca_pys  = $9B          \ py sign-extended (s16)
bca_cx   = $9D          \ corner x (s16)
t0       = $FA2A
t1       = $FA2B
val_lo   = $FA2C
val_hi   = $FA2D
bca_ccsave = $FA2E
VATOX    = $F601      \ viewangletox, 1025 entries (phi+512), $F601-$FA01

.bbox_check_angle
{
    LDA #0 : STA bca_vis
    \ sign-extend px,py to s16
    LDA bca_px : STA bca_pxs : LDX #0 : BPL bs1
.bs1
    LDA bca_px : BPL bs1p : LDX #$FF
.bs1p
    STX bca_pxs+1
    LDA bca_py : STA bca_pys : LDX #0
    LDA bca_py : BPL bs2p : LDX #$FF
.bs2p
    STX bca_pys+1
    \ inside test: left<=px<=right and bot<=py<=top  -> full (0,255)
    \ left<=px : px-left >= 0
    JSR ins_test
    \ a_fine = ab << 4 (ab is u8): low = (ab<<4)&FF, high = ab>>4. Nibble
    \ shifts in the register beat 8 absolute read-modify-write shifts.
    LDA bca_ab : LSR A : LSR A : LSR A : LSR A : STA bca_afn+1
    LDA bca_ab : ASL A : ASL A : ASL A : ASL A : STA bca_afn
    \ boxx/boxy -> boxpos -> checkcoord
    JSR box_pos               \ -> X = boxpos
    \ cc = checkcoord + boxpos*4
    TXA : ASL A : ASL A : TAX
    \ corner1 = (val[cc0], val[cc1]); load_val inlined -> cx/cy directly
    \ (Y = val index*2 into the box at bca_top; X unchanged by the load).
    LDY bca_cc,X   : TYA : ASL A : TAY : LDA bca_top,Y : STA bca_cx : LDA bca_top+1,Y : STA bca_cx+1
    LDY bca_cc+1,X : TYA : ASL A : TAY : LDA bca_top,Y : STA bca_cy : LDA bca_top+1,Y : STA bca_cy+1
    STX bca_ccsave
    JSR corner_phi : LDA pa_res : STA bca_p1 : LDA pa_res+1 : STA bca_p1+1
    LDX bca_ccsave
    \ corner2 = (val[cc2], val[cc3])
    LDY bca_cc+2,X : TYA : ASL A : TAY : LDA bca_top,Y : STA bca_cx : LDA bca_top+1,Y : STA bca_cx+1
    LDY bca_cc+3,X : TYA : ASL A : TAY : LDA bca_top,Y : STA bca_cy : LDA bca_top+1,Y : STA bca_cy+1
    JSR corner_phi : LDA pa_res : STA bca_p2 : LDA pa_res+1 : STA bca_p2+1
    \ lo/hi = sorted(p1,p2)  (SIGNED s16 compare: p1-p2 < 0 -> p1 is lo)
    SEC : LDA bca_p1 : SBC bca_p2 : LDA bca_p1+1 : SBC bca_p2+1
    BVC so1 : EOR #$80
.so1
    BMI p1lo
.p2lo  \ p1 >= p2 -> p2 is lo
    LDA bca_p2 : STA bca_lo : LDA bca_p2+1 : STA bca_lo+1
    LDA bca_p1 : STA bca_hi : LDA bca_p1+1 : STA bca_hi+1
    JMP havelh
.p1lo
    LDA bca_p1 : STA bca_lo : LDA bca_p1+1 : STA bca_lo+1
    LDA bca_p2 : STA bca_hi : LDA bca_p2+1 : STA bca_hi+1
.havelh
    JMP havelh2
.cullt
    JMP cull
.havelh2
    \ if hi-lo > ANG180 (2048): None
    SEC : LDA bca_hi : SBC bca_lo : STA t0
          LDA bca_hi+1 : SBC bca_lo+1 : STA t1
    \ compare (t1:t0) > 2048 : if t1>8 or (t1==8 and t0>0)
    LDA t1 : CMP #8 : BCC span_ok : BNE cullt
    LDA t0 : BNE cullt
.span_ok
    \ if hi < -CLIPANGLE(-512): cull   (hi signed)
    LDA bca_hi+1 : BPL hi_nonneg
    \ hi negative: hi < -512 ? compare hi < -512
    LDA bca_hi : CMP #$00 : LDA bca_hi+1 : SBC #$FE : BVC h1 : EOR #$80
.h1
    BMI cullt
.hi_nonneg
    \ if lo > CLIPANGLE(512): cull  (strict: keep lo == 512)
    SEC : LDA #<512 : SBC bca_lo : LDA #>512 : SBC bca_lo+1 : BVC h2 : EOR #$80
.h2
    BPL lo_le : JMP cull        \ 512-lo >= 0 -> lo <= 512 -> keep
.lo_le
    \ clamp lo to >= -512, hi to <= 512
    JSR clamp_lohi
    \ ilo = VATOX[lo+512]-1 ; ihi = VATOX[hi+512]+1 ; clamp [0,255].
    \ VATOX holds only the used range (phi in [-512,512] -> index [0,1024]),
    \ so the bias is +512 (not +1024); upper half of the angle range is
    \ never reached after clamp_lohi.
    \ address = (VATOX+512) + lo : fold the +512 bias into the base so it's a
    \ single add (lo is signed s16; two's-complement add lands in range).
    CLC : LDA #<(VATOX+512) : ADC bca_lo   : STA pa_ptr
          LDA #>(VATOX+512) : ADC bca_lo+1 : STA pa_ptr+1
    LDY #0 : LDA (pa_ptr),Y          \ vatox[lo]
    SEC : SBC #1 : BCS il1 : LDA #0
.il1
    STA bca_ilo
    CLC : LDA #<(VATOX+512) : ADC bca_hi   : STA pa_ptr
          LDA #>(VATOX+512) : ADC bca_hi+1 : STA pa_ptr+1
    LDA (pa_ptr),Y                    \ vatox[hi]
    CLC : ADC #1 : BCC ih1 : LDA #255
.ih1
    CMP #255 : BCC ih2 : LDA #255
.ih2
    STA bca_ihi
    \ if ilo > ihi: cull
    LDA bca_ilo : CMP bca_ihi : BEQ visok : BCS cull
.visok
    LDA #1 : STA bca_vis
    RTS
.cull
    LDA #0 : STA bca_vis
    RTS
}

\ inside test: if left<=px<=right and bot<=py<=top, set vis=1,ilo=0,ihi=255,
\ and return from bbox_check_angle (pull caller return).
.ins_test
{
    \ px - left >= 0 ?
    SEC : LDA bca_pxs : SBC bca_left : LDA bca_pxs+1 : SBC bca_left+1
    BVC i1 : EOR #$80
.i1
    BMI notin
    \ right - px >= 0 ?
    SEC : LDA bca_right : SBC bca_pxs : LDA bca_right+1 : SBC bca_pxs+1
    BVC i2 : EOR #$80
.i2
    BMI notin
    \ py - bot >= 0 ?
    SEC : LDA bca_pys : SBC bca_bot : LDA bca_pys+1 : SBC bca_bot+1
    BVC i3 : EOR #$80
.i3
    BMI notin
    \ top - py >= 0 ?
    SEC : LDA bca_top : SBC bca_pys : LDA bca_top+1 : SBC bca_pys+1
    BVC i4 : EOR #$80
.i4
    BMI notin
    \ inside -> set full, discard bbox_check_angle's return addr, return to its caller
    LDA #1 : STA bca_vis
    LDA #0 : STA bca_ilo
    LDA #255 : STA bca_ihi
    PLA : PLA               \ drop ins_test return
    RTS                      \ return to bbox_check_angle's caller
.notin
    RTS
}

\ box_pos -> X = boxy*4+boxx
.box_pos
{
    \ boxx: 0 if px<=left, 1 if px<right, else 2
    SEC : LDA bca_left : SBC bca_pxs : LDA bca_left+1 : SBC bca_pxs+1
    BVC b1 : EOR #$80
.b1
    BPL bx0                 \ left-px >= 0 -> px<=left -> boxx=0
    SEC : LDA bca_right : SBC bca_pxs : LDA bca_right+1 : SBC bca_pxs+1
    BVC b2 : EOR #$80
.b2
    BMI bx2                 \ right-px < 0 -> px>=right -> boxx=2 (px<right false)
    LDA #1 : JMP bxd
.bx0
    LDA #0 : JMP bxd
.bx2
    LDA #2
.bxd
    STA t0                  \ boxx
    \ boxy: 0 if py>=top, 1 if py>bot, else 2
    SEC : LDA bca_pys : SBC bca_top : LDA bca_pys+1 : SBC bca_top+1
    BVC c1 : EOR #$80
.c1
    BPL by0                 \ py-top>=0 -> py>=top -> boxy=0
    SEC : LDA bca_pys : SBC bca_bot : LDA bca_pys+1 : SBC bca_bot+1
    BVC c2 : EOR #$80
.c2
    BMI by2                 \ py-bot<0 -> py<=bot -> boxy=2
    LDA #1 : JMP byd        \ py>bot -> boxy=1
.by0
    LDA #0 : JMP byd
.by2
    LDA #2
.byd
    ASL A : ASL A : CLC : ADC t0 : TAX
    RTS
}

\ (load_val removed: inlined at the corner loads.)

\ corner_phi: dx=cx-pxs, dy=cy-pys; point_to_angle; pa_res=(afn-psi)&MASK signed
.corner_phi
{
    SEC : LDA bca_cx : SBC bca_pxs : STA pa_dx
          LDA bca_cx+1 : SBC bca_pxs+1 : STA pa_dx+1
    SEC : LDA bca_cy : SBC bca_pys : STA pa_dy
          LDA bca_cy+1 : SBC bca_pys+1 : STA pa_dy+1
    JSR point_to_angle       \ -> pa_res (psi)
    SEC : LDA bca_afn : SBC pa_res : STA pa_res
          LDA bca_afn+1 : SBC pa_res+1
    \ Mask to 12 bits and sign-extend to s16 in one go on the hi byte: 4096's
    \ low byte is 0, so the &4095 and the (>=2048 ? -4096) only touch the hi
    \ byte; pa_res (lo) is already correct.
    AND #$0F                  \ phi & 4095 (hi nibble)
    CMP #8 : BCC cp_store     \ < 2048 -> keep; else C=1 for the wrap
    SBC #$10                  \ -= 4096 (hi -= $10) -> signed [-2048,2048)
.cp_store
    STA pa_res+1
    RTS
}

\ clamp bca_lo >= -512, bca_hi <= 512
.clamp_lohi
{
    \ lo < -512 ? -> lo = -512
    LDA bca_lo : CMP #$00 : LDA bca_lo+1 : SBC #$FE : BVC k1 : EOR #$80
.k1
    BPL k_hi
    LDA #$00 : STA bca_lo : LDA #$FE : STA bca_lo+1
.k_hi
    \ hi > 512 ? -> hi = 512
    LDA #<512 : CMP bca_hi : LDA #>512 : SBC bca_hi+1 : BVC k2 : EOR #$80
.k2
    BPL k_done
    LDA #<512 : STA bca_hi : LDA #>512 : STA bca_hi+1
.k_done
    RTS
}

\ checkcoord[boxpos*4]: indices into (top=0,bot=1,left=2,right=3).
\ rows 3,7,11 and 5 unused (5=inside handled earlier).
.bca_cc
    EQUB 3,0,2,1,  3,0,2,0,  3,1,2,0,  0,0,0,0
    EQUB 2,0,2,1,  0,0,0,0,  3,1,3,0,  0,0,0,0
    EQUB 2,0,3,1,  2,1,3,1,  2,1,3,0,  0,0,0,0

\ cos_fine (option-2b): cf_ang (u16 fine angle) -> A = cf_res = s8 (cos*127).
\ 256-entry s8 cos table at byte-angle resolution: idx = ((hi&15)<<4)|(lo>>4).
cf_ang = $9B
cf_res = $9D
cf_tmp = $9F
COS_TAB = $FB00          \ 256 bytes, signed (above bca vars at $FA10)
.cos_fine
{
    LDA cf_ang : LSR A : LSR A : LSR A : LSR A : STA cf_tmp   \ lo>>4
    LDA cf_ang+1 : AND #$0F : ASL A : ASL A : ASL A : ASL A   \ (hi&15)<<4
    ORA cf_tmp : TAX
    LDA COS_TAB,X : STA cf_res
    RTS
}

\ seg_depth (option-2b): depth = c*cos(phi)/cos(den_angle), clamped u16.
\   in : sp_c (s16, perp dist s.4), sp_phi (fine), sp_den (fine = a_fine-phi-na)
\   out: sp_depth (u16 = CFRAC*true_depth); C set on cull (depth<=0).
\ Uses umul8 ($2030) for |c|*cph and a u24/u8 rounded restoring divide.
SC_UMUL8 = $2030
zp_mul_b = $D9
zp_prod_lo = $DA
zp_prod_hi = $DB
sp_c     = $30
sp_phi   = $32
sp_den   = $44
sp_depth = $46
sp_absc  = $48
sp_num0  = $4A
sp_num1  = $4B
sp_num2  = $71
sp_cph   = $72
sp_den8  = $73
sp_sign  = $89
sp_rem   = $8A
.seg_depth
{
    LDA sp_phi   : STA cf_ang
    LDA sp_phi+1 : STA cf_ang+1
    JSR cos_fine                       \ A = cph (s8, >0 for clamped phi)
    STA sp_cph
    LDA sp_den   : STA cf_ang
    LDA sp_den+1 : STA cf_ang+1
    JSR cos_fine                       \ A = cden (s8)
    LDX #0
    STA sp_den8
    CMP #0 : BPL sd_dpos               \ CMP sets N from cden (LDX clobbered it)
    LDA #0 : SEC : SBC sp_den8 : STA sp_den8    \ |cden|
    LDX #1
.sd_dpos
    STX sp_sign
    LDA sp_den8 : BNE sd_dok           \ cos(den)==0 -> divide-by-zero -> cull
    SEC : RTS
.sd_dok
    LDA sp_c+1 : BPL sd_cpos
    SEC : LDA #0 : SBC sp_c   : STA sp_absc
          LDA #0 : SBC sp_c+1 : STA sp_absc+1
    LDA sp_sign : EOR #1 : STA sp_sign
    JMP sd_havec
.sd_cpos
    LDA sp_c : STA sp_absc : LDA sp_c+1 : STA sp_absc+1
.sd_havec
    \ |num| (u24) = |c| * cph
    LDA sp_cph : STA zp_mul_b
    LDA sp_absc : JSR SC_UMUL8
    LDA zp_prod_lo : STA sp_num0
    LDA zp_prod_hi : STA sp_num1
    LDA sp_cph : STA zp_mul_b
    LDA sp_absc+1 : JSR SC_UMUL8
    CLC
    LDA zp_prod_lo : ADC sp_num1 : STA sp_num1
    LDA zp_prod_hi : ADC #0      : STA sp_num2
    \ round: num += |den|>>1
    LDA sp_den8 : LSR A
    CLC : ADC sp_num0 : STA sp_num0
    LDA sp_num1 : ADC #0 : STA sp_num1
    LDA sp_num2 : ADC #0 : STA sp_num2
    \ u24 / u8 restoring divide
    LDA #0 : STA sp_rem
    LDX #24
.sd_dl
    ASL sp_num0 : ROL sp_num1 : ROL sp_num2 : ROL sp_rem
    LDA sp_rem : CMP sp_den8 : BCC sd_dno
    SBC sp_den8 : STA sp_rem
    INC sp_num0
.sd_dno
    DEX : BNE sd_dl
    LDA sp_sign : BNE sd_cull
    LDA sp_num2 : BNE sd_clamp
    LDA sp_num0 : STA sp_depth
    LDA sp_num1 : STA sp_depth+1
    ORA sp_depth : BEQ sd_cull
    CLC : RTS
.sd_clamp
    LDA #$FF : STA sp_depth : STA sp_depth+1
    CLC : RTS
.sd_cull
    SEC : RTS
}

\ proj_yd (option-2b): yt = HALF_H - round(hd*FOCAL*16 / depth)  (= hd<<11 / depth).
\   in : sp_hd (s8), sp_depth (u16, from seg_depth) ; out: sp_yt (s16).
HALF_H_C = 80
sp_hd  = $30
sp_yt  = $32
sp_dl  = $48
sp_dh  = $49
sp_yrem = $44
.proj_yd
{
    LDA sp_hd : BPL py_pos
    EOR #$FF : CLC : ADC #1            \ |hd|
.py_pos
    \ (|hd|<<3) -> sp_dl:sp_dh ; num24 = that << 8  (num0=0,num1=dl,num2=dh)
    STA sp_dl : LDA #0 : STA sp_dh
    ASL sp_dl : ROL sp_dh
    ASL sp_dl : ROL sp_dh
    ASL sp_dl : ROL sp_dh
    LDA #0     : STA sp_num0
    LDA sp_dl  : STA sp_num1
    LDA sp_dh  : STA sp_num2
    \ round: num24 += depth>>1
    LDA sp_depth+1 : LSR A : STA sp_dh
    LDA sp_depth   : ROR A : STA sp_dl
    CLC
    LDA sp_num0 : ADC sp_dl : STA sp_num0
    LDA sp_num1 : ADC sp_dh : STA sp_num1
    LDA sp_num2 : ADC #0    : STA sp_num2
    \ u24 / u16 restoring divide -> quotient in sp_num0/1
    LDA #0 : STA sp_yrem : STA sp_yrem+1
    LDX #24
.py_dl
    ASL sp_num0 : ROL sp_num1 : ROL sp_num2 : ROL sp_yrem : ROL sp_yrem+1
    BCS py_dyes                       \ 17th bit -> rem >= 65536 > depth
    LDA sp_yrem+1 : CMP sp_depth+1 : BCC py_dno
    BNE py_dyes
    LDA sp_yrem   : CMP sp_depth   : BCC py_dno
.py_dyes
    LDA sp_yrem   : SEC : SBC sp_depth   : STA sp_yrem
    LDA sp_yrem+1 :       SBC sp_depth+1 : STA sp_yrem+1
    INC sp_num0
.py_dno
    DEX : BNE py_dl
    \ yt = 80 -/+ quotient (sign of hd)
    LDA sp_hd : BMI py_neg
    SEC : LDA #HALF_H_C : SBC sp_num0 : STA sp_yt
    LDA #0 :             SBC sp_num1 : STA sp_yt+1
    RTS
.py_neg
    CLC : LDA #HALF_H_C : ADC sp_num0 : STA sp_yt
    LDA #0 :             ADC sp_num1 : STA sp_yt+1
    RTS
}

\ seg_c (option-2b): per-seg signed perpendicular distance (s.4).
\   c = round( (dy1*ldx - dx1*ldy) << 4 / L )  with L the seg length (u8 ROM).
\   in : sc_dy1=wy1-py (s16), sc_dx1=wx1-px (s16), sc_ldx (s8), sc_ldy (s8),
\        sc_L (u8) ;  out: sp_c (s16, $30/$31).
sc_dy1 = $32
sc_dx1 = $34
sc_ldx = $36
sc_ldy = $37
sc_L   = $38
sc_sgn = $39
sc_p2  = $3A
.seg_c
{
    \ ---- p1 = dy1 * ldx -> cross (sp_num0/1/2, signed 24) ----
    LDA #0 : STA sc_sgn
    LDA sc_dy1+1 : BPL sc_dyp
    SEC : LDA #0 : SBC sc_dy1 : STA sc_dy1
          LDA #0 : SBC sc_dy1+1 : STA sc_dy1+1
    INC sc_sgn
.sc_dyp
    LDA sc_ldx : BPL sc_lxp
    EOR #$FF : CLC : ADC #1 : STA sc_ldx
    LDA sc_sgn : EOR #1 : STA sc_sgn
.sc_lxp
    LDA sc_ldx : STA zp_mul_b
    LDA sc_dy1 : JSR SC_UMUL8
    LDA zp_prod_lo : STA sp_num0
    LDA zp_prod_hi : STA sp_num1
    LDA sc_ldx : STA zp_mul_b
    LDA sc_dy1+1 : JSR SC_UMUL8
    CLC
    LDA zp_prod_lo : ADC sp_num1 : STA sp_num1
    LDA zp_prod_hi : ADC #0      : STA sp_num2
    LDA sc_sgn : BEQ sc_p1pos
    SEC : LDA #0 : SBC sp_num0 : STA sp_num0
          LDA #0 : SBC sp_num1 : STA sp_num1
          LDA #0 : SBC sp_num2 : STA sp_num2
.sc_p1pos
    \ ---- p2 = dx1 * ldy -> sc_p2 (signed 24) ----
    LDA #0 : STA sc_sgn
    LDA sc_dx1+1 : BPL sc_dxp
    SEC : LDA #0 : SBC sc_dx1 : STA sc_dx1
          LDA #0 : SBC sc_dx1+1 : STA sc_dx1+1
    INC sc_sgn
.sc_dxp
    LDA sc_ldy : BPL sc_lyp
    EOR #$FF : CLC : ADC #1 : STA sc_ldy
    LDA sc_sgn : EOR #1 : STA sc_sgn
.sc_lyp
    LDA sc_ldy : STA zp_mul_b
    LDA sc_dx1 : JSR SC_UMUL8
    LDA zp_prod_lo : STA sc_p2
    LDA zp_prod_hi : STA sc_p2+1
    LDA sc_ldy : STA zp_mul_b
    LDA sc_dx1+1 : JSR SC_UMUL8
    CLC
    LDA zp_prod_lo : ADC sc_p2+1 : STA sc_p2+1
    LDA zp_prod_hi : ADC #0      : STA sc_p2+2
    LDA sc_sgn : BEQ sc_p2pos
    SEC : LDA #0 : SBC sc_p2   : STA sc_p2
          LDA #0 : SBC sc_p2+1 : STA sc_p2+1
          LDA #0 : SBC sc_p2+2 : STA sc_p2+2
.sc_p2pos
    \ ---- cross = p1 - p2 (signed 24, in sp_num0/1/2) ----
    SEC
    LDA sp_num0 : SBC sc_p2   : STA sp_num0
    LDA sp_num1 : SBC sc_p2+1 : STA sp_num1
    LDA sp_num2 : SBC sc_p2+2 : STA sp_num2
    \ ---- |cross| + sign ----
    LDA #0 : STA sc_sgn
    LDA sp_num2 : BPL sc_crp
    SEC : LDA #0 : SBC sp_num0 : STA sp_num0
          LDA #0 : SBC sp_num1 : STA sp_num1
          LDA #0 : SBC sp_num2 : STA sp_num2
    INC sc_sgn
.sc_crp
    \ num = |cross| << 4
    LDX #4
.sc_shl
    ASL sp_num0 : ROL sp_num1 : ROL sp_num2
    DEX : BNE sc_shl
    \ round: num += L>>1
    LDA sc_L : LSR A
    CLC : ADC sp_num0 : STA sp_num0
    LDA sp_num1 : ADC #0 : STA sp_num1
    LDA sp_num2 : ADC #0 : STA sp_num2
    \ u24 / u8 restoring divide -> quotient (sp_num0/1)
    LDA #0 : STA sp_rem
    LDX #24
.sc_dl
    ASL sp_num0 : ROL sp_num1 : ROL sp_num2 : ROL sp_rem
    LDA sp_rem : CMP sc_L : BCC sc_dno
    SBC sc_L : STA sp_rem
    INC sp_num0
.sc_dno
    DEX : BNE sc_dl
    \ c = sgn ? -quotient : quotient -> sp_c
    LDA sc_sgn : BNE sc_cneg
    LDA sp_num0 : STA sp_c
    LDA sp_num1 : STA sp_c+1
    RTS
.sc_cneg
    SEC : LDA #0 : SBC sp_num0 : STA sp_c
          LDA #0 : SBC sp_num1 : STA sp_c+1
    RTS
}

\ seg_project (option-2b): one endpoint -> sx (column) + depth, or carry=cull.
\   in : bca_cx/bca_cy (vertex s16), bca_pxs/bca_pys (player s16),
\        bca_afn (a_fine), sp_na (seg normal s16), sp_c (perp dist, from seg_c).
\   out: sp_sx (u8 column), sp_depth (u16) ; carry set = cull.
\   Mirrors angle_seg.seg_2b per-endpoint: phi = clamp(a_fine-ptangle, +/-512);
\   sx = VATOX_centre[phi] (clamp baked into table); depth via seg_depth.
sp_na    = $4C
sp_sx    = $4E
sc_stash = $42
.seg_project
{
    LDA sp_c   : STA sc_stash          \ c survives point_to_angle ($30/$31 reuse)
    LDA sp_c+1 : STA sc_stash+1
    JSR corner_phi                     \ pa_res = phi signed [-2048,2048)
    \ clamp phi to [-512,+512]  (same compares as clamp_lohi)
    LDA #<512 : CMP pa_res : LDA #>512 : SBC pa_res+1 : BVC sp_c1 : EOR #$80
.sp_c1
    BPL sp_clo
    LDA #<512 : STA pa_res : LDA #>512 : STA pa_res+1
    JMP sp_have
.sp_clo
    LDA pa_res : CMP #$00 : LDA pa_res+1 : SBC #$FE : BVC sp_c2 : EOR #$80
.sp_c2
    BPL sp_have
    LDA #$00 : STA pa_res : LDA #$FE : STA pa_res+1
.sp_have
    LDA pa_res   : STA sp_phi
    LDA pa_res+1 : STA sp_phi+1
    \ sx = VATOX[(VATOX+512) + phi]   (table already clamps column to [0,255])
    CLC : LDA #<(VATOX+512) : ADC pa_res   : STA pa_ptr
          LDA #>(VATOX+512) : ADC pa_res+1 : STA pa_ptr+1
    LDY #0 : LDA (pa_ptr),Y : STA sp_sx
    \ den = a_fine - phi - na -> sp_den  (cos_fine masks to 4096 internally)
    SEC : LDA bca_afn   : SBC sp_phi   : STA sp_den
          LDA bca_afn+1 : SBC sp_phi+1 : STA sp_den+1
    SEC : LDA sp_den   : SBC sp_na   : STA sp_den
          LDA sp_den+1 : SBC sp_na+1 : STA sp_den+1
    LDA sc_stash   : STA sp_c          \ restore c for seg_depth
    LDA sc_stash+1 : STA sp_c+1
    JMP seg_depth                      \ tail: -> sp_depth or carry=cull
}

.end
ASSERT end <= TA_HI      \ code must not grow into the relocated tables ($F200+)
SAVE "bsp_render_ang.bin", $E940, end, $E940
