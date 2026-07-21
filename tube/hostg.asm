\ hostg.asm — the GAME host program (DFS name HOSTT on the game disc;
\ pulled onto the host at &1900 by the copro's raw R2 OSCLI).
\
\ The proven carousel from the bring-up test (hostt.asm) plus the REAL
\ rasteriser: the engine's own axis plotters (plot_h/plot_v transcribed
\ from src/clip/plot_axis.s, same ZP, same algorithm, OR-writes) and
\ the REAL NJ rasteriser (the same raster/ sources linedraw_or_reloc
\ assembles at &A900 for the flat build, re-ORG'd here for host RAM).
\ Dispatch replicates dcl's des_dispatch exactly: y0==y1 -> plot_h,
\ else x0==x1 -> plot_v, else NJ — so every received line runs through
\ the same routine that draws it in the flat build, into a carousel
\ buffer selected by RASTER_ZP_SCRSTRT ($70), which the raster was
\ already parameterized by.
\
\ ZP: $70,$74-$87 raster (the linedraw wrapper's map, x0..y1 = $82-$85
\ doubling as the receive slots); $DE-$E0/$95 plotter scratch (engine
\ numbers); $60-$6E carousel/keys (clear of all of it).
disp=&60
pend=&61
draw=&62
free=&63
mask=&64
ptr=&6C
tmpc=&6E

scr = &74
scrstrt = &70
cnt = &79
err = &76
errs = &7A
dx = &80
dy = &81
x0 = &82
y0 = &83
x1 = &84
y1 = &85
ls = &86
b = &87
zp_tmp0 = &DE
zp_tmp1 = &DF
zp_tmp2 = &E0
zp_plot_i = &95

HAMILTONIAN_12 = TRUE
STEEP_COMPACT = TRUE
HAMILTONIAN_23 = FALSE

ORG &1900
.start
    JMP realstart
    JMP drawcmd                 \ &1903: py65 pipeline-gate entry
.realstart
    SEI
    LDA #&7F                    \ every VIA interrupt source off
    STA &FE4E
    STA &FE6E
    LDA #&0F                    \ Tube control: clear Q,I,J,M — all polling
    STA &FEE0
    LDA #1                      \ CRTC: narrow 256x160 centred (walk_drv)
    STA &FE00
    LDA #32
    STA &FE01
    LDA #2
    STA &FE00
    LDA #45
    STA &FE01
    LDA #6
    STA &FE00
    LDA #20
    STA &FE01
    LDA #7
    STA &FE00
    LDA #28
    STA &FE01
    LDA #8
    STA &FE00
    LDA #0
    STA &FE01
    LDA #10
    STA &FE00
    LDA #&20
    STA &FE01
    LDA #3                      \ keyboard: IC32 write enable + DDRA out
    STA &FE40
    LDA #&7F
    STA &FE43
    LDX #0
    JSR clearbuf
    LDX #1
    JSR clearbuf
    LDX #2
    JSR clearbuf
.drain
    LDA &FEE0                   \ flush stale copro->host bytes
    BPL drained
    LDA &FEE1
    JMP drain
.drained
    LDA #0
    STA disp
    LDA #&FF
    STA pend
    LDA #1
    STA draw
    LDA #2
    STA free
    LDA bufhi+1                 \ raster target = draw buffer's page
    STA scrstrt
    LDA #12                     \ present B0
    STA &FE00
    LDA crtc12
    STA &FE01
    LDA #13
    STA &FE00
    LDA crtc13
    STA &FE01
    LDA #LO(irq)
    STA &204
    LDA #HI(irq)
    STA &205
    LDA #2                      \ clear stale vsync, enable CA1 only
    STA &FE4D
    LDA #&82
    STA &FE4E
    CLI
.main
    JSR rd
    STA x0
    JSR rd
    STA y0
    JSR rd
    STA x1
    JSR rd
    STA y1
    LDA x0                      \ all four FF = end of frame
    AND y0
    AND x1
    AND y1
    CMP #&FF
    BEQ eof
    INC &6F                     \ diagnostics: commands this frame (cheap;
    JSR drawcmd                 \ &6A = last frame's count, &6B = EOFs)
    JMP main
.drawcmd                        \ x0..y1 in $82-$85: dcl's des_dispatch,
    LDA y0                      \ replicated (JSR-able: the py65 pipeline
    CMP y1                      \ gate drives this directly)
    BNE noth
    JMP plot_h
.noth
    LDA x0
    CMP x1
    BNE diag
    JMP plot_v
.diag
    JMP linedraw4               \ the real NJ rasteriser
.eof
    LDA &6F                     \ publish the frame's command count
    STA &6A
    LDA #0
    STA &6F
    INC &6B                     \ EOF counter
    SEI                         \ swap races the presenter
    LDA pend
    BMI nopend
    TAX                         \ latest wins: old pend -> new draw
    LDA draw
    STA pend
    STX draw
    JMP swapped
.nopend
    LDA draw
    STA pend
    LDA free
    STA draw
    LDA #&FF
    STA free
.swapped
    CLI
    LDX draw
    LDA bufhi,X
    STA scrstrt                 \ retarget the raster
    JSR clearbuf
    JMP main
.rd
    LDA &FEE0
    BPL rd
    LDA &FEE1
    RTS
.irq
    LDA &FE4D
    AND #2
    BEQ iout
    STA &FE4D
    TXA
    PHA
    LDX pend
    BMI nopres
    LDA #12
    STA &FE00
    LDA crtc12,X
    STA &FE01
    LDA #13
    STA &FE00
    LDA crtc13,X
    STA &FE01
    LDA disp
    STA free
    STX disp
    LDA #&FF
    STA pend
.nopres
    LDA #0                      \ cursor keys -> mask
    STA mask
    LDA #&39                    \ UP
    STA &FE4F
    BIT &FE4F
    BPL nk1
    LDA mask
    ORA #1
    STA mask
.nk1
    LDA #&29                    \ DOWN
    STA &FE4F
    BIT &FE4F
    BPL nk2
    LDA mask
    ORA #2
    STA mask
.nk2
    LDA #&19                    \ LEFT
    STA &FE4F
    BIT &FE4F
    BPL nk3
    LDA mask
    ORA #4
    STA mask
.nk3
    LDA #&79                    \ RIGHT
    STA &FE4F
    BIT &FE4F
    BPL nk4
    LDA mask
    ORA #8
    STA mask
.nk4
    LDA &FEE0                   \ push the mask if there's FIFO room —
    AND #&40                    \ this byte paces the copro's frame loop
    BEQ nosend
    LDA mask
    STA &FEE1
.nosend
    PLA
    TAX
.iout
    LDA &FC
    RTI
.clearbuf
    LDA #0                      \ X = buffer index; 20 pages of zeros
    STA ptr
    LDA bufhi,X
    STA ptr+1
    LDA #20
    STA tmpc
    LDY #0
    TYA
.cb
    STA (ptr),Y
    INY
    BNE cb
    INC ptr+1
    DEC tmpc
    BNE cb
    RTS
.bufhi
    EQUB &44,&58,&6C
.crtc12
    EQUB &08,&0B,&0D
.crtc13
    EQUB &80,&00,&80

\ ======================================================================
\ plot_h / plot_v — transcribed from src/clip/plot_axis.s (ca65 ->
\ beebasm; same ZP, same write order, bit-identical OR patterns).
\ ======================================================================
.plot_lmask
    EQUB &FF,&7F,&3F,&1F,&0F,&07,&03,&01
.plot_rmask
    EQUB &80,&C0,&E0,&F0,&F8,&FC,&FE,&FF
.plot_bmask
    EQUB &80,&40,&20,&10,&08,&04,&02,&01
.plot_h
    LDA y0
    LSR A
    LSR A
    LSR A
    CLC
    ADC scrstrt
    STA zp_tmp1
    LDA x0
    AND #&F8
    STA zp_tmp2
    LDA y0
    AND #7
    ORA zp_tmp2
    STA zp_tmp0
    LDA x1
    AND #&F8
    SEC
    SBC zp_tmp2
    BEQ ph_single
    STA zp_plot_i
    LDA x0
    AND #7
    TAX
    LDY #0
    LDA plot_lmask,X
    ORA (zp_tmp0),Y
    STA (zp_tmp0),Y
    LDA x1
    AND #7
    TAX
    LDY zp_plot_i
    LDA plot_rmask,X
    ORA (zp_tmp0),Y
    STA (zp_tmp0),Y
    LDX #&FF
    SEC
.ph_mid
    TYA
    SBC #8
    TAY
    BEQ ph_done
    TXA
    STA (zp_tmp0),Y
    BMI ph_mid
.ph_done
    RTS
.ph_single
    LDA x0
    AND #7
    TAX
    LDA plot_lmask,X
    STA zp_tmp2
    LDA x1
    AND #7
    TAX
    LDA plot_rmask,X
    AND zp_tmp2
    LDY #0
    ORA (zp_tmp0),Y
    STA (zp_tmp0),Y
    RTS
.plot_v
    LDA y0
    CMP y1
    BCC pv_ord
    LDX y1
    STA y1
    STX y0
.pv_ord
    LDA x0
    AND #7
    TAX
    LDA x0
    AND #&F8
    STA zp_tmp0
    LDA plot_bmask,X
    TAX
    LDA y1
    LSR A
    LSR A
    LSR A
    STA zp_plot_i
    CLC
    ADC scrstrt
    STA zp_tmp1
    LDA y0
    LSR A
    LSR A
    LSR A
    STA zp_tmp2
    LDA zp_plot_i
    SEC
    SBC zp_tmp2
    STA zp_plot_i
    BNE pv_multi
    LDA y0
    AND #7
    ORA zp_tmp0
    STA zp_tmp0
    LDA y1
    SEC
    SBC y0
    TAY
.pv_lp1
    TXA
    ORA (zp_tmp0),Y
    STA (zp_tmp0),Y
    DEY
    BPL pv_lp1
    RTS
.pv_multi
    LDA y1
    AND #7
    TAY
.pv_lp2
    TXA
    ORA (zp_tmp0),Y
    STA (zp_tmp0),Y
    DEY
    BPL pv_lp2
    DEC zp_tmp1
    DEC zp_plot_i
    BEQ pv_top
.pv_mid
    LDY #7
FOR n, 1, 7
    TXA
    ORA (zp_tmp0),Y
    STA (zp_tmp0),Y
    DEY
NEXT
    TXA
    ORA (zp_tmp0),Y
    STA (zp_tmp0),Y
    DEC zp_tmp1
    DEC zp_plot_i
    BNE pv_mid
.pv_top
    LDA y0
    AND #7
    ORA zp_tmp0
    STA zp_tmp0
    LDA y0
    AND #7
    EOR #7
    TAY
.pv_lp3
    TXA
    ORA (zp_tmp0),Y
    STA (zp_tmp0),Y
    DEY
    BPL pv_lp3
    RTS

\ ======================================================================
\ The REAL NJ rasteriser — the same sources linedraw_or_reloc.asm
\ builds at &A900 for the flat/banked engines, assembled at THIS
\ address for host RAM. Entry: linedraw4.
\ ======================================================================
INCLUDE "raster/nj-linedraw4-or.asm"
INCLUDE "raster/shallow_12_hamiltonian-or.asm"
.hostend
ASSERT hostend <= &4400         \ carousel buffer B0 starts at &4400
SAVE "HOSTT", start, hostend, start
