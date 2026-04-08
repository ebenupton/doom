; span_clip.asm — Standalone 6502 span clipper subsystem
;
; Pool at POOL ($0400), 32 × 8-byte slots.  Slot 0 = null.
; Slot layout: next(u8), xlo(u8), xhi(u8), tl(u8), bl(u8), tr(u8), br(u8), pad
; Access: LDX span_offset; LDA POOL_XLO,X  (fast absolute indexed)
;
; Division by 256 (ex=0): just take high byte of multiply (shift, no loop).
; Otherwise: restoring division loop, 8 iterations.

ORG $2000

; Jump table
JMP span_init       ; $2000
JMP span_mark_solid ; $2003
JMP span_tighten    ; $2006
JMP span_has_gap    ; $2009
JMP span_is_full    ; $200C
JMP span_read       ; $200F
JMP interp_floor    ; $2012
JMP interp_ceil     ; $2015
JMP interp_store    ; $2018

; === Constants ===
POOL      = $0400
POOL_NEXT = $0400
POOL_XLO  = $0401
POOL_XHI  = $0402
POOL_TL   = $0403
POOL_BL   = $0404
POOL_TR   = $0405
POOL_BR   = $0406

sqr_lo  = $5400 : sqr_hi  = $5500
sqr2_lo = $5600 : sqr2_hi = $5700

; === ZP ($C0-$EF) ===
zp_head  = $C0 : zp_free  = $C1
zp_ilo   = $C2 : zp_ihi   = $C3
zp_sx1   = $C4 : zp_sx2   = $C5
zp_yt1   = $C6 : zp_yt2   = $C7
zp_yb1   = $C8 : zp_yb2   = $C9
zp_i_x   = $CA : zp_i_x0  = $CB : zp_i_y0 = $CC
zp_i_x1  = $CD : zp_i_y1  = $CE : zp_i_res = $CF
zp_mul_b = $D0 : zp_prod_lo = $D1 : zp_prod_hi = $D2
zp_div_lo = $D3 : zp_div_hi = $D4
zp_div_den = $D5 : zp_div_rem = $D6
zp_tmp0  = $D7 : zp_tmp1  = $D8 : zp_tmp2  = $D9
zp_tmp3  = $DA : zp_prev  = $DB
zp_buf   = $DC  ; u16 pointer
zp_save0 = $DE  ; safe scratch (not clobbered by interp)
zp_save1 = $DF  ; safe scratch #2

; ======================================================================
; SPAN_INIT
; ======================================================================
.span_init
{
    ; Free list: slots 2..31
    LDX #16              ; slot 2
    STX zp_free
.il  TXA : CLC : ADC #8
    BEQ id               ; wrapped to 0 → done
    STA POOL_NEXT,X : TAX
    JMP il
.id  LDA #0 : STA POOL_NEXT,X
    ; Active list: slot 1 = [0, 256) top=0 bot=159
    LDX #8 : STX zp_head
    LDA #0
    STA POOL_NEXT,X : STA POOL_XLO,X : STA POOL_XHI,X
    STA POOL_TL,X : STA POOL_TR,X
    LDA #159
    STA POOL_BL,X : STA POOL_BR,X
    RTS
}

; ======================================================================
; ALLOC / FREE
; ======================================================================
.alloc_span
    ; Returns X = new span offset.  Z=1 if failed (X=0), Z=0 if success.
    LDX zp_free : BEQ af
    LDA POOL_NEXT,X : STA zp_free
    LDA #0 : STA POOL_NEXT,X
    TXA                     ; A=X, sets Z=0 since X≠0
.af RTS

.free_span
    LDA zp_free : STA POOL_NEXT,X : STX zp_free : RTS

; ======================================================================
; UNSIGNED 8×8 MULTIPLY: A × zp_mul_b → zp_prod_lo:zp_prod_hi
; ======================================================================
.umul8
{
    ; a*b = sqr(a+b) - sqr(|a-b|)
    ; sqr_lo/hi for index [0,255], sqr2_lo/hi for index [256,511]
    STA zp_tmp0
    CLC : ADC zp_mul_b : BCS uo
    ; sum < 256: use sqr for sum
    TAX
    SEC : LDA zp_tmp0 : SBC zp_mul_b : BCS up
    EOR #$FF : ADC #1   ; |diff| (carry was clear so ADC adds 1 extra — fix:)
.up TAY                  ; Y = |diff|, always use sqr (not sqr2) for diff
    LDA sqr_lo,X : SEC : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr_hi,X : SBC sqr_hi,Y : STA zp_prod_hi : RTS
.uo ; sum >= 256: use sqr2 for sum
    TAX                  ; X = (a+b) & 0xFF
    SEC : LDA zp_tmp0 : SBC zp_mul_b : BCS uop
    EOR #$FF : ADC #1   ; |diff|
.uop TAY                 ; Y = |diff|, use sqr (not sqr2) for diff
    LDA sqr2_lo,X : SEC : SBC sqr_lo,Y : STA zp_prod_lo
    LDA sqr2_hi,X : SBC sqr_hi,Y : STA zp_prod_hi : RTS
}

; s8 × u8: A(s8) × zp_mul_b(u8) → zp_prod_lo:zp_prod_hi(s16)
.smul8
{
    BPL umul8
    EOR #$FF : CLC : ADC #1 : JSR umul8
    SEC : LDA #0 : SBC zp_prod_lo : STA zp_prod_lo
    LDA #0 : SBC zp_prod_hi : STA zp_prod_hi : RTS
}

; ======================================================================
; UNSIGNED 16/8 DIVISION: zp_div_lo:hi / zp_div_den → A(quot) rem in zp_div_rem
; Special: den=0 → divide by 256 → A=zp_div_hi
; ======================================================================
.udiv16_8
{
    ; u16 / u8 → u8 quotient (in A), u8 remainder (in zp_div_rem)
    ; 16-iteration restoring division.
    ; Special: den=0 → divide by 256 → A = zp_div_hi
    LDA zp_div_den : BNE dn
    LDA zp_div_hi : LDX #0 : STX zp_div_rem : RTS
.dn LDA #0 : STA zp_div_rem : LDX #16
.dl ASL zp_div_lo : ROL zp_div_hi : ROL zp_div_rem
    LDA zp_div_rem : SEC : SBC zp_div_den : BCC ds
    STA zp_div_rem : INC zp_div_lo
.ds DEX : BNE dl
    LDA zp_div_lo : RTS   ; quotient in low byte
}

; ======================================================================
; INTERP CORE: compute product and divide
; Shared by floor/ceil/store.  On entry, zp_i_* set up.
; Returns with product in zp_prod_lo:hi, den in zp_div_den.
; ======================================================================
.interp_core
{
    ; Check true x0==x1 (not 0==0 which means ex=256)
    LDA zp_i_x0 : CMP zp_i_x1 : BNE ic_ok
    ; x0==x1: degenerate (zero-width span)
    LDA #0 : STA zp_prod_lo : STA zp_prod_hi : RTS
.ic_ok
    LDA zp_i_x1 : SEC : SBC zp_i_x0  ; ex (0 means 256)
    STA zp_div_den
    LDA zp_i_y1 : SEC : SBC zp_i_y0 : STA zp_tmp0  ; dy
    LDA zp_i_x : SEC : SBC zp_i_x0 : STA zp_mul_b   ; offset
    LDA zp_tmp0 : JMP smul8   ; product in zp_prod_lo:hi
}

; ======================================================================
; INTERP_FLOOR: y0 + floor(dy*offset/ex)
; ======================================================================
.interp_floor
{
    JSR interp_core
    ; Check if product is 0
    LDA zp_prod_lo : ORA zp_prod_hi
    BNE if_nz
    LDA zp_i_y0 : STA zp_i_res : RTS
.if_nz
    LDA zp_prod_hi : BMI if_neg
    ; Positive: floor = unsigned divide
    LDA zp_prod_lo : STA zp_div_lo
    LDA zp_prod_hi : STA zp_div_hi
    JSR udiv16_8
    CLC : ADC zp_i_y0 : STA zp_i_res : RTS
.if_neg
    ; Negative: floor = -((-prod + den - 1) / den)
    SEC : LDA #0 : SBC zp_prod_lo : STA zp_div_lo
    LDA #0 : SBC zp_prod_hi : STA zp_div_hi
    ; Add den-1
    LDA zp_div_lo : CLC : ADC zp_div_den : STA zp_div_lo
    LDA zp_div_hi : ADC #0 : STA zp_div_hi
    LDA zp_div_lo : SEC : SBC #1 : STA zp_div_lo
    LDA zp_div_hi : SBC #0 : STA zp_div_hi
    JSR udiv16_8
    EOR #$FF : CLC : ADC #1  ; negate
    CLC : ADC zp_i_y0 : STA zp_i_res : RTS
}

; ======================================================================
; INTERP_CEIL: y0 + ceil(dy*offset/ex)
; ======================================================================
.interp_ceil
{
    JSR interp_core
    LDA zp_prod_lo : ORA zp_prod_hi
    BNE ic_nz
    LDA zp_i_y0 : STA zp_i_res : RTS
.ic_nz
    LDA zp_prod_hi : BMI ic_neg
    ; Positive: ceil = (prod + den - 1) / den
    LDA zp_prod_lo : CLC : ADC zp_div_den : STA zp_div_lo
    LDA zp_prod_hi : ADC #0 : STA zp_div_hi
    LDA zp_div_lo : SEC : SBC #1 : STA zp_div_lo
    LDA zp_div_hi : SBC #0 : STA zp_div_hi
    JSR udiv16_8
    CLC : ADC zp_i_y0 : STA zp_i_res : RTS
.ic_neg
    ; Negative: ceil = -((-prod) / den) (truncate toward zero)
    SEC : LDA #0 : SBC zp_prod_lo : STA zp_div_lo
    LDA #0 : SBC zp_prod_hi : STA zp_div_hi
    JSR udiv16_8
    EOR #$FF : CLC : ADC #1
    CLC : ADC zp_i_y0 : STA zp_i_res : RTS
}

; ======================================================================
; INTERP_STORE: y0 + round_nearest(dy*offset/ex)
; ======================================================================
.interp_store
{
    JSR interp_core
    ; Add ex/2 to product
    LDA zp_div_den : LSR A : CLC : ADC zp_prod_lo : STA zp_prod_lo
    LDA zp_prod_hi : ADC #0 : STA zp_prod_hi
    ; Now floor-divide
    LDA zp_prod_hi : BMI is_neg
    LDA zp_prod_lo : STA zp_div_lo
    LDA zp_prod_hi : STA zp_div_hi
    JSR udiv16_8
    CLC : ADC zp_i_y0 : STA zp_i_res : RTS
.is_neg
    SEC : LDA #0 : SBC zp_prod_lo : STA zp_div_lo
    LDA #0 : SBC zp_prod_hi : STA zp_div_hi
    LDA zp_div_lo : CLC : ADC zp_div_den : STA zp_div_lo
    LDA zp_div_hi : ADC #0 : STA zp_div_hi
    LDA zp_div_lo : SEC : SBC #1 : STA zp_div_lo
    LDA zp_div_hi : SBC #0 : STA zp_div_hi
    JSR udiv16_8
    EOR #$FF : CLC : ADC #1
    CLC : ADC zp_i_y0 : STA zp_i_res : RTS
}

; ======================================================================
; INTERP_SPAN: interpolate top+bot of span X at zp_tmp0=x using _store
; Input: X=span offset, zp_tmp0=x. Output: zp_tmp1=top, zp_tmp2=bot
; Preserves: nothing (uses zp_i_*)
; ======================================================================
.interp_span
{
    LDA zp_tmp0 : STA zp_i_x
    LDA POOL_XLO,X : STA zp_i_x0 : LDA POOL_XHI,X : STA zp_i_x1
    LDA POOL_TL,X : STA zp_i_y0 : LDA POOL_TR,X : STA zp_i_y1
    STX zp_tmp3 : JSR interp_store
    LDA zp_i_res : STA zp_tmp1  ; top
    LDX zp_tmp3
    LDA POOL_BL,X : STA zp_i_y0 : LDA POOL_BR,X : STA zp_i_y1
    JSR interp_store
    LDA zp_i_res : STA zp_tmp2  ; bot
    RTS
}

; ======================================================================
; MARK_SOLID: remove [zp_ilo, zp_ihi) from spans
; ======================================================================
.span_mark_solid
{
    LDA zp_ihi : CMP zp_ilo : BEQ msd : BCC msd : JMP mss
.msd RTS
.mss
    ; Walk list.  zp_prev = offset of previous span (or $FF = head)
    LDA #$FF : STA zp_prev
    LDA zp_head : TAX : BNE msl : RTS

.msl ; X = current span
    ; Skip if xhi <= ilo
    LDA POOL_XHI,X : BEQ ms_xhi256a   ; xhi=256 > any ilo
    CMP zp_ilo : BEQ ms_skip : BCC ms_skip
    JMP ms_chk_after
.ms_xhi256a
    JMP ms_chk_after
.ms_skip
    STX zp_prev : LDA POOL_NEXT,X : TAX : BNE msl : RTS

.ms_chk_after
    ; Done if xlo >= ihi
    LDA POOL_XLO,X : CMP zp_ihi : BCC ms_overlap : RTS

.ms_overlap
    ; Check left fragment: xlo < ilo?
    LDA POOL_XLO,X : CMP zp_ilo : BCC ms_has_left : JMP ms_no_left
.ms_has_left

    ; --- Left fragment: truncate span to [xlo, ilo) ---
    ; Save original right-side data (all on stack — interp clobbers ZP temps)
    LDA POOL_XHI,X : PHA            ; save xhi_orig
    LDA POOL_TR,X : PHA             ; save tr_orig
    LDA POOL_BR,X : PHA             ; save br_orig
    ; Interpolate Y at ilo
    LDA zp_ilo : STA zp_tmp0
    JSR interp_span              ; zp_tmp1=top, zp_tmp2=bot at ilo
    ; Modify span: xhi=ilo, tr=top, br=bot
    LDX zp_tmp3                  ; restore span offset (interp_span saved it)
    LDA zp_ilo : STA POOL_XHI,X
    LDA zp_tmp1 : STA POOL_TR,X
    LDA zp_tmp2 : STA POOL_BR,X
    ; Check right fragment: xhi_orig > ihi?
    PLA : STA zp_tmp2            ; br_orig
    PLA : STA zp_tmp1            ; tr_orig
    PLA : STA zp_save0            ; xhi_orig (PLA sets Z if 0)
    BEQ ms_xhi_orig_256
    CMP zp_ihi : BCC ms_left_adv : BEQ ms_left_adv
    JMP ms_right_frag
.ms_xhi_orig_256
    LDA zp_ihi : BEQ ms_left_adv  ; ihi=256 too → no right fragment
.ms_right_frag
    ; Allocate right fragment [ihi, xhi_orig)
    STX zp_prev                  ; prev = current (left fragment)
    JSR alloc_span : BEQ ms_left_adv  ; out of spans
    ; X = new span.  Interpolate Y at ihi from ORIGINAL span line.
    ; Original line: (orig_xlo, tl) → (xhi_orig, tr_orig)
    ; orig_xlo is still in POOL_XLO of current span
    LDY zp_prev                  ; Y = original span
    LDA POOL_XLO,Y : STA zp_i_x0
    LDA zp_save0 : STA zp_i_x1  ; xhi_orig
    LDA POOL_TL,Y : STA zp_i_y0
    LDA zp_tmp1 : STA zp_i_y1    ; tr_orig
    LDA zp_ihi : STA zp_i_x
    STX zp_tmp3 : JSR interp_store
    LDX zp_tmp3 : LDA zp_i_res : STA POOL_TL,X
    ; Bot at ihi
    LDY zp_prev
    LDA POOL_BL,Y : STA zp_i_y0
    LDA zp_tmp2 : STA zp_i_y1    ; br_orig
    STX zp_tmp3 : JSR interp_store
    LDX zp_tmp3 : LDA zp_i_res : STA POOL_BL,X
    ; Fill rest of new span
    LDA zp_ihi : STA POOL_XLO,X
    LDA zp_save0 : STA POOL_XHI,X
    LDA zp_tmp1 : STA POOL_TR,X
    LDA zp_tmp2 : STA POOL_BR,X
    ; Link: curr.next → new → old_next
    LDY zp_prev
    LDA POOL_NEXT,Y : STA POOL_NEXT,X
    TXA : STA POOL_NEXT,Y
    ; Advance past new span
    LDA POOL_NEXT,X : TAX : BEQ ms_rts_340 : JMP msl
.ms_rts_340 RTS

.ms_left_adv
    STX zp_prev : LDA POOL_NEXT,X : TAX : BEQ ms_rts_343 : JMP msl
.ms_rts_343 RTS

.ms_no_left
    ; No left fragment.  Right fragment: xhi > ihi?
    LDA POOL_XHI,X : BEQ ms_xhi256_r
    CMP zp_ihi : BCC ms_free : BEQ ms_free
    JMP ms_right_only
.ms_xhi256_r
    LDA zp_ihi : BEQ ms_free
.ms_right_only
    ; Modify to [ihi, xhi)
    LDA zp_ihi : STA zp_tmp0
    JSR interp_span
    LDX zp_tmp3
    LDA zp_ihi : STA POOL_XLO,X
    LDA zp_tmp1 : STA POOL_TL,X
    LDA zp_tmp2 : STA POOL_BL,X
    STX zp_prev : LDA POOL_NEXT,X : TAX : BEQ ms_rts_360 : JMP msl
.ms_rts_360 RTS

.ms_free
    ; Entirely within [ilo, ihi): unlink and free
    LDA POOL_NEXT,X : STA zp_tmp0  ; save next
    JSR free_span
    ; Unlink
    LDA zp_prev : CMP #$FF : BNE ms_unlink_span
    LDA zp_tmp0 : STA zp_head : JMP ms_free_next
.ms_unlink_span
    LDY zp_prev : LDA zp_tmp0 : STA POOL_NEXT,Y
.ms_free_next
    LDA zp_tmp0 : TAX : BEQ ms_rts_372 : JMP msl
.ms_rts_372 RTS
}

; ======================================================================
; HAS_GAP
; ======================================================================
.span_has_gap
{
    LDX zp_head : BEQ hgn
.hgl LDA POOL_XLO,X : CMP zp_ihi : BCS hgn
    LDA POOL_XHI,X : BEQ hgx : CMP zp_ilo : BCC hgk : BEQ hgk
    JMP hgc
.hgx ; xhi=256: overlaps
.hgc ; Check aperture: max(tl,tr) < min(bl,br)?
    LDA POOL_TL,X : CMP POOL_TR,X : BCS hg1 : LDA POOL_TR,X
.hg1 STA zp_tmp0
    LDA POOL_BL,X : CMP POOL_BR,X : BCC hg2 : LDA POOL_BR,X
.hg2 CMP zp_tmp0 : BCC hgk : BEQ hgk
    LDA #1 : RTS
.hgk LDA POOL_NEXT,X : TAX : BNE hgl
.hgn LDA #0 : RTS
}

; ======================================================================
; IS_FULL
; ======================================================================
.span_is_full
    LDA zp_head : BNE snf : LDA #1 : RTS
.snf LDA #0 : RTS

; ======================================================================
; SPAN_READ: dump spans to (zp_buf)
; ======================================================================
.span_read
{
    LDY #1 : LDA #0 : STA zp_tmp0
    LDX zp_head : BEQ srd
.srl INC zp_tmp0
    LDA POOL_XLO,X : STA (zp_buf),Y : INY
    LDA POOL_XHI,X : STA (zp_buf),Y : INY
    LDA POOL_TL,X  : STA (zp_buf),Y : INY
    LDA POOL_BL,X  : STA (zp_buf),Y : INY
    LDA POOL_TR,X  : STA (zp_buf),Y : INY
    LDA POOL_BR,X  : STA (zp_buf),Y : INY
    LDA POOL_NEXT,X : TAX : BNE srl
.srd LDA zp_tmp0 : LDY #0 : STA (zp_buf),Y : RTS
}

; ======================================================================
; TIGHTEN: narrow top/bot boundaries over [zp_ilo, zp_ihi)
; Inputs: zp_ilo, zp_ihi, zp_sx1, zp_sx2, zp_yt1, zp_yt2, zp_yb1, zp_yb2
; Walks old list, builds new list.
; ======================================================================
; Extra ZP for tighten
zp_new_tail = $E0     ; offset of last span in new list (or $FF for head)
zp_old_cur  = $E1     ; current span in old list walk
zp_ox0      = $E2     ; overlap X range
zp_ox1      = $E3
zp_ot_l     = $E4     ; old boundary at overlap endpoints
zp_ot_r     = $E5
zp_ob_l     = $E6
zp_ob_r     = $E7
zp_nt_l     = $E8     ; new boundary at overlap endpoints
zp_nt_r     = $E9
zp_nb_l     = $EA
zp_nb_r     = $EB

.span_tighten
    LDA zp_ihi : CMP zp_ilo : BEQ tg_rts : BCC tg_rts : JMP tg_start
.tg_rts RTS
.tg_start
    ; Save old head, then start building new list
    LDA zp_head : STA zp_old_cur
    LDA #$FF : STA zp_new_tail
    LDA #0 : STA zp_head

.tg_walk
    LDX zp_old_cur
    BNE tg_process
    RTS                            ; done walking
.tg_process
    ; Save next before we potentially free this span
    LDA POOL_NEXT,X : STA zp_save0  ; next in old list

    ; Check overlap
    LDA POOL_XHI,X : BEQ tg_xhi256a
    CMP zp_ilo : BEQ tg_no_overlap : BCC tg_no_overlap
    JMP tg_chk2
.tg_xhi256a
    JMP tg_chk2
.tg_no_overlap
    ; Before [ilo,ihi): move to new list
    JSR tg_append_x
    LDA zp_save0 : STA zp_old_cur
    JMP tg_walk

.tg_chk2
    LDA POOL_XLO,X : CMP zp_ihi : BCC tg_overlaps
    ; After [ilo,ihi): move to new list (and all remaining too)
    JSR tg_append_x
    LDA zp_save0 : STA zp_old_cur
    JMP tg_walk

.tg_overlaps
    ; Compute overlap range
    LDA POOL_XLO,X : CMP zp_ilo : BCS tg_ox0_xlo
    LDA zp_ilo : JMP tg_ox0_set
.tg_ox0_xlo LDA POOL_XLO,X
.tg_ox0_set STA zp_ox0

    LDA POOL_XHI,X : BEQ tg_ox1_256
    CMP zp_ihi : BCC tg_ox1_xhi : BEQ tg_ox1_xhi
    LDA zp_ihi : JMP tg_ox1_set
.tg_ox1_xhi LDA POOL_XHI,X : JMP tg_ox1_set
.tg_ox1_256 LDA zp_ihi
.tg_ox1_set STA zp_ox1

    ; --- Dominance check: is new boundary <= old at both overlap endpoints? ---
    ; (old dominates = new is less restrictive → keep span unchanged)
    ; Evaluate old and new at ox0 and ox1 using interp (floor for comparison)
    ; Old top at ox0
    LDA zp_ox0 : STA zp_i_x
    LDA POOL_XLO,X : STA zp_i_x0 : LDA POOL_XHI,X : STA zp_i_x1
    LDA POOL_TL,X : STA zp_i_y0 : LDA POOL_TR,X : STA zp_i_y1
    STX zp_save1           ; save span offset (we'll clobber X)
    JSR interp_floor : LDA zp_i_res : STA zp_ot_l
    ; Old top at ox1
    LDA zp_ox1 : STA zp_i_x
    JSR interp_floor : LDA zp_i_res : STA zp_ot_r
    ; Old bot at ox0
    LDX zp_save1
    LDA POOL_BL,X : STA zp_i_y0 : LDA POOL_BR,X : STA zp_i_y1
    LDA zp_ox0 : STA zp_i_x
    JSR interp_floor : LDA zp_i_res : STA zp_ob_l
    LDA zp_ox1 : STA zp_i_x
    JSR interp_floor : LDA zp_i_res : STA zp_ob_r
    ; New top at ox0, ox1
    LDA zp_sx1 : STA zp_i_x0 : LDA zp_sx2 : STA zp_i_x1
    LDA zp_yt1 : STA zp_i_y0 : LDA zp_yt2 : STA zp_i_y1
    LDA zp_ox0 : STA zp_i_x
    JSR interp_floor : LDA zp_i_res : STA zp_nt_l
    LDA zp_ox1 : STA zp_i_x
    JSR interp_floor : LDA zp_i_res : STA zp_nt_r
    ; New bot at ox0, ox1
    LDA zp_yb1 : STA zp_i_y0 : LDA zp_yb2 : STA zp_i_y1
    LDA zp_ox0 : STA zp_i_x
    JSR interp_floor : LDA zp_i_res : STA zp_nb_l
    LDA zp_ox1 : STA zp_i_x
    JSR interp_floor : LDA zp_i_res : STA zp_nb_r

    ; Check: new_tl <= old_tl AND new_tr <= old_tr AND new_bl >= old_bl AND new_br >= old_br?
    ; Clamp new values to [0,159] first so unsigned CMP works.
    ; (new top < 0 → clamp to 0 = most generous ceiling)
    ; (new bot > 159 → clamp to 159 = most generous floor)
    LDA zp_nt_l : BPL tg_cn1 : LDA #0 : STA zp_nt_l
.tg_cn1 LDA zp_nt_r : BPL tg_cn2 : LDA #0 : STA zp_nt_r
.tg_cn2 LDA zp_nb_l : CMP #160 : BCC tg_cn3 : LDA #159 : STA zp_nb_l
.tg_cn3 LDA zp_nb_r : CMP #160 : BCC tg_cn4 : LDA #159 : STA zp_nb_r
.tg_cn4
    ; Now unsigned comparison is safe (all values in [0,159])
    LDA zp_nt_l : CMP zp_ot_l : BEQ tg_d1 : BCS tg_not_old_dom
.tg_d1 LDA zp_nt_r : CMP zp_ot_r : BEQ tg_d2 : BCS tg_not_old_dom
.tg_d2 LDA zp_ob_l : CMP zp_nb_l : BEQ tg_d3 : BCS tg_not_old_dom
.tg_d3 LDA zp_ob_r : CMP zp_nb_r : BEQ tg_d4 : BCS tg_not_old_dom
.tg_d4 ; Old dominates: keep span unchanged
    LDX zp_save1
    JSR tg_append_x
    LDA zp_save0 : STA zp_old_cur
    JMP tg_walk

.tg_not_old_dom
    ; --- General path: DON'T modify original span. Alloc new spans for ---
    ; --- left/right fragments and tightened overlap. Free original last. ---
    LDX zp_save1    ; X = original span offset (preserved throughout)

    ; --- Left fragment: if xlo < ilo ---
    LDA POOL_XLO,X : CMP zp_ilo : BCS tg_no_left
    ; Alloc new span for [xlo, ilo)
    STX zp_save1 : JSR alloc_span : BEQ tg_no_left_alloc
    ; Copy original span, then modify endpoints
    LDY zp_save1                 ; Y = original
    LDA POOL_XLO,Y : STA POOL_XLO,X
    LDA POOL_TL,Y  : STA POOL_TL,X
    LDA POOL_BL,Y  : STA POOL_BL,X
    LDA zp_ilo : STA POOL_XHI,X ; xhi = ilo
    ; Interp Y at ilo from ORIGINAL span (Y still = original offset)
    LDA zp_ilo : STA zp_i_x
    LDA POOL_XLO,Y : STA zp_i_x0 : LDA POOL_XHI,Y : STA zp_i_x1
    LDA POOL_TL,Y : STA zp_i_y0 : LDA POOL_TR,Y : STA zp_i_y1
    STX zp_tmp3 : JSR interp_store
    LDX zp_tmp3 : LDA zp_i_res : STA POOL_TR,X  ; tr at ilo
    LDY zp_save1
    LDA POOL_BL,Y : STA zp_i_y0 : LDA POOL_BR,Y : STA zp_i_y1
    STX zp_tmp3 : JSR interp_store
    LDX zp_tmp3 : LDA zp_i_res : STA POOL_BR,X  ; br at ilo
    JSR tg_append_x
.tg_no_left_alloc
.tg_no_left

    ; --- Tighten the overlap [ox0, ox1) from ORIGINAL span (unmodified) ---
    LDX zp_save1
    LDA POOL_XLO,X : STA zp_i_x0 : LDA POOL_XHI,X : STA zp_i_x1
    ; Old top at ox0, ox1
    LDA POOL_TL,X : STA zp_i_y0 : LDA POOL_TR,X : STA zp_i_y1
    LDA zp_ox0 : STA zp_i_x
    JSR interp_store : LDA zp_i_res : STA zp_ot_l
    LDA zp_ox1 : STA zp_i_x
    JSR interp_store : LDA zp_i_res : STA zp_ot_r
    ; Old bot at ox0, ox1
    LDX zp_save1
    LDA POOL_BL,X : STA zp_i_y0 : LDA POOL_BR,X : STA zp_i_y1
    LDA zp_ox0 : STA zp_i_x
    JSR interp_store : LDA zp_i_res : STA zp_ob_l
    LDA zp_ox1 : STA zp_i_x
    JSR interp_store : LDA zp_i_res : STA zp_ob_r
    ; New top/bot at ox0, ox1
    LDA zp_sx1 : STA zp_i_x0 : LDA zp_sx2 : STA zp_i_x1
    LDA zp_yt1 : STA zp_i_y0 : LDA zp_yt2 : STA zp_i_y1
    LDA zp_ox0 : STA zp_i_x
    JSR interp_store : LDA zp_i_res : STA zp_nt_l
    LDA zp_ox1 : STA zp_i_x
    JSR interp_store : LDA zp_i_res : STA zp_nt_r
    LDA zp_yb1 : STA zp_i_y0 : LDA zp_yb2 : STA zp_i_y1
    LDA zp_ox0 : STA zp_i_x
    JSR interp_store : LDA zp_i_res : STA zp_nb_l
    LDA zp_ox1 : STA zp_i_x
    JSR interp_store : LDA zp_i_res : STA zp_nb_r

    ; max top, min bot
    LDA zp_ot_l : CMP zp_nt_l : BCS tg_tl_ok : LDA zp_nt_l
.tg_tl_ok STA zp_ot_l
    LDA zp_ot_r : CMP zp_nt_r : BCS tg_tr_ok : LDA zp_nt_r
.tg_tr_ok STA zp_ot_r
    LDA zp_ob_l : CMP zp_nb_l : BCC tg_bl_ok : LDA zp_nb_l
.tg_bl_ok STA zp_ob_l
    LDA zp_ob_r : CMP zp_nb_r : BCC tg_br_ok : LDA zp_nb_r
.tg_br_ok STA zp_ob_r

    ; Check aperture: tl < bl OR tr < br
    LDA zp_ot_l : CMP zp_ob_l : BCC tg_has_ap
    LDA zp_ot_r : CMP zp_ob_r : BCS tg_no_ap
.tg_has_ap
    JSR alloc_span : BEQ tg_no_ap
    LDA zp_ox0 : STA POOL_XLO,X : LDA zp_ox1 : STA POOL_XHI,X
    LDA zp_ot_l : STA POOL_TL,X : LDA zp_ob_l : STA POOL_BL,X
    LDA zp_ot_r : STA POOL_TR,X : LDA zp_ob_r : STA POOL_BR,X
    JSR tg_append_x
.tg_no_ap

    ; --- Right fragment: if original xhi > ihi ---
    LDX zp_save1                 ; original span (still unmodified!)
    LDA POOL_XHI,X : BEQ tg_rhi256
    CMP zp_ihi : BCC tg_no_right : BEQ tg_no_right
    JMP tg_make_right
.tg_rhi256
    LDA zp_ihi : BEQ tg_no_right
.tg_make_right
    ; Alloc right fragment [ihi, original_xhi)
    STX zp_save1 : JSR alloc_span : BEQ tg_no_right
    LDY zp_save1                 ; Y = original
    ; Copy right-side data from original
    LDA POOL_XHI,Y : STA POOL_XHI,X
    LDA POOL_TR,Y  : STA POOL_TR,X
    LDA POOL_BR,Y  : STA POOL_BR,X
    LDA zp_ihi : STA POOL_XLO,X ; xlo = ihi
    ; Interp Y at ihi from ORIGINAL span
    LDA zp_ihi : STA zp_i_x
    LDA POOL_XLO,Y : STA zp_i_x0 : LDA POOL_XHI,Y : STA zp_i_x1
    LDA POOL_TL,Y : STA zp_i_y0 : LDA POOL_TR,Y : STA zp_i_y1
    STX zp_tmp3 : JSR interp_store
    LDX zp_tmp3 : LDA zp_i_res : STA POOL_TL,X
    LDY zp_save1
    LDA POOL_BL,Y : STA zp_i_y0 : LDA POOL_BR,Y : STA zp_i_y1
    STX zp_tmp3 : JSR interp_store
    LDX zp_tmp3 : LDA zp_i_res : STA POOL_BL,X
    JSR tg_append_x
.tg_no_right

    ; Free the original span (never reused — we always alloc new)
    LDX zp_save1 : JSR free_span

    LDA zp_save0 : STA zp_old_cur
    JMP tg_walk

; --- Helper: append span X to new list ---
.tg_append_x
{
    LDA #0 : STA POOL_NEXT,X   ; new span is at end
    LDA zp_new_tail : CMP #$FF : BNE ta_link
    ; First span: set head
    STX zp_head : STX zp_new_tail : RTS
.ta_link
    LDY zp_new_tail
    TXA : STA POOL_NEXT,Y
    STX zp_new_tail : RTS
}

.end_code
SAVE "span_clip.bin", $2000, end_code, $2000
