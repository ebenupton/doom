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

; ============================================================================
; walk_drv -- the game driver, ca65 (converted from beebasm 2026-08-30).
;
; It used to be assembled SEPARATELY, after the engine linked, against a
; generated engine_syms.inc of addresses scraped from the ld65 map.  That
; dance is gone: the driver is a link unit and IMPORTS the engine entries
; by name, so a moved entry is a LINK ERROR instead of a stale address in
; a generated file.
; ============================================================================
.include "../abi.inc"
.include "../layout.inc"          ; table homes (ROM_DRV_*) as CONSTANTS,
                                  ; per-build, rather than literals here

angidx = DV_ANGIDX          ; view angle index 0..63 (angle byte = idx*4)
backhi = DV_BACKHI          ; hidden-buffer page hi ($58 or $6C)
pxf    = DV_PXF          ; player x: 8.8 prescaled, 24-bit (frac, lo, hi)
pxl    = DV_PXL
pxh    = DV_PXH
pyf    = DV_PYF
pyl    = DV_PYL
pyh    = DV_PYH
hud_en   = DV_HUD_EN        ; debug HUD on/off (H key toggles)
hud_prev = DV_HUD_PREV        ; H-key state last frame (press-edge debounce)
; ---        ; per-frame flag: this frame's move was forward-only
; (vsync journal RETIRED 2026-08-09 — the flip timing is validated and the
; page was reclaimed for the quarter-square tables; the class logic below
; is unchanged, the flight recorder is gone. JBASE/DV_JIDX freed.)
                          ; (STEPTAB died with the single-step momentum rework —
                          ;  it had no reader anywhere)
space_prev = DV_SPACE_PREV   ; SPACE edge-detect state -- from the ABI now,
mv_dir     = DV_MV_DIR       ; not a private DRV_VARS+n copy. Those private
                             ; offsets were invisible to the ABI table, so
                             ; adding DV_HUD_FONT at +11 silently ate both
                             ; and broke input. gen_abi now checks the block
                             ; for collisions.

SPEED = 12              ; world units per frame of forward motion

; map bounds in RAW world units relative to MAP_CENTER (1200,-3248),
; with a 32-unit margin: x in [-768,3808] -> raw [-1968+32, 2608-32]
RAWX_MIN = $F870        ; -1936 as u16
RAWX_MAX = $0A10        ;  2576
RAWY_MIN = $F9D0        ; -1584 (same WORLD clamp; center moved -3250->-3248)
RAWY_MAX = $0490        ;  1168

; BOTH BUILDS since 2026-09-02 (the flat-first-class purge): the
; parasite SHIPS the banked walk driver verbatim -- 22K identity is
; BYTE identity.  It never RUNS on the copro (tubedrv is the driver
; there), so its HW touches (CRTC, keyboard, T1) are inert bytes.

.import view_setup
.import render_frame
.import span_init
.import anim_tick
.import ANIM_FIELDS
.import anim_init
.import bca_tail_postrc
.import box_classify
.import pq_pump_op
.import plotq_drain
.import plotq_arm
.import plotq_off
.import sqr_fill_cold
.import obj_anyb_fill
.import zp_br_px, zp_br_py
.import obj_key
.import fb_clr0
.import fb_clr1
.import fb_clr_back
.import pmove_try
.import pmove_use
.import pm_oldx
.import pm_vz
.import pm_ux
.import pmove_zonly
.import pm_frame

ENG_VIEW_SETUP = view_setup
ENG_RENDER_FRAME = render_frame
ENG_SPAN_INIT = span_init
ENG_ANIM_TICK = anim_tick
ENG_ANIM_FIELDS = ANIM_FIELDS
ENG_ANIM_INIT = anim_init
ENG_TAIL_POSTRC = bca_tail_postrc
ENG_BOX_CLASSIFY = box_classify
ENG_PQ_PUMP_OP = pq_pump_op
ENG_PLOTQ_DRAIN = plotq_drain
ENG_PLOTQ_ARM = plotq_arm
ENG_PLOTQ_OFF = plotq_off
ENG_SQR_FILL = sqr_fill_cold
ENG_OBJ_FILL = obj_anyb_fill
ENG_FB_CLR0 = fb_clr0
ENG_FB_CLR1 = fb_clr1
ENG_FB_CLR_BACK = fb_clr_back
ENG_PMOVE_TRY = pmove_try
ENG_PMOVE_USE = pmove_use
ENG_PM_OLDX = pm_oldx
ENG_PM_VZ = pm_vz
ENG_PM_UX = pm_ux
ENG_PMOVE_ZONLY = pmove_zonly
ENG_PM_FRAME = pm_frame

tabbase = ROM_DRV_SINCOS_C ; sincos table: 64 x 8 bytes, BANK C (from the
                          ; MAP, not a literal -- banked_bsp seeds it;
                          ; seeds it; page 6 before reading — 2026-08-17: both
                          ; driver tables left bank A so its bottom 19 pages
                          ; could come free for the main-RAM caches)
USEVEC  = ROM_DRV_USEVEC_C           ; SPACE use-trace vectors: 64 x 4 (ux,uy s16 raw), bank A since 2026-09-02

.segment "DRV"
; ---------------------------------------------------------------------------
; drv — one-time boot init, then falls through into the frame loop.
; Entry: JMP $2000 from the !BOOT loader (banks 4/6/7 = L0/C/L2 already
; copied to sideways RAM, LOW loaded, MODE 4 selected). Never returns.
; Interrupts stay off for ever (SEI; direct hardware only from here on —
; the OS workspace is dead and reused, e.g. the vsync journal at $0300).
; Phases:
;   1. spawn position/VZ            5. keyboard -> manual-scan mode
;   2. engine ROM-table pointers    6. render caches (RCACHE, VXCACHE)
;   3. CRTC 256x160 non-interlaced  7. animated-sector init (bank L2)
;   4. T1 field-locked beam clock   8. driver state + clear both buffers
; ---------------------------------------------------------------------------
drv:
    ; --- MOS font base for the debug HUD, decided HERE and only here ----
    ; The glyphs are not at a fixed address (OS 1.2 $C000, MOS 3.20
    ; $F900), so ask the OS which machine this is. This is the ONLY
    ; moment it can be asked: SEI goes down on the next instruction and
    ; by the house rule nothing calls the OS after boot.
    ; OSBYTE 129 with Y=$FF is "read OS version" -- with any other Y it
    ; is INKEY and would WAIT for a key.
    LDA #$81
    LDX #0
    LDY #$FF
    JSR $FFF4   ; X = OS version
    LDA #<(HUD_FONT_B)
    LDY #>(HUD_FONT_B)
    ; Known INKEY-256 answers: $FF = OS 0.10 (and jsbeeb's OS 1.2 image
    ; answers $FF too — measured); 0/1/2 = OS 1.x / B+; $E0 = Electron.
    ; The ANDY-font machines are the Master family: $FD = MOS 3.20,
    ; $FC = Master ET, $F5 = Compact (MOS 5).  The old test (`>= $80 ->
    ; B font`) swallowed ALL of those into the OS 0.10 arm and drew
    ; Master HUDs from $C000 = filing-system workspace: the garbage HUD.
    CPX #$F0
    BCC drv_fontset   ; 0-2, $E0... = the $C000-font classes
    CPX #$FF
    BEQ drv_fontset   ; $FF = OS 0.10 / jsbeeb B
    LDA #<(HUD_FONT_MASTER)
    LDY #>(HUD_FONT_MASTER)
drv_fontset:
    STA DV_HUD_FONT
    STY DV_HUD_FONT+1
    SEI
    LDX #$DF
    TXS   ; stack tops out at $01DF:
                                                    ; SQR_MIRROR owns $01E0-$01FF
                                                    ; (rebuilt at first render,
                                                    ; but never push into it)
    ; --- REAL-HW hardening: ZERO PAGE (2026-08-23).  The engine reads ZP
    ;     bytes it never writes and relies on them being 0 -- see
    ;     tools/zpvirgin.py, which lists every such consumer.  On a real
    ;     Beeb ZP arrives holding OS/BASIC workspace, not zeros, and no
    ;     loaded file covers $00-$FF (LOW starts at $1600).  plotq_mode
    ;     ($A1) is the sharp one: flip_sched only writes it at the END of
    ;     a frame, so a garbage bit 7 queues the WHOLE first frame.
    ;     Safe here: SEI is held, this block makes no OS calls, and by
    ;     the house rule nothing calls the OS after boot.  Clearing to 0
    ;     reproduces the py65 image every harness validates against.
    LDA #0
    TAX
zpclr:
    STA $00,X
    INX
    BNE zpclr
    LDA #0
    STA $FE34   ; Master: ACCCON off (harmless on B)
    ; (respawn is NOT called here — see the end of init. It writes
    ;  pm_vz, which is a PM_SCRATCH slot overlaying THIS block.)
    ; --- CRTC: narrow 256x160 centred, cursor off (R12/R13 set per flip) ---
    LDA #1
    STA $FE00
    LDA #32
    STA $FE01
    LDA #2
    STA $FE00
    LDA #45
    STA $FE01
    LDA #6
    STA $FE00
    LDA #20
    STA $FE01
    LDA #7
    STA $FE00
    LDA #28
    STA $FE01
    LDA #8
    STA $FE00
    LDA #0
    STA $FE01   ; R8=0: interlace OFF. The MODE 4
    ; default (R8=1, interlace sync) makes every field 312.5 lines = 20000us,
    ; which drifts the 19968us T1 field lock by 32us/field (beam classes
    ; rotate through all phases every ~12s -> periodic clear-vs-beam races),
    ; and shimmers 1px lines at 25Hz. Non-interlaced: field = exactly 312
    ; lines = 19968us, T1 lock is exact and the raster is stable.
    LDA #10
    STA $FE00
    LDA #$20
    STA $FE01   ; R10 = cursor non-display
    JSR cur_park                                    ; park it out of view too
    ; --- System VIA T1 field lock (see anim_drv for the full rationale):
    ;     free-running T1, period 19968us = exactly one non-interlaced
    ;     312-line PAL field, phase-locked once to the vsync edge (CA1 IFR
    ;     bit 1). T1's high byte is then a drift-free beam-position clock
    ;     (4-line granularity) that flip_sched reads every frame. ---
    LDA $FE4B
    AND #$1F
    ORA #$40
    STA $FE4B   ; ACR: T1 continuous, PB7 off,
                                                    ; and T2 TIMED (bit 5): the
                                                    ; OS leaves it set = count
                                                    ; PB6 pulses, so T2 sat at
                                                    ; $FFFF and the frame clock
                                                    ; read pure noise
    LDA #$FE
    STA $FE46   ; T1 latch = $4DFE = 19966 (+2)
    LDA #$4D
    STA $FE47
    LDA #2
    STA $FE4D   ; clear stale vsync flag
vsy0:
    LDA $FE4D
    AND #2
    BEQ vsy0   ; wait for vsync edge
    LDA #$4D
    STA $FE45   ; start T1: phase = time since vsync
    LDA #$FF
    STA $FE48
    STA $FE49   ; T2 = free 1MHz odometer
                                                    ; (the clock prevs are
                                                    ; seeded at the END of
                                                    ; init — see there)
    ; --- keyboard: manual scan mode (IC32 addr 3 = 0), DDRA 0-6 out ---
    LDA #3
    STA $FE40
    LDA #$7F
    STA $FE43
    ; --- rotation-coherence bbox cache: clear header state, enable.
    ;     RCACHE lives in the bank L2 window ($AD00 data; header/bitmaps at
    ;     $B460-$B4E8) — page L2 for the init writes; the frame loop pages
    ;     banks explicitly before every engine call anyway. Zero-init is
    ;     safe: even a false-stable first frame sees COMPUTED=0 -> all
    ;     checks take the cold path -> correct results. ---
    LDA #7
    STA $FE30                                       ; page bank L2
    LDA #0
    TAX
rcinit:
    STA RCACHE_STATE,X
    INX
    CPX #RCACHE_STATE_LEN
    BNE rcinit
    LDA #1
    STA RCACHE_ENABLE
    LDA #<(ENG_TAIL_POSTRC)    ; frame-class VECTORS (zp.inc zp_tail_vec
    STA $CA                     ; $CA/$CB + zp_bv_entry $63/$64): seed the
    LDA #>(ENG_TAIL_POSTRC)    ; moving targets so the first frame is sane
    STA $CB                     ; even before bca_frame runs — boot garbage
    LDA #<(ENG_BOX_CLASSIFY)   ; in a vector would be a wild indirect JMP,
    STA $63                     ; not a soft mis-class
    LDA #>(ENG_BOX_CLASSIFY)
    STA $64
    LDA #6
    STA $FE30   ; pq_pump_op lives in the BANK C window —
    LDA #<(pq_pump)            ; page it in for the poke (the RCACHE write
    STA ENG_PQ_PUMP_OP+1        ; above left bank 7 selected: poking there
    LDA #>(pq_pump)            ; would shred node data — the CPM scar
    STA ENG_PQ_PUMP_OP+2        ; class; jsbeeb caught it 2026-08-14)
                                ; (no bank restore: the init tail is main-
                                ; only and anim_glue_init pages for itself)
    LDA #0
    STA $A1
    STA $A0   ; mode DIRECT until the first flip (the
                                ; engine ships dv_emit_op = JMP plot_v, so
                                ; the flag alone is consistent here)
    ; --- translation-coherence vertex cache (VXCACHE): zero the valid bitmap
    ;     page, then enable (the scalar state ships as LOW zeros at
    ;     $19A0-$19FF since the window slide). Zero-init is safe:
    ;     first enabled frame is cold (prev_ab sentinel path) and every
    ;     entry stores before it loads. ---
    LDA #0
    TAX
vxinit:
    STA VXCACHE_STATE,X             ; the whole bitmap page ($0700: VALID+
    INX                         ; VDONE+VXCACHE_VALID+RCACHE_COMPUTED —
    BNE vxinit                  ; boot-garbage safety, 256 bytes)
    LDA #1
    STA VXCACHE_ENABLE
    ; --- animated sectors: init state machines + lazy patch hook (glue
    ;     at $3DA0 pages bank L2; must run AFTER vxinit's $05xx zeroing) ---
    JSR anim_glue_init
    ; --- init state ---
    LDA #1
    ; (the forward-coherence bbox cache went 2026-09-04: no enable, no
    ;  D_FWD -- read_input no longer computes one)
    LDA #$6C
    STA backhi
    ; --- spawn pose LAST, with the clock seed, and for the same reason:
    ; respawn writes pm_vz = PM_SCRATCH+$3F = $1A3F, and PM_SCRATCH
    ; OVERLAYS THIS INIT BLOCK. Called from the top (where it used to
    ; live) it wrote $06 over the high byte of the `STA $FE00` that
    ; selects R10 -- turning it into `STA $0600`. The CRTC address
    ; register then still held 8 from the R8 write, so the following
    ; `LDA #$20 : STA $FE01` put $20 into R8 (display-enable skew = 2
    ; CHARACTERS = 16 bytes: the whole picture shifted with the right
    ; edge wrapping) and R10 never got its cursor-off value, leaving
    ; the MOS blink cursor on. ONE stray byte, BOTH artefacts.
    ; RULE: nothing called from init may write PM_SCRATCH until the PC
    ; is past the overlay ($2000..$208A today) -- that is why this and
    ; mv_frame sit down here.
    .assert * > ENG_PM_VZ, error, "GUARD: the call site must"
                                                    ; sit ABOVE the scratch slot
                                                    ; respawn writes, or it
                                                    ; shreds unexecuted init
    JSR respawn                                     ; pos/angle/VZ/pm seeds
    ; Seed the frame clock's prevs LAST. This must come after every
    ; instruction of the init block has run: pm_frame's scratch OVERLAYS
    ; that block at PM_SCRATCH (= DRV_ORG), so calling it earlier
    ; rewrites the init code still ahead of the PC (it shredded the boot
    ; screen when this sat up by the T1 lock, 2026-08-15). The literal
    ; $2000/$208A this comment used to quote were the 2026-08-15 driver
    ; org, three window slides ago. With no keys held the call is a
    ; no-op: it just stores now->prev, so the first real frame gets an
    ; honest delta. (It said "and zero momentum" until 2026-08-29 —
    ; momentum retired 2026-08-22.)
    JSR mv_frame
    LDA #BANK_C
    STA $FE30   ; the clears live in bank C
    JSR ENG_FB_CLR0
    JSR ENG_FB_CLR1
; ---------------------------------------------------------------------------
; frame — main loop, one iteration per rendered frame (paced by flip_sched's
; vsync waits when the beam demands one; free-running otherwise).
; Pseudocode:
;   read_input                  keys -> 4 input bits (fwd/back/left/right)
;   mv_frame                    field clock -> pm_frame, which owns ROTATION,
;                               position, slide, D_FWD and the $90-$93 raws.
;                               Both the walk and the turn are scaled by the
;                               field count, so neither changes with the frame
;                               rate; the sincos load below reads the angidx
;                               pm_frame just wrote, so a turn lands the SAME
;                               frame it was pressed.
;   ZP $00-$03/$9D/$9E <- pos   8.8 frac/lo + s16 integer high bytes
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
frame:
    JSR read_input
    JSR mv_frame                                    ; field clock -> rotate +
                                                    ; walk (pages WALK)
    ; --- position -> engine ZP ---
    LDA pxf
    STA zp_br_px                                    ; the 8.8 FRACTION moved to
                                                    ; the WORK segment in the
                                                    ; 2026-08-31 zp rotation --
                                                    ; the old STA $00 fed LC
                                                    ; clip scratch and the view
                                                    ; rendered EVERY walked
                                                    ; frame with frac 0: the
                                                    ; 8-world-unit camera snap
                                                    ; = THE judder (2026-09-01)
    STA $00                                         ; (old cell: harmless, kept
                                                    ;  for any straggler reads)
    LDA pxl
    STA $01
    LDA pxh
    STA $9D
    LDA pyf
    STA zp_br_py
    STA $02
    LDA pyl
    STA $03
    LDA pyh
    STA $9E
    JSR mv_reval                                    ; DOOM z (rides live lifts;
                                                    ; $90-$93 raws come from
                                                    ; pm_frame — see its ABI)
    ; --- sincos + view angle from table[angidx] (bank C) ---
    LDA #BANK_C
    STA $FE30
    LDA #0
    STA $ED
    LDA angidx
    ASL A
    ROL $ED
    ASL A
    ROL $ED
    ASL A
    ROL $ED
    STA $EC
    LDA $ED
    CLC
    ADC #>(tabbase)
    STA $ED
    LDY #0
    LDA ($EC),Y
    STA $05
    INY
    LDA ($EC),Y
    STA $06
    INY
    LDA ($EC),Y
    STA $07
    INY
    LDA ($EC),Y
    STA $08
    INY
    LDA ($EC),Y
    STA $09
    INY
    LDA ($EC),Y
    STA $0A
    INY
    LDA ($EC),Y
    STA BCA_AB   ; view angle byte
    JSR anim_glue_tick                              ; advance movers (lazy patch)
    ; --- render into hidden buffer (cleared by previous flip_sched) ---
    LDA backhi
    STA $70
    LDA #BANK_L0
    STA $FE30
    JSR ENG_VIEW_SETUP   ; view_setup (real address, from the map)
    LDA #BANK_C
    STA $FE30
    JSR ENG_SPAN_INIT   ; span_init / pool
    LDA #BANK_L0
    STA $FE30
    JSR ENG_RENDER_FRAME   ; (init is inline at render entry)
    JSR flip_sched
    JMP frame

; ptrtab must clear the driver variable block (angidx.. live at
; $3D80-$3D88 as fixed equates; the sincos table is overlaid at $3E00).
; An extra init block once pushed it INTO the variables - the engine's
; table pointers then got clobbered at runtime by angidx/etc stores and
; every frame rendered pixel-free while the loop ran happily. Pin it.
; (.ptrtab retired 2026-07-10 — the engine assembles its ROM bases from
; src/layout.inc; the $0BE8 block is dead. $3D90-$3D9F freed.)
; The driver's ORG'd span is  code | glue (DRV_GLUE) | vars (DRV_VARS) |
; input+flip (DRV_CLR).  DRV_VARS used to sit at $1B80, in the MIDDLE of
; the code, which capped it at 384 B; it moved to the 16 free bytes below
; DRV_CLR on 2026-08-24 so the OSBYTE font probe above would fit.
drv_end:

; --- unrolled framebuffer clears + flip scheduler: identical to anim_drv --
; --- animated-sector glue: page bank L2 and enter the anim jump table
;     ($3DA0-$3DBF pocket between ptrtab and the sincos table at $3E00) ---
; (was ORG DRV_GLUE -- the sections are contiguous now; DRV_GLUE/DRV_CLR
;  were layout markers for the beebasm ORGs, not addresses anything
;  outside this file depends on.  Only DRV_ORG is a contract: !BOOT
;  and both boot stubs JMP it.)
; anim_glue_init: one-time mover-state init + SMC-installs the per-subsector
; visibility hook in the renderer. anim_glue_tick: per-frame logical advance
; of every mover's height state machine (no table writes; the hook patches
; the read tables lazily when a mover becomes visible — see src/bsp/anim.s /
; anim_sectors.py). The jump table + tick code are MAIN now (2026-07-10
; reshuffle) but the tick reads ANIM_CFG in bank L2, so the page-in stays. Leaves L2 paged (the frame loop
; re-pages banks before every engine call). Clobbers A + whatever anim uses.
anim_glue_init:
    LDA #0
    STA hud_en
    STA hud_prev   ; HUD off at boot
    LDA #7
    STA $FE30
    ; (RNS stack-page copy retired 2026-07-12: the vectoring block lives
    ; in engine CODE now; page 1 is reserved headroom.)
    JMP ENG_ANIM_INIT
anim_glue_tick:
    LDA #7
    STA $FE30   ; (ANIM_FIELDS is stored by mv_frame -- the
    JMP ENG_ANIM_TICK           ;  glue pocket has no room for the copy)
key_hud:
    JSR obj_key                                     ; "O": billboard objects
                                                    ;  on/off (engine-side)
    ; H key: toggle the debug HUD on the press edge only (hud_prev holds
    ; last frame's state, so holding the key flips it exactly once).
    LDA #$54
    STA $FE4F
    BIT $FE4F
    BMI kh_dn   ; H internal code $54
    LDA #0
    STA hud_prev
    RTS
kh_dn:
    LDA hud_prev
    BNE kh_done   ; still held: no retrigger
    LDA #1
    STA hud_prev
    LDA hud_en
    EOR #1
    STA hud_en
kh_done:
    RTS
hud_glue:
    ; When enabled, draw "X=hhhh Y=hhhh R=hh" (OS ROM font) onto the top
    ; row of the buffer just rendered, before flip_sched displays it.
    LDA hud_en
    BNE hg_on
    RTS
hg_on:
    LDA #6
    STA $FE30   ; HUD code lives in bank C
    JSR HUD_ENTRY                                   ; hud_draw
    LDA #4
    STA $FE30   ; restore a render bank
    RTS
                                        ; block (the vars left the driver span
                                        ; for the WORK segment, 2026-08-26)
; (was ORG DRV_CLR -- the sections are contiguous now; DRV_GLUE/DRV_CLR
;  were layout markers for the beebasm ORGs, not addresses anything
;  outside this file depends on.  Only DRV_ORG is a contract: !BOOT
;  and both boot stubs JMP it.)
; ---------------------------------------------------------------------------
; The framebuffer clears used to live here (~145 B of unrolled STAs). They
; moved into BANK C on 2026-08-16 (src/clip/fbclear.s) to buy main RAM
; back: call ENG_FB_CLR_BACK / ENG_FB_CLR0 / ENG_FB_CLR1 with bank C
; paged. Both call sites below page it for the plot-queue drain anyway.
; ---------------------------------------------------------------------------

; The cadence probe was retired 2026-08-17: it logged the beam phase (T1hi)
; to $1100,X once per frame, indexed by a frame counter at $0A50. Neither
; address was free. $1100 is a whole page of main RAM, and $0A50 is NOT the
; dead zp_side slot its comment claimed — it is VC_RLO+$50, the cached
; rotated-r low byte of vertex 80, so the INC corrupted one vertex's cache
; by 1 LSB every frame (invisible: no harness runs the driver).
flip_sched:
    ; --- finalize the run-ahead queue (fast frames only: the flip vsync
    ; never arrived mid-render, so the whole frame sits queued). Normal
    ; frames: the pump already cleared/drained/switched to direct. ---
    LDA $A1                                         ; plotq_mode (zp.inc)
    BPL fs_done_q
    LDA $FE4D
    AND #2
    BNE fs_wq_stale   ; latch already set: the
                                                    ; edge is STALE — skip the
                                                    ; T1 re-phase (free-run is
                                                    ; exact; see fs_w1 history)
fs_wq:
    LDA $FE4D
    AND #2
    BEQ fs_wq   ; wait the flip vsync
    LDA #$4D
    STA $FE45   ; fresh edge: re-phase T1
fs_wq_stale:
    LDA #BANK_C
    STA $FE30   ; clear + drain both live
    JSR ENG_FB_CLR_BACK                             ;  in bank C
    LDA $A0                                         ; plotq_n: 63 = no lines
    CMP #63                                         ; (count-down empty home)
    BEQ fs_q_empty
    JSR ENG_PLOTQ_DRAIN                             ; (the pump forces at 64)
fs_q_empty:
    JSR ENG_PLOTQ_OFF                               ; direct mode (also puts
fs_done_q: ;  dv_emit_op back)
    JSR hud_glue                                    ; debug HUD onto the back buffer
    ; R12/R13 straddle guard: the pair of writes must not bracket the CRTC
    ; frame-top reload (e=5632us -> T1 = $37FE), or one field displays a
    ; mixed address. Spin while H is in [$36,$38] (<= 768us, rare).
fs_guard:
    LDA $FE45
    CMP #$36
    BCC fs_go
    CMP #$39
    BCS fs_go
    JMP fs_guard
fs_go:
    ; CRTC screen start = address/8: R12 = backhi>>3, R13 = (backhi$7)<<5
    ; Screen start = base/8, NO bias — matches banked_boot.asm and both
    ; tube hosts (crtc12/crtc13 = $08/$80, $0B/$00, $0D/$80). A -2
    ; character bias was briefly shipped here on a bad measurement: the
    ; pattern used to measure it was being overwritten by the renderer
    ; mid-frame. tools/crtc_probe.asm settles it with no engine running
    ; — FB byte 0 IS the first displayed pixel with these registers.
    LDA #12
    STA $FE00
    LDA backhi
    LSR A
    LSR A
    LSR A
    STA $FE01
    LDA #13
    STA $FE00
    LDA backhi
    AND #7
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    STA $FE01
    LDA backhi
    EOR #($58 ^ $6C)
    STA backhi   ; backhi = buffer coming off display
    ; arm the run-ahead pipeline for the next frame: clear the vsync
    ; latch, enqueue mode, empty queue. The next frame's plots queue
    ; until the pump sees this flip's vsync (buffer off display), then
    ; it full-clears, drains and drops to direct — the old class-0/1
    ; waits are covered by render compute.
    LDA #2
    STA $FE4D
    LDA #BANK_C
    STA $FE30   ; dv_emit_op lives in bank
    JSR ENG_PLOTQ_ARM                               ;  C — page it to patch.
    RTS                                             ; (the next frame pages
                                                    ;  L0 itself, so leaving
                                                    ;  C live is fine.
                                                    ;  plotq_arm owns the
                                                    ;  count-down home n=63:
                                                    ;  the old LDA#0/STA $A0
                                                    ;  "empty" reset here made
                                                    ;  every frame's first
                                                    ;  enqueue WRAP to FULL
                                                    ;  and the pump drain
                                                    ;  63 slots of stale
                                                    ;  garbage -- the jsbeeb
                                                    ;  static-line artefacts,
                                                    ;  2026-09-01)

; --- pq_pump: poked into ENG_PQ_PUMP_OP at init; the engine calls it
; after every enqueue (all enqueue sites are in the emit cascade, bank C
; live). n==0 after an append means the queue is FULL (64 entries). ---
pq_pump:
    LDA $A0
    BMI pq_force   ; $FF = FULL (count-down)
    LDA $FE4D
    AND #2
    BEQ pq_ret   ; vsync not yet: queue on
pq_ready:
    LDA #BANK_C
    STA $FE30   ; (explicit: the emit
    JSR ENG_FB_CLR_BACK                             ;  cascade leaves C live,
    JSR ENG_PLOTQ_DRAIN                             ;  but do not lean on it)
    JSR ENG_PLOTQ_OFF                               ; direct from here on
pq_ret:
    RTS
pq_force:
    LDA $FE4D
    AND #2
    BEQ pq_force   ; full before vsync: wait
    JMP pq_ready                                    ; (no T1 re-phase: the
                                                    ; mid-frame latch is stale
                                                    ; by an unknown few lines)

; --- read_input: scan keys, update angidx / position (with bounds) --------
; Manual keyboard scan, no OS: init put the keyboard in manual-scan mode
; (IC32 addr 3 low) with DDRA bits 0-6 out; writing a key number to $FE4F
; and reading bit 7 back (BIT -> N) gives that key's state directly.
; Keys (internal key numbers): $19 LEFT / $79 RIGHT turn, $39 UP / $29
; DOWN walk. All four are now just INPUT BITS for ENG_PM_FRAME
;   b0 fwd  b1 back  b2 left  b3 right
; which owns position, rotation, slide and D_FWD. Rotation moved there
; (2026-08-22) because only pm_frame knows the field count: stepping
; angidx here turned one step per FRAME, i.e. faster the faster the
; frame rate. All four keys are independent (no else-chains).
; Clobbers A,X.
read_input:
    LDX #0
    LDA #$19
    STA $FE4F
    BIT $FE4F
    BPL ri_nleft   ; cursor LEFT
    LDX #4
ri_nleft:
    LDA #$79
    STA $FE4F
    BIT $FE4F
    BPL ri_nright   ; cursor RIGHT
    TXA
    ORA #8
    TAX
ri_nright:
    LDA #$39
    STA $FE4F
    BIT $FE4F
    BPL ri_nup   ; cursor UP: forward
    TXA
    ORA #1
    TAX
ri_nup:
    LDA #$29
    STA $FE4F
    BIT $FE4F
    BPL ri_ndown   ; cursor DOWN: back
    TXA
    ORA #2
    TAX
ri_ndown:
    STX mv_in
    ; SPACE: DOOM 'use' on the press edge (doors, the exit switch)
    LDA #$62
    STA $FE4F
    BIT $FE4F
    BMI ri_spdn
    LDA #0
    STA space_prev
    JMP key_hud
ri_spdn:
    LDA space_prev
    BNE ri_spdone
    LDA #1
    STA space_prev
    LDA #BANK_SEG
    STA $FE30   ; USE VECTORS moved to bank A 2026-09-02; ENG_PMOVE_USE
                ; (next) also pages SEG, so this collapses a ROMSEL
    LDA angidx
    ASL A
    ASL A
    TAX
    LDY #0
ri_uv:
    LDA USEVEC,X
    STA ENG_PM_UX,Y   ; ux,uy (contiguous)
    INX
    INY
    CPY #4
    BNE ri_uv
    JSR ENG_PMOVE_USE                               ; ($90-$93 = trace origin:
                                                    ;  pm_frame's exit contract)
    CMP #$FE
    BNE ri_spdone   ; exit switch: respawn
    JSR respawn
ri_spdone:
    JMP key_hud                                     ; H: HUD toggle (RTSes)

; --- respawn: the spawn pose (init + the exit switch 'ending the level')
respawn:
    LDX #5                                          ; pxf..pyh from the table
rs_l:
    LDA rs_tab,X
    STA pxf,X
    DEX
    BPL rs_l
    LDA #16
    STA angidx
    LDA #$06
    STA $04
    STA ENG_PM_VZ
    LDA #0
    STA space_prev
    STA PM_TURNREM                                  ; teleport clears the
    RTS                                             ; part-turn fraction
rs_tab:
    .byte $00,$EE,$FF, $00,$D2,$FF

; --- per-frame z revalidate: pmove_try on the standing position snaps
; VZ to the DOOM rule (sector floor + 41, live movers included)
mv_reval:
    JSR ENG_PMOVE_ZONLY
    LDA ENG_PM_VZ
    STA $04
    RTS

; --- cur_park: park the hardware cursor outside both framebuffers ---------
; R10 = $20 (cursor non-display) alone was NOT enough: the MOS leaves
; R14/R15 = $0D00, i.e. $5800 — the FIRST displayed character of the
; $5800 buffer — so a cursor block sat at the window's top-left on every
; frame that displayed $5800 and vanished on the $6C00 frames. $3FFF is
; past both windows, so the address can never coincide.
; (Init-block space is razor thin, hence a tail routine + JSR.)
cur_park:
    LDA #14
    STA $FE00
    LDA #$3F
    STA $FE01
    LDA #15
    STA $FE00
    LDA #$FF
    STA $FE01
    RTS

; --- mv_frame: elapsed PAL fields since last frame -> ENG_PM_FRAME -------
; T1 (field-locked, period 19968us) gives duration mod 19968; T2 (free
; 1MHz odometer) gives it mod 65536; both count down on the SAME crystal
; so the pair is drift-free. fields = smallest f with
; (d1 + f*19968) mod 65536 == d2. gcd(19968,65536) = 512, so the 128
; candidate residues are 512us apart — a +-64us window absorbs the
; T1-vs-T2 read skew and still resolves f uniquely. 19968 = $4E00, so the step is a hi-byte add.
mv_frame:
    JSR rd_timers
    SEC                                             ; d1 = (prev-now) mod 19968
    LDA prev_t1
    SBC now_t1
    STA acc_l
    LDA prev_t1+1
    SBC now_t1+1
    STA acc_h
    BCS mf_d1ok
    LDA acc_h
    CLC
    ADC #$4E
    STA acc_h   ; borrow: += $4E00
mf_d1ok:
    SEC                                             ; d2 = (prev-now) mod 2^16
    LDA prev_t2
    SBC now_t2
    STA d2_l
    LDA prev_t2+1
    SBC now_t2+1
    STA d2_h
    LDA now_t1
    STA prev_t1
    LDA now_t1+1
    STA prev_t1+1
    LDA now_t2
    STA prev_t2
    LDA now_t2+1
    STA prev_t2+1
    LDX #0
mf_f:
    SEC                                             ; t = acc - d2 (mod 2^16);
    LDA acc_l
    SBC d2_l
    STA tt   ; accept |t| <= 64 by the
    LDA acc_h
    SBC d2_h   ; HIGH BYTE's case, so the
    BEQ mf_pos                                      ; borrow chain is never
    CMP #$FF
    BNE mf_no   ; interrupted (the bias
    LDA tt
    CMP #$C0
    BCS mf_go   ; form broke it and the
    BCC mf_no                                       ; search never matched:
mf_pos: ; every frame clamped to
    LDA tt
    CMP #65
    BCC mf_go   ; 127 -> 32 fields)
mf_no:
    LDA acc_h
    CLC
    ADC #$4E
    STA acc_h   ; acc += 19968
    INX
    CPX #128
    BCC mf_f   ; f is unique mod 128:
    LDX #0                                          ; the residues are 512
mf_go: ; apart, so a miss means
                                                    ; a bad read — sit still
    LDA #7
    STA $FE30   ; pm_frame LIVES IN BANK
    STX DV_FIELDS                                   ; debug HUD F=: the count
    STX ENG_ANIM_FIELDS                             ; FIELD-SCALED anim_tick
                                                    ; (2026-08-25) reads the
                                                    ; same count (stored here:
                                                    ; the glue pocket is full)
    TXA                                             ; WALK - page before JSR
    LDX mv_in
    JMP ENG_PM_FRAME                                ; (tail call)

; rd_timers: atomic 16-bit reads (hi-lo-hi retry; the counters tick at
; 1MHz so a hi-byte carry mid-read is rare). T1 low read clears IFR6 -
; nothing consumes it (flip_sched uses the CA1 vsync latch, bit 1).
rd_timers:
    LDA $FE45
    STA now_t1+1
    LDA $FE44
    STA now_t1
    LDA $FE45
    CMP now_t1+1
    BNE rd_timers
rd_t2:
    LDA $FE49
    STA now_t2+1
    LDA $FE48
    STA now_t2
    LDA $FE49
    CMP now_t2+1
    BNE rd_t2
    RTS
mv_in:
    .byte 0
now_t1:
    .word 0
now_t2:
    .word 0
prev_t1:
    .word 0
prev_t2:
    .word 0
acc_l:
    .byte 0
acc_h:
    .byte 0
d2_l:
    .byte 0
d2_h:
    .byte 0
tt:
    .byte 0

; --- T1hi -> beam class (same boundaries as anim_drv's table; see the
; flip_sched header). Only 78 entries — flip_sched pre-filters H >= 78
; to class 0 — where anim_drv pads the table to 256 instead. ---

clr_end:
.assert clr_end <= MAIN_BASE, error, "MUST NOT touch the engine CODE region"
; (SAVE dropped: the linker emits the image)
