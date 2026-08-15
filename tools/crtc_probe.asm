\ crtc_probe.asm — standalone CRTC display-start probe.
\
\ WHY: walk_drv's narrow 256x160 window displayed the framebuffer 2
\ characters (16 bytes) too far in. Measuring that from the running
\ game meant racing the renderer's clear/flip and eyeballing pixel
\ coordinates in a screenshot — both unreliable. This program removes
\ every variable: no engine, no flipping, no clearing. It paints ONE
\ self-identifying pattern, programs the CRTC exactly as walk_drv does,
\ and spins forever.
\
\ THE PATTERN is a STAIRCASE: cell c carries a solid 8x8 block in row
\ c (c = 0..19), so the blocks form a diagonal running down-right. The
\ VERTICAL position of the leftmost block names the first displayed
\ cell — start at cell 0 and the diagonal touches the top-left corner;
\ start at cell 2 and the top two steps are missing, so the diagonal
\ begins two rows down. That reading needs no pixel arithmetic, which
\ is what made the earlier eyeballed measurements untrustworthy.
\ Row 0 also carries a thin dash per cell as a horizontal ruler.
\
\ Build variants with -D R8VAL=n -D BIAS=n (BIAS in characters, applied
\ to R12/R13). tools/crtc_probe.py drives it.

R8VAL = R8V
BIAS  = BI
LOOPW = LW                                      \ 1 = rewrite R12/R13 forever
                                                \ from the spin loop, i.e.
                                                \ MID-FRAME, which is what
                                                \ flip_sched does every flip
                                                \ (the probe otherwise writes
                                                \ them exactly once)
CURV  = CU                                      \ 1 = point R14/R15 at &0B00
                                                \ (what the MOS leaves in the
                                                \ game: the FIRST displayed
                                                \ character of the $5800
                                                \ buffer) to test whether
                                                \ R10 = &20 really suppresses
                                                \ the cursor there

SCRN  = &5800
START = (SCRN / 8) - BIAS

ORG &1900
.start
    LDA #22 : JSR &FFEE : LDA #4 : JSR &FFEE    \ MODE 4 (OS sets its own
                                                \ CRTC; we override below)
    \ --- clear the whole 5120-byte window ---
    LDA #LO(SCRN) : STA &70
    LDA #HI(SCRN) : STA &71
    LDX #20
.cl1
    LDY #0
    LDA #0
.cl2
    STA (&70),Y : INY : BNE cl2
    INC &71 : DEX : BNE cl1

    \ --- ruler: a 4px dash on the last raster of every cell in row 0 ---
    LDX #0
.rl
    LDA #&F0 : STA SCRN+7,X
    TXA : CLC : ADC #8 : TAX
    BNE rl                                      \ 32 cells x 8 = 256, wraps

    \ --- the staircase: cell c -> solid block in row c ---
    LDX #0
.dg
    TXA : CLC : ADC #HI(SCRN) : STA &71         \ hi = row c
    TXA : ASL A : ASL A : ASL A : STA &70       \ lo = cell c * 8
    LDY #7 : LDA #&FF
.dg2
    STA (&70),Y : DEY : BPL dg2
    INX : CPX #20 : BNE dg

    \ --- take the screen over, exactly as walk_drv does ---
    SEI
    LDA #1 :STA &FE00: LDA #32     :STA &FE01
    LDA #2 :STA &FE00: LDA #45     :STA &FE01
    LDA #6 :STA &FE00: LDA #20     :STA &FE01
    LDA #7 :STA &FE00: LDA #28     :STA &FE01
    LDA #8 :STA &FE00: LDA #R8VAL  :STA &FE01
    LDA #10:STA &FE00: LDA #&20    :STA &FE01
IF CURV = 1
    LDA #14:STA &FE00: LDA #&0B    :STA &FE01
    LDA #15:STA &FE00: LDA #&00    :STA &FE01
ENDIF
    LDA #12:STA &FE00: LDA #HI(START) :STA &FE01
    LDA #13:STA &FE00: LDA #LO(START) :STA &FE01
.spin
IF LOOPW = 1
    LDA #12:STA &FE00 : LDA #HI(START) :STA &FE01
    LDA #13:STA &FE00 : LDA #LO(START) :STA &FE01
ENDIF
    JMP spin
.end
SAVE "PROBE", start, end, start
