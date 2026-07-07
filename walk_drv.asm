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

angidx = &3D80          ; view angle index 0..63 (angle byte = idx*4)
backhi = &3D81          ; hidden-buffer page hi ($58 or $6C)
pxf    = &3D82          ; player x: 8.8 prescaled, 24-bit (frac, lo, hi)
pxl    = &3D83
pxh    = &3D84
pyf    = &3D85
pyl    = &3D86
pyh    = &3D87
jidx   = &3D88          ; vsync journal index (0..62)
; vsync journal: 64 x 4 bytes at $0300 (dead OS workspace; no OS after boot):
;   +0 class taken (0/1/2)   +1 T1 hi at classify
;   +2 T1 hi after the vsync wait ($FF = class 2, no wait)
;   +3 T1 hi after clears done
jbase  = &0300
tabbase = &3E00         ; sincos table (build-overlaid): 64 x 8 bytes

SPEED = 12              ; world units per frame of forward motion

; map bounds in RAW world units relative to MAP_CENTER (1200,-3250),
; with a 32-unit margin: x in [-768,3808] -> raw [-1968+32, 2608-32]
RAWX_MIN = &F870        ; -1936 as u16
RAWX_MAX = &0A10        ;  2576
RAWY_MIN = &F9D2        ; -1582
RAWY_MAX = &0492        ;  1170

ORG &3C00
.drv
    SEI
    LDA #0 : STA &FE34                              ; Master: ACCCON off (harmless on B)
    ; --- spawn position 1056,-3616 as 24-bit prescaled 8.8 ---
    LDA #&00:STA pxf : LDA #&EE:STA pxl : LDA #&FF:STA pxh
    LDA #&40:STA pyf : LDA #&D2:STA pyl : LDA #&FF:STA pyh
    LDA #&06:STA &04                                ; VZ (spawn floor; constant v1)
    ; --- ROM table pointers ---
    LDA #&4C:STA &42 : LDA #&87:STA &43             ; zp_rom_nodes -> $874C
    LDA #235:STA &4C : LDA #0:STA &4D               ; zp_root_node = n_nodes-1
    LDX #15
.pcpy
    LDA ptrtab,X : STA &0BE8,X : DEX : BPL pcpy
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
    ; --- System VIA T1 field lock (see anim_drv for the full rationale) ---
    LDA &FE4B:AND #&3F:ORA #&40:STA &FE4B
    LDA #&FE:STA &FE46
    LDA #&4D:STA &FE47
    LDA #2  :STA &FE4D
.vsy0
    LDA &FE4D:AND #2:BEQ vsy0
    LDA #&4D:STA &FE45
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
    STA &B460,X
    INX
    CPX #&89
    BNE rcinit
    LDA #1
    STA &B4E8                                       ; RCACHE_ENABLE
    ; --- translation-coherence vertex cache (VXC): zero valid bitmap +
    ;     state ($05A0-$05FF, unbanked), then enable. Zero-init is safe:
    ;     first enabled frame is cold (prev_ab sentinel path) and every
    ;     entry stores before it loads. ---
    LDA #0
    TAX
.vxinit
    STA &05A0,X
    INX
    CPX #&60
    BNE vxinit
    LDA #1
    STA &05DB                                       ; VXC_ENABLE
    ; --- animated sectors: init state machines + lazy patch hook (glue
    ;     at $3DA0 pages bank L2; must run AFTER vxinit's $05xx zeroing) ---
    JSR anim_glue_init
    ; --- init state ---
    LDA #16  :STA angidx                            ; angle byte 64 (spawn facing)
    LDA #0   :STA jidx
    LDA #&6C :STA backhi
    JSR clr58t:JSR clr58b:JSR clr6Ct:JSR clr6Cb
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
    INY:LDA (&EC),Y:STA &3A2F                       ; bca_ab
    JSR anim_glue_tick                              ; advance movers (lazy patch)
    ; --- render into hidden buffer (cleared by previous flip_sched) ---
    LDA backhi:STA &70
    LDA #4 :STA &FE30 : JSR &4809                   ; br_view_setup
    LDA #6 :STA &FE30 : JSR &8000                   ; span_init / pool
    LDA #4 :STA &FE30 : JSR &481B : JSR &4815       ; init_frame + render_frame
    JSR flip_sched
    JMP frame

; ptrtab must clear the driver variable block (angidx..jidx live at
; $3D80-$3D88 as fixed equates; the sincos table is overlaid at $3E00).
; An extra init block once pushed it INTO the variables - the engine's
; table pointers then got clobbered at runtime by angidx/jidx stores and
; every frame rendered pixel-free while the loop ran happily. Pin it.
ASSERT P% <= &3D80
ORG &3D90
.ptrtab
    EQUB &00,&24, &00,&8E, &00,&80, &00,&00         ; fhch bbox verts (unused)
    EQUB &0C,&96, &C0,&99, &00,&A2, &00,&24         ; ss seg_hdr vwh detail
.drv_end

; --- unrolled framebuffer clears + flip scheduler: identical to anim_drv --
; --- animated-sector glue: page bank L2 and enter the anim jump table
;     ($3DA0-$3DBF pocket between ptrtab and the sincos table at $3E00) ---
ORG &3DA0
.anim_glue_init
    LDA #7:STA &FE30
    JMP &BA03                                       ; jt_anim_init (RTS there)
.anim_glue_tick
    LDA #7:STA &FE30
    JMP &BA00                                       ; jt_anim_tick

ORG &4000
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

.flip_sched
.fs_guard
    LDA &FE45
    CMP #&36 : BCC fs_go
    CMP #&39 : BCS fs_go
    JMP fs_guard
.fs_go
    LDA #12:STA &FE00 : LDA backhi:LSR A:LSR A:LSR A:STA &FE01
    LDA #13:STA &FE00 : LDA backhi:AND #7:ASL A:ASL A:ASL A:ASL A:ASL A:STA &FE01
    LDA backhi:EOR #(&58 EOR &6C):STA backhi
    LDA jidx:ASL A:ASL A:TAY
    LDX &FE45
    LDA #0                                          ; T1hi >= 78: transient/wrap read
    CPX #78                                         ; -> class 0 (wait; always safe)
    BCS fs_havecls
    LDA beamtbl,X
.fs_havecls
    STA jbase,Y                                     ; journal: class
    TXA:STA jbase+1,Y                               ; journal: T1hi at classify
    LDA jbase,Y
    BEQ fs_cls0
    CMP #1 : BEQ fs_cls1
    LDA #&FF:STA jbase+2,Y                          ; journal: no wait
    JSR fs_clrtop
    JSR fs_clrbot
    JMP fs_logdone
.fs_cls0
    LDA #2:STA &FE4D
.fs_w0
    LDA &FE4D:AND #2:BEQ fs_w0
    LDA #&4D:STA &FE45                              ; re-phase T1 to this vsync
    JSR fs_logwait
    JSR fs_clrtop
    JSR fs_clrbot
    JMP fs_logdone
.fs_cls1
    LDA #2:STA &FE4D
    JSR fs_clrtop
.fs_w1
    LDA &FE4D:AND #2:BEQ fs_w1
    LDA #&4D:STA &FE45                              ; re-phase T1 to this vsync
    JSR fs_logwait
    JSR fs_clrbot
    JMP fs_logdone
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
.read_input
    LDA #&19:STA &FE4F : BIT &FE4F : BPL ri_nleft   ; cursor LEFT
    LDA angidx:CLC:ADC #1:AND #63:STA angidx
.ri_nleft
    LDA #&79:STA &FE4F : BIT &FE4F : BPL ri_nright  ; cursor RIGHT
    LDA angidx:SEC:SBC #1:AND #63:STA angidx
.ri_nright
    LDA #&39:STA &FE4F : BIT &FE4F : BPL ri_nup     ; cursor UP: forward
    JSR step_fwd
    JSR bounds_or_revert_fwd
.ri_nup
    LDA #&29:STA &FE4F : BIT &FE4F : BPL ri_ndown   ; cursor DOWN: back
    JSR step_back
    JSR bounds_or_revert_back
.ri_ndown
    RTS

; --- movement: position += / -= step table entry for angidx ---------------
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
.step_tab
FOR i, 0, 63
    EQUW INT(SPEED * 32 * COS(i * PI / 32) + 65536.5) AND &FFFF
    EQUW INT(SPEED * 32 * SIN(i * PI / 32) + 65536.5) AND &FFFF
NEXT

.beamtbl
    FOR n, 0, 77
      IF n <= 14
        EQUB 2
      ELIF n <= 34
        EQUB 1
      ELIF n <= 56
        EQUB 0
      ELSE
        EQUB 2
      ENDIF
    NEXT

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
SAVE "WALKDRV", &3C00, clr_end, &3C00
