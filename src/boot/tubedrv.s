; tubedrv.asm — the COPRO-side game driver, TWO blocks since the
; 2026-09-02 top-of-A free:
;
;   BOOT (DFS COPROT, *RUN at &7800): transient bootstrap.  OSCLI-*LOADs
;   the engine/data files across the Tube (the parasite OS + host DFS do
;   the byte shuffling), sends RUN HOSTT raw over R2 (no reply wait —
;   the host program never returns to the Tube service loop), then JMPs
;   the resident block and is never entered again.  It squats the flat
;   VRCACHE X-plane BSS (&7800-&7BFF): dead code there is fine BECAUSE
;   it is dead — the planes are runtime state the engine may write, which
;   is exactly why nothing RESIDENT can live in this hole (the 2026-09-02
;   esend1-misland: the emitters lived here and sxv0_rwpb wrote a vertex
;   y over the RTS).
;
;   RESIDENT (&F600-&F7FF, shipped INSIDE the DATA file): init + the
;   frame loop + the line-command emitters + the driver variables.
;   Eben's ruling made concrete: the only tube-specific code is the
;   Tube-ULA driver, and it sits right at the top of memory — in the
;   512 B the bank-B/CBITS slide freed under the client OS at &F800.
;
; walk_drv's soul with the hardware removed: no CRTC, no vsync clock,
; no keyboard matrix, no banking — the key mask arrives over the Tube
; (one byte per displayed frame, which IS the frame pacing) and every
; drawn line leaves over the Tube via the emitters at &F610+.
   .include "../../tube/tube_syms.inc"   ; generated: flat engine addresses + spawn

; TRIPWIRE (debug): id must be NON-ZERO. Transparent -- A, X, Y and the
; flags all survive, so a checkpoint can go anywhere. FIRST WRITER WINS,
; so the surviving id names the EARLIEST phase that saw the corruption.
.macro TW id
.if ::T_TRIPWIRE
    PHP
    PHA
    LDA #id
    JSR T_TW_CHECK
    PLA
    PLP
.endif
.endmacro

R1S=$FEF8
R1D=$FEF9
R2S=$FEFA
R2D=$FEFB
OSCLI=$FFF7   ; parasite OS (alive until RUN HOSTT)

RESIDENT=$F600   ; the resident block's home (and entry:
; it opens with JMP init)

; =====================================================================
; BOOT — transient, &7800-&7BFF (the VRCACHE X-plane hole; dead after
; the JMP RESIDENT below, and the engine is free to trample it)
; =====================================================================
.segment "BOOT"
boot:
    SEI
    LDX #$DF   ; STACK CAP (2026-08-23): SQR_MIRROR owns
    TXS   ; $01E0-$01FF since the sqr swap (15ba65c)
; made the quad boot-GENERATED with a mirror
; prefix in the stack page.  walk_drv caps
; the stack for exactly this reason; the
; parasite never did, so its stack started
; at $FF and the mirror overwrote the JSR
; OSCLI return addresses in .boot's load
; sequence -- the copro disappeared into the
; tube MOS and never came back, so HOSTT was
; never RUN and the screen stayed black.
    LDA #0   ; REAL-HW hardening: the engine's runtime
    STA T_ZP_CLRP   ; arenas ($0400-$19FF: pool/records/
    LDA #4   ; scratch/bitmap page/cache planes)
    LDY #0   ; assume the py65-zeros ground state;
    STA T_ZP_CLRP+1   ; parasite RAM is only zeroed by luck on
    TYA   ; emulators. Zero them BEFORE the loads.
pz1:   ; STOP at $1A00: the sqr quad rides the
    STA (T_ZP_CLRP),Y   ; CODE file from $1A00 (f34f835 map) —
    INY   ; the old #&1B bound wiped its first page.
    BNE pz1
    INC T_ZP_CLRP+1
    LDX T_ZP_CLRP+1
    CPX #$1A
    BNE pz1
    LDX #0   ; *LOAD every engine/data file: strings
ldloop:   ; are CR-terminated, list ends with 0
    LDA loads,X
    BEQ ldone
    TXA
    PHA
    CLC
    ADC #<(loads)
    TAX
    LDA #0
    ADC #>(loads)
    TAY
    CLI   ; parasite OS needs its IRQs for R4
    JSR OSCLI
    SEI
    PLA
    TAX
skip:
    INX   ; advance past this string's CR
    LDA loads,X
    CMP #13
    BNE skip
    INX
    JMP ldloop
ldone:
    LDX #0   ; raw R2 OSCLI: RUN HOSTT (id 2 + string,
cli_l:   ; NO reply wait — host never comes back)
    LDA runcmd,X
    BEQ cdone
cw:
    BIT R2S
    BVC cw
    STA R2D
    INX
    BNE cli_l
cdone:
; ---- un-stage the client-OS pages (2026-09-02): VEXPL_LO/HI ($F800)
; and VPTAB ($F900) -- the two documented exceptions to the linear
; bank-C map -- live above the OS floor, which the LOADs (running
; through the live OS) cannot write.  The DATA file carries them
; STAGED at $7C00-$7DFF (flat VRCACHE Y-plane BSS, dead until the
; engine runs; the engine then tramples the stage freely).  Copy up
; now: the OS has served its last call (the R2 RUN went raw),
; interrupts are off, and the $FFFA+ hardware vectors stay intact.
; Pointers: T_ZP_CLRP (zp_save2) as src, T_ZP_BOOTDST (zp_ox0) as
; dst -- both re-aimed by init.
    LDY #0
    STY T_ZP_CLRP
    STY T_ZP_BOOTDST
    LDX #$7C
uspg:
    STX T_ZP_CLRP+1
    TXA
    CLC
    ADC #$7C   ; $7Cxx -> $F8xx .. $7Fxx -> $FBxx
    STA T_ZP_BOOTDST+1
usb:
    LDA (T_ZP_CLRP),Y
    STA (T_ZP_BOOTDST),Y
    INY
    BNE usb
    INX
    CPX #$7E   ; two pages: VEXPL + VPTAB
    BNE uspg
    JMP RESIDENT   ; the resident block arrived with DATA

; ---- command strings ----
runcmd:
    .byte 2
    .byte "RUN HOSTT"
    .byte 13
    .byte 0
loads:
   .include "../../tube/tube_loads.inc"   ; generated: EQUS "LOAD En":EQUB 13 ... EQUB 0
bootend:
   .assert bootend <= $7C00, error   ; boot must fit the X-plane hole; DATA
; starts at &7C00 (VDESC/sincos)
; SAVE "COPROT", &7800, bootend -> the build script

; =====================================================================
; RESIDENT — &F600-&F7FF, init + frame loop + emitters.  Shipped inside
; the DATA file (build_tube_game injects the COPRES image at &F600
; before cutting DATA), so the boot loads deliver it and nothing ever
; overwrites it: the engine content ends at &F5FF and the client OS
; starts at &F800.
; =====================================================================
.segment "RESIDENT"
    JMP init   ; &F600: boot's JMP lands here; the py65
; harnesses enter here too (loads
; pre-applied, no OSCLI)
; Driver variables live as ABSOLUTES in this image (not ZP): the copro
; shares its zero page with the whole flat engine, and $63/$64 are the
; zp_bv_entry vector — a driver var there would be a wild indirect JMP.
; Access count is ~30/frame; absolute vs zp is noise on a 3MHz copro.
mask:
    .byte 0
fields:
    .byte 0   ; PAL fields since the last rendered frame
spraw:
    .byte 0   ; button LEVELS, from the last b7=1 byte
; (2026-09-02 two-byte mask): b0 SPACE,
; b1 O.  The host sends a button byte only
; when a level CHANGES, so this latch
; persists across frames.
space_prev:
    .byte 0   ; press-edge state, as walk_drv's
o_prev:
    .byte 0   ; O press-edge state (masked b1 value)
; ---- line-command emitter slots (FIXED addresses: build_tube_game
; pokes the engine's plot_h/plot_v/RASTER_ENTRY stubs to JMP these) ----
.segment "EMIT"                             ; SKIPTO $F610
entry_diag:   ; = RASTER_ENTRY target (des_diag JMPs here)
    JMP ediag
entry_h:   ; plot_h's poked JMP lands here (&F613)
    JMP eph
entry_v:   ; plot_v = &F616 (engine equate)
    JMP epv
entry_rts:
    RTS   ; &F619: pinned RTS -- the engine's flat
; fb_clr0/1/back equates land here (the
; host driver's flip path, never run on
; the copro but linked by the shared DRV)
epv:
    JSR exy0   ; all three emitters open with x0,y0
    LDA T_RZP_X0
    JSR esend1
    LDA T_RZP_Y1
    JMP esend1
ediag:
    JSR exy0
    LDA T_RZP_X1
    JSR esend1
    LDA T_RZP_Y1
    JMP esend1
eph:
    JSR exy0
    LDA T_RZP_X1
    JSR esend1
    LDA T_RZP_Y0
    JMP esend1
exy0:
    LDA T_RZP_X0
    JSR esend1
    LDA T_RZP_Y0
esend1:
    BIT R1S   ; V = space in the parasite->host FIFO
    BVC esend1
    STA R1D
    RTS

init:
; ---- REAL-HW hardening, part 2: ZERO PAGE (2026-08-23) ----
; boot already zeroes the runtime arenas ($0400-$19FF) because parasite
; RAM is only zeroed by luck; zero page was never covered, and it
; arrives holding tube MOS workspace.  The engine READS ZP bytes it
; never writes and relies on them being 0 -- tools/zpvirgin.py lists
; them.  The one that kills the port is plotq_mode ($A1): dcl.s's
; contract is "Harness/default: plotq_mode = 0 -- everything draws
; direct", and walk_drv establishes it on the host (it writes &A1 in
; flip_sched) but NOTHING on the parasite ever does.  With bit 7 set by
; chance, every line is enqueued into PLOTQ instead of drawn, and the
; Tube port has no drain because the rasteriser is exactly what it
; removed -- so the screen stays blank forever.  plotq_n, zp_dcl_out
; and TFS_PEND_ACT are consumers of the same ground state.
; Clearing to 0 reproduces the py65 image every harness validates
; against.  Safe here: the parasite OS is finished (SEI is held since
; the last OSCLI), driver variables live as absolutes in THIS block,
; and init is entered exactly twice -- boot JMPs here, and &F600 is the
; harness entry, so the harness exercises this too.
    LDA #0
    TAX
zpclr:
    STA $00,X
    INX
    BNE zpclr
; ---- engine state init (flat addresses) ----
; (the RCACHE_STATE zeroing loop died 2026-09-04 with the extent cache)
; (A = 0, X = 0 still — rides into vxinit)
vxinit:
    STA T_VRCACHE_STATE,X   ; whole bitmap page (VXCACHE_VALID +
    INX   ; VDONE + VRCACHE_VALID)
    BNE vxinit
    LDA #1   ; VRCACHE ON -- by construction (Eben
    STA T_VRCACHE_ENABLE   ; 2026-09-02): the flat planes own the
; full bank-A-hole $7800-$7FFF now that
; VDESC/sincos moved to the reclaimed
; client-OS 1K ($F800/$FA00)
; animated sectors (doors/lifts): engine
    STA T_ANIM_ENABLE   ; anim, no driver glue needed on the
    JSR T_ANIM_INIT   ; copro (flat build: no banking)
; (the corner-phi memo, whose $80 validity plane used to be seeded here,
;  was retired 2026-09-04)
; (the frame-class vector seeding died 2026-09-04 with the extent cache)
; ---- spawn state (constants from tube_syms.inc) ----
; Spawn lands in pm_frame's DRIVER-VARIABLE CONTRACT (DV_*): the engine
; reads AND writes those, so the driver no longer keeps its own copy of
; the pose.
    LDX #7   ; table-driven (the 512 B fit): DV_* +0..+7
spw:   ; = angidx, backhi, pxf/l/h, pyf/l/h --
    LDA sptab,X   ; backhi gets 0, which the copro never
    STA T_DV_ANGIDX,X   ; reads (no framebuffer, no flip)
    DEX
    BPL spw
    LDA #SPAWN_VZ
    STA T_PM_VZ   ; pm_frame/pmove_zonly own vz
    STA T_ZP_VZ   ; engine ZP eye height for frame 1
    LDA #0
    STA T_PM_TURNREM   ; no carried sub-step rotation
rdrain:
    BIT R1S   ; eat stale host->parasite R1 bytes (the
    BPL rdone   ; Tube OS uses R1 for escape/event
    LDA R1D   ; notifications during the load phase —
    JMP rdrain   ; one of those cost us an angle step)
rdone:
; ---------------------------------------------------------------------
; frame loop — paced by the host's one-mask-per-vsync
; ---------------------------------------------------------------------
; TWO-BYTE MASK (2026-09-02, Eben's ask -- pass "O"): the R1 latch is
; ONE byte, so the protocol is TAGGED bytes, overwrite-safe by
; construction.  b7=0: MOVEMENT -- b0-3 keys, b4-6 elapsed PAL fields
; (the copro's field clock; HOSTT packs the count because a 1-deep
; latch could never be counted).  b7=1: BUTTONS -- b0 SPACE, b1 O,
; LEVELS, sent only when one changes (so the movement stream keeps
; its full one-per-field rate).  A frame is paced by MOVEMENT bytes;
; button bytes just update the spraw latch and keep waiting.
frame:
    LDA #0
    STA fields
wm:
    BIT R1S   ; N = a mask byte waiting
    BPL wm
    LDA R1D
    BMI wx   ; b7=1: buttons -- latch, keep waiting
mgot:
    TAX   ; movement byte
    AND #$0F
    STA mask
    TXA
    AND #$70
    LSR A
    LSR A
    LSR A
    LSR A
    CLC
    ADC fields   ; sum, in case more than one arrives
    STA fields   ; (<=2 movement bytes fit a drain window,
; 7 fields each -- far under pm_frame's 32)
drain:
    BIT R1S   ; drain every queued byte: the host sends
    BPL wgo   ; at most one per DISPLAYED field, so the
    LDA R1D   ; summed count IS the elapsed field count,
    BPL mgot   ; standing in for walk_drv's T1/T2 pair.
    STA spraw   ; button byte mid-drain: latch it
    BMI drain   ; (N=1 from the LDA -- always taken)
wx:
    STA spraw   ; button levels (b7 rides along, harmless)
    BMI wm   ; (always taken) -- still need a movement
; byte to pace the frame
wgo:
; ---- DOOM movement: same engine entry the host uses --------------------
; pm_frame owns ROTATION, position, P_TryMove box collision, wall slide
; and D_FWD, and scales both the walk and the turn by the field count --
; so neither changes with the frame rate.  (No bank paging here: the
; copro runs the FLAT engine.)
    TW 1   ; frame start, before any engine work
    LDA fields
    LDX mask   ; b0 fwd b1 back b2 left b3 right -- the
    JSR T_PM_FRAME   ; mask bit order IS walk_drv's mv_in order
    TW 2   ; after pm_frame (rotation + position)
; ---- SPACE: DOOM 'use' on the PRESS EDGE (doors) -----------------------
; Every DR door on the map is "shut until used" (anim_sectors), so with no
; use path the copro's doors could never open -- the lifts self-cycle,
; which is exactly why only the DOORS looked frozen while anim_tick,
; anim_hub and the mover state machine were all provably running.
; Must come AFTER pm_frame: $90-$93 are its exit contract and pmove_use
; traces from them.  (No bank paging: the copro runs the FLAT engine, so
; walk_drv's PAGE BANK_SEG around USEVEC has no counterpart here.)
    LDA spraw
    AND #1   ; SPACE level (two-byte mask: b0)
    BEQ spclr
    LDA space_prev
    BNE spdone
    LDA #1
    STA space_prev
    LDA T_DV_ANGIDX   ; USEVEC entry = 4 bytes (ux,uy s16 raw)
    ASL A
    ASL A
    TAX
    LDY #0
spuv:
    LDA T_USEVEC,X
    STA T_PM_UX,Y
    INX
    INY
    CPY #4
    BNE spuv
    JSR T_PMOVE_USE
    JMP spdone
spclr:
    STA space_prev   ; A = 0 here
spdone:
; ---- O: billboard objects toggle, PRESS EDGE (2026-09-02) --------------
; The host scans the key and ships the LEVEL in the button byte's b1;
; the edge lives here, and the flip is the engine's ok_flip (obj_key's
; body minus the $FE4F scan the copro has no hardware for).
    LDA spraw
    AND #2
    CMP o_prev
    BEQ odone
    STA o_prev
    TAY   ; STA sets no flags and the CMP's Z is
    BEQ odone   ; stale -- TAY re-derives Z from A, so a
; RELEASE edge records and stops here
    JSR T_OK_FLIP   ; press edge: flip + refill/zero OBJ_ANYB
odone:
    TW 3   ; after the SPACE use / door sense
; ---- pose -> engine ZP (pm_frame wrote DV_* and the $90-$93 raws) ------
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
    TW 4   ; after the pose copy to engine ZP
    JSR T_PMOVE_ZONLY   ; DOOM z: rides live lifts (walk_drv's
    LDA T_PM_VZ   ; mv_reval).  derive_raw is gone: the
    STA T_ZP_VZ   ; $90-$93 raws are pm_frame's exit contract
; sincos <- sctab[angidx].  The pointer rides T_ZP_CLRP (the boot clear
; pointer's pair) rather than a hand-picked &EC/&ED: those two were an
; unregistered squat on whatever the engine keeps there, and the pair is
; asserted adjacent-and-in-zero-page by build_tube_game.  Safe to share:
; this runs before view_setup, and the clipper rewrites the pair.
    LDA T_DV_ANGIDX   ; sincos <- table[angidx] (entry = 8 bytes)
    ASL A
    ASL A
    ASL A
    STA T_ZP_CLRP
    LDA #0
    ROL A
    CLC
    ADC #>(T_DRV_SINCOS)   ; the ENGINE's driver sincos ($7E00, seeded
    STA T_ZP_CLRP+1   ; by the image builder) -- no duplicate table
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
    STA T_BCA_AB   ; view angle byte
    TW 5   ; after pmove_zonly + the sincos copy
    LDA fields   ; summed mask-drain field count -> the
    STA T_ANIM_FIELDS   ; FIELD-SCALED tick (2026-08-25)
    JSR T_ANIM_TICK   ; advance door/lift movers
    TW 6   ; after anim_tick
    JSR T_VIEW_SETUP   ; br_view_setup (flat: no banking)
    TW 7   ; after view_setup
    JSR T_SPAN_INIT   ; span_init / pool
    TW 8   ; after span_init
    JSR T_RENDER_FRAME   ; lines leave via the &F610+ emitters
    TW 9   ; after render_frame -- THE big phase
; ---- HUD packet: FE FE FE FE + 12 payload bytes (last = class code) ----
; The HOST draws the HUD, not the copro: the parasite has no framebuffer
; and no OS font ($C000 is its own DATA span), so it just ships its pose
; every frame and the H toggle lives host-side.  That also dodges the
; mask byte being full -- 4 keys + 3 field bits + SPACE, no room for an
; H bit.
; FE FE FE FE cannot collide with geometry (a real y byte is < 160).
; EVERY payload tuple ends in 00, which does two jobs: it keeps the
; packet 4-TUPLE ALIGNED so the host's skip-ahead parser stays in step,
; and it breaks any run of FFs in the position bytes -- x = -1/256 would
; otherwise put four consecutive FFs on the wire and fake the ISR's
; 4-consecutive-FF end-of-frame marker.
    LDX #4
hudmk:
    LDA #$FE
    JSR esend1
    DEX
    BNE hudmk
    LDA T_DV_ANGIDX
    JSR esend1
    LDA T_DV_PXF
    JSR esend1
    LDA T_DV_PXL
    JSR esend1
    LDA #0
    JSR esend1
    LDA T_DV_PXH
    JSR esend1
    LDA T_DV_PYF
    JSR esend1
    LDA T_DV_PYL
    JSR esend1
    LDA #0
    JSR esend1
    LDA T_DV_PYH
    JSR esend1
.if ::T_TRIPWIRE
    LDA T_ZP_TW   ; TRIPWIRE latch -> the HUD's T= field
.else
    LDA #0
.endif
    JSR esend1
    LDA fields
    JSR esend1   ; PAL fields this frame -> the HUD's F=
; The tuple's last byte is PAD again (2026-09-04): the bbox extent cache
; is gone, so there is no frame class to report.  A zero keeps the packet
; 4-tuple aligned and cannot extend an FF run.
    LDA #0
    JSR esend1
    LDX #4   ; end of frame: FF FF FF FF
eof:
    LDA #$FF
    JSR esend1
    DEX
    BNE eof
    JMP frame
sptab:   ; spawn pose, DV_* +0..+7 order
    .byte SPAWN_ANGIDX, 0, SPAWN_PXF, SPAWN_PXL, SPAWN_PXH
    .byte SPAWN_PYF, SPAWN_PYL, SPAWN_PYH
; (The old movement block -- step_fwd/step_back, bounds_or_revert and
; their derive_raw/floor_vz helpers, 223 lines transplanted from an
; early walk_drv -- was DELETED 2026-08-23.  It stepped a fixed
; distance per mask (so speed tracked the frame rate) and clamped the
; player to a rectangle instead of colliding with the map.  The copro
; now calls the engine's pm_frame, exactly as the host does.  send1 was
; folded into esend1 with the 2026-09-02 resident re-cut: same loop,
; two names.)
resend:
   .assert resend <= $F800, error   ; RESIDENT must fit under the client OS
; SAVE "COPRES", RESIDENT, resend -> the build script
