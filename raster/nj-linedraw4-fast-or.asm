;--------------------------------------------------------------------
; Engine NJ rasteriser + line-test-a double-SBC shallow entries
; (commit 2aa0369, accidentally clobbered there by the later KCHACK
; commit — recovered 2026-07-05). Unconditional first SBC per shallow
; span entry: valid because the 1-2 band (dx <= 2*dy, INCLUSIVE) is
; peeled off to the hamiltonian module first, so these blocks only
; ever see runs >= 2. Mid-run byte-wrap re-entry keeps a single-SBC
; path (ob00/ob01). OR-mode transform; pixel identity verified by
; tools/raster_ab.py (42,462-line corpus).
;--------------------------------------------------------------------

;----------------------------------------------------------------------------------------------------------
; Line rendering routine for 1-bit per pixel mode 4
; Not yet annotated
;----------------------------------------------------------------------------------------------------------

SCREEN_WIDTH=256


.linedraw4
{
    LDA y0:SEC:SBC y1:BCS dyok
    SBC #0:EOR #&FF
    LDX x0:LDY x1:STY x0:STX x1
    LDY y1:STY y0
    .dyok STA dy
    LDA x0:SBC x1:PHP:BCS dxok
    SBC #0:EOR #&FF
    .dxok TAX
;    LDA #&80:STA scr
    LDA #&00:STA scr            \\ KCHACK
    LDA y0:LSR A:LSR A:LSR A:STA scr+1
;    LSR A:ROR scr:LSR A:ROR scr
;    ADC scr+1:STA scr+1
    CLC
    LDA x0:AND #&F8:ADC scr:STA scr
    LDA scrstrt:ADC scr+1:STA scr+1
    LDA x0:AND #7:TAY
    CPX dy:BCS notsteep:JMP steep

    .notsteep
IF HAMILTONIAN_12
    STX dx                 ; store dx to ZP for hamiltonian entry
    ; exact inclusive test: dx <= 2*dy -> 1-2 band (dx == 2*dy MUST go to
    ; the hamiltonian: the double-SBC entries below assume runs >= 2)
    TXA:SEC:SBC dy:CMP dy
    BEQ go_ham
    BCS skip_ham
    .go_ham JMP entry_12_nj  ; hamiltonian path (do_dispatch PLPs direction)
    .skip_ham
ENDIF
    LDA dy:BEQ horizontal:STA cnt
    TXA:LSR A:STA err:STA errs
    LDA #2:STA ls
    .backh PLP:BCC right
    LDA strt1,Y:STA x1
    LDA strt1+8,Y:STA y1
    LDA y0:AND #7:TAY
    STX b01bor+1:STX b11+5
    STX b21+5:STX b31+5
    STX b41+5:STX b51+5
    STX b61+5:STX b71+5
    LDA dy
    STA a01s+1:STA a11s+1
    STA a21s+1:STA a31s+1
    STA a41s+1:STA a51s+1
    STA a61s+1
    STA b01+1:STA b11+1
    STA b21+1:STA b31+1
    STA b41+1:STA b51+1
    STA b61+1:STA b71+1
    SEC:JMP (x1)
    .horizontal STX err
    LDA #1:STA ls:STA cnt:STA dy
    BNE backh
    .right
    LDA strt0,Y:STA x1
    LDA strt0+8,Y:STA y1
    LDA y0:AND #7:TAY
    STX b00bor+1:STX b10+5
    STX b20+5:STX b30+5
    STX b40+5:STX b50+5
    STX b60+5:STX b70+5
    LDA dy
    STA a00s+1:STA a10s+1
    STA a20s+1:STA a30s+1
    STA a40s+1:STA a50s+1
    STA a60s+1
    STA b00+1:STA b10+1
    STA b20+1:STA b30+1
    STA b40+1:STA b50+1
    STA b60+1:STA b70+1
    SEC:JMP (x1)

    .steep
    TXA:BEQ vertical:STX cnt
    LDA dy:LSR A:STA errs
    LDA #2:STA ls
    .backv PLP:BCS left
    LDA strt2,Y:STA x1
    LDA strt2+8,Y:STA y1
    LDA y0:AND #7:TAY
    STX a02+1:STX a12+1
    STX a22+1:STX a32+1
    STX a42+1:STX a52+1
    STX a62+1:STX a72+1
    LDA dy
    STA b02+1:STA b12+1
    STA b22+1:STA b32+1
    STA b42+1:STA b52+1
    STA b62+1:STA b72+1
    LDX errs:SEC:JMP (x1)

    .vertical LDA dy:STA errs
    LDX #1:STX ls:STX cnt
    BNE backv
    .left
    LDA strt3,Y:STA x1
    LDA strt3+8,Y:STA y1
    LDA y0:AND #7:TAY
    STX a03+1:STX a13+1
    STX a23+1:STX a33+1
    STX a43+1:STX a53+1
    STX a63+1:STX a73+1
    LDA dy
    STA b03+1:STA b13+1
    STA b23+1:STA b33+1
    STA b43+1:STA b53+1
    STA b63+1:STA b73+1
    LDX errs:SEC:JMP (x1)

    .a00 LDA err:LDX #&FF
    .a00s SBC #dy
    .b10 SBC #dy:BCS b20:ADC #dx:STA err
    TXA:AND #&C0:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e10:.f10 DEY:BPL a20
    DEC scr+1:LDY #7:BNE a20
    .e10 DEC ls:BEQ d10:LDA err:SBC errs
    STA err:INC cnt:BCS f10
    .d10 RTS

    .a10 LDA err:LDX #&7F
    .a10s SBC #dy
    .b20 SBC #dy:BCS b30:ADC #dx:STA err
    TXA:AND #&E0:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e20:.f20 DEY:BPL a30
    DEC scr+1:LDY #7:BNE a30
    .e20 DEC ls:BEQ d20:LDA err:SBC errs
    STA err:INC cnt:BCS f20
    .d20 RTS

    .a20 LDA err:LDX #&3F
    .a20s SBC #dy
    .b30 SBC #dy:BCS b40:ADC #dx:STA err
    TXA:AND #&F0:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e30:.f30 DEY:BPL a40
    DEC scr+1:LDY #7:BNE a40
    .e30 DEC ls:BEQ d30:LDA err:SBC errs
    STA err:INC cnt:BCS f30
    .d30 RTS

    .a30 LDA err:LDX #&1F
    .a30s SBC #dy
    .b40 SBC #dy:BCS b50:ADC #dx:STA err
    TXA:AND #&F8:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e40:.f40 DEY:BPL a50
    DEC scr+1:LDY #7:BNE a50
    .e40 DEC ls:BEQ d40:LDA err:SBC errs
    STA err:INC cnt:BCS f40
    .d40 RTS

    .a40 LDA err:LDX #&0F
    .a40s SBC #dy
    .b50 SBC #dy:BCS b60:ADC #dx:STA err
    TXA:AND #&FC:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e50:.f50 DEY:BPL a60
    DEC scr+1:LDY #7:BNE a60
    .e50 DEC ls:BEQ d50:LDA err:SBC errs
    STA err:INC cnt:BCS f50
    .d50 RTS

    .a50 LDA err:LDX #7
    .a50s SBC #dy
    .b60 SBC #dy:BCS b70:ADC #dx:STA err
    TXA:AND #&FE:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e60:.f60 DEY:BPL f60a:DEC scr+1:LDY #7:.f60a JMP a70
    .e60 DEC ls:BEQ d60:LDA err:SBC errs
    STA err:INC cnt:BCS f60
    .d60 RTS

    .a60 LDA err:LDX #3
    .a60s SBC #dy
    .b70 SBC #dy:BCS by0:ADC #dx:STA err
    TXA:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e70:.f70 DEY:BPL ad0
    LDA scr:SBC #LO(SCREEN_WIDTH-8):LDY #7:STA scr
    LDA scr+1:SBC #HI(SCREEN_WIDTH-8):STA scr+1:JMP ob00
    .e70 DEC ls:BEQ d70:LDA err:SBC errs
    STA err:INC cnt:BCS f70
    .d70 RTS:.by0 STA err
    TXA:ORA (scr),Y:STA (scr),Y
    .ad0 LDA scr:ADC #7:STA scr:BCS ac0
    SEC:JMP ob00
    .ac0 INC scr+1:JMP ob00
    ; ob00: single-SBC for by0/f70 mid-run column advance
    .ob00 LDA err:LDX #&FF
    .b00 SBC #dy:BCC b00bor:JMP b10:.b00bor ADC #dx:STA err
    LDA #&80:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e00:.f00 DEY:BPL f00a:DEC scr+1:LDY #7:.f00a JMP a10
    .e00 DEC ls:BEQ d00:LDA err:SBC errs
    STA err:INC cnt:BCS f00
    .d00 RTS
    .a70 LDA err:LDX #1:JMP b70
    ; === SHALLOW LEFT: double-SBC entry, 3 cyc/span saved (dx > 2*dy) ===
    .a01 LDA err:LDX #&FF
    .a01s SBC #dy
    .b11 SBC #dy:BCS b21:ADC #dx:STA err
    TXA:AND #3:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e11:.f11 DEY:BPL a21
    DEC scr+1:LDY #7:BNE a21
    .e11 DEC ls:BEQ d11:LDA err:SBC errs
    STA err:INC cnt:BCS f11
    .d11 RTS
    .a11 LDA err:LDX #&FE
    .a11s SBC #dy
    .b21 SBC #dy:BCS b31:ADC #dx:STA err
    TXA:AND #7:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e21:.f21 DEY:BPL a31
    DEC scr+1:LDY #7:BNE a31
    .e21 DEC ls:BEQ d21:LDA err:SBC errs
    STA err:INC cnt:BCS f21
    .d21 RTS
    .a21 LDA err:LDX #&FC
    .a21s SBC #dy
    .b31 SBC #dy:BCS b41:ADC #dx:STA err
    TXA:AND #&F:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e31:.f31 DEY:BPL a41
    DEC scr+1:LDY #7:BNE a41
    .e31 DEC ls:BEQ d31:LDA err:SBC errs
    STA err:INC cnt:BCS f31
    .d31 RTS
    .a31 LDA err:LDX #&F8
    .a31s SBC #dy
    .b41 SBC #dy:BCS b51:ADC #dx:STA err
    TXA:AND #&1F:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e41:.f41 DEY:BPL a51
    DEC scr+1:LDY #7:BNE a51
    .e41 DEC ls:BEQ d41:LDA err:SBC errs
    STA err:INC cnt:BCS f41
    .d41 RTS
    .a41 LDA err:LDX #&F0
    .a41s SBC #dy
    .b51 SBC #dy:BCS b61:ADC #dx:STA err
    TXA:AND #&3F:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e51:.f51 DEY:BPL a61
    DEC scr+1:LDY #7:BNE a61
    .e51 DEC ls:BEQ d51:LDA err:SBC errs
    STA err:INC cnt:BCS f51
    .d51 RTS
    .a51 LDA err:LDX #&E0
    .a51s SBC #dy
    .b61 SBC #dy:BCS b71:ADC #dx:STA err
    TXA:AND #&7F:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e61:.f61 DEY:BPL f61a:DEC scr+1:LDY #7:.f61a JMP a71
    .e61 DEC ls:BEQ d61:LDA err:SBC errs
    STA err:INC cnt:BCS f61
    .d61 RTS
    .a61 LDA err:LDX #&C0
    .a61s SBC #dy
    .b71 SBC #dy:BCS by1:ADC #dx:STA err
    TXA:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e71:.f71 DEY:BPL sb1
    LDA scr:SBC #LO(SCREEN_WIDTH+8):LDY #7:STA scr
    LDA scr+1:SBC #HI(SCREEN_WIDTH+8):STA scr+1:JMP ob01
    .e71 DEC ls:BEQ d71:LDA err:SBC errs
    STA err:INC cnt:BCS f71
    .d71 RTS:.by1 STA err
    TXA:ORA (scr),Y:STA (scr),Y
    .sb1 LDA scr:SBC #8:STA scr:BCC sc1
    JMP ob01
    .sc1 DEC scr+1:SEC:JMP ob01
    ; ob01: single-SBC for by1/f71 mid-run column retreat
    .ob01 LDA err:LDX #&FF
    .b01 SBC #dy:BCC b01bor:JMP b11:.b01bor ADC #dx:STA err
    LDA #1:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e01:.f01 DEY:BPL f01a:DEC scr+1:LDY #7:.f01a JMP a11
    .e01 DEC ls:BEQ d01:LDA err:SBC errs
    STA err:INC cnt:BCS f01
    .d01 RTS
    .a71 LDA err:LDX #&80:JMP b71
    ; === STEEP RIGHT: DRAW-SBC-SBC-DRAW, 23.5 cyc/px fast path ===
    ; Position 0 (mask &80)
    .p02 LDA #&80:ORA (scr),Y:STA (scr),Y
    TXA:.a02 SBC #dx:BCC b02:TAX
    DEY:BPL p02
    .s02 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p02:DEC scr+1:SEC:BCS p02
    .e02 DEC ls:BEQ d02:SBC errs
    INC cnt:BCS n02:.d02 RTS
    .b02 ADC #dy:DEC cnt:BEQ e02
    .n02 TAX:DEY:BMI s12
    .p12 LDA #&40:ORA (scr),Y:STA (scr),Y
    TXA:.a12 SBC #dx:BCC b12:TAX
    DEY:BPL p12
    .s12 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p12:DEC scr+1:SEC:BCS p12
    .e12 DEC ls:BEQ d12:SBC errs
    INC cnt:BCS n12:.d12 RTS
    .b12 ADC #dy:DEC cnt:BEQ e12
    .n12 TAX:DEY:BMI s22
    .p22 LDA #&20:ORA (scr),Y:STA (scr),Y
    TXA:.a22 SBC #dx:BCC b22:TAX
    DEY:BPL p22
    .s22 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p22:DEC scr+1:SEC:BCS p22
    .e22 DEC ls:BEQ d22:SBC errs
    INC cnt:BCS n22:.d22 RTS
    .b22 ADC #dy:DEC cnt:BEQ e22
    .n22 TAX:DEY:BMI s32
    .p32 LDA #&10:ORA (scr),Y:STA (scr),Y
    TXA:.a32 SBC #dx:BCC b32:TAX
    DEY:BPL p32
    .s32 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p32:DEC scr+1:SEC:BCS p32
    .e32 DEC ls:BEQ d32:SBC errs
    INC cnt:BCS n32:.d32 RTS
    .b32 ADC #dy:DEC cnt:BEQ e32
    .n32 TAX:DEY:BMI s42
    .p42 LDA #8:ORA (scr),Y:STA (scr),Y
    TXA:.a42 SBC #dx:BCC b42:TAX
    DEY:BPL p42
    .s42 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p42:DEC scr+1:SEC:BCS p42
    .e42 DEC ls:BEQ d42:SBC errs
    INC cnt:BCS n42:.d42 RTS
    .b42 ADC #dy:DEC cnt:BEQ e42
    .n42 TAX:DEY:BMI s52
    .p52 LDA #4:ORA (scr),Y:STA (scr),Y
    TXA:.a52 SBC #dx:BCC b52:TAX
    DEY:BPL p52
    .s52 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p52:DEC scr+1:SEC:BCS p52
    .e52 DEC ls:BEQ d52:SBC errs
    INC cnt:BCS n52:.d52 RTS
    .b52 ADC #dy:DEC cnt:BEQ e52
    .n52 TAX:DEY:BMI s62
    .p62 LDA #2:ORA (scr),Y:STA (scr),Y
    TXA:.a62 SBC #dx:BCC b62:TAX
    DEY:BPL p62
    .s62 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p62:DEC scr+1:SEC:BCS p62
    .e62 DEC ls:BEQ d62:SBC errs
    INC cnt:BCS n62:.d62 RTS
    .b62 ADC #dy:DEC cnt:BEQ e62
    .n62 TAX:DEY:BMI s72
    .p72 LDA #1:ORA (scr),Y:STA (scr),Y
    TXA:.a72 SBC #dx:BCC b72:TAX
    DEY:BPL p72
    .s72 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p72:DEC scr+1:SEC:BCS p72
    .e72 DEC ls:BEQ d72:SBC errs
    INC cnt:BCS n72:.d72 RTS
    .b72 ADC #dy:DEC cnt:BEQ e72
    .n72 TAX:DEY:BMI s82
    LDA scr:ADC #7:STA scr:BCS ac2
    SEC:JMP p02:.ac2 INC scr+1:JMP p02
    .s82 LDY #7:LDA scr:SBC #LO(SCREEN_WIDTH-8):STA scr
    LDA scr+1:SBC #HI(SCREEN_WIDTH-8):STA scr+1:JMP p02
    .p03 LDA #1:ORA (scr),Y:STA (scr),Y
    TXA:.a03 SBC #dx:BCC b03:TAX
    DEY:BPL p03
    .s03 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p03:DEC scr+1:SEC:BCS p03
    .e03 DEC ls:BEQ d03:SBC errs
    INC cnt:BCS n03:.d03 RTS
    .b03 ADC #dy:DEC cnt:BEQ e03
    .n03 TAX:DEY:BMI s13
    .p13 LDA #2:ORA (scr),Y:STA (scr),Y
    TXA:.a13 SBC #dx:BCC b13:TAX
    DEY:BPL p13
    .s13 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p13:DEC scr+1:SEC:BCS p13
    .e13 DEC ls:BEQ d13:SBC errs
    INC cnt:BCS n13:.d13 RTS
    .b13 ADC #dy:DEC cnt:BEQ e13
    .n13 TAX:DEY:BMI s23
    .p23 LDA #4:ORA (scr),Y:STA (scr),Y
    TXA:.a23 SBC #dx:BCC b23:TAX
    DEY:BPL p23
    .s23 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p23:DEC scr+1:SEC:BCS p23
    .e23 DEC ls:BEQ d23:SBC errs
    INC cnt:BCS n23:.d23 RTS
    .b23 ADC #dy:DEC cnt:BEQ e23
    .n23 TAX:DEY:BMI s33
    .p33 LDA #8:ORA (scr),Y:STA (scr),Y
    TXA:.a33 SBC #dx:BCC b33:TAX
    DEY:BPL p33
    .s33 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p33:DEC scr+1:SEC:BCS p33
    .e33 DEC ls:BEQ d33:SBC errs
    INC cnt:BCS n33:.d33 RTS
    .b33 ADC #dy:DEC cnt:BEQ e33
    .n33 TAX:DEY:BMI s43
    .p43 LDA #&10:ORA (scr),Y:STA (scr),Y
    TXA:.a43 SBC #dx:BCC b43:TAX
    DEY:BPL p43
    .s43 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p43:DEC scr+1:SEC:BCS p43
    .e43 DEC ls:BEQ d43:SBC errs
    INC cnt:BCS n43:.d43 RTS
    .b43 ADC #dy:DEC cnt:BEQ e43
    .n43 TAX:DEY:BMI s53
    .p53 LDA #&20:ORA (scr),Y:STA (scr),Y
    TXA:.a53 SBC #dx:BCC b53:TAX
    DEY:BPL p53
    .s53 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p53:DEC scr+1:SEC:BCS p53
    .e53 DEC ls:BEQ d53:SBC errs
    INC cnt:BCS n53:.d53 RTS
    .b53 ADC #dy:DEC cnt:BEQ e53
    .n53 TAX:DEY:BMI s63
    .p63 LDA #&40:ORA (scr),Y:STA (scr),Y
    TXA:.a63 SBC #dx:BCC b63:TAX
    DEY:BPL p63
    .s63 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p63:DEC scr+1:SEC:BCS p63
    .e63 DEC ls:BEQ d63:SBC errs
    INC cnt:BCS n63:.d63 RTS
    .b63 ADC #dy:DEC cnt:BEQ e63
    .n63 TAX:DEY:BMI s73
    .p73 LDA #&80:ORA (scr),Y:STA (scr),Y
    TXA:.a73 SBC #dx:BCC b73:TAX
    DEY:BPL p73
    .s73 LDY #7:DEC scr+1:LDA scr
	SBC #LO(SCREEN_WIDTH)
    STA scr:BCS p73:DEC scr+1:SEC:BCS p73
    .e73 DEC ls:BEQ d73:SBC errs
    INC cnt:BCS n73:.d73 RTS
    .b73 ADC #dy:DEC cnt:BEQ e73
    .n73 TAX:DEY:BMI s83
    LDA scr:SBC #8:STA scr:BCC ac3
    JMP p03:.ac3 DEC scr+1:SEC:JMP p03
    .s83 LDY #7:LDA scr:SBC #LO(SCREEN_WIDTH+8):STA scr
    LDA scr+1:SBC #HI(SCREEN_WIDTH+8):STA scr+1
    JMP p03


    .strt0
    EQUB a00 AND &FF:EQUB a10 AND &FF
    EQUB a20 AND &FF:EQUB a30 AND &FF
    EQUB a40 AND &FF:EQUB a50 AND &FF
    EQUB a60 AND &FF:EQUB a70 AND &FF
    EQUB a00 DIV 256:EQUB a10 DIV 256
    EQUB a20 DIV 256:EQUB a30 DIV 256
    EQUB a40 DIV 256:EQUB a50 DIV 256
    EQUB a60 DIV 256:EQUB a70 DIV 256
    .strt1
    EQUB a71 AND &FF:EQUB a61 AND &FF
    EQUB a51 AND &FF:EQUB a41 AND &FF
    EQUB a31 AND &FF:EQUB a21 AND &FF
    EQUB a11 AND &FF:EQUB a01 AND &FF
    EQUB a71 DIV 256:EQUB a61 DIV 256
    EQUB a51 DIV 256:EQUB a41 DIV 256
    EQUB a31 DIV 256:EQUB a21 DIV 256
    EQUB a11 DIV 256:EQUB a01 DIV 256
    .strt2
    EQUB p02 AND &FF:EQUB p12 AND &FF
    EQUB p22 AND &FF:EQUB p32 AND &FF
    EQUB p42 AND &FF:EQUB p52 AND &FF
    EQUB p62 AND &FF:EQUB p72 AND &FF
    EQUB p02 DIV 256:EQUB p12 DIV 256
    EQUB p22 DIV 256:EQUB p32 DIV 256
    EQUB p42 DIV 256:EQUB p52 DIV 256
    EQUB p62 DIV 256:EQUB p72 DIV 256
    .strt3
    EQUB p73 AND &FF:EQUB p63 AND &FF
    EQUB p53 AND &FF:EQUB p43 AND &FF
    EQUB p33 AND &FF:EQUB p23 AND &FF
    EQUB p13 AND &FF:EQUB p03 AND &FF
    EQUB p73 DIV 256:EQUB p63 DIV 256
    EQUB p53 DIV 256:EQUB p43 DIV 256
    EQUB p33 DIV 256:EQUB p23 DIV 256
    EQUB p13 DIV 256:EQUB p03 DIV 256    
}
