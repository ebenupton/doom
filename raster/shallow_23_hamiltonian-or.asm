; =====================================================================
; 2-3 band Hamiltonian rasteriser (2dy < dx <= 3dy), right + left.
; Requires HAMILTONIAN_12 module (shares delta1/delta2/remaining ZP
; equates and row_handler). Generated from the oracle-proven protocol:
;   e = (dx>>1) - 2dy (mod 256), first run always 2 (entered C=0),
;   2px: ADC delta1 (dx-2dy);  3px: SBC delta2 (3dy-dx = dy-delta1);
;   carry-out 1 -> next run 3, 0 -> next run 2.
; The final run is always exactly 2 (NJ e-phase, oracle-verified) and
; is drawn up-front by the entry prologue at the far endpoint, so the
; state machine runs exactly dy rows (first + dy-1 interior) and
; terminates on row count via row_handler, no per-row end test.
; Physical order follows the alternating Hamiltonian cycle so the
; switch-length edge is the fall-through and the stay-length edge is a
; short branch (+4 blocks for stay-2, -2 blocks for stay-3); only the
; two stay-2 cycle wraps need JMP trampolines.
; =====================================================================

.r23_tr_5_3
    JMP r23_5_3

.r23_0_2
    DEY
    BPL r23_0_2_s
    JSR row_handler
.r23_0_2_s
    LDA #&C0:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC r23_2_2

.r23_2_3
    DEY
    BPL r23_2_3_s
    JSR row_handler
.r23_2_3_s
    LDA #&38:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS r23_tr_5_3

.r23_5_2
    DEY
    BPL r23_5_2_s
    JSR row_handler
.r23_5_2_s
    LDA #&06:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC r23_7_2

.r23_7_3
    DEY
    BPL r23_7_3_s
    JSR row_handler
.r23_7_3_s
    LDA #&01:ORA (scr),Y:STA (scr),Y
    LDA scr:ADC #7:STA scr
    LDA #&C0:ORA (scr),Y:STA (scr),Y
    SEC
    TXA:SBC delta2:TAX
    BCS r23_2_3

.r23_2_2
    DEY
    BPL r23_2_2_s
    JSR row_handler
.r23_2_2_s
    LDA #&30:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC r23_4_2

.r23_4_3
    DEY
    BPL r23_4_3_s
    JSR row_handler
.r23_4_3_s
    LDA #&0E:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS r23_7_3

.r23_7_2
    DEY
    BPL r23_7_2_s
    JSR row_handler
.r23_7_2_s
    LDA #&01:ORA (scr),Y:STA (scr),Y
    LDA scr:ADC #8:STA scr
    LDA #&80:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC r23_1_2

.r23_1_3
    DEY
    BPL r23_1_3_s
    JSR row_handler
.r23_1_3_s
    LDA #&70:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS r23_4_3

.r23_4_2
    DEY
    BPL r23_4_2_s
    JSR row_handler
.r23_4_2_s
    LDA #&0C:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC r23_6_2

.r23_6_3
    DEY
    BPL r23_6_3_s
    JSR row_handler
.r23_6_3_s
    LDA #&03:ORA (scr),Y:STA (scr),Y
    LDA scr:ADC #7:STA scr
    LDA #&80:ORA (scr),Y:STA (scr),Y
    SEC
    TXA:SBC delta2:TAX
    BCS r23_1_3

.r23_1_2
    DEY
    BPL r23_1_2_s
    JSR row_handler
.r23_1_2_s
    LDA #&60:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC r23_3_2

.r23_3_3
    DEY
    BPL r23_3_3_s
    JSR row_handler
.r23_3_3_s
    LDA #&1C:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS r23_6_3

.r23_6_2
    DEY
    BPL r23_6_2_s
    JSR row_handler
.r23_6_2_s
    LDA #&03:ORA (scr),Y:STA (scr),Y
    LDA scr:ADC #8:STA scr
    TXA:ADC delta1:TAX
    BCC r23_tr_0_2

.r23_0_3
    DEY
    BPL r23_0_3_s
    JSR row_handler
.r23_0_3_s
    LDA #&E0:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS r23_3_3

.r23_3_2
    DEY
    BPL r23_3_2_s
    JSR row_handler
.r23_3_2_s
    LDA #&18:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC r23_tr_5_2

.r23_5_3
    DEY
    BPL r23_5_3_s
    JSR row_handler
.r23_5_3_s
    LDA #&07:ORA (scr),Y:STA (scr),Y
    LDA scr:ADC #7:STA scr
    SEC
    TXA:SBC delta2:TAX
    BCS r23_0_3
    JMP r23_0_2

.r23_tr_0_2
    JMP r23_0_2
.r23_tr_5_2
    JMP r23_5_2

.l23_tr_3_3
    JMP l23_3_3

.l23_0_2
    DEY
    BPL l23_0_2_s
    JSR row_handler
.l23_0_2_s
    LDA #&80:ORA (scr),Y:STA (scr),Y
    LDA scr:SBC #7:STA scr
    LDA #&01:ORA (scr),Y:STA (scr),Y
    CLC
    TXA:ADC delta1:TAX
    BCC l23_6_2

.l23_6_3
    DEY
    BPL l23_6_3_s
    JSR row_handler
.l23_6_3_s
    LDA #&0E:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS l23_tr_3_3

.l23_3_2
    DEY
    BPL l23_3_2_s
    JSR row_handler
.l23_3_2_s
    LDA #&30:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC l23_1_2

.l23_1_3
    DEY
    BPL l23_1_3_s
    JSR row_handler
.l23_1_3_s
    LDA #&C0:ORA (scr),Y:STA (scr),Y
    LDA scr:SBC #8:STA scr
    LDA #&01:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS l23_6_3

.l23_6_2
    DEY
    BPL l23_6_2_s
    JSR row_handler
.l23_6_2_s
    LDA #&06:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC l23_4_2

.l23_4_3
    DEY
    BPL l23_4_3_s
    JSR row_handler
.l23_4_3_s
    LDA #&38:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS l23_1_3

.l23_1_2
    DEY
    BPL l23_1_2_s
    JSR row_handler
.l23_1_2_s
    LDA #&C0:ORA (scr),Y:STA (scr),Y
    LDA scr:SBC #7:STA scr
    CLC
    TXA:ADC delta1:TAX
    BCC l23_7_2

.l23_7_3
    DEY
    BPL l23_7_3_s
    JSR row_handler
.l23_7_3_s
    LDA #&07:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS l23_4_3

.l23_4_2
    DEY
    BPL l23_4_2_s
    JSR row_handler
.l23_4_2_s
    LDA #&18:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC l23_2_2

.l23_2_3
    DEY
    BPL l23_2_3_s
    JSR row_handler
.l23_2_3_s
    LDA #&E0:ORA (scr),Y:STA (scr),Y
    LDA scr:SBC #8:STA scr
    TXA:SBC delta2:TAX
    BCS l23_7_3

.l23_7_2
    DEY
    BPL l23_7_2_s
    JSR row_handler
.l23_7_2_s
    LDA #&03:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC l23_5_2

.l23_5_3
    DEY
    BPL l23_5_3_s
    JSR row_handler
.l23_5_3_s
    LDA #&1C:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS l23_2_3

.l23_2_2
    DEY
    BPL l23_2_2_s
    JSR row_handler
.l23_2_2_s
    LDA #&60:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC l23_tr_0_2

.l23_0_3
    DEY
    BPL l23_0_3_s
    JSR row_handler
.l23_0_3_s
    LDA #&80:ORA (scr),Y:STA (scr),Y
    LDA scr:SBC #8:STA scr
    LDA #&03:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS l23_5_3

.l23_5_2
    DEY
    BPL l23_5_2_s
    JSR row_handler
.l23_5_2_s
    LDA #&0C:ORA (scr),Y:STA (scr),Y
    TXA:ADC delta1:TAX
    BCC l23_tr_3_2

.l23_3_3
    DEY
    BPL l23_3_3_s
    JSR row_handler
.l23_3_3_s
    LDA #&70:ORA (scr),Y:STA (scr),Y
    TXA:SBC delta2:TAX
    BCS l23_0_3
    JMP l23_0_2

.l23_tr_0_2
    JMP l23_0_2
.l23_tr_3_2
    JMP l23_3_2

; =====================================================================
; DISPATCH TABLES - entry (skip) labels - 1, indexed by x0&7
; =====================================================================

.r23_lo
    EQUB LO(r23_0_2_s-1):EQUB LO(r23_1_2_s-1)
    EQUB LO(r23_2_2_s-1):EQUB LO(r23_3_2_s-1)
    EQUB LO(r23_4_2_s-1):EQUB LO(r23_5_2_s-1)
    EQUB LO(r23_6_2_s-1):EQUB LO(r23_7_2_s-1)
.r23_hi
    EQUB HI(r23_0_2_s-1):EQUB HI(r23_1_2_s-1)
    EQUB HI(r23_2_2_s-1):EQUB HI(r23_3_2_s-1)
    EQUB HI(r23_4_2_s-1):EQUB HI(r23_5_2_s-1)
    EQUB HI(r23_6_2_s-1):EQUB HI(r23_7_2_s-1)
.l23_lo
    EQUB LO(l23_0_2_s-1):EQUB LO(l23_1_2_s-1)
    EQUB LO(l23_2_2_s-1):EQUB LO(l23_3_2_s-1)
    EQUB LO(l23_4_2_s-1):EQUB LO(l23_5_2_s-1)
    EQUB LO(l23_6_2_s-1):EQUB LO(l23_7_2_s-1)
.l23_hi
    EQUB HI(l23_0_2_s-1):EQUB HI(l23_1_2_s-1)
    EQUB HI(l23_2_2_s-1):EQUB HI(l23_3_2_s-1)
    EQUB HI(l23_4_2_s-1):EQUB HI(l23_5_2_s-1)
    EQUB HI(l23_6_2_s-1):EQUB HI(l23_7_2_s-1)

; adjacent-pair masks: pixels k, k+1 in one byte (k = 0..6)
.p23_pairmask
    EQUB &C0,&60,&30,&18,&0C,&06,&03

; =====================================================================
; ENTRY - JMPed from the .notsteep dispatcher with:
;   A = delta1 (dx-2dy), X = dx, Y = x0&7, direction flags still pushed,
;   scr = anchored to x0 byte / y0 char row (lo = x0 AND F8).
; Uses x1/y1 as a screen pointer for the far-end prologue, ls/b as
; scratch. Draws the final 2px run at the far end, then anchors Y/
; remaining for dy rows and RTS-dispatches into the first 2px block.
; =====================================================================

.entry_23_nj
    STA delta1
    LDA dy:SEC:SBC delta1:STA delta2
    PLP:BCC e23_right
    JMP e23_left
.e23_right

    \ ---- right-going ----
    LDA x0:CLC:ADC dx:STA ls          \ x_end
    LDA y0:SEC:SBC dy:STA b           \ y_top
    LSR A:LSR A:LSR A
    CLC:ADC scrstrt:STA y1            \ far ptr hi
    LDA ls:AND #&F8:STA x1            \ far ptr lo (x_end byte)
    LDA b:AND #7:TAY
    LDA ls:AND #7:TAX
    BEQ e23r_split
    LDA p23_pairmask-1,X              \ pair at bits X-1, X
    ORA (x1),Y:STA (x1),Y
    JMP e23r_go
.e23r_split                           \ x_end at bit 0: pair splits bytes
    LDA #&80:ORA (x1),Y:STA (x1),Y
    LDA x1:SEC:SBC #8:STA x1
    LDA #&01:ORA (x1),Y:STA (x1),Y
.e23r_go
    LDA y0:AND #7:TAY
    CLC:ADC #1
    SEC:SBC dy                        \ (y0&7)+1-dy = (y0&7)-(dy-1); C=1 iff >= 0
    BCC e23r_multi
    CLC:ADC scr:STA scr
    LDY dy:DEY
    LDA #0:STA remaining
    BEQ e23r_disp
.e23r_multi
    EOR #&FF:ADC #1                   \ negate: (dy-1) - (y0&7)
    STA remaining
.e23r_disp
    LDA x0:AND #7:TAX
    LDA r23_hi,X:PHA
    LDA r23_lo,X:PHA
    LDA dy:ASL A:STA b                \ 2dy
    LDA dx:LSR A:SEC:SBC b:TAX        \ X0 = (dx>>1) - 2dy, C=0 always
    RTS                               \ -> first 2px block (skip label)

.e23_left
    LDA x0:SEC:SBC dx:STA ls          \ x_end
    LDA y0:SEC:SBC dy:STA b           \ y_top
    LSR A:LSR A:LSR A
    CLC:ADC scrstrt:STA y1
    LDA ls:AND #&F8:STA x1
    LDA b:AND #7:TAY
    LDA ls:AND #7:CMP #7:BEQ e23l_split
    TAX
    LDA p23_pairmask,X                \ pair at bits k, k+1
    ORA (x1),Y:STA (x1),Y
    JMP e23l_go
.e23l_split                           \ x_end at bit 7: pair splits bytes
    LDA #&01:ORA (x1),Y:STA (x1),Y
    LDA x1:CLC:ADC #8:STA x1
    LDA #&80:ORA (x1),Y:STA (x1),Y
.e23l_go
    LDA y0:AND #7:TAY
    CLC:ADC #1
    SEC:SBC dy                        \ (y0&7)+1-dy = (y0&7)-(dy-1); C=1 iff >= 0
    BCC e23l_multi
    CLC:ADC scr:STA scr
    LDY dy:DEY
    LDA #0:STA remaining
    BEQ e23l_disp
.e23l_multi
    EOR #&FF:ADC #1
    STA remaining
.e23l_disp
    LDA x0:AND #7:TAX
    LDA l23_hi,X:PHA
    LDA l23_lo,X:PHA
    LDA dy:ASL A:STA b
    LDA dx:LSR A:SEC:SBC b:TAX
    RTS
