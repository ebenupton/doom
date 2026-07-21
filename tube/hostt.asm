\ HOSTT — host-side carousel/keypress test. Pulled onto the host by the
\ copro's raw R2 OSCLI ("RUN HOSTT", load &FFFF1900) and never returns.
\
\ Triple-buffered display carousel, 256x160 1bpp (walk_drv's exact CRTC
\ window), interrupts ENABLED:
\   B0 &4400  B1 &5800  B2 &6C00   (5120 bytes each, last ends at &8000)
\   invariant: {disp} + {draw} + exactly one of {pend | free} = 3 buffers
\   vsync IRQ: if pend valid, present it (CRTC R12/13), old disp -> free;
\              scan cursor keys, push the mask byte to the copro (R1).
\   main loop: drain 4-byte line commands from the copro (R1, 24-deep),
\              rasterize into draw; on FF,FF,FF,FF: pend <- draw (latest
\              wins if a pend was already waiting), pick up the spare,
\              clear it, carry on.
\ Test rasterizer is h/v lines only — the NJ port replaces it later.
disp=&70
pend=&71
draw=&72
free=&73
c0=&74
c1=&75
c2=&76
c3=&77
ptr=&78
tmp=&7A
mask=&7B
vmask=&7C
vcol=&7D
yrow=&7E
ORG &1900
.start
    SEI
    LDA #&7F                    \ every VIA interrupt source off
    STA &FE4E
    STA &FE6E
    LDA #&0F                    \ Tube control: S=0 -> clear Q,I,J,M — no
    STA &FEE0                   \ Tube IRQs/NMIs on either processor; both
                                \ sides poll from here on
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
    LDA #0                      \ interlace OFF
    STA &FE01
    LDA #10
    STA &FE00
    LDA #&20                    \ cursor off
    STA &FE01
    LDA #3                      \ keyboard: IC32 write enable + DDRA out
    STA &FE40
    LDA #&7F
    STA &FE43
    LDX #0                      \ clear all three buffers
    JSR clearbuf
    LDX #1
    JSR clearbuf
    LDX #2
    JSR clearbuf
.drain
    LDA &FEE0                   \ flush any stale copro->host bytes
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
    LDA #12                     \ present B0
    STA &FE00
    LDA crtc12
    STA &FE01
    LDA #13
    STA &FE00
    LDA crtc13
    STA &FE01
    LDA #LO(irq)                \ IRQ1V -> us (OS stub banks A in &FC)
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
    STA c0
    JSR rd
    STA c1
    JSR rd
    STA c2
    JSR rd
    STA c3
    LDA c0                      \ all four FF = end of frame
    AND c1
    AND c2
    AND c3
    CMP #&FF
    BEQ eof
    JSR drawline
    JMP main
.eof
    SEI                         \ buffer swap races the presenter
    LDA pend
    BMI nopend
    TAX                         \ pend still waiting: LATEST WINS — the
    LDA draw                    \ old pend is recycled as the new draw
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
    JSR clearbuf
    JMP main
.rd
    LDA &FEE0                   \ b7 = copro byte waiting
    BPL rd
    LDA &FEE1
    RTS
.irq
    LDA &FE4D                   \ (only CA1 is enabled; stay tidy anyway)
    AND #2
    BEQ iout
    STA &FE4D                   \ clear CA1
    TXA
    PHA
    LDX pend
    BMI nopres
    LDA #12                     \ present the pending buffer: writes land
    STA &FE00                   \ just after vsync, so the CRTC latches
    LDA crtc12,X                \ them for the NEXT field — no tear
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
    LDA #0                      \ scan cursor keys -> mask
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
    LDA &FEE0                   \ push the mask if the FIFO has room —
    AND #&40                    \ this byte is what paces the copro
    BEQ nosend
    LDA mask
    STA &FEE1
.nosend
    PLA
    TAX
.iout
    LDA &FC
    RTI
.drawline
    LDA c1
    CMP c3
    BEQ hline
    LDA c0
    CMP c2
    BEQ vline
    RTS                         \ test host: h/v only (NJ port comes later)
.hline
    LDA c0                      \ normalize x0 <= x1
    CMP c2
    BCC hnorm
    LDA c2
    LDX c0
    STA c0
    STX c2
.hnorm
    LDA c1
    JSR rowptr
.hl
    LDA c0
    AND #&F8
    TAY
    LDA c0
    AND #7
    TAX
    LDA bits,X
    ORA (ptr),Y
    STA (ptr),Y
    LDA c0
    CMP c2
    BEQ ldone
    INC c0
    JMP hl
.vline
    LDA c1                      \ normalize y0 <= y1
    CMP c3
    BCC vnorm
    LDA c3
    LDX c1
    STA c1
    STX c3
.vnorm
    LDA c0
    AND #&F8
    STA vcol                    \ column byte offset
    LDA c0
    AND #7
    TAX
    LDA bits,X
    STA vmask                   \ pixel mask
.vl
    LDA c1
    JSR rowptr
    LDY vcol
    LDA vmask
    ORA (ptr),Y
    STA (ptr),Y
    LDA c1
    CMP c3
    BEQ ldone
    INC c1
    JMP vl
.ldone
    RTS
.rowptr
    STA yrow                    \ A = y: ptr = base[draw] + (y>>3)*256 + (y&7)
    AND #7
    STA ptr
    LDA yrow
    LSR A
    LSR A
    LSR A
    LDX draw
    CLC
    ADC bufhi,X
    STA ptr+1
    RTS
.clearbuf
    LDA #0                      \ X = buffer index; 20 pages of zeros
    STA ptr
    LDA bufhi,X
    STA ptr+1
    LDA #20
    STA tmp
    LDY #0
    TYA
.cb
    STA (ptr),Y
    INY
    BNE cb
    INC ptr+1
    DEC tmp
    BNE cb
    RTS
.bits
    EQUB &80,&40,&20,&10,&08,&04,&02,&01
.bufhi
    EQUB &44,&58,&6C
.crtc12
    EQUB &08,&0B,&0D
.crtc13
    EQUB &80,&00,&80
.end
SAVE "HOSTT", start, end
