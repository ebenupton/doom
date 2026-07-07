
;----------------------------------------------------------------------------------------------------------
; Line rendering routine for 1-bit per pixel mode 4
;
; linedraw4 — OR-mode Bresenham into the BBC mode-4 framebuffer.
; Pixel-exact python mirror: nj_raster.py (the authoritative pseudocode);
; the pixel-for-pixel contract is enforced against the 42,462-line golden
; corpus by tools/nj_raster_check.py. Derived from Nick Jameson's routine,
; retargeted from 320 to 256 pixels wide.
;
; In:  x0,y0,x1,y1 (ZP)  endpoints (x 0..255, y 0..159)
;      scrstrt (ZP)      framebuffer page hi ($58 or $6C)
; Out: pixels ORed into the framebuffer. A,X,Y trashed; x0/y0/x1/y1 and the
;      ZP scratch (scr, cnt, err, errs, ls, b, dx, dy) trashed.
; Framebuffer byte = (scrstrt<<8) + ((y>>3)<<8) + (x AND &F8) + (y AND 7);
; pixel bit = &80 >> (x AND 7). At 256 wide a character row is exactly one
; page, so vertical byte steps are pure scr-hi arithmetic.
;
; Structure:
;   setup     sort endpoints so y0 >= y1 (drawing runs bottom-to-top, rows
;             DECrement); x direction = carry of the post-sort x0-x1
;             compare, saved with PHP and consumed by the cores' PLP
;             (C=1 -> x decreases along the drawing direction: "left");
;             dy=|y0-y1|, dx=|x0-x1| (kept in X); scr -> byte of (x0,y0)
;   dispatch  dx >= dy -> shallow (run-accumulating; optional handoff to
;             the Hamiltonian slope-band modules), else steep (per-pixel)
;
; NJ error protocol (both cores; see nj_raster.py draw_line/_shallow/_steep):
;   shallow: err starts at dx>>1; per pixel err -= dy; on borrow the run of
;     pixels accumulated since the last y-step is plotted as one ORed byte
;     mask and err += dx. cnt counts the dy y-steps.
;   steep:   r starts at dy>>1; per row r -= dx; on borrow r += dy and the
;     column steps. cnt counts the dx x-steps.
;   two-phase ls counter: ls=2 for a generic line. When cnt reaches 0 the
;     e-phase runs: ls 2->1 and err -= errs (errs holds the initial dx>>1
;     or dy>>1); borrow -> line complete, else exactly one more run/step
;     (cnt=1) whose completion (ls 1->0) ends the line. This decides
;     whether the final half-step lands on a row/column of its own, giving
;     symmetric endpoints across all dy+1 rows (dx+1 columns).
;   degenerates re-enter the same cores with cnt=ls=1 and patched state:
;     horizontal: err=dx, dy:=1  (one long run, plotted via byte flushes)
;     vertical:   r=dy, step:=1  (one column; the e-phase ends it)
;
; NOTE on SMC: the '#dy' / '#dx' immediates inside the cores are
; placeholders (they assemble as the ZP ADDRESSES of dy/dx); the dispatch
; code pokes the real dy/dx VALUES over them before jumping in.
;----------------------------------------------------------------------------------------------------------

SCREEN_WIDTH=256


.linedraw4
{
    ; --- endpoint sort: ensure y0 >= y1; dy = |y0-y1| ---
    LDA y0:SEC:SBC y1:BCS dyok
    SBC #0:EOR #&FF             ; y0 < y1: negate (SBC #0 exits with C=1)...
    LDX x0:LDY x1:STY x0:STX x1 ; ...and swap the endpoints
    LDY y1:STY y0
    .dyok STA dy
    ; --- x direction + dx: C=1 into the SBC on both paths (exact subtract);
    ;     PHP banks C (1 = x0 >= x1 = leftward) for the cores' PLP ---
    LDA x0:SBC x1:PHP:BCS dxok
    SBC #0:EOR #&FF             ; negate: dx = x1-x0
    .dxok TAX                   ; X = dx from here to core entry
    ; --- scr -> framebuffer byte of the start pixel (x0,y0) ---
    ; (the commented-out lines are NJ's original 320-wide address math —
    ;  (y>>3)*320 with a +&80 base; at 256 wide a char row is one whole
    ;  page, so hi = scrstrt + (y0>>3) and lo is just the byte column)
;    LDA #&80:STA scr
    LDA #&00:STA scr            \\ KCHACK
    LDA y0:LSR A:LSR A:LSR A:STA scr+1
;    LSR A:ROR scr:LSR A:ROR scr
;    ADC scr+1:STA scr+1
    CLC
    LDA x0:AND #&F8:ADC scr:STA scr
    LDA scrstrt:ADC scr+1:STA scr+1
    LDA x0:AND #7:TAY           ; Y = start bit -> strtN dispatch index
    CPX dy:BCS notsteep:JMP steep

    ; ==================== shallow dispatch (dx >= dy) ====================
    .notsteep
IF HAMILTONIAN_12
    STX dx                 ; store dx to ZP for hamiltonian entry
    TXA:LSR A:CMP dy
    BCS skip_ham           ; dx/2 >= dy -> not in 1:2 band (excludes 2:1)
    JMP entry_12_nj        ; hamiltonian path (do_dispatch PLPs direction)
    .skip_ham
ENDIF
IF HAMILTONIAN_23
    \ here dx >= 2dy (dy <= dx/2), so dx-dy >= dy and neither SBC borrows
    TXA:SEC:SBC dy:SBC dy  ; A = dx - 2dy exact, C=1
    BEQ skip_23            ; dx == 2dy -> generic (protocol excludes boundary)
    CMP dy
    BCC in_23              ; dx <  3dy -> band
    BNE skip_23            ; dx >  3dy -> generic
    .in_23 JMP entry_23_nj ; dx == 3dy included; A = delta1
    .skip_23
ENDIF
    ; --- generic shallow setup: cnt = dy y-steps, err = errs = dx>>1, ls=2 ---
    LDA dy:BEQ horizontal:STA cnt
    TXA:LSR A:STA err:STA errs
    LDA #2:STA ls
    ; --- direction dispatch + SMC patch: poke the dy VALUE over the eight
    ;     SBC immediates (bN?+1) and the dx VALUE over the eight ADC
    ;     immediates (bN?+5) of the chosen direction's blocks; x1/y1 are
    ;     dead now and get reused as the JMP (x1) vector, picked from the
    ;     strtN table by the pre-loaded Y = x0&7; then Y := y0&7 (the row
    ;     within the char row, i.e. the (scr),Y offset). C=1 on entry. ---
    .backh PLP:BCC right        ; banked x-compare carry: C=1 -> leftward
    LDA strt1,Y:STA x1
    LDA strt1+8,Y:STA y1
    LDA y0:AND #7:TAY
    STX b01+5:STX b11+5
    STX b21+5:STX b31+5
    STX b41+5:STX b51+5
    STX b61+5:STX b71+5
    LDA dy
    STA b01+1:STA b11+1
    STA b21+1:STA b31+1
    STA b41+1:STA b51+1
    STA b61+1:STA b71+1
    SEC:JMP (x1)
    ; dy == 0: one run of dx+1 pixels. Re-enter the shallow core with
    ; err=dx and dy:=1, so err borrows only after exactly dx+1 bits;
    ; cnt=ls=1 makes that first y-step attempt end the line. The row
    ; emerges as byte-split run flushes.
    .horizontal STX err
    LDA #1:STA ls:STA cnt:STA dy
    BNE backh                   ; (A=1, always taken)
    .right
    LDA strt0,Y:STA x1
    LDA strt0+8,Y:STA y1
    LDA y0:AND #7:TAY
    STX b00+5:STX b10+5
    STX b20+5:STX b30+5
    STX b40+5:STX b50+5
    STX b60+5:STX b70+5
    LDA dy
    STA b00+1:STA b10+1
    STA b20+1:STA b30+1
    STA b40+1:STA b50+1
    STA b60+1:STA b70+1
    SEC:JMP (x1)

    ; ==================== steep dispatch (dy > dx) =======================
    ; generic setup: cnt = dx x-steps, errs = dy>>1, ls=2; the running
    ; error r rides in X (loaded from errs at entry).
    .steep
    TXA:BEQ vertical:STX cnt
    LDA dy:LSR A:STA errs
    LDA #2:STA ls
    .backv
IF STEEP_COMPACT
    LDA stmask,Y:STA b       \ single-pixel mask for x0&7 (Y = x0&7 here)
    PLP:BCS left             \ banked x-compare carry: C=1 -> leftward
    STX sr_dx+1              \ SMC: core's SBC #dx (X = dx, or 1 if vertical)
    LDA dy:STA sr_dy+1       \ SMC: core's ADC #dy
    LDA y0:AND #7:TAY        \ Y = row within char row
    LDX errs:SEC:JMP sr_loop \ X = r = dy>>1 (or dy); C=1 loop invariant
ELSE
    PLP:BCS left
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
ENDIF

    ; dx == 0: re-enter the steep core with step:=1 (X=1 -> SBC #1) and
    ; r=dy: r never borrows within the column's dy+1 rows, and cnt=ls=1
    ; makes the first x-step attempt end the line via the e-phase.
    .vertical LDA dy:STA errs
    LDX #1:STX ls:STX cnt
    BNE backv                   ; (X=1, always taken)
    .left
IF STEEP_COMPACT
    STX sl_dx+1              \ SMC: core's SBC #dx
    LDA dy:STA sl_dy+1       \ SMC: core's ADC #dy
    LDA y0:AND #7:TAY
    LDX errs:SEC:JMP sl_loop
ELSE
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
ENDIF

    ; =====================================================================
    ; Unrolled shallow cores: eight blocks per direction, one per bit
    ; position in the byte. Right-going blocks aN0/bN0 handle the (N+1)th
    ; pixel from the LEFT edge (plot mask &80>>N); left-going aN1/bN1 the
    ; (N+1)th from the RIGHT edge (&01<<N). Entered via strt0/strt1[x0&7].
    ;
    ; Run accumulation: X carries the run mask seed — all bits from the
    ; run's start position to the byte's far edge (right: LDX #&FF>>M at
    ; block M; left: the mirror &FF<<M). While err-dy doesn't borrow,
    ; control FALLS THROUGH from bN to the NEXT block's b entry: the run
    ; grows one bit, nothing is plotted, err rides in A. On borrow
    ; (y-step): err += dx is stored, and the run is plotted in one OR —
    ; TXA AND end-mask = exactly the bits [run start..N]. Then:
    ;   fN (cnt > 0): DEY steps to the row below in the char row (drawing
    ;      is bottom-to-top); on Y wrap, scr -= 256 with a two-step hi
    ;      borrow (the SBC #LO(256) leaves C for the BCS after LDY #7)
    ;      and Y := 7; continue at block N+1 with a fresh run.
    ;   eN (cnt == 0): the two-phase ls tail — ls 2->1: err -= errs; no
    ;      borrow -> one final run (cnt := 1, resume at fN); borrow, or
    ;      ls 1->0 -> RTS.
    ; Block 7 handles the byte edge: the no-y-step path (by0/by1) flushes
    ; the run up to the edge, then ad0/sb1 step scr one byte along and
    ; re-enter block 0 (mirror: block 7) continuing the SAME run — the
    ; 'byte-end flush'. C=1 is an invariant into every SBC.
    ; =====================================================================
    ; --- right-going blocks: masks &80,&40..&01; scr steps right ---
    .a00 LDA err:LDX #&FF       ; run starts at bit 0: seed mask = all 8 bits
    .b00 SBC #dy:BCS b10:ADC #dx:STA err    ; (dy/dx immediates SMC-patched)
    LDA #&80:ORA (scr),Y:STA (scr),Y        ; plot run [bit 0..bit 0]
    DEC cnt:BEQ e00:.f00 DEY:BPL a10        ; row step; new run at bit 1
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a10:DEC scr+1:SEC:BCS a10    ; char-row wrap (scr -= 256)
    .e00 DEC ls:BEQ d00:LDA err:SBC errs    ; ls tail: final half-step test
    STA err:INC cnt:BCS f00
    .d00 RTS

    ; blocks 1..6: as block 0 with everything shifted one pixel — seed
    ; LDX #&FF>>N, plot mask X AND (bits 0..N); run [M..N] plots as
    ; (&FF>>M) AND ~(&FF>>(N+1))
    .a10 LDA err:LDX #&7F
    .b10 SBC #dy:BCS b20:ADC #dx:STA err
    TXA:AND #&C0:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e10:.f10 DEY:BPL a20
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a20:DEC scr+1:SEC:BCS a20
    .e10 DEC ls:BEQ d10:LDA err:SBC errs
    STA err:INC cnt:BCS f10
    .d10 RTS

    .a20 LDA err:LDX #&3F
    .b20 SBC #dy:BCS b30:ADC #dx:STA err
    TXA:AND #&E0:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e20:.f20 DEY:BPL a30
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a30:DEC scr+1:SEC:BCS a30
    .e20 DEC ls:BEQ d20:LDA err:SBC errs
    STA err:INC cnt:BCS f20
    .d20 RTS

    .a30 LDA err:LDX #&1F
    .b30 SBC #dy:BCS b40:ADC #dx:STA err
    TXA:AND #&F0:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e30:.f30 DEY:BPL a40
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a40:DEC scr+1:SEC:BCS a40
    .e30 DEC ls:BEQ d30:LDA err:SBC errs
    STA err:INC cnt:BCS f30
    .d30 RTS

    .a40 LDA err:LDX #&F
    .b40 SBC #dy:BCS b50:ADC #dx:STA err
    TXA:AND #&F8:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e40:.f40 DEY:BPL a50
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a50:DEC scr+1:SEC:BCS a50
    .e40 DEC ls:BEQ d40:LDA err:SBC errs
    STA err:INC cnt:BCS f40
    .d40 RTS

    .a50 LDA err:LDX #7
    .b50 SBC #dy:BCS b60:ADC #dx:STA err
    TXA:AND #&FC:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e50:.f50 DEY:BPL a60
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a60:DEC scr+1:SEC:BCS a60
    .e50 DEC ls:BEQ d50:LDA err:SBC errs
    STA err:INC cnt:BCS f50
    .d50 RTS

    .a60 LDA err:LDX #3
    .b60 SBC #dy:BCS b70:ADC #dx:STA err
    TXA:AND #&FE:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e60:.f60 DEY:BPL a70
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a70:DEC scr+1:SEC:BCS a70
    .e60 DEC ls:BEQ d60:LDA err:SBC errs
    STA err:INC cnt:BCS f60
    .d60 RTS

    ; block 7 (rightmost pixel): every continuation crosses into the next
    ; byte to the right
    .a70 LDA err:LDX #1
    .b70 SBC #dy:BCS by0:ADC #dx:STA err
    TXA:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e70:.f70 DEY:BPL ad0        ; y-step: next byte (same rows)
    LDA scr:SBC #LO(SCREEN_WIDTH-8):LDY #7:STA scr      ; combined char-row
    LDA scr+1:SBC #HI(SCREEN_WIDTH-8):STA scr+1:JMP a00 ; wrap + byte right
    .e70 DEC ls:BEQ d70:LDA err:SBC errs
    STA err:INC cnt:BCS f70
    ; by0: no y-step at the byte edge — flush the run to the edge and let
    ; ad0 step scr one byte right (+8: ADC #7 with C=1); the run continues
    ; from bit 0 of the new byte (a00 reseeds the mask)
    .d70 RTS:.by0 STA err
    TXA:ORA (scr),Y:STA (scr),Y
    .ad0 LDA scr:ADC #7:STA scr:BCS ac0
    SEC:JMP a00
    .ac0 INC scr+1:JMP a00
    ; --- left-going blocks: masks &01,&02..&80; scr steps left (mirror of
    ;     the above; block digit still = distance along drawing direction) ---
    .a01 LDA err:LDX #&FF
    .b01 SBC #dy:BCS b11:ADC #dx:STA err
    LDA #1:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e01:.f01 DEY:BPL a11
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a11:DEC scr+1:SEC:BCS a11
    .e01 DEC ls:BEQ d01:LDA err:SBC errs
    STA err:INC cnt:BCS f01
    .d01 RTS

    .a11 LDA err:LDX #&FE
    .b11 SBC #dy:BCS b21:ADC #dx:STA err
    TXA:AND #3:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e11:.f11 DEY:BPL a21
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a21:DEC scr+1:SEC:BCS a21
    .e11 DEC ls:BEQ d11:LDA err:SBC errs
    STA err:INC cnt:BCS f11
    .d11 RTS

    .a21 LDA err:LDX #&FC
    .b21 SBC #dy:BCS b31:ADC #dx:STA err
    TXA:AND #7:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e21:.f21 DEY:BPL a31
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a31:DEC scr+1:SEC:BCS a31
    .e21 DEC ls:BEQ d21:LDA err:SBC errs
    STA err:INC cnt:BCS f21
    .d21 RTS

    .a31 LDA err:LDX #&F8
    .b31 SBC #dy:BCS b41:ADC #dx:STA err
    TXA:AND #&F:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e31:.f31 DEY:BPL a41
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a41:DEC scr+1:SEC:BCS a41
    .e31 DEC ls:BEQ d31:LDA err:SBC errs
    STA err:INC cnt:BCS f31
    .d31 RTS

    .a41 LDA err:LDX #&F0
    .b41 SBC #dy:BCS b51:ADC #dx:STA err
    TXA:AND #&1F:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e41:.f41 DEY:BPL a51
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a51:DEC scr+1:SEC:BCS a51
    .e41 DEC ls:BEQ d41:LDA err:SBC errs
    STA err:INC cnt:BCS f41
    .d41 RTS

    .a51 LDA err:LDX #&E0
    .b51 SBC #dy:BCS b61:ADC #dx:STA err
    TXA:AND #&3F:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e51:.f51 DEY:BPL a61
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a61:DEC scr+1:SEC:BCS a61
    .e51 DEC ls:BEQ d51:LDA err:SBC errs
    STA err:INC cnt:BCS f51
    .d51 RTS

    .a61 LDA err:LDX #&C0
    .b61 SBC #dy:BCS b71:ADC #dx:STA err
    TXA:AND #&7F:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e61:.f61 DEY:BPL a71
    LDA scr
	SBC #LO(SCREEN_WIDTH)
	STA scr:DEC scr+1
    LDY #7:BCS a71:DEC scr+1:SEC:BCS a71
    .e61 DEC ls:BEQ d61:LDA err:SBC errs
    STA err:INC cnt:BCS f61
    .d61 RTS

    ; block 7 of the left core (leftmost pixel, mask &80): continuations
    ; cross into the next byte to the LEFT
    .a71 LDA err:LDX #&80
    .b71 SBC #dy:BCS by1:ADC #dx:STA err
    TXA:ORA (scr),Y:STA (scr),Y
    DEC cnt:BEQ e71:.f71 DEY:BPL sb1        ; y-step: next byte (same rows)
    LDA scr:SBC #LO(SCREEN_WIDTH+8):LDY #7:STA scr      ; combined char-row
    LDA scr+1:SBC #HI(SCREEN_WIDTH+8):STA scr+1:JMP a01 ; wrap + byte left
    .e71 DEC ls:BEQ d71:LDA err:SBC errs
    STA err:INC cnt:BCS f71
    ; by1: no y-step at the byte edge — flush, then sb1 steps scr one byte
    ; left (-8: SBC #8 with C=1) and the run continues at a01 (mask &01)
    .d71 RTS:.by1 STA err
    TXA:ORA (scr),Y:STA (scr),Y
    .sb1 LDA scr:SBC #8:STA scr:BCC sc1
    JMP a01
    .sc1 DEC scr+1:SEC:JMP a01
IF STEEP_COMPACT
    \ ------------------------------------------------------------------
    \ Compact steep (dy > dx): same NJ error protocol as the unrolled
    \ blocks below, but the bit position lives in ZP `b` (single-pixel
    \ mask) instead of 16 unrolled code copies. Pixel-identical.
    \ Invariants (proven from the unrolled code): the loop is entered
    \ with C=1; SBC dx no-borrow keeps C=1 (row-cross path); ADC dy after
    \ a borrow always carries out (err+dy >= dx because dy > dx), so the
    \ x-step path also re-enters with C=1 available via SEC.
    \ ------------------------------------------------------------------
    \ sr_loop — right-going steep core. State: X = running error r,
    \ Y = row within char row, b = single-pixel mask, cnt/ls as per the
    \ protocol. One pixel per iteration, rows bottom-to-top.
    .sr_loop
    LDA b:ORA (scr),Y:STA (scr),Y
    TXA
    .sr_dx SBC #0            \ r -= dx (immediate SMC-patched; C=1 in)
    BCC sr_x                 \ borrow -> column step
    TAX
    DEY:BPL sr_loop          \ same column, row above
    LDY #7:DEC scr+1         \ char-row wrap: up one page
    BCS sr_loop              \ (C=1 preserved: SBC didn't borrow)
    .sr_x
    .sr_dy ADC #0            \ r += dy (SMC); always carries out (dy > dx)
    DEC cnt:BEQ sr_e         \ all dx column steps done -> ls tail
    .sr_n
    TAX
    LSR b                    \ mask one pixel right...
    BCS sr_wrap              \ ...bit fell off the byte -> byte cross
    DEY:BMI sr_row
    SEC:BCS sr_loop          \ (SEC restores the C=1 loop invariant)
    .sr_row
    LDY #7:DEC scr+1         \ char-row wrap after the column step
    SEC:BCS sr_loop
    .sr_wrap
    ROR b                    \ C back into bit 7: mask := &80, C := 0
    LDA scr:ADC #8:STA scr   \ scr one byte right (C=0 -> exact +8)
    BCS sr_hi
    DEY:BMI sr_row
    SEC:BCS sr_loop
    .sr_hi
    INC scr+1                \ +8 crossed a page
    DEY:BMI sr_row
    SEC:BCS sr_loop
    .sr_e
    DEC ls:BEQ sr_d          \ ls 1->0: line complete
    SBC errs                 \ ls 2->1: final half-step test (A = r+dy, C=1)
    INC cnt
    BCS sr_n                 \ no borrow -> exactly one more column
    .sr_d RTS

    \ sl_loop — left-going steep core: exact mirror of sr_loop (mask
    \ shifts left with ASL/ROL, byte cross steps scr -8)
    .sl_loop
    LDA b:ORA (scr),Y:STA (scr),Y
    TXA
    .sl_dx SBC #0            \ r -= dx (SMC)
    BCC sl_x
    TAX
    DEY:BPL sl_loop
    LDY #7:DEC scr+1
    BCS sl_loop
    .sl_x
    .sl_dy ADC #0            \ r += dy (SMC); always carries out
    DEC cnt:BEQ sl_e
    .sl_n
    TAX
    ASL b                    \ mask one pixel left...
    BCS sl_wrap              \ ...bit fell off -> byte cross
    DEY:BMI sl_row
    SEC:BCS sl_loop
    .sl_row
    LDY #7:DEC scr+1
    SEC:BCS sl_loop
    .sl_wrap
    ROL b                    \ C back into bit 0: mask := &01, C := 0
    LDA scr:SBC #7:STA scr   \ scr one byte left (C=0 -> exact -8)
    BCC sl_hi
    DEY:BMI sl_row
    SEC:BCS sl_loop
    .sl_hi
    DEC scr+1                \ -8 crossed a page
    DEY:BMI sl_row
    SEC:BCS sl_loop
    .sl_e
    DEC ls:BEQ sl_d          \ ls tail, as sr_e
    SBC errs
    INC cnt
    BCS sl_n
    .sl_d RTS

    \ stmask[x&7] = single-pixel mask &80>>(x&7)
    .stmask EQUB &80,&40,&20,&10,&08,&04,&02,&01
ELSE
    \ ------------------------------------------------------------------
    \ Original unrolled steep cores (superseded by STEEP_COMPACT above,
    \ kept selectable): one block per bit position, pN2 right-going /
    \ pN3 left-going, same protocol with dx/dy SMC-poked into the aN?/bN?
    \ immediates and entry via strt2/strt3[x0&7]. sN2/sN3 = char-row
    \ wraps; s82/s83 = combined wrap + byte cross at block 7.
    \ ------------------------------------------------------------------
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
ENDIF


    ; entry-point dispatch tables, indexed by x0&7 (8 lo bytes then 8 hi
    ; bytes -> the strtN,Y / strtN+8,Y pairs). strt1/strt3 are listed
    ; reversed so that index 0 (leftmost pixel, mask &80) selects the
    ; &80-mask block of the left-going core, and so on.
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
IF NOT(STEEP_COMPACT)
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
ENDIF
}
