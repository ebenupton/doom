; =====================================================================
; 1-2 Hamiltonian rasteriser — right + left, shared entry
; 789 bytes. Pixel-identical to nj-linedraw4.
;
; Error protocol (both directions):
;   e = (dx >> 1) - dy                biased error (unsigned byte)
;   delta1 = dx - dy                  1px step delta
;   delta2 = 2*dy - dx                2px step delta
;   1px entered C=0: ADC delta1. C=1 → 2px next. C=0 → 1px next.
;   2px entered C=1: SBC delta2. C=1 → 2px next. C=0 → 1px next.
;
; Caller does PHP with C=0 (right) or C=1 (left) before JSR/JMP.
; Entry does PLP, then ROL A to fold direction into the table index:
;   X = (x0 & 7) * 2 + direction
; Interleaved dispatch table: [r0, l0, r1, l1, ... r7, l7].
;
; ZP (aligned with nj-linedraw4):
;   scr       = &74  (2 bytes, shared)
;   delta1    = &76  (nj's cnt)
;   delta2    = &77  (nj's err)
;   remaining = &78  (nj's errs)
;   dx        = &80  (shared)
;   dy        = &81  (shared)
;   x0        = &82  (shared)
;   y0        = &83  (shared)
;
; Integration: in nj's .notsteep, after STX dx:
;   TXA:LSR A:CMP dy:BCS not_12
;   PLP                        \ carry already set by nj for direction
;   PHP                        \ re-push with C=direction
;   JMP entry_12_nj
;   .not_12
; =====================================================================

delta1    = cnt      ; &79 - dx-dy (reuses NJ's cnt)
delta2    = err      ; &76 - 2*dy-dx (reuses NJ's err)
remaining = errs     ; &7A - spans remaining (reuses NJ's errs)
; scr, dx, dy, x0, y0 already defined by line-test.asm

; =====================================================================
; RIGHT-GOING INNER LOOP — 326 bytes
; =====================================================================

.r_ftramp_3
    JMP r_bit7_p1

; [ 1] bit1_plot2
;      fall=SAME→b3p2  Bxx→b3p1
.r_bit1_p2
    DEY
    BPL r_skip_1
    JSR row_handler
.r_skip_1
    LDA #&60
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC r_bit3_p1

; [ 2] bit3_plot2
;      fall=SAME→b5p2  Bxx→b5p1
.r_bit3_p2
    DEY
    BPL r_skip_2
    JSR row_handler
.r_skip_2
    LDA #&18
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC r_bit5_p1

; [ 3] bit5_plot2
;      fall=SAME→b7p2  Bxx→b7p1
.r_bit5_p2
    DEY
    BPL r_skip_3
    JSR row_handler
.r_skip_3
    LDA #&06
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC r_ftramp_3

; [ 4] bit7_plot2 — cross
;      fall=ALT→b1p1  Bxx→b1p2
.r_bit7_p2
    DEY
    BPL r_skip_4
    JSR row_handler
.r_skip_4
    LDA #&01
    ORA (scr),Y
    STA (scr),Y
    LDA scr:ADC #7:STA scr
    LDA #&80:ORA (scr),Y:STA (scr),Y
    SEC
    TXA
    SBC delta2
    TAX
    BCS r_bit1_p2

; [ 5] bit1_plot1
;      fall=SAME→b2p1  Bxx→b2p2
.r_bit1_p1
    DEY
    BPL r_skip_5
    JSR row_handler
.r_skip_5
    LDA #&40
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS r_bit2_p2

; [ 6] bit2_plot1
;      fall=SAME→b3p1  Bxx→b3p2
.r_bit2_p1
    DEY
    BPL r_skip_6
    JSR row_handler
.r_skip_6
    LDA #&20
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS r_bit3_p2

; [ 7] bit3_plot1
;      fall=SAME→b4p1  Bxx→b4p2
.r_bit3_p1
    DEY
    BPL r_skip_7
    JSR row_handler
.r_skip_7
    LDA #&10
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS r_bit4_p2

; [ 8] bit4_plot1
;      fall=SAME→b5p1  Bxx→b5p2
.r_bit4_p1
    DEY
    BPL r_skip_8
    JSR row_handler
.r_skip_8
    LDA #&08
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS r_bit5_p2

; [ 9] bit5_plot1
;      fall=ALT→b6p2  Bxx→b6p1
.r_bit5_p1
    DEY
    BPL r_skip_9
    JSR row_handler
.r_skip_9
    LDA #&04
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCC r_bit6_p1

; [10] bit6_plot2 — col (2px)
;      fall=SAME→b0p2  Bxx→b0p1
.r_bit6_p2
    DEY
    BPL r_skip_10
    JSR row_handler
.r_skip_10
    LDA #&03
    ORA (scr),Y
    STA (scr),Y
    LDA scr:ADC #7:STA scr
    SEC
    TXA
    SBC delta2
    TAX
    BCC r_bit0_p1

; [11] bit0_plot2
;      fall=SAME→b2p2  Bxx→b2p1
.r_bit0_p2
    DEY
    BPL r_skip_11
    JSR row_handler
.r_skip_11
    LDA #&C0
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC r_bit2_p1

; [12] bit2_plot2
;      fall=SAME→b4p2  Bxx→b4p1
.r_bit2_p2
    DEY
    BPL r_skip_12
    JSR row_handler
.r_skip_12
    LDA #&30
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC r_bit4_p1

; [13] bit4_plot2
;      fall=ALT→b6p1  Bxx→b6p2
.r_bit4_p2
    DEY
    BPL r_skip_13
    JSR row_handler
.r_skip_13
    LDA #&0C
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCS r_bit6_p2

; [14] bit6_plot1
;      fall=SAME→b7p1  Bxx→b7p2
.r_bit6_p1
    DEY
    BPL r_skip_14
    JSR row_handler
.r_skip_14
    LDA #&02
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS r_btramp_14

; [15] bit7_plot1 — col (1px)
;      fall=SAME→b0p1  Bxx→b0p2
.r_bit7_p1
    DEY
    BPL r_skip_15
    JSR row_handler
.r_skip_15
    LDA #&01
    ORA (scr),Y
    STA (scr),Y
    LDA scr:ADC #8:STA scr
    TXA
    ADC delta1
    TAX
    BCS r_bit0_p2

; [ 0] bit0_plot1 (block 15 falls through)
;      fall=ALT→b1p2  Bxx→b1p1
.r_bit0_p1
    DEY
    BPL r_skip_0
    JSR row_handler
.r_skip_0
    LDA #&80
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCC r_btramp_0
    JMP r_bit1_p2

.r_btramp_0
    JMP r_bit1_p1

.r_btramp_14
    JMP r_bit7_p2

; =====================================================================
; LEFT-GOING INNER LOOP — 325 bytes
; =====================================================================

.l_ftramp_3
    JMP l_bit0_p1

; [ 1] bit6_plot2
;      fall=SAME→b4p2  Bxx→b4p1
.l_bit6_p2
    DEY
    BPL l_skip_1
    JSR row_handler
.l_skip_1
    LDA #&06
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC l_bit4_p1

; [ 2] bit4_plot2
;      fall=SAME→b2p2  Bxx→b2p1
.l_bit4_p2
    DEY
    BPL l_skip_2
    JSR row_handler
.l_skip_2
    LDA #&18
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC l_bit2_p1

; [ 3] bit2_plot2
;      fall=SAME→b0p2  Bxx→b0p1
.l_bit2_p2
    DEY
    BPL l_skip_3
    JSR row_handler
.l_skip_3
    LDA #&60
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC l_ftramp_3

; [ 4] bit0_plot2 — cross
;      fall=ALT→b6p1  Bxx→b6p2
.l_bit0_p2
    DEY
    BPL l_skip_4
    JSR row_handler
.l_skip_4
    LDA #&80
    ORA (scr),Y
    STA (scr),Y
    LDA scr:SBC #8:STA scr
    LDA #&01:ORA (scr),Y:STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCS l_bit6_p2

; [ 5] bit6_plot1
;      fall=SAME→b5p1  Bxx→b5p2
.l_bit6_p1
    DEY
    BPL l_skip_5
    JSR row_handler
.l_skip_5
    LDA #&02
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS l_bit5_p2

; [ 6] bit5_plot1
;      fall=SAME→b4p1  Bxx→b4p2
.l_bit5_p1
    DEY
    BPL l_skip_6
    JSR row_handler
.l_skip_6
    LDA #&04
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS l_bit4_p2

; [ 7] bit4_plot1
;      fall=SAME→b3p1  Bxx→b3p2
.l_bit4_p1
    DEY
    BPL l_skip_7
    JSR row_handler
.l_skip_7
    LDA #&08
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS l_bit3_p2

; [ 8] bit3_plot1
;      fall=SAME→b2p1  Bxx→b2p2
.l_bit3_p1
    DEY
    BPL l_skip_8
    JSR row_handler
.l_skip_8
    LDA #&10
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS l_bit2_p2

; [ 9] bit2_plot1
;      fall=ALT→b1p2  Bxx→b1p1
.l_bit2_p1
    DEY
    BPL l_skip_9
    JSR row_handler
.l_skip_9
    LDA #&20
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCC l_bit1_p1

; [10] bit1_plot2 — col (2px)
;      fall=SAME→b7p2  Bxx→b7p1
.l_bit1_p2
    DEY
    BPL l_skip_10
    JSR row_handler
.l_skip_10
    LDA #&C0
    ORA (scr),Y
    STA (scr),Y
    LDA scr:SBC #8:STA scr
    TXA
    SBC delta2
    TAX
    BCC l_bit7_p1

; [11] bit7_plot2
;      fall=SAME→b5p2  Bxx→b5p1
.l_bit7_p2
    DEY
    BPL l_skip_11
    JSR row_handler
.l_skip_11
    LDA #&03
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC l_bit5_p1

; [12] bit5_plot2
;      fall=SAME→b3p2  Bxx→b3p1
.l_bit5_p2
    DEY
    BPL l_skip_12
    JSR row_handler
.l_skip_12
    LDA #&0C
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCC l_bit3_p1

; [13] bit3_plot2
;      fall=ALT→b1p1  Bxx→b1p2
.l_bit3_p2
    DEY
    BPL l_skip_13
    JSR row_handler
.l_skip_13
    LDA #&30
    ORA (scr),Y
    STA (scr),Y
    TXA
    SBC delta2
    TAX
    BCS l_bit1_p2

; [14] bit1_plot1
;      fall=SAME→b0p1  Bxx→b0p2
.l_bit1_p1
    DEY
    BPL l_skip_14
    JSR row_handler
.l_skip_14
    LDA #&40
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCS l_btramp_14

; [15] bit0_plot1 — col (1px)
;      fall=SAME→b7p1  Bxx→b7p2
.l_bit0_p1
    DEY
    BPL l_skip_15
    JSR row_handler
.l_skip_15
    LDA #&80
    ORA (scr),Y
    STA (scr),Y
    LDA scr:SBC #7:STA scr
    CLC
    TXA
    ADC delta1
    TAX
    BCS l_bit7_p2

; [ 0] bit7_plot1 (block 15 falls through)
;      fall=ALT→b6p2  Bxx→b6p1
.l_bit7_p1
    DEY
    BPL l_skip_0
    JSR row_handler
.l_skip_0
    LDA #&01
    ORA (scr),Y
    STA (scr),Y
    TXA
    ADC delta1
    TAX
    BCC l_btramp_0
    JMP l_bit6_p2

.l_btramp_0
    JMP l_bit6_p1

.l_btramp_14
    JMP l_bit0_p2

; =====================================================================
; ROW HANDLER — 31 bytes (shared)
; =====================================================================

.row_handler
    PHP
    LDA remaining
    BEQ rh_done
    DEC scr+1
    CMP #8
    BCC rh_partial
    SBC #8
    STA remaining
    LDY #7
    PLP
    RTS

.rh_partial
    TAY:DEY
    EOR #&FF
    ADC #8               ; ~remaining + 8 + 0 = 7-remaining, C=1
    ADC scr              ; + scr + 1 = scr + 8-remaining
    STA scr
    LDA #0
    STA remaining
    PLP
    RTS

.rh_done
    PLP
    PLA:PLA
    RTS

; =====================================================================
; INTERLEAVED DISPATCH TABLE — 32 bytes
; [r0, l0, r1, l1, ... r7, l7]  indexed by pos*2 + direction
; =====================================================================

.draw_1px_lo
    EQUB LO(r_skip_0-1)   ; pos 0 right
    EQUB LO(l_skip_15-1)   ; pos 0 left
    EQUB LO(r_skip_5-1)   ; pos 1 right
    EQUB LO(l_skip_14-1)   ; pos 1 left
    EQUB LO(r_skip_6-1)   ; pos 2 right
    EQUB LO(l_skip_9-1)   ; pos 2 left
    EQUB LO(r_skip_7-1)   ; pos 3 right
    EQUB LO(l_skip_8-1)   ; pos 3 left
    EQUB LO(r_skip_8-1)   ; pos 4 right
    EQUB LO(l_skip_7-1)   ; pos 4 left
    EQUB LO(r_skip_9-1)   ; pos 5 right
    EQUB LO(l_skip_6-1)   ; pos 5 left
    EQUB LO(r_skip_14-1)   ; pos 6 right
    EQUB LO(l_skip_5-1)   ; pos 6 left
    EQUB LO(r_skip_15-1)   ; pos 7 right
    EQUB LO(l_skip_0-1)   ; pos 7 left
.draw_1px_hi
    EQUB HI(r_skip_0-1)
    EQUB HI(l_skip_15-1)
    EQUB HI(r_skip_5-1)
    EQUB HI(l_skip_14-1)
    EQUB HI(r_skip_6-1)
    EQUB HI(l_skip_9-1)
    EQUB HI(r_skip_7-1)
    EQUB HI(l_skip_8-1)
    EQUB HI(r_skip_8-1)
    EQUB HI(l_skip_7-1)
    EQUB HI(r_skip_9-1)
    EQUB HI(l_skip_6-1)
    EQUB HI(r_skip_14-1)
    EQUB HI(l_skip_5-1)
    EQUB HI(r_skip_15-1)
    EQUB HI(l_skip_0-1)

; =====================================================================
; SHARED ENTRY — caller pushes flags with C=0 (right) or C=1 (left)
; =====================================================================

.entry_12_nj
    LDA dy:ASL A:SEC:SBC dx:STA delta2
    SEC:LDA dx:SBC dy:STA delta1

    LDA y0:AND #7:TAY
    SEC:SBC dy
    BCC multi_row

    CLC:ADC scr:STA scr
    LDY dy
    LDA #0:STA remaining
    BEQ do_dispatch

.multi_row
    EOR #&FF:ADC #1
    STA remaining

.do_dispatch
    PLP                  ; C = direction (0=right, 1=left)
    LDA x0:AND #7
    ROL A                ; pos*2 + C = interleaved index
    TAX
    LDA draw_1px_hi,X:PHA
    LDA draw_1px_lo,X:PHA
    LDA dx:LSR A:SEC:SBC dy:TAX  ; e → X
    CLC                  ; 1px entered C=0
    RTS                  ; → chain
