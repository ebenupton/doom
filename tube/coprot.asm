\ COPROT — parasite-side carousel/keypress test (loads at parasite &2000
\ via DFS across the Tube; 65C02 but written as plain 6502).
\
\ Startup: sends "RUN HOSTT"<cr> over R2 as a raw OSCLI (id byte &02 then
\ the string) and does NOT wait for the reply — the host DFS loads HOSTT
\ into I/O memory (&FFFF1900) and jumps it, and the Tube OS protocol is
\ dead from that moment on. Pure register polling after that.
\
\ Protocol (the real engine will speak exactly this):
\   host -> copro: R1, one byte per displayed frame = key mask
\                  (b0 up, b1 down, b2 left, b3 right). The copro BLOCKS
\                  on it, so the host's vsync paces the frame loop.
\   copro -> host: R1 (24-deep this direction), 4-byte line commands
\                  x0,y0,x1,y1; end of frame = FF,FF,FF,FF (y<160 makes
\                  FF unambiguous). One test frame = rect (16 bytes) +
\                  sweep marker (4) + EOF (4) = 24 bytes = exactly one
\                  FIFO fill — the copro can queue a whole frame while
\                  the host is still clearing.
R1S=&FEF8
R1D=&FEF9
R2S=&FEFA
R2D=&FEFB
px=&70
py=&71
x1=&72
y1=&73
mask=&74
tick=&75
b0=&78
b1=&79
b2=&7A
b3=&7B
ORG &2000
.start
    SEI                         \ poll-only from here
    LDX #0
.cli
    LDA cmd,X
    BEQ cdone
.cw
    BIT R2S                     \ b6 (V) = space in parasite->host R2
    BVC cw
    STA R2D
    INX
    BNE cli
.cdone
    LDA #108                    \ rect top-left start position
    STA px
    LDA #68
    STA py
    LDA #0
    STA tick
.frame
.wm
    BIT R1S                     \ b7 (N) = key mask waiting
    BPL wm
    LDA R1D
    STA mask
    INC tick
    LDA mask
    AND #1
    BEQ nup
    LDA py
    CMP #10
    BCC nup
    DEC py
    DEC py
.nup
    LDA mask
    AND #2
    BEQ ndn
    LDA py
    CMP #128
    BCS ndn
    INC py
    INC py
.ndn
    LDA mask
    AND #4
    BEQ nlf
    LDA px
    CMP #10
    BCC nlf
    DEC px
    DEC px
.nlf
    LDA mask
    AND #8
    BEQ nrt
    LDA px
    CMP #208
    BCS nrt
    INC px
    INC px
.nrt
    LDA px
    CLC
    ADC #40
    STA x1                      \ rect is 40x24
    LDA py
    CLC
    ADC #24
    STA y1
    LDA px                      \ top edge
    STA b0
    LDA py
    STA b1
    LDA x1
    STA b2
    LDA py
    STA b3
    JSR send4
    LDA px                      \ bottom edge
    STA b0
    LDA y1
    STA b1
    LDA x1
    STA b2
    LDA y1
    STA b3
    JSR send4
    LDA px                      \ left edge
    STA b0
    LDA py
    STA b1
    LDA px
    STA b2
    LDA y1
    STA b3
    JSR send4
    LDA x1                      \ right edge
    STA b0
    LDA py
    STA b1
    LDA x1
    STA b2
    LDA y1
    STA b3
    JSR send4
    LDA tick                    \ autonomous sweep marker: proves the
    AND #127                    \ carousel presents without any key input
    CLC
    ADC #64
    STA b0
    STA b2
    LDA #2
    STA b1
    LDA #6
    STA b3
    JSR send4
    LDA #&FF                    \ end of frame
    STA b0
    STA b1
    STA b2
    STA b3
    JSR send4
    JMP frame
.send4
    LDX #0
.s4
    LDA b0,X
.sw
    BIT R1S                     \ b6 (V) = FIFO space
    BVC sw
    STA R1D
    INX
    CPX #4
    BNE s4
    RTS
.cmd
    EQUB 2                      \ Tube R2 OSCLI id
    EQUS "RUN HOSTT"
    EQUB 13
    EQUB 0                      \ (loop terminator, not sent)
.end
SAVE "COPROT", start, end
