\ emit.asm — parasite-side line-command emitters, ORG &7500 (flat
\ RASTER_ENTRY since the 2026-08-09 cache-region map — the OR blob's
\ home: the copro build loads THIS instead of linedraw_or_reloc.bin,
\ so dcl's des_diag "JMP RASTER_ENTRY" lands on the diagonal emitter
\ with no engine change at all; plot_h/plot_v's entry bytes are poked
\ to JMP &7510/&7520 by build_tube_game.py — the only two patches
\ distinguishing the parasite image from the flat build).
\
\ Each emitter sends exactly the operands its plotter would consume,
\ which sidesteps every "is $84/$85 actually stored on this path"
\ question: dcl's horizontal path may leave y1 only in A, its vertical
\ path may leave x1 unstored — so the h-emitter sends y0 twice and the
\ v-emitter sends x0 twice. The host re-derives the same h/v/diagonal
\ routing from the equalities, so the SAME plot routines run there.
INCLUDE "tube/tube_syms.inc"    \ generated: the raster ZP slots
R1S=&FEF8
R1D=&FEF9
\ The line operands: GENERATED, not literal.  These were &82..&85 -- the
\ rasteriser's zero-page slots as of whenever this file was written.  Zero
\ page is linker-allocated and rotated, so a literal here is a copy of a
\ fact that nothing keeps true.
X0=T_RZP_X0
Y0=T_RZP_Y0
X1=T_RZP_X1
Y1=T_RZP_Y1
ORG &7500
.entry_diag                     \ = RASTER_ENTRY (des_diag JMPs here)
    JMP diag
.pad1
FOR n, 1, &7510 - pad1
    EQUB 0
NEXT
.entry_h                        \ plot_h's poked JMP lands here
    JMP ph
.pad2
FOR n, 1, &7520 - pad2
    EQUB 0
NEXT
.entry_v                        \ plot_v's poked JMP lands here
.pv
    LDA X0
    JSR send1
    LDA Y0
    JSR send1
    LDA X0
    JSR send1
    LDA Y1
    JMP send1                   \ tail: RTS returns to dcl
.diag
    LDA X0
    JSR send1
    LDA Y0
    JSR send1
    LDA X1
    JSR send1
    LDA Y1
    JMP send1
.ph
    LDA X0
    JSR send1
    LDA Y0
    JSR send1
    LDA X1
    JSR send1
    LDA Y0
.send1
    BIT R1S                     \ V = space in the parasite->host FIFO
    BVC send1
    STA R1D
    RTS
.end
SAVE "EMIT", entry_diag, end
