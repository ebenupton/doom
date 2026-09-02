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
eofs=&65                        \ complete frames currently queued in the
                                \ ring (ISR increments at each EOF; the
                                \ main loop decrements per frame consumed)
ffrun=&71                       \ ISR: consecutive-FF run length (EOF detect)
skpd=&72                        \ diagnostics: frames skipped (latency cap)
fields=&73                      \ PAL fields since the last mask the copro
                                \ actually TOOK (see .nk4)
wrl=&66
wrh=&67
rdl=&68
rdh=&69
xcur=&6A                        \ button LEVELS this field (b0 SPACE,
                                \ b1 O) -- the two-byte-mask X byte's
                                \ payload, rebuilt every vsync
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
hudsrc = &88                    \ HUD glyph pointer (above the raster map,
huddst = &8A                    \ and the HUD only runs between frames)
zp_tmp0 = &DE
zp_tmp1 = &DF
zp_tmp2 = &E0
zp_plot_i = &95

INCLUDE "abi_beeb.inc"          \ HUD_FONT_B / HUD_FONT_MASTER
INCLUDE "tube/tube_syms.inc"    \ generated -- for T_TRIPWIRE, so the host's
                                \ debug field is gated by the SAME constant
                                \ the parasite is

HAMILTONIAN_12 = TRUE
STEEP_COMPACT = TRUE
HAMILTONIAN_23 = FALSE

ORG &1900
.start
    JMP realstart
    JMP drawcmd                 \ &1903: py65 pipeline-gate entry
.realstart
    JSR hudprobe                \ while the OS is still alive
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
    LDA #0                      \ FIFO ring $3000-$3FFF empty
    STA eofs
    STA ffrun
    STA skpd
    STA wrl
    STA rdl
    LDA #&30
    STA wrh
    STA rdh
    LDA #LO(irq)
    STA &204
    LDA #HI(irq)
    STA &205
    LDA &FE4B                   \ ACR: T1 continuous, PB7 off
    AND #&3F
    ORA #&40
    STA &FE4B
    LDA #&E8                    \ T1 = 1000us: the ISR FIFO-drain tick —
    STA &FE46                   \ the host must never leave the copro
    LDA #&03                    \ blocked on a full FIFO while it clears
    STA &FE47                   \ or draws (Eben: unload in the ISR)
    STA &FE45                   \ start T1 (write hi counter)
    LDA #&42                    \ clear stale vsync + T1
    STA &FE4D
    LDA #&C2                    \ enable CA1 + T1
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
    CMP #&FE                    \ FE FE FE FE = the copro's HUD packet.
    BEQ hudpkt                  \ A real line cannot AND to FE: that needs
                                \ every byte in {FE,FF} and y is < 160.
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
.hudpkt
    LDX #0
.hp1
    JSR rd
    STA hudb,X
    INX
    CPX #12
    BNE hp1
    JMP main
.eof
    JSR hudglue                 \ onto the buffer just rendered, before the
                                \ swap hands it to the presenter
    SEI                         \ one complete frame consumed
    DEC eofs
    CLI
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
\ ---- SKIP-AHEAD (latency cap): while at least TWO complete frames sit
\ in the ring, the next one is already stale — consume it tuple-aligned
\ (an x-byte can be FF, so byte-hunting can misalign; the 4-tuple test
\ is exact) without drawing, and re-check. The frame that finally gets
\ drawn is always the NEWEST complete one; the partial behind it
\ streams normally.
.skipchk
    SEI
    LDA eofs
    CLI
    CMP #2
    BCS skipfrm
    JMP main
.skipfrm
    JSR rd
    STA x0
    JSR rd
    STA y0
    JSR rd
    STA x1
    JSR rd
    STA y1
    LDA x0
    AND y0
    AND x1
    AND y1
    CMP #&FF
    BNE skipfrm
    SEI
    DEC eofs
    CLI
    INC skpd                    \ diagnostics: skipped-frame counter
    JMP skipchk
.rd
    LDA rdl                     \ ring empty? (ISR only appends: a stale
    CMP wrl                     \ read of wr just looks briefly empty)
    BNE rdhave
    LDA rdh
    CMP wrh
    BEQ rd
.rdhave
    STY &6D
    LDY #0
    LDA (rdl),Y
    LDY &6D
    INC rdl
    BNE rdok
    PHA
    LDA rdh
    CLC
    ADC #1
    AND #&0F
    ORA #&30
    STA rdh
    PLA
.rdok
    RTS
.irq
    TXA
    PHA
    TYA
    PHA
\ drain the Tube FIFO into the ring FIRST, on EVERY interrupt (T1 tick
\ or vsync): the copro must never block on a full FIFO while the main
\ loop is busy clearing/drawing. Bounded at 48 bytes per entry.
    LDX #48
    LDY #0
.dr1
    LDA &FEE0
    BPL drdone
    LDA &FEE1
    STA (wrl),Y
    CMP #&FF                    \ EOF tally: y-bytes are <160 except in
    BEQ drff                    \ the FF,FF,FF,FF marker, so a run of 4
    LDA #0                      \ consecutive FFs IS an EOF (an x-byte FF
    STA ffrun                   \ can extend a run to 5+ but never fake 4)
    BEQ drnf                    \ (always)
.drff
    INC ffrun
    LDA ffrun
    CMP #4
    BNE drnf
    INC eofs                    \ a complete frame is now fully queued
    LDA #0
    STA ffrun
.drnf
    INC wrl
    BNE drnext
    LDA wrh
    CLC
    ADC #1
    AND #&0F
    ORA #&30
    STA wrh
.drnext
    DEX
    BNE dr1
.drdone
    LDA &FE4D                   \ T1 tick? clear by reading T1CL
    AND #&40
    BEQ notick
    LDA &FE44
.notick
    LDA &FE4D
    AND #2
    BNE isvsync                 \ (trampoline: the field-count block below
    JMP ipop                    \  pushed ipop out of branch range)
.isvsync                        \ no vsync: drain-only entry
    STA &FE4D
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
    LDA #0                      \ button levels: rebuilt each vsync,
    STA xcur                    \ shipped only on CHANGE (see .nk5)
    LDA #&62                    \ SPACE -> X-byte b0: DOOM 'use'.  Without
    STA &FE4F                   \ it the map's DR doors never open on the
    BIT &FE4F                   \ copro (anim_sectors keeps them "shut
    BPL nksp                    \ until used"); the lifts self-cycle,
    LDA xcur                    \ which is why only the DOORS looked
    ORA #1                      \ frozen.
    STA xcur
.nksp
    LDA #&36                    \ O -> X-byte b1: billboard objects toggle
    STA &FE4F                   \ (the copro edge-detects the level and
    BIT &FE4F                   \ JSRs the engine's ok_flip)
    BPL nko
    LDA xcur
    ORA #2
    STA xcur
.nko
    LDA #&54                    \ H: toggle the HUD on the PRESS EDGE only,
    STA &FE4F                   \ so holding it flips exactly once (same
    BIT &FE4F                   \ internal code and debounce as walk_drv)
    BPL hudup
    LDA hudprev
    BNE hudkdone
    LDA #1
    STA hudprev
    LDA huden
    EOR #1
    STA huden
    JMP hudkdone
.hudup
    LDA #0
    STA hudprev
.hudkdone
\ The mask byte carries the ELAPSED FIELD COUNT in its high nibble.
\ R1 host->parasite is ONE BYTE, not a FIFO: at most one mask is ever in
\ flight, so the copro cannot recover elapsed time by counting the masks
\ it drains -- it always finds exactly one, and moves a single field's
\ worth per RENDERED frame, i.e. slower in exact proportion to the frame
\ rate.  Counting here is free: this is already the vsync arm of the ISR
\ (the T1 drain tick exits at ipop above, so ticks are NOT counted).
\ The count is fields since the copro last TOOK a byte, so a still-full
\ register just keeps accumulating.
\ b7 IS THE TAG BIT (0 = movement byte; SPACE moved to the X byte with
\ the 2026-09-02 two-byte mask), so the count has THREE bits and
\ saturates at 7, not 15.
\ That is a real trade and worth stating: the count only exceeds 1 while
\ the copro is behind, and 7 fields is 140 ms -- below about 7 fps the
\ count clips and motion slows, exactly as it already does past the
\ copro's own cap of 32.  At the 19 fps recorded for the port in 32f9e35
\ that is ~2.6 fields a frame -- better than 2x headroom -- but that
\ figure predates the billboards and is NOT a fresh measurement of this
\ build.  If the copro ever drops near 7 fps, widen this before believing
\ the motion.
    LDA fields
    CMP #7
    BCS nk5
    INC fields
.nk5
\ TWO-BYTE MASK (2026-09-02): the R1 latch is 1-deep, so bytes are
\ TAGGED (b7=0 movement / b7=1 buttons) and buttons ship only when a
\ level CHANGES -- the movement stream keeps its one-per-field rate
\ and nothing ever blocks.  A pending button byte takes priority; the
\ movement byte it displaces just accumulates its field into the next
\ one (same non-blocking contract as the old still-full case).
    LDA &FEE0                   \ room in the h->c latch?
    AND #&40
    BEQ nosend
    LDA xcur
    ORA #&80                    \ the X byte as it would ship
    CMP xsent
    BEQ sendm                   \ unchanged: send movement instead
    STA &FEE1                   \ changed: ship the button byte
    STA xsent
    JMP nosend                  \ (fields keep accumulating)
.sendm
    LDA fields
    ASL A
    ASL A
    ASL A
    ASL A
    ORA mask                    \ b0-3 = keys, b4-6 = elapsed fields, b7=0
    STA &FEE1
    LDA #0
    STA fields                  \ only on a SUCCESSFUL hand-off
.nosend
.ipop
    PLA
    TAY
    PLA
    TAX
    LDA &FC
    RTI
\ ---- MOS font base -----------------------------------------------------
\ The 96 glyphs (chars 32..127, 8 bytes each) are contiguous but NOT at a
\ fixed address: OS 1.2 keeps them at &C000, MOS 3.20 at &F900. Reading
\ &C000 on a Master gets MOS code, which is how the HUD came out as
\ garbage there.
\ So ask the OS which machine this is, ONCE, at entry -- the only moment
\ it can be asked, since SEI goes down immediately after and nothing
\ calls the OS again. OSBYTE 129 with Y=&FF is "read OS version"; with
\ any other Y it is INKEY and would WAIT for a key.
.hudprobe
    LDA #&81
    LDX #0
    LDY #&FF
    JSR &FFF4                   \ X = OS version
    LDA #LO(HUD_FONT_B)
    LDY #HI(HUD_FONT_B)
    \ measured on jsbeeb (622ad83): Master 128 = &FD, jsbeeb B = &FF;
    \ [&F0,&FE] is the Master/ANDY family, everything else the &C000 font
    CPX #&F0
    BCC hpset                   \ 0-2, &E0 Electron... = &C000 classes
    CPX #&FF
    BEQ hpset                   \ &FF = OS 0.10 / jsbeeb B
    LDA #LO(HUD_FONT_MASTER)
    LDY #HI(HUD_FONT_MASTER)
.hpset
    STA hudbase
    STY hudbase+1
    LDA &F4                     \ the OS's ROMSEL copy, taken while it is
    STA hudrom                  \ still alive: what to page BACK after ANDY
    RTS


\ ---- debug HUD (H toggles) --------------------------------------------
\ "X=hhhh.hh Y=hhhh.hh R=hh" on the top character row, exactly what the
\ banked build's src/hud.s shows -- but drawn HERE, because the copro has
\ neither a framebuffer nor the OS font.  Mode 4 makes it a straight copy:
\ a row-0 cell is 8 CONSECUTIVE bytes at buf + col*8, and an OS glyph is 8
\ consecutive bytes at &C000 + (ascii-32)*8.  24 cells * 8 = 192 < 256, so
\ the destination low byte never leaves the buffer's first page.
\ Payload (tuple-padded on the wire): 0 angidx, 1 xf, 2 xl, 4 xh,
\ 5 yf, 6 yl, 8 yh.
.hudglue
    LDA huden
    BNE hgon
    RTS
.hgon
    LDA hudbase+1               \ set by hudprobe at entry; 0 only if the
    BNE hgdraw                  \ probe never ran (py65 harnesses)
    RTS
.hgdraw
    \ The Master keeps its CURRENT character definitions in ANDY
    \ ($8900-$8FFF), paged over $8000-$8FFF by ROMSEL bit 7 -- its font is
    \ NOT in the MOS ROM.  This host runs from main RAM and calls no ROM,
    \ so ANDY can stay in for the draw; hgpg restores the OS's bank after.
    \ A $C000 base is MOS ROM on a Model B and needs no paging.
    LDA hudbase+1
    CMP #HI(HUD_FONT_B)
    BCS hgnopg
    LDA hudrom
    ORA #&80
    STA &FE30
.hgnopg
    LDA #0
    STA huddst
    LDX draw                    \ the buffer this frame was drawn into
    LDA bufhi,X
    STA huddst+1
    LDA #'X' : JSR hudchar
    LDA #'=' : JSR hudchar
    LDA hudb+4 : JSR hudhex     \ x int hi
    LDA hudb+2 : JSR hudhex     \ x int lo
    LDA #'.' : JSR hudchar
    LDA hudb+1 : JSR hudhex     \ x frac
    LDA #' ' : JSR hudchar
    LDA #'Y' : JSR hudchar
    LDA #'=' : JSR hudchar
    LDA hudb+8 : JSR hudhex
    LDA hudb+6 : JSR hudhex
    LDA #'.' : JSR hudchar
    LDA hudb+5 : JSR hudhex
    LDA #' ' : JSR hudchar
    LDA #'R' : JSR hudchar
    LDA #'=' : JSR hudchar
    LDA hudb+0
    ASL A
    ASL A                       \ angle byte = angidx*4, as src/hud.s
    JSR hudhex
    LDA #' ' : JSR hudchar      \ F = PAL fields the last frame consumed,
    LDA #'F' : JSR hudchar      \ i.e. how many 1/50ths that frame cost --
    LDA #'=' : JSR hudchar      \ the copro's own frame-rate readout
    LDA hudb+10
    JSR hudhex
IF T_TRIPWIRE
    LDA #' ' : JSR hudchar      \ TRIPWIRE latch: the id of the EARLIEST
    LDA #'T' : JSR hudchar      \ checkpoint that saw the watched byte
    LDA #'=' : JSR hudchar      \ corrupted. 00 = nothing has tripped.
    LDA hudb+9
    JSR hudhex
ENDIF
    LDA hudbase+1               \ un-page ANDY if we paged it
    CMP #HI(HUD_FONT_B)
    BCS hgret
    LDA hudrom
    STA &FE30
.hgret
    RTS
.hudhex                         \ A = byte -> two hex cells
    PHA
    LSR A
    LSR A
    LSR A
    LSR A
    TAX
    LDA hexdig,X
    JSR hudchar
    PLA
    AND #&0F
    TAX
    LDA hexdig,X
.hudchar                        \ A = ascii -> blit the glyph, advance a cell
    SEC
    SBC #32                     \ src = hudbase + (A-32)*8; (A-32) < 96, so
    STA hudt                    \ the product is 11 bits and needs both ends
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    STA hudt+1                  \ hi = (A-32) >> 5
    LDA hudt
    ASL A
    ASL A
    ASL A                       \ lo = ((A-32) << 3) & 255
    CLC
    ADC hudbase
    STA hudsrc
    LDA hudt+1
    ADC hudbase+1               \ + the carry out of the low add
    STA hudsrc+1
    LDY #7
.hcrow
    LDA (hudsrc),Y
    STA (huddst),Y
    DEY
    BPL hcrow
    CLC
    LDA huddst
    ADC #8
    STA huddst
    RTS
.hexdig
    EQUS "0123456789ABCDEF"
.hudrom
    EQUB 0                      \ ROMSEL value the OS was using at boot
.hudbase
    EQUW 0                      \ found font base; &FFxx = searched, none
.hudt
    EQUW 0                      \ hudchar scratch
.huden
    EQUB 0
.hudprev
    EQUB 0
.xsent
    EQUB 0                      \ last button byte shipped; starts 0 (an
                                \ impossible X byte -- b7 set on the wire)
                                \ so the FIRST vsync ships the ground
                                \ state (&80 all-released) unprompted
.hudb
    EQUD 0 : EQUD 0 : EQUD 0
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
    STA (ptr),Y
    INY
    STA (ptr),Y
    INY
    STA (ptr),Y
    INY
    STA (ptr),Y
    INY
    STA (ptr),Y
    INY
    STA (ptr),Y
    INY
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
