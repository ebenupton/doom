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
ORG &5800                       \ the FB region: 5K the copro never
                                \ touches (the rasteriser IS what the
                                \ Tube port removed). Everything below
                                \ $2000 is claimed by runtime arenas —
                                \ pool/records/TFS/LC/VCACHE planes
                                \ ($0C00-$1AFF ate the first two homes)
                                \ — and parasite PAGE ($800) gets OS
                                \ scribbles during cross-Tube loads
    JMP boot
    JMP init                    \ &F03: harness entry — py65 runs the
                                \ driver with loads pre-applied (no OSCLI)
.angidx
    EQUB 0
.mask
    EQUB 0
.pxf
    EQUB 0
.pxl
    EQUB 0
.pxh
    EQUB 0
.pyf
    EQUB 0
.pyl
    EQUB 0
.pyh
    EQUB 0
.boot
    SEI
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
\ ---- high table: copy the staged $F800+ block into place (the client
\      OS executed from up there during the loads; it is dead now) ----
    LDA #LO(HITAB_STAGE)
    STA &6C
    LDA #HI(HITAB_STAGE)
    STA &6D
    LDA #LO(HITAB_DST)
    STA &6E
    LDA #HI(HITAB_DST)
    STA &6F
    LDX #HI(HITAB_LEN)+1        \ whole pages (+ tail page)
    LDY #0
.hcopy
    LDA (&6C),Y
    STA (&6E),Y
    INY
    BNE hcopy
    INC &6D
    INC &6F
    DEX
    BNE hcopy
\ ---- engine state init (walk_drv's rcinit block, flat addresses) ----
    LDA #0
    TAX
.rcinit
    STA T_RCACHE_STATE,X
    INX
    CPX #T_RCACHE_LEN
    BNE rcinit
    LDX #0
.vxinit
    STA T_VXC_STATE,X
    INX
    CPX #T_VXC_LEN
    BNE vxinit
    LDA #1
    STA T_VXC_ENABLE
\ (CPM memo: NOT zeroed here — its ground state is not all-zeros: the
\  KDXH validity plane ships as a data file full of $80 sentinels, and
\  a wipe after the load would destroy it. The other five planes rely
\  on zeroed RAM — true in jsbeeb; REAL-HW TODO: zero $5500-$57FF
\  BEFORE the D-file loads, i.e. in a pre-load stub.)
    LDA #LO(T_TAIL_POSTRC)      \ frame-class vectors: moving targets
    STA &CA
    LDA #HI(T_TAIL_POSTRC)
    STA &CB
    LDA #LO(T_BOX_CLASSIFY)
    STA &63
    LDA #HI(T_BOX_CLASSIFY)
    STA &64
\ ---- spawn state (constants from tube_syms.inc) ----
    LDA #SPAWN_ANGIDX
    STA angidx
    LDA #SPAWN_PXF
    STA pxf
    LDA #SPAWN_PXL
    STA pxl
    LDA #SPAWN_PXH
    STA pxh
    LDA #SPAWN_PYF
    STA pyf
    LDA #SPAWN_PYL
    STA pyl
    LDA #SPAWN_PYH
    STA pyh
    LDA #SPAWN_VZ
    STA &04
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
    LDA R1D
    STA mask
    AND #4                      \ b2 LEFT: turn
    BEQ nlf
    LDA angidx
    CLC
    ADC #1
    AND #63
    STA angidx
.nlf
    LDA mask
    AND #8                      \ b3 RIGHT
    BEQ nrt
    LDA angidx
    SEC
    SBC #1
    AND #63
    STA angidx
.nrt
    LDA mask
    AND #1                      \ b0 UP: forward + bounds
    BEQ nup
    JSR step_fwd
    JSR bounds_or_revert_fwd
.nup
    LDA mask
    AND #2                      \ b1 DOWN: back + bounds
    BEQ ndn
    JSR step_back
    JSR bounds_or_revert_back
.ndn
    LDA pxf                     \ position -> engine ZP
    STA &00
    LDA pxl
    STA &01
    LDA pxh
    STA &9D
    LDA pyf
    STA &02
    LDA pyl
    STA &03
    LDA pyh
    STA &9E
    JSR derive_raw
    JSR floor_vz
    LDA angidx                  \ sincos <- table[angidx] (entry = 8 bytes)
    ASL A
    ASL A
    ASL A
    STA &EC
    LDA #0
    ROL A
    CLC
    ADC #HI(sctab)
    STA &ED
    LDY #0
    LDA (&EC),Y
    STA &05
    INY
    LDA (&EC),Y
    STA &06
    INY
    LDA (&EC),Y
    STA &07
    INY
    LDA (&EC),Y
    STA &08
    INY
    LDA (&EC),Y
    STA &09
    INY
    LDA (&EC),Y
    STA &0A
    INY
    LDA (&EC),Y
    STA T_BCA_AB                \ view angle byte
    JSR T_VIEW_SETUP            \ br_view_setup (flat: no banking)
    JSR T_SPAN_INIT             \ span_init / pool
    JSR T_RENDER_FRAME          \ lines leave via the &A900 emitters
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
\ ---- movement block: VERBATIM from walk_drv.asm (D_FWD lines dropped) ----
.step_fwd
    LDA angidx
    ASL A
    ASL A
    TAX
    CLC
    LDA pxf
    ADC step_tab,X
    STA pxf
    LDA pxl
    ADC step_tab+1,X
    STA pxl
    LDA step_tab+1,X
    BMI sf_xneg
    LDA pxh
    ADC #0
    STA pxh
    JMP sf_y
.sf_xneg
    LDA pxh
    ADC #&FF
    STA pxh
.sf_y
    CLC
    LDA pyf
    ADC step_tab+2,X
    STA pyf
    LDA pyl
    ADC step_tab+3,X
    STA pyl
    LDA step_tab+3,X
    BMI sf_yneg
    LDA pyh
    ADC #0
    STA pyh
    RTS
.sf_yneg
    LDA pyh
    ADC #&FF
    STA pyh
    RTS
.step_back
    LDA angidx
    ASL A
    ASL A
    TAX
    SEC
    LDA pxf
    SBC step_tab,X
    STA pxf
    LDA pxl
    SBC step_tab+1,X
    STA pxl
    LDA step_tab+1,X
    BMI sb_xneg
    LDA pxh
    SBC #0
    STA pxh
    JMP sb_y
.sb_xneg
    LDA pxh
    SBC #&FF
    STA pxh
.sb_y
    SEC
    LDA pyf
    SBC step_tab+2,X
    STA pyf
    LDA pyl
    SBC step_tab+3,X
    STA pyl
    LDA step_tab+3,X
    BMI sb_yneg
    LDA pyh
    SBC #0
    STA pyh
    RTS
.sb_yneg
    LDA pyh
    SBC #&FF
    STA pyh
    RTS
.derive_raw
    LDA pxf
    STA &90
    LDA pxl
    STA &91
    LDA pxh
    STA &EC
    LDX #5
.dr_x
    LDA &EC
    CMP #&80
    ROR &EC
    ROR &91
    ROR &90
    DEX
    BNE dr_x
    LDA pyf
    STA &92
    LDA pyl
    STA &93
    LDA pyh
    STA &EC
    LDX #5
.dr_y
    LDA &EC
    CMP #&80
    ROR &EC
    ROR &93
    ROR &92
    DEX
    BNE dr_y
    RTS
.floor_vz
    LDA &90
    CLC
    ADC #&90
    STA &EC
    LDA &91
    ADC #&07
    STA &ED
    LDA &EC
    ASL A
    LDA &ED
    ROL A
    STA &EC
    LDA &92
    CLC
    ADC #&2E
    STA &ED
    LDA &93
    ADC #&06
    STA &EE
    LDA &ED
    ASL A
    LDA &EE
    ROL A
    TAY
    LDA frow_lo,Y
    CLC
    ADC &EC
    STA &EC
    LDA frow_hi,Y
    ADC #0
    STA &ED
    LDA &EC
    CLC
    ADC #LO(floor_tab)
    STA &EC
    LDA &ED
    ADC #HI(floor_tab)
    STA &ED
    LDY #0
    LDA (&EC),Y
    CMP &04
    BEQ fv_done
    SEC
    SBC &04
    BMI fv_down
    INC &04
    RTS
.fv_down
    DEC &04
.fv_done
    RTS
.bounds_or_revert_fwd
    JSR derive_raw
    JSR bounds_ok
    BCS bor_ok1
    JSR step_back
.bor_ok1
    RTS
.bounds_or_revert_back
    JSR derive_raw
    JSR bounds_ok
    BCS bor_ok2
    JSR step_fwd
.bor_ok2
    RTS
.bounds_ok
    LDA &90
    SEC
    SBC #LO(RAWX_MIN)
    LDA &91
    SBC #HI(RAWX_MIN)
    BVC bo_c1
    EOR #&80
.bo_c1
    BMI bo_bad
    LDA #LO(RAWX_MAX)
    SEC
    SBC &90
    LDA #HI(RAWX_MAX)
    SBC &91
    BVC bo_c2
    EOR #&80
.bo_c2
    BMI bo_bad
    LDA &92
    SEC
    SBC #LO(RAWY_MIN)
    LDA &93
    SBC #HI(RAWY_MIN)
    BVC bo_c3
    EOR #&80
.bo_c3
    BMI bo_bad
    LDA #LO(RAWY_MAX)
    SEC
    SBC &92
    LDA #HI(RAWY_MAX)
    SBC &93
    BVC bo_c4
    EOR #&80
.bo_c4
    BMI bo_bad
    SEC
    RTS
.bo_bad
    CLC
    RTS
\ ---- command strings ----
.runcmd
    EQUB 2
    EQUS "RUN HOSTT"
    EQUB 13
    EQUB 0
.loads
INCLUDE "tube/tube_loads.inc"   \ generated: EQUS "LOAD En":EQUB 13 ... EQUB 0
\ ---- tables ----
ALIGN &100
.sctab
INCBIN "SINCOS.bin"             \ 64 x 8: smag,sneg,sone,cmag,cneg,cone,ab,pad
.step_tab
FOR i, 0, 63
    EQUW INT(SPEED * 32 * COS(i * PI / 32) + 65536.5) AND &FFFF
    EQUW INT(SPEED * 32 * SIN(i * PI / 32) + 65536.5) AND &FFFF
NEXT
.floor_tab
INCBIN "FLOORGRD.bin"
.frow_lo
FOR n, 0, 21
    EQUB LO(n * 36)
NEXT
.frow_hi
FOR n, 0, 21
    EQUB HI(n * 36)
NEXT
.drvend
ASSERT drvend <= &6C00          \ the FB region ends at $6C00 (flat map)
SAVE "COPROT", &5800, drvend, &5800
