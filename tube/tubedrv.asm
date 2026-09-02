\ tubedrv.asm — the COPRO-side game driver (parasite &0800, DFS name
\ COPROT on the game disc). walk_drv's soul with the hardware removed:
\ no CRTC, no vsync clock, no keyboard matrix, no banking — the key
\ mask arrives over the Tube (one byte per displayed frame, which IS
\ the frame pacing) and every drawn line leaves over the Tube via the
\ emitters at &A900 (see emit.asm).
\
\ Boot: OSCLI-*LOADs the engine/data files across the Tube (the
\ parasite OS + host DFS do the byte shuffling), then sends RUN HOSTT
\ raw over R2 (no reply wait — the host program never returns to the
\ Tube service loop) and drops into init + the frame loop.
\
\ Movement/tables (step_fwd/back, bounds, derive_raw, floor_vz,
\ step_tab, floor grid) are transplanted VERBATIM from walk_drv.asm —
\ same ZP contract with the engine ($00-$0A, $90-$93, $9D/$9E, BCA_AB).
INCLUDE "tube/tube_syms.inc"    \ generated: flat engine addresses + spawn

\ TRIPWIRE (debug): id must be NON-ZERO. Transparent -- A, X, Y and the
\ flags all survive, so a checkpoint can go anywhere. FIRST WRITER WINS,
\ so the surviving id names the EARLIEST phase that saw the corruption.
MACRO TW id
IF T_TRIPWIRE
    PHP
    PHA
    LDA #id
    JSR T_TW_CHECK
    PLA
    PLP
ENDIF
ENDMACRO

R1S=&FEF8
R1D=&FEF9
R2S=&FEFA
R2D=&FEFB
OSCLI=&FFF7                     \ parasite OS (alive until RUN HOSTT)

SPEED = 12                      \ world units per frame (walk_drv)
RAWX_MIN = &F870                \ -1936 as u16
RAWX_MAX = &0A10                \  2576
RAWY_MIN = &F9D2                \ -1582
RAWY_MAX = &0492                \  1170

\ Driver variables live as ABSOLUTES in this image (not ZP): the copro
\ shares its zero page with the whole flat engine, and $63/$64 are the
\ zp_bv_entry vector — a driver var there would be a wild indirect JMP.
\ Access count is ~30/frame; absolute vs zp is noise on a 3MHz copro.
ORG &7800                       \ THE GLUE GAP (parasite re-cut 2026-09-02):
                                \ the copro image ships CODE $0F00-$77FF +
                                \ this COPROT $7800-$7BFF + DATA $7C00-$F7FF,
                                \ so COPROT rides a static hole its OWN
                                \ CODE/DATA loads never touch (the old $EA00
                                \ FB-region trick, relocated -- there is no
                                \ FB gap under the parasite map).  571 B of
                                \ genuine tube glue; movement/tables all live
                                \ in the engine image now (Eben: the only
                                \ tube-specific code is the Tube-ULA driver)
    JMP boot
    JMP init                    \ &F03: harness entry — py65 runs the
                                \ driver with loads pre-applied (no OSCLI)
.mask
    EQUB 0
.fields
    EQUB 0                      \ PAL fields since the last rendered frame
.spraw
    EQUB 0                      \ SPACE, STICKY across a multi-mask drain:
                                \ a press must never be lost to a burst
.space_prev
    EQUB 0                      \ press-edge state, as walk_drv's
                                \ (masks drained), pm_frame's A argument.
                                \ The pose lives in DV_* now -- pm_frame
                                \ reads and writes it there.
.boot
    SEI
    LDX #&DF                    \ STACK CAP (2026-08-23): SQR_MIRROR owns
    TXS                         \ $01E0-$01FF since the sqr swap (15ba65c)
                                \ made the quad boot-GENERATED with a mirror
                                \ prefix in the stack page.  walk_drv caps
                                \ the stack for exactly this reason; the
                                \ parasite never did, so its stack started
                                \ at $FF and the mirror overwrote the JSR
                                \ OSCLI return addresses in .boot's load
                                \ sequence -- the copro disappeared into the
                                \ tube MOS and never came back, so HOSTT was
                                \ never RUN and the screen stayed black.
    LDA #0                      \ REAL-HW hardening: the engine's runtime
    STA T_ZP_CLRP                     \ arenas ($0400-$19FF: pool/records/
    LDA #4                      \ scratch/bitmap page/cache planes)
    LDY #0                      \ assume the py65-zeros ground state;
    STA T_ZP_CLRP+1                     \ parasite RAM is only zeroed by luck on
    TYA                         \ emulators. Zero them BEFORE the loads.
.pz1                            \ STOP at $1A00: the sqr quad rides the
    STA (T_ZP_CLRP),Y                 \ CODE file from $1A00 (f34f835 map) —
    INY                         \ the old #&1B bound wiped its first page.
    BNE pz1
    INC T_ZP_CLRP+1
    LDX T_ZP_CLRP+1
    CPX #&1A
    BNE pz1
    LDA #HI(T_CPM_KDXH)         \ CPM memo page (symbol-driven since the
    STA T_ZP_CLRP+1                     \ 2026-08-14 pmove arc moved flat CPM to
    LDA #0                      \ $2900); init $80-fills KDXH on top
.pz2
    STA (T_ZP_CLRP),Y
    INY
    BNE pz2
    LDX #0                      \ *LOAD every engine/data file: strings
.ldloop                         \ are CR-terminated, list ends with 0
    LDA loads,X
    BEQ ldone
    TXA
    PHA
    CLC
    ADC #LO(loads)
    TAX
    LDA #0
    ADC #HI(loads)
    TAY
    CLI                         \ parasite OS needs its IRQs for R4
    JSR OSCLI
    SEI
    PLA
    TAX
.skip
    INX                         \ advance past this string's CR
    LDA loads,X
    CMP #13
    BNE skip
    INX
    JMP ldloop
.ldone
    LDX #0                      \ raw R2 OSCLI: RUN HOSTT (id 2 + string,
.cli                            \ NO reply wait — host never comes back)
    LDA runcmd,X
    BEQ cdone
.cw
    BIT R2S
    BVC cw
    STA R2D
    INX
    BNE cli
.cdone
.init
\ ---- REAL-HW hardening, part 2: ZERO PAGE (2026-08-23) ----
\ boot already zeroes the runtime arenas ($0400-$19FF) because parasite
\ RAM is only zeroed by luck; zero page was never covered, and it
\ arrives holding tube MOS workspace.  The engine READS ZP bytes it
\ never writes and relies on them being 0 -- tools/zpvirgin.py lists
\ them.  The one that kills the port is plotq_mode ($A1): dcl.s's
\ contract is "Harness/default: plotq_mode = 0 -- everything draws
\ direct", and walk_drv establishes it on the host (it writes &A1 in
\ flip_sched) but NOTHING on the parasite ever does.  With bit 7 set by
\ chance, every line is enqueued into PLOTQ instead of drawn, and the
\ Tube port has no drain because the rasteriser is exactly what it
\ removed -- so the screen stays blank forever.  plotq_n, zp_dcl_out
\ and TFS_PEND_ACT are consumers of the same ground state.
\ Clearing to 0 reproduces the py65 image every harness validates
\ against.  Safe here: the parasite OS is finished (SEI is held since
\ the last OSCLI), driver variables live as absolutes at &EA00, and
\ init is entered exactly twice -- boot falls in, and &F03 is the
\ harness entry, so the harness exercises this too.
    LDA #0
    TAX
.zpclr
    STA &00,X
    INX
    BNE zpclr
\ ---- engine state init (walk_drv's rcinit block, flat addresses) ----
                                \ (A = 0, X = 0 still — rides into rcinit)
.rcinit
    STA T_RCACHE_STATE,X
    INX
    CPX #T_RCACHE_LEN
    BNE rcinit
    LDX #0
.vxinit
    STA T_VXCACHE_STATE,X           \ whole bitmap page (VALID+VDONE+
    INX                         \ VXCACHE_VALID+RCACHE_COMPUTED)
    BNE vxinit
    LDA #1
    STA T_VXCACHE_ENABLE
    LDA #1                      \ animated sectors (doors/lifts): engine
    STA T_ANIM_ENABLE           \ anim, no driver glue needed on the
    JSR T_ANIM_INIT             \ copro (flat build: no banking)
    LDA #1                      \ forward-coherence bbox cache (dbox):
    STA T_D_ENABLE              \ the engine classifies frames itself,
                                \ the driver just asserts D_FWD below
\ CPM sentinel: the KDXH validity plane is $80-filled ($80 = impossible
\ dx hi) — initialized HERE now (the cache block is never loaded)
    LDA #&80
    LDX #&7F
.cpms
    STA T_CPM_KDXH,X
    DEX
    BPL cpms
    LDA #LO(T_TAIL_POSTRC)      \ frame-class vectors: moving targets
    STA T_ZP_TAIL_VEC
    LDA #HI(T_TAIL_POSTRC)
    STA T_ZP_TAIL_VEC+1
    LDA #LO(T_BOX_CLASSIFY)
    STA T_ZP_BV_ENTRY
    LDA #HI(T_BOX_CLASSIFY)
    STA T_ZP_BV_ENTRY+1
\ ---- spawn state (constants from tube_syms.inc) ----
\ Spawn lands in pm_frame's DRIVER-VARIABLE CONTRACT (DV_*, abi $1B80):
\ the engine reads AND writes those, so the driver no longer keeps its
\ own copy of the pose.
    LDA #SPAWN_ANGIDX
    STA T_DV_ANGIDX
    LDA #SPAWN_PXF
    STA T_DV_PXF
    LDA #SPAWN_PXL
    STA T_DV_PXL
    LDA #SPAWN_PXH
    STA T_DV_PXH
    LDA #SPAWN_PYF
    STA T_DV_PYF
    LDA #SPAWN_PYL
    STA T_DV_PYL
    LDA #SPAWN_PYH
    STA T_DV_PYH
    LDA #SPAWN_VZ
    STA T_PM_VZ                 \ pm_frame/pmove_zonly own vz
    STA T_ZP_VZ                 \ engine ZP eye height for frame 1
    LDA #0
    STA T_PM_TURNREM            \ no carried sub-step rotation
.rdrain
    BIT R1S                     \ eat stale host->parasite R1 bytes (the
    BPL rdone                   \ Tube OS uses R1 for escape/event
    LDA R1D                     \ notifications during the load phase —
    JMP rdrain                  \ one of those cost us an angle step)
.rdone
\ ---------------------------------------------------------------------
\ frame loop — paced by the host's one-mask-per-vsync
\ ---------------------------------------------------------------------
.frame
.wm
    BIT R1S                     \ N = key mask waiting
    BPL wm
    LDA #0
    STA fields
    STA spraw
.mloop
    LDA R1D
    TAX                         \ b0-3 = keys, b4-6 = elapsed PAL fields,
    AND #&0F                    \ b7 = SPACE (HOSTT packs the count because
    STA mask                    \ R1 host->parasite is ONE BYTE, not a
    TXA                         \ FIFO -- draining masks could never
    AND #&80                    \ measure elapsed time, it would always
    ORA spraw                   \ find exactly one)
    STA spraw
    TXA
    AND #&70
    LSR A
    LSR A
    LSR A
    LSR A
    CLC
    ADC fields                  \ sum, in case more than one arrives
    CMP #33
    BCC mnocount
    LDA #32                     \ pm_frame's ABI caps fields at 32
.mnocount
    STA fields
    BIT R1S                     \ drain every queued mask: the host sends
    BMI mloop                   \ exactly one per DISPLAYED field, so the
                                \ count IS the elapsed field count -- the
                                \ copro's field clock, standing in for
                                \ walk_drv's T1/T2 pair.  Draining also
                                \ keeps input realtime when the render
                                \ runs behind vsync.
\ ---- DOOM movement: same engine entry the host uses --------------------
\ pm_frame owns ROTATION, position, P_TryMove box collision, wall slide
\ and D_FWD, and scales both the walk and the turn by the field count --
\ so neither changes with the frame rate.  The parasite's old step_fwd /
\ step_back / bounds_or_revert did a fixed step per mask and a plain
\ rectangle clamp: no collision, no slide, and a speed that tracked the
\ frame rate.  (No bank paging here: the copro runs the FLAT engine.)
    TW 1                        \ frame start, before any engine work
    LDA fields
    LDX mask                    \ b0 fwd b1 back b2 left b3 right -- the
    JSR T_PM_FRAME              \ mask bit order IS walk_drv's mv_in order
    TW 2                        \ after pm_frame (rotation + position)
\ ---- SPACE: DOOM 'use' on the PRESS EDGE (doors) -----------------------
\ Every DR door on the map is "shut until used" (anim_sectors), so with no
\ use path the copro's doors could never open -- the lifts self-cycle,
\ which is exactly why only the DOORS looked frozen while anim_tick,
\ anim_hub and the mover state machine were all provably running.
\ Must come AFTER pm_frame: $90-$93 are its exit contract and pmove_use
\ traces from them.  (No bank paging: the copro runs the FLAT engine, so
\ walk_drv's PAGE BANK_C around USEVEC has no counterpart here.)
    LDA spraw
    BEQ spclr
    LDA space_prev
    BNE spdone
    LDA #1
    STA space_prev
    LDA T_DV_ANGIDX             \ USEVEC entry = 4 bytes (ux,uy s16 raw)
    ASL A
    ASL A
    TAX
    LDY #0
.spuv
    LDA T_USEVEC,X
    STA T_PM_UX,Y
    INX
    INY
    CPY #4
    BNE spuv
    JSR T_PMOVE_USE
    JMP spdone
.spclr
    STA space_prev              \ A = 0 here
.spdone
    TW 3                        \ after the SPACE use / door sense
\ ---- pose -> engine ZP (pm_frame wrote DV_* and the $90-$93 raws) ------
    LDA T_DV_PXF
    STA T_ZP_PX
    LDA T_DV_PXL
    STA T_ZP_PXH
    LDA T_DV_PXH
    STA T_ZP_PXX
    LDA T_DV_PYF
    STA T_ZP_PY
    LDA T_DV_PYL
    STA T_ZP_PYH
    LDA T_DV_PYH
    STA T_ZP_PYX
    TW 4                        \ after the pose copy to engine ZP
    JSR T_PMOVE_ZONLY           \ DOOM z: rides live lifts (walk_drv's
    LDA T_PM_VZ                 \ mv_reval).  derive_raw is gone: the
    STA T_ZP_VZ                 \ $90-$93 raws are pm_frame's exit contract
\ sincos <- sctab[angidx].  The pointer rides T_ZP_CLRP (the boot clear
\ pointer's pair) rather than a hand-picked &EC/&ED: those two were an
\ unregistered squat on whatever the engine keeps there, and the pair is
\ asserted adjacent-and-in-zero-page by build_tube_game.  Safe to share:
\ this runs before view_setup, and the clipper rewrites the pair.
    LDA T_DV_ANGIDX             \ sincos <- table[angidx] (entry = 8 bytes)
    ASL A
    ASL A
    ASL A
    STA T_ZP_CLRP
    LDA #0
    ROL A
    CLC
    ADC #HI(T_DRV_SINCOS)       \ the ENGINE's driver sincos ($7E00, seeded
    STA T_ZP_CLRP+1             \ by the image builder) -- no duplicate table
    LDY #0
    LDA (T_ZP_CLRP),Y
    STA T_ZP_SMAG
    INY
    LDA (T_ZP_CLRP),Y
    STA T_ZP_SNEG
    INY
    LDA (T_ZP_CLRP),Y
    STA T_ZP_SONE
    INY
    LDA (T_ZP_CLRP),Y
    STA T_ZP_CMAG
    INY
    LDA (T_ZP_CLRP),Y
    STA T_ZP_CNEG
    INY
    LDA (T_ZP_CLRP),Y
    STA T_ZP_CONE
    INY
    LDA (T_ZP_CLRP),Y
    STA T_BCA_AB                \ view angle byte
    TW 5                        \ after pmove_zonly + the sincos copy
    LDA fields                  \ summed mask-drain field count -> the
    STA T_ANIM_FIELDS           \ FIELD-SCALED tick (2026-08-25)
    JSR T_ANIM_TICK             \ advance door/lift movers
    TW 6                        \ after anim_tick
    JSR T_VIEW_SETUP            \ br_view_setup (flat: no banking)
    TW 7                        \ after view_setup
    JSR T_SPAN_INIT             \ span_init / pool
    TW 8                        \ after span_init
    JSR T_RENDER_FRAME          \ lines leave via the &A900 emitters
    TW 9                        \ after render_frame -- THE big phase
\ ---- HUD packet: FE FE FE FE + 12 payload bytes -----------------------
\ The HOST draws the HUD, not the copro: the parasite has no framebuffer
\ and no OS font ($C000 is its own DATA span), so it just ships its pose
\ every frame and the H toggle lives host-side.  That also dodges the
\ mask byte being full -- 4 keys + 3 field bits + SPACE, no room for an
\ H bit.
\ FE FE FE FE cannot collide with geometry (a real y byte is < 160).
\ EVERY payload tuple ends in 00, which does two jobs: it keeps the
\ packet 4-TUPLE ALIGNED so the host's skip-ahead parser stays in step,
\ and it breaks any run of FFs in the position bytes -- x = -1/256 would
\ otherwise put four consecutive FFs on the wire and fake the ISR's
\ 4-consecutive-FF end-of-frame marker.
    LDX #4
.hudmk
    LDA #&FE
    JSR send1
    DEX
    BNE hudmk
    LDA T_DV_ANGIDX : JSR send1
    LDA T_DV_PXF    : JSR send1
    LDA T_DV_PXL    : JSR send1
    LDA #0          : JSR send1
    LDA T_DV_PXH    : JSR send1
    LDA T_DV_PYF    : JSR send1
    LDA T_DV_PYL    : JSR send1
    LDA #0          : JSR send1
    LDA T_DV_PYH    : JSR send1
IF T_TRIPWIRE
    LDA T_ZP_TW                     \ TRIPWIRE latch -> the HUD's T= field
ELSE
    LDA #0
ENDIF
    JSR send1
    LDA fields      : JSR send1     \ PAL fields this frame -> the HUD's F=
    LDA #0          : JSR send1
    LDA #&FF                    \ end of frame
    JSR send1
    LDA #&FF
    JSR send1
    LDA #&FF
    JSR send1
    LDA #&FF
    JSR send1
    JMP frame
.send1
    BIT R1S
    BVC send1
    STA R1D
    RTS
\ (The old movement block -- step_fwd/step_back, bounds_or_revert and
\ their derive_raw/floor_vz helpers, 223 lines transplanted from an
\ early walk_drv -- was DELETED 2026-08-23.  It stepped a fixed
\ distance per mask (so speed tracked the frame rate) and clamped the
\ player to a rectangle instead of colliding with the map.  The copro
\ now calls the engine's pm_frame, exactly as the host does.)

\ ---- command strings ----
.runcmd
    EQUB 2
    EQUS "RUN HOSTT"
    EQUB 13
    EQUB 0
.loads
INCLUDE "tube/tube_loads.inc"   \ generated: EQUS "LOAD En":EQUB 13 ... EQUB 0
.drvend
ASSERT drvend <= &7B00          \ glue $7800-$7AFF; emit at $7B00 below

\ ---- line-command emitters (folded in from emit.asm 2026-09-02) ----
\ RASTER_ENTRY / plot_h / plot_v are RTS stubs in the flat engine; the
\ image builder pokes them to JMP entry_diag/entry_h/entry_v here.  Each
\ emitter sends exactly the operands its plotter consumes (the host
\ re-derives h/v/diag routing from the equalities), sidestepping every
\ "is this operand actually stored on this path" question.
SKIPTO &7B00
.entry_diag                     \ = RASTER_ENTRY target (des_diag JMPs here)
    JMP ediag
    EQUB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0    \ pad to $7B10
.entry_h                        \ plot_h's poked JMP lands here
    JMP eph
    EQUB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0    \ pad to $7B20
.entry_v                        \ plot_v's poked JMP lands here
    LDA T_RZP_X0
    JSR esend1
    LDA T_RZP_Y0
    JSR esend1
    LDA T_RZP_X0
    JSR esend1
    LDA T_RZP_Y1
    JMP esend1
.ediag
    LDA T_RZP_X0
    JSR esend1
    LDA T_RZP_Y0
    JSR esend1
    LDA T_RZP_X1
    JSR esend1
    LDA T_RZP_Y1
    JMP esend1
.eph
    LDA T_RZP_X0
    JSR esend1
    LDA T_RZP_Y0
    JSR esend1
    LDA T_RZP_X1
    JSR esend1
    LDA T_RZP_Y0
.esend1
    BIT R1S                     \ V = space in the parasite->host FIFO
    BVC esend1
    STA R1D
    RTS
.shipend
ASSERT shipend <= &7C00         \ COPROT (glue + emitters) fits the
                                \ $7800-$7BFF gap; CODE ends $77FF, DATA
                                \ starts $7C00.  sincos/COLPORT/SHTAB are
                                \ ENGINE data (seeded by build_tube_game).
SAVE "COPROT", &7800, shipend, &7800
