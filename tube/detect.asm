\ DETECT — the Tube boot dispatcher (this file IS !BOOT: DFS boot option 2
\ *RUNs it). Loads at host &0900 (DFS 18-bit &30900 = I/O processor, so it
\ runs on the HOST even when a copro owns the current language).
\   Tube present : MODE 4 (host screen), then *RUN COPROT — DFS loads the
\                  parasite program across the Tube (load addr &2000, top
\                  bits 0 = parasite memory) and starts it; the host drops
\                  back to the Tube service loop, ready for the copro's
\                  R2 OSCLI that pulls HOSTT onto the host.
\   No tube      : message (the real disc will chain the regular loader).
OSWRCH=&FFEE
OSNEWL=&FFE7
OSBYTE=&FFF4
OSCLI=&FFF7
ORG &900
.start
    LDA #&EA                    \ OSBYTE &EA: read Tube-present flag
    LDX #0
    LDY #&FF
    JSR OSBYTE
    TXA
    BNE tube
    LDX #LO(runwalk)            \ no copro: chain the regular banked game
    LDY #HI(runwalk)
    JMP OSCLI
.tube
    LDA #22                     \ VDU 22,4: host MODE 4 (HOSTT then narrows
    JSR OSWRCH                  \ the CRTC window itself, like walk_drv)
    LDA #4
    JSR OSWRCH
    LDX #LO(runco)
    LDY #HI(runco)
    JMP OSCLI
.runco
    EQUS "RUN COPROT"
    EQUB 13
.runwalk
    EQUS "RUN WALK"
    EQUB 13
.end
SAVE "DETECT", start, end
