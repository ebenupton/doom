; walk_drv.asm — autobooting WALKABLE E1M1 wireframe for the banked renderer.
; anim_drv's frame loop (T1 field-locked flip scheduler, split clears) with
; keyboard-driven position/angle instead of the canned spin:
;   cursor Left/Right  turn (4 angle-bytes per frame)
;   cursor Up/Down     move forward/back (12 world units per frame)
; Player position is kept as prescaled 8.8 in 24 bits (frac, lo, hi) — the
; s16-integer engine representation (zp $00/$01 + $9D, $02/$03 + $9E) covers
; the whole map. PXRAW/PYRAW are derived per frame (>>5 of the 24-bit 8.8).
; Movement steps come from a beebasm-computed 64-entry table of premultiplied
; 8.8 deltas; sincos comes from the same 64x8 table the spin build overlays
; at $3E00 (indexed by angidx here instead of walked sequentially).
; Keyboard: direct System VIA scan (IC32 addr 3 low = manual scan, key number
; written to $FE4F, bit 7 read back). No OS.

INCLUDE "abi_beeb.inc"\ every cross-file address comes from the ABI table
INCLUDE "engine_syms.inc"\ engine entry addresses, generated from the ld65 map by build_walk_ssd.py
angidx = DV_ANGIDX          ; view angle index 0..63 (angle byte = idx*4)
backhi = DV_BACKHI          ; hidden-buffer page hi ($58 or $6C)
pxf    = DV_PXF          ; player x: 8.8 prescaled, 24-bit (frac, lo, hi)
pxl    = DV_PXL
pxh    = DV_PXH
pyf    = DV_PYF
pyl    = DV_PYL
pyh    = DV_PYH
jidx   = DV_JIDX          ; vsync journal index (0..62)
hud_en   = DV_HUD_EN        ; debug HUD on/off (H key toggles)
hud_prev = DV_HUD_PREV        ; H-key state last frame (press-edge debounce)
; (D_ENABLE/D_FWD from the ABI include)        ; forward-coherence bbox cache master switch (bbox.s)
; ---        ; per-frame flag: this frame's move was forward-only
; vsync journal: 64 x 4 bytes at $0300 (dead OS workspace; no OS after boot):
;   +0 class taken (0/1/2)   +1 T1 hi at classify
;   +2 T1 hi after the vsync wait ($FF = class 2, no wait)
;   +3 T1 hi after clears done
jbase  = JBASE          ; RELOCATED 2026-07-08 from $0300: the forward-coherence
                        ; bbox cache owns $0210-$03F7 (bbox.s); $1A00 is dead
                        ; boot-loader memory (loader stages below $1B40, never
                        ; touched after boot)
tabbase = DRV_TAB         ; sincos table (build-overlaid): 64 x 8 bytes

SPEED = 12              ; world units per frame of forward motion

; map bounds in RAW world units relative to MAP_CENTER (1200,-3250),
; with a 32-unit margin: x in [-768,3808] -> raw [-1968+32, 2608-32]
RAWX_MIN = &F870        ; -1936 as u16
RAWX_MAX = &0A10        ;  2576
RAWY_MIN = &F9D2        ; -1582
RAWY_MAX = &0492        ;  1170

ORG DRV_ORG
; ---------------------------------------------------------------------------
; drv — one-time boot init, then falls through into the frame loop.
; Entry: JMP $2000 from the !BOOT loader (banks 4/6/7 = L0/C/L2 already
; copied to sideways RAM, LOW loaded, MODE 4 selected). Never returns.
; Interrupts stay off for ever (SEI; direct hardware only from here on —
; the OS workspace is dead and reused, e.g. the vsync journal at $0300).
; Phases:
;   1. spawn position/VZ            5. keyboard -> manual-scan mode
;   2. engine ROM-table pointers    6. render caches (RCACHE, VXC)
;   3. CRTC 256x160 non-interlaced  7. animated-sector init (bank L2)
;   4. T1 field-locked beam clock   8. driver state + clear both buffers
; ---------------------------------------------------------------------------
.drv
    SEI
    LDA #0 : STA &FE34                              ; Master: ACCCON off (harmless on B)
    ; --- spawn position 1056,-3616 as 24-bit prescaled 8.8 ---
    LDA #&00:STA pxf : LDA #&EE:STA pxl : LDA #&FF:STA pxh
    LDA #&40:STA pyf : LDA #&D2:STA pyl : LDA #&FF:STA pyh
    LDA #&06:STA &04                                ; VZ (spawn floor; constant v1)
    ; --- CRTC: narrow 256x160 centred, cursor off (R12/R13 set per flip) ---
    LDA #1 :STA &FE00: LDA #32 :STA &FE01
    LDA #2 :STA &FE00: LDA #45 :STA &FE01
    LDA #6 :STA &FE00: LDA #20 :STA &FE01
    LDA #7 :STA &FE00: LDA #28 :STA &FE01
    LDA #8 :STA &FE00: LDA #0  :STA &FE01           ; R8=0: interlace OFF. The MODE 4
    ; default (R8=1, interlace sync) makes every field 312.5 lines = 20000us,
    ; which drifts the 19968us T1 field lock by 32us/field (beam classes
    ; rotate through all phases every ~12s -> periodic clear-vs-beam races),
    ; and shimmers 1px lines at 25Hz. Non-interlaced: field = exactly 312
    ; lines = 19968us, T1 lock is exact and the raster is stable.
    LDA #10:STA &FE00: LDA #&20:STA &FE01
    ; --- System VIA T1 field lock (see anim_drv for the full rationale):
    ;     free-running T1, period 19968us = exactly one non-interlaced
    ;     312-line PAL field, phase-locked once to the vsync edge (CA1 IFR
    ;     bit 1). T1's high byte is then a drift-free beam-position clock
    ;     (4-line granularity) that flip_sched reads every frame. ---
    LDA &FE4B:AND #&3F:ORA #&40:STA &FE4B           ; ACR: T1 continuous, PB7 off
    LDA #&FE:STA &FE46                              ; T1 latch = $4DFE = 19966 (+2)
    LDA #&4D:STA &FE47
    LDA #2  :STA &FE4D                              ; clear stale vsync flag
.vsy0
    LDA &FE4D:AND #2:BEQ vsy0                       ; wait for vsync edge
    LDA #&4D:STA &FE45                              ; start T1: phase = time since vsync
    ; --- keyboard: manual scan mode (IC32 addr 3 = 0), DDRA 0-6 out ---
    LDA #3  :STA &FE40
    LDA #&7F:STA &FE43
    ; --- rotation-coherence bbox cache: clear header state, enable.
    ;     RCACHE lives in the bank L2 window ($AD00 data; header/bitmaps at
    ;     $B460-$B4E8) — page L2 for the init writes; the frame loop pages
    ;     banks explicitly before every engine call anyway. Zero-init is
    ;     safe: even a false-stable first frame sees COMPUTED=0 -> all
    ;     checks take the cold path -> correct results. ---
    LDA #7
    STA &FE30                                       ; page bank L2
    LDA #0
    TAX
.rcinit
    STA RCACHE_STATE,X
    INX
    CPX #RCACHE_STATE_LEN
    BNE rcinit
    LDA #1
    STA RCACHE_ENABLE
    LDA #LO(ENG_TAIL_POSTRC)    \ frame-class VECTORS (zp.inc zp_tail_vec
    STA &CA                     \ $CA/$CB + zp_bv_entry $63/$64): seed the
    LDA #HI(ENG_TAIL_POSTRC)    \ moving targets so the first frame is sane
    STA &CB                     \ even before bca_frame runs — boot garbage
    LDA #LO(ENG_BOX_CLASSIFY)   \ in a vector would be a wild indirect JMP,
    STA &63                     \ not a soft mis-class
    LDA #HI(ENG_BOX_CLASSIFY)
    STA &64
    ; --- translation-coherence vertex cache (VXC): zero valid bitmap +
    ;     state ($05A0-$05FF, unbanked), then enable. Zero-init is safe:
    ;     first enabled frame is cold (prev_ab sentinel path) and every
    ;     entry stores before it loads. ---
    LDA #0
    TAX
.vxinit
    STA VXC_STATE,X
    INX
    CPX #VXC_STATE_LEN
    BNE vxinit
    LDA #1
    STA VXC_ENABLE
    ; --- animated sectors: init state machines + lazy patch hook (glue
    ;     at $3DA0 pages bank L2; must run AFTER vxinit's $05xx zeroing) ---
    JSR anim_glue_init
    ; --- init state ---
    LDA #1  :STA D_ENABLE                           ; forward-coherence bbox cache
    ; (D_FWD needs no init: read_input clears it every frame)
    LDA #16  :STA angidx                            ; angle byte 64 (spawn facing)
    LDA #&6C :STA backhi
    JSR clr58t:JSR clr58b:JSR clr6Ct:JSR clr6Cb
; ---------------------------------------------------------------------------
; frame — main loop, one iteration per rendered frame (paced by flip_sched's
; vsync waits when the beam demands one; free-running otherwise).
; Pseudocode:
;   read_input                  keys -> angidx, 24-bit position (bounds-checked)
;   ZP $00-$03/$9D/$9E <- pos   8.8 frac/lo + s16 integer high bytes
;   derive_raw / floor_vz       PXRAW/PYRAW ($90-$93); VZ ($04) eased to grid
;   sincos <- table[angidx]     entry is 8 bytes, so ptr = tabbase + idx*8
;                               (24-bit shift into $EC/$ED); bytes 0-5 ->
;                               ZP $05-$0A (s/c mag,neg,one), byte 6 -> bca_ab
;   anim_glue_tick              advance door/lift movers (lazy patching)
;   render                      view_setup (bank L0) -> span_init (bank C) ->
;                               init_frame + render_frame (L0) into the
;                               hidden buffer backhi (pre-cleared by the
;                               previous flip_sched)
;   flip_sched                  show it; beam-safe clear of the other buffer
; ---------------------------------------------------------------------------
.frame
    JSR read_input
    ; --- position -> engine ZP ---
    LDA pxf:STA &00 : LDA pxl:STA &01 : LDA pxh:STA &9D
    LDA pyf:STA &02 : LDA pyl:STA &03 : LDA pyh:STA &9E
    JSR derive_raw                                  ; PXRAW/PYRAW ($90-$93)
    JSR floor_vz                                    ; VZ from grid (smoothed)
    ; --- sincos + view angle from table[angidx] ---
    LDA #0:STA &ED
    LDA angidx
    ASL A:ROL &ED
    ASL A:ROL &ED
    ASL A:ROL &ED
    STA &EC
    LDA &ED:CLC:ADC #HI(tabbase):STA &ED
    LDY #0
    LDA (&EC),Y:STA &05
    INY:LDA (&EC),Y:STA &06
    INY:LDA (&EC),Y:STA &07
    INY:LDA (&EC),Y:STA &08
    INY:LDA (&EC),Y:STA &09
    INY:LDA (&EC),Y:STA &0A
    INY:LDA (&EC),Y:STA BCA_AB                      ; view angle byte
    JSR anim_glue_tick                              ; advance movers (lazy patch)
    ; --- render into hidden buffer (cleared by previous flip_sched) ---
    LDA backhi:STA &70
    LDA #BANK_L0 :STA &FE30 : JSR ENG_VIEW_SETUP    ; br_view_setup (real address, from the map)
    LDA #BANK_C :STA &FE30 : JSR ENG_SPAN_INIT      ; span_init / pool
    LDA #BANK_L0 :STA &FE30 : JSR ENG_RENDER_FRAME ; (init is inline at render entry)
    JSR flip_sched
    JMP frame

; ptrtab must clear the driver variable block (angidx..jidx live at
; $3D80-$3D88 as fixed equates; the sincos table is overlaid at $3E00).
; An extra init block once pushed it INTO the variables - the engine's
; table pointers then got clobbered at runtime by angidx/jidx stores and
; every frame rendered pixel-free while the loop ran happily. Pin it.
ASSERT P% <= DRV_VARS
ORG DRV_VARS + &10
; (.ptrtab retired 2026-07-10 — the engine assembles its ROM bases from
; src/layout.inc; the $0BE8 block is dead. $3D90-$3D9F freed.)
.drv_end

; --- unrolled framebuffer clears + flip scheduler: identical to anim_drv --
; --- animated-sector glue: page bank L2 and enter the anim jump table
;     ($3DA0-$3DBF pocket between ptrtab and the sincos table at $3E00) ---
ORG DRV_GLUE
; anim_glue_init: one-time mover-state init + SMC-installs the per-subsector
; visibility hook in the renderer. anim_glue_tick: per-frame logical advance
; of every mover's height state machine (no table writes; the hook patches
; the read tables lazily when a mover becomes visible — see src/bsp/anim.s /
; anim_sectors.py). The jump table + tick code are MAIN now (2026-07-10
; reshuffle) but the tick reads ANIM_CFG in bank L2, so the page-in stays. Leaves L2 paged (the frame loop
; re-pages banks before every engine call). Clobbers A + whatever anim uses.
.anim_glue_init
    LDA #0
    STA jidx                                        ; (init spill: main is full)
    STA hud_en : STA hud_prev                       ; HUD off at boot
    LDA #7:STA &FE30
    ; (RNS stack-page copy retired 2026-07-12: the vectoring block lives
    ; in engine CODE now; page 1 is reserved headroom.)
    JMP ENG_ANIM_INIT
.anim_glue_tick
    LDA #7:STA &FE30
    JMP ENG_ANIM_TICK
.key_hud
    ; H key: toggle the debug HUD on the press edge only (hud_prev holds
    ; last frame's state, so holding the key flips it exactly once).
    LDA #&54:STA &FE4F : BIT &FE4F : BMI kh_dn      ; H internal code &54
    LDA #0 : STA hud_prev
    RTS
.kh_dn
    LDA hud_prev : BNE kh_done                      ; still held: no retrigger
    LDA #1 : STA hud_prev
    LDA hud_en : EOR #1 : STA hud_en
.kh_done
    RTS
.hud_glue
    ; When enabled, draw "X=hhhh Y=hhhh R=hh" (OS ROM font) onto the top
    ; row of the buffer just rendered, before flip_sched displays it.
    LDA hud_en : BNE hg_on
    RTS
.hg_on
    LDA #6:STA &FE30                                ; HUD code lives in bank C
    JSR HUD_ENTRY                                   ; hud_draw
    LDA #4:STA &FE30                                ; restore a render bank
    RTS

ORG DRV_CLR
; ---------------------------------------------------------------------------
; clr58t/clr58b/clr6Ct/clr6Cb — unrolled clears of framebuffer half-screens.
; Each 20-page buffer ($5800 or $6C00) splits at the 80-row midline into a
; top half (10 pages) and a bottom half (10 pages) so flip_sched can clear
; the beam-passed top early while waiting for vsync to release the bottom.
; One INY/BNE loop, ten STA abs,Y per pass = 5 cyc/byte. Clobbers A,Y.
; ---------------------------------------------------------------------------
.clr58t
    LDA #0 : TAY
.c0t
    STA &5800,Y : STA &5900,Y : STA &5A00,Y : STA &5B00,Y
    STA &5C00,Y : STA &5D00,Y : STA &5E00,Y : STA &5F00,Y
    STA &6000,Y : STA &6100,Y
    INY : BNE c0t
    RTS
.clr58b
    LDA #0 : TAY
.c0b
    STA &6200,Y : STA &6300,Y : STA &6400,Y : STA &6500,Y
    STA &6600,Y : STA &6700,Y : STA &6800,Y : STA &6900,Y
    STA &6A00,Y : STA &6B00,Y
    INY : BNE c0b
    RTS
.clr6Ct
    LDA #0 : TAY
.c1t
    STA &6C00,Y : STA &6D00,Y : STA &6E00,Y : STA &6F00,Y
    STA &7000,Y : STA &7100,Y : STA &7200,Y : STA &7300,Y
    STA &7400,Y : STA &7500,Y
    INY : BNE c1t
    RTS
.clr6Cb
    LDA #0 : TAY
.c1b
    STA &7600,Y : STA &7700,Y : STA &7800,Y : STA &7900,Y
    STA &7A00,Y : STA &7B00,Y : STA &7C00,Y : STA &7D00,Y
    STA &7E00,Y : STA &7F00,Y
    INY : BNE c1b
    RTS

; ---------------------------------------------------------------------------
; flip_sched — show the just-rendered buffer, then clear the buffer coming
; off display without ever touching a row the beam has yet to draw. Same
; beam-class scheme as anim_drv (see the header there for the full field
; timeline); T1's high byte H classifies the beam:
;   class 2 (H 0..14 bottom border, 57..77 blanking): old buffer's display
;           is over -> clear top+bottom now, no wait
;   class 1 (H 15..34, beam in bottom half): clear top now, wait for vsync,
;           then clear bottom
;   class 0 (H 35..56, beam in top half): wait for vsync, then clear all
; walk_drv extras over the anim_drv version:
;   - the class thresholds cover H 0-77, so a raw H >= 78 (transient/wrap
;     read) is pre-filtered to class 0, the always-safe choice;
;   - every decision is journalled, 4 bytes/frame at jbase ($0300): class,
;     H at classify, H after the vsync wait ($FF = class 2, none), H when
;     the clears finished — post-mortem evidence for clear-vs-beam races.
; Toggles backhi. Re-phases T1 at each vsync it waits on. Clobbers A,X,Y.
; ---------------------------------------------------------------------------
.flip_sched
    JSR hud_glue                                    ; debug HUD onto the back buffer
    ; R12/R13 straddle guard: the pair of writes must not bracket the CRTC
    ; frame-top reload (e=5632us -> T1 = $37FE), or one field displays a
    ; mixed address. Spin while H is in [$36,$38] (<= 768us, rare).
.fs_guard
    LDA &FE45
    CMP #&36 : BCC fs_go
    CMP #&39 : BCS fs_go
    JMP fs_guard
.fs_go
    ; CRTC screen start = address/8: R12 = backhi>>3, R13 = (backhi&7)<<5
    LDA #12:STA &FE00 : LDA backhi:LSR A:LSR A:LSR A:STA &FE01
    LDA #13:STA &FE00 : LDA backhi:AND #7:ASL A:ASL A:ASL A:ASL A:ASL A:STA &FE01
    LDA backhi:EOR #(&58 EOR &6C):STA backhi        ; backhi = buffer coming off display
    ; classify the beam; Y = jidx*4 = journal record offset
    LDA jidx:ASL A:ASL A:TAY
    LDX &FE45
    ; class(T1hi): <=14 -> 2, 15-34 -> 1, 35-56 -> 0, 57-77 -> 2, >=78 -> 0
    ; (was a 78-byte beamtbl lookup; thresholds inlined 2026-07-08 to free
    ; driver bytes for the D-cache flag handling)
    LDA #0                                          ; class 0 (35-56, >=78 guard)
    CPX #78 : BCS fs_havecls                        ; transient/wrap read -> wait
    CPX #57 : BCS fs_cls2i                          ; 57-77 -> class 2
    CPX #35 : BCS fs_havecls                        ; 35-56 -> class 0
    CPX #15 : BCS fs_cls1i                          ; 15-34 -> class 1
.fs_cls2i
    LDA #2 : BNE fs_havecls                         ; <=14 (and 57-77) -> class 2
.fs_cls1i
    LDA #1
.fs_havecls
    STA jbase,Y                                     ; journal: class
    TXA:STA jbase+1,Y                               ; journal: T1hi at classify
    LDA jbase,Y
    BEQ fs_cls0
    CMP #1 : BEQ fs_cls1
    ; class 2: display of the old buffer already over — clear all, no wait
    LDA #&FF:STA jbase+2,Y                          ; journal: no wait
    JSR fs_clrtop
    JSR fs_clrbot
    JMP fs_logdone
.fs_cls0
    ; class 0: beam still in the top half — everything must wait for vsync
    LDA #2:STA &FE4D                                ; arm the vsync flag
.fs_w0
    LDA &FE4D:AND #2:BEQ fs_w0
    LDA #&4D:STA &FE45                              ; re-phase T1 to this vsync
    JSR fs_logwait
    JSR fs_clrtop
    JSR fs_clrbot
    JMP fs_logdone
.fs_cls1
    ; class 1: beam in the bottom half — top is clearable now; arm the vsync
    ; flag BEFORE clearing (it latches), then wait and clear the bottom
    LDA #2:STA &FE4D
    JSR fs_clrtop
    ; If vsync latched DURING the top clear, the edge is stale (up to
    ; ~5.5ms old): re-phasing T1 from it would set the beam clock that
    ; late and every later frame would classify against a shifted clock —
    ; clears then race the visible beam (mid-screen tearing/corruption).
    ; T1 free-runs at exactly one field (latch 19966 + 2), so when the
    ; edge is stale the existing phase is still correct: skip the
    ; re-phase and only re-lock on a freshly-observed edge.
    LDA &FE4D:AND #2:BNE fs_w1_stale
.fs_w1
    LDA &FE4D:AND #2:BEQ fs_w1
    LDA #&4D:STA &FE45                              ; fresh edge: re-phase T1
.fs_w1_stale
    JSR fs_logwait
    JSR fs_clrbot
    JMP fs_logdone
; fs_logwait: journal byte +2 = T1hi right after the vsync wait (should be
; ~$4D). fs_logdone: byte +3 = T1hi when the clears finished, then advance
; the ring index (wraps at 63 so record 63 stays as a scribble guard).
.fs_logwait
    LDA jidx:ASL A:ASL A:TAY
    LDA &FE45:STA jbase+2,Y
    RTS
.fs_logdone
    LDA jidx:ASL A:ASL A:TAY
    LDA &FE45:STA jbase+3,Y
    LDX jidx:INX
    CPX #63:BCC fs_jw
    LDX #0
.fs_jw
    STX jidx
    RTS
; fs_clrtop/fs_clrbot: clear the half of whichever buffer backhi now names
; (i.e. the one just taken OFF display; the CRTC shows the other one).
.fs_clrbot
    LDA backhi : CMP #&58 : BNE fs_cb1
    JMP clr58b
.fs_cb1
    JMP clr6Cb
.fs_clrtop
    LDA backhi : CMP #&58 : BNE fs_ct1
    JMP clr58t
.fs_ct1
    JMP clr6Ct

; --- read_input: scan keys, update angidx / position (with bounds) --------
; Manual keyboard scan, no OS: init put the keyboard in manual-scan mode
; (IC32 addr 3 low) with DDRA bits 0-6 out; writing a key number to $FE4F
; and reading bit 7 back (BIT -> N) gives that key's state directly.
; Keys (internal key numbers): $19 LEFT / $79 RIGHT turn one table step
; (= 4 angle-bytes); $39 UP / $29 DOWN move SPEED world units along the
; view direction, then bounds_or_revert undoes any step that leaves the
; clamp rectangle. All four keys are independent (no else-chains).
; Clobbers A,X (via the movement helpers).
.read_input
    ; D_FWD: 1 iff this frame's net move is forward-only. Turn keys need
    ; no explicit clear (the engine classifier compares the angle byte);
    ; DOWN clears it (an UP whose bounds-revert cancelled plus a live
    ; DOWN would otherwise flag a net-backward frame as forward).
    LDA #0:STA D_FWD
    LDA #&19:STA &FE4F : BIT &FE4F : BPL ri_nleft   ; cursor LEFT
    LDA angidx:CLC:ADC #1:AND #63:STA angidx
.ri_nleft
    LDA #&79:STA &FE4F : BIT &FE4F : BPL ri_nright  ; cursor RIGHT
    LDA angidx:SEC:SBC #1:AND #63:STA angidx
.ri_nright
    LDA #&39:STA &FE4F : BIT &FE4F : BPL ri_nup     ; cursor UP: forward
    JSR step_fwd
    JSR bounds_or_revert_fwd
    LDA #1:STA D_FWD
.ri_nup
    LDA #&29:STA &FE4F : BIT &FE4F : BPL ri_ndown   ; cursor DOWN: back
    JSR step_back
    JSR bounds_or_revert_back
    LDA #0:STA D_FWD
.ri_ndown
    JMP key_hud                                     ; H: HUD toggle (in the
                                                    ; $3DA0 pocket; RTSes)

; --- movement: position += / -= step table entry for angidx ---------------
; step_fwd: 24-bit position += step_tab[angidx] (s16 8.8 delta, applied to
; x then y). The delta is sign-extended by hand: the high-byte ADC uses #0
; or #$FF depending on the delta's sign bit (tested from the table's hi
; byte). step_back is the exact inverse (SBC with #0/#$FF), used both for
; reverse motion and to undo an out-of-bounds step, so fwd-then-back is
; always bit-exact. Clobbers A,X.
.step_fwd
    LDA angidx:ASL A:ASL A:TAX                      ; idx*4 into step table
    CLC
    LDA pxf:ADC step_tab,X:STA pxf
    LDA pxl:ADC step_tab+1,X:STA pxl
    LDA step_tab+1,X:BMI sf_xneg
    LDA pxh:ADC #0:STA pxh
    JMP sf_y
.sf_xneg
    LDA pxh:ADC #&FF:STA pxh
.sf_y
    CLC
    LDA pyf:ADC step_tab+2,X:STA pyf
    LDA pyl:ADC step_tab+3,X:STA pyl
    LDA step_tab+3,X:BMI sf_yneg
    LDA pyh:ADC #0:STA pyh
    RTS
.sf_yneg
    LDA pyh:ADC #&FF:STA pyh
    RTS

.step_back
    LDA angidx:ASL A:ASL A:TAX
    SEC
    LDA pxf:SBC step_tab,X:STA pxf
    LDA pxl:SBC step_tab+1,X:STA pxl
    LDA step_tab+1,X:BMI sb_xneg
    LDA pxh:SBC #0:STA pxh
    JMP sb_y
.sb_xneg
    LDA pxh:SBC #&FF:STA pxh
.sb_y
    SEC
    LDA pyf:SBC step_tab+2,X:STA pyf
    LDA pyl:SBC step_tab+3,X:STA pyl
    LDA step_tab+3,X:BMI sb_yneg
    LDA pyh:SBC #0:STA pyh
    RTS
.sb_yneg
    LDA pyh:SBC #&FF:STA pyh
    RTS

; --- derive_raw: PXRAW/PYRAW = 24-bit 8.8 position >> 5 (s16 result) ------
; In: pxf..pyh. Out: $90/$91 = PXRAW, $92/$93 = PYRAW. Clobbers A,X,$EC.
; Each shift step is an arithmetic >>1 of the 24-bit value: CMP #$80 copies
; the top byte's sign into C, then ROR ripples it down through all 3 bytes.
.derive_raw
    ; raw s16 = (24-bit 8.8 position) >> 5 — i.e. bits [20:5]. Shift the
    ; full 24 bits right 5 and keep the LOW TWO bytes of the result
    ; (the top byte is sign extension once raw fits s16).
    LDA pxf:STA &90
    LDA pxl:STA &91
    LDA pxh:STA &EC
    LDX #5
.dr_x
    LDA &EC:CMP #&80:ROR &EC:ROR &91:ROR &90
    DEX:BNE dr_x
    LDA pyf:STA &92
    LDA pyl:STA &93
    LDA pyh:STA &EC
    LDX #5
.dr_y
    LDA &EC:CMP #&80:ROR &EC:ROR &93:ROR &92
    DEX:BNE dr_y
    RTS

; --- floor_vz: VZ ($04) tracks the grid floor under the derived raws ------
; In: PXRAW/PYRAW ($90-$93). Out: VZ ($04) moved at most 1 prescaled unit
; toward floor_tab[celly*36 + cellx] (see the grid comment at floor_tab):
;   cellx = (rawx+1936)>>7 (0..35), celly = (rawy+1582)>>7 (0..21)
; The 1-unit-per-frame easing ramps stairs/lifts smoothly instead of
; snapping the eye height. Clobbers A,Y,$EC-$EE.
.floor_vz
    LDA &90:CLC:ADC #&90:STA &EC                    ; rawx + 1936 ($790)
    LDA &91:ADC #&07:STA &ED
    LDA &EC:ASL A                                   ; C = bit 7 of lo
    LDA &ED:ROL A                                   ; A = (hi<<1)|(lo>>7) = cellx
    STA &EC                                         ; cellx (0..35)
    LDA &92:CLC:ADC #&2E:STA &ED                    ; rawy + 1582 ($62E)
    LDA &93:ADC #&06:STA &EE
    LDA &ED:ASL A
    LDA &EE:ROL A                                   ; A = celly (0..21)
    TAY
    LDA frow_lo,Y:CLC:ADC &EC:STA &EC
    LDA frow_hi,Y:ADC #0:STA &ED
    LDA &EC:CLC:ADC #LO(floor_tab):STA &EC
    LDA &ED:ADC #HI(floor_tab):STA &ED
    LDY #0
    LDA (&EC),Y                                     ; target VZ (s8, -15..21)
    CMP &04
    BEQ fv_done
    ; move VZ one prescaled unit per frame toward the target (smooth stairs);
    ; |diff| <= ~36 so the s8 subtract cannot overflow and N is the true sign
    SEC:SBC &04
    BMI fv_down
    INC &04
    RTS
.fv_down
    DEC &04
.fv_done
    RTS

; --- bounds check on the derived raws; revert the step if outside ---------
; s16 compare: in-range iff RAW >= MIN and RAW <= MAX.
; bounds_or_revert_fwd/back: re-derive the raws for the just-stepped
; position, test them, and undo the step (with the exact-inverse helper)
; if any of the four limits failed. The stale raws left by a revert are
; harmless: the frame loop re-derives before rendering.
.bounds_or_revert_fwd
    JSR derive_raw
    JSR bounds_ok
    BCS bor_ok1
    JSR step_back                                   ; undo
.bor_ok1
    RTS
.bounds_or_revert_back
    JSR derive_raw
    JSR bounds_ok
    BCS bor_ok2
    JSR step_fwd                                    ; undo
.bor_ok2
    RTS

; bounds_ok — C=1 iff (PXRAW,PYRAW) is inside the clamp rectangle.
; Each test is the standard signed-16 '>=': subtract (keeping only the high
; byte's flags) and correct N by V (EOR #$80 when the subtract overflowed);
; N set after correction means the difference is negative -> out of range.
; Clobbers A.
.bounds_ok
    ; x >= RAWX_MIN ?
    LDA &90:SEC:SBC #LO(RAWX_MIN)
    LDA &91:SBC #HI(RAWX_MIN)
    BVC bo_c1
    EOR #&80
.bo_c1
    BMI bo_bad
    ; x <= RAWX_MAX ?
    LDA #LO(RAWX_MAX):SEC:SBC &90
    LDA #HI(RAWX_MAX):SBC &91
    BVC bo_c2
    EOR #&80
.bo_c2
    BMI bo_bad
    ; y >= RAWY_MIN ?
    LDA &92:SEC:SBC #LO(RAWY_MIN)
    LDA &93:SBC #HI(RAWY_MIN)
    BVC bo_c3
    EOR #&80
.bo_c3
    BMI bo_bad
    ; y <= RAWY_MAX ?
    LDA #LO(RAWY_MAX):SEC:SBC &92
    LDA #HI(RAWY_MAX):SBC &93
    BVC bo_c4
    EOR #&80
.bo_c4
    BMI bo_bad
    SEC
    RTS
.bo_bad
    CLC
    RTS


; --- 64-entry movement step table: premultiplied 8.8 deltas ---------------
; forward = (cos(a), sin(a)) in world units; 8.8 prescaled delta =
; world_step * 256/8 = *32. Entry: dx lo, dx hi, dy lo, dy hi (s16).
; The +65536.5 / AND &FFFF idiom is round-to-nearest of a possibly-negative
; value into u16 two's complement (beebasm INT truncates toward zero).
.step_tab
FOR i, 0, 63
    EQUW INT(SPEED * 32 * COS(i * PI / 32) + 65536.5) AND &FFFF
    EQUW INT(SPEED * 32 * SIN(i * PI / 32) + 65536.5) AND &FFFF
NEXT

; --- T1hi -> beam class (same boundaries as anim_drv's table; see the
; flip_sched header). Only 78 entries — flip_sched pre-filters H >= 78
; to class 0 — where anim_drv pads the table to 256 instead. ---

; --- floor-height grid: 36x22 cells of 128 world units over the clamp
; bounds, holding prescaled VZ (= _prescale_height(player_floor+41)),
; sampled at cell centres from the Python float BSP at build time.
; cellx = (rawx+1936)>>7, celly = (rawy+1582)>>7, byte = grid[celly*36+cellx].
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
.clr_end
ASSERT clr_end <= MAIN_BASE ; MUST NOT touch the engine CODE region
SAVE "WALKDRV", DRV_ORG, clr_end, DRV_ORG
