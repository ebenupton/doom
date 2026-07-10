; anim_drv.asm — autobooting rotating E1M1 wireframe for the banked renderer.
; Spins the view in place at spawn (1056,-3616): position-derived ZP is constant,
; only sincos ($05-$0A) + bca_ab ($3A2F) change per frame, read from a 64-entry
; table (8 bytes/entry) the build overlays at $3E00. Double-buffered: render to
; the hidden buffer ($5800/$6C00), then flip CRTC R12/R13 to show it.
;
; Lives in the driver slot ($2000-$2BFF) below the engine CODE region at $2C00.
; Loaded as part of LOW; !BOOT just *SRLOADs the banks, *LOADs LOW, MODE 4, and
; JMP $2000. No separate DRV file.

angidx = &2180          ; frame index 0..63
ptlo   = &2181          ; running table pointer
pthi   = &2182
backhi = &2183          ; hidden-buffer page hi ($58 or $6C)
tabbase = &2200         ; sincos table (build-overlaid): 64 x 8 bytes

ORG &2000
; ---------------------------------------------------------------------------
; drv — one-time boot init, then falls through into the frame loop.
; Entry: JMP $3C00 from !BOOT (banks loaded, LOW loaded, MODE 4). Never
; returns; interrupts stay off for ever (SEI; direct hardware only).
; The camera never translates, so ALL position-derived ZP (PX/PY, s16 int
; high bytes, VZ, PXRAW/PYRAW) is written once here; the frame loop only
; changes sincos + view angle. Phases: fixed ZP -> engine table pointers ->
; CRTC (non-interlaced 256x160) -> T1 field-locked beam clock -> RCACHE
; init -> animation state + clear both buffers.
; ---------------------------------------------------------------------------
.drv
    SEI
    ; --- Master 128: clear ACCCON so $8000-$8FFF is the sideways bank (not ANDY),
    ;     $3000-$7FFF is main RAM, and the display reads main (no shadow). This
    ;     makes the Master behave like a plain Model B + SWRAM. Harmless on a B
    ;     (no $FE34). Without this the DFS may leave ANDY paged over our bank
    ;     window's first 4K -> render reads garbage. ---
    LDA #0 : STA &FE34
    ; --- fixed (position-derived) ZP for spawn 1056,-3616 ---
    LDA #&00:STA &00 : LDA #&EE:STA &01             ; PX = $EE00
    LDA #&40:STA &02 : LDA #&D2:STA &03             ; PY = $D240
    LDA #&FF:STA &9D : STA &9E                      ; px_e/py_e: s16 int high bytes
    LDA #&06:STA &04                                ; VZ
    LDA #&70:STA &90 : LDA #&FF:STA &91             ; PXRAW
    LDA #&92:STA &92 : LDA #&FE:STA &93             ; PYRAW
    ; (ROM-pointer copy retired 2026-07-10: bases are layout.inc constants)
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
    ; --- System VIA T1: free-run, period 19968us = exactly one 312-line PAL
    ;     field (latch 19966 + 2), so one phase-lock to vsync here holds for
    ;     ever (zero drift). T1 high byte then gives the beam position at any
    ;     instant (4-line granularity) without interrupts. CA1 IFR bit 1 is
    ;     the vsync edge; MOS is dead after our SEI so nobody else clears it.
    LDA &FE4B:AND #&3F:ORA #&40:STA &FE4B           ; ACR: T1 continuous, PB7 off
    LDA #&FE:STA &FE46                              ; T1 latch = $4DFE = 19966
    LDA #&4D:STA &FE47
    LDA #2  :STA &FE4D                              ; clear stale vsync flag
.vsy0
    LDA &FE4D:AND #2:BEQ vsy0                       ; wait for vsync edge
    LDA #&4D:STA &FE45                              ; start T1: phase = time since vsync
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
    ; --- init animation state ---
    LDA #0   :STA angidx
    LDA #LO(tabbase):STA ptlo : LDA #HI(tabbase):STA pthi
    LDA #&6C :STA backhi                            ; first hidden buffer = FB1
    JSR clr58t:JSR clr58b:JSR clr6Ct:JSR clr6Cb     ; both buffers start clean
; ---------------------------------------------------------------------------
; frame — one rendered frame per iteration (paced by flip_sched's vsync
; waits when the beam demands one; free-running otherwise):
;   load the 8-byte sincos entry at ptlo/pthi -> ZP $05-$0A + bca_ab
;   render into the hidden buffer backhi (pre-cleared by the previous flip)
;   flip_sched: display it, beam-safe clear of the other buffer
;   advance angidx 0..63 (table pointer += 8; both rewound at wrap)
; ---------------------------------------------------------------------------
.frame
    ; --- load per-frame sincos + view angle from the table ---
    LDA ptlo:STA &EC : LDA pthi:STA &ED
    LDY #0
    LDA (&EC),Y:STA &05                             ; s_mag
    INY:LDA (&EC),Y:STA &06                         ; s_neg
    INY:LDA (&EC),Y:STA &07                         ; s_one
    INY:LDA (&EC),Y:STA &08                         ; c_mag
    INY:LDA (&EC),Y:STA &09                         ; c_neg
    INY:LDA (&EC),Y:STA &0A                         ; c_one
    INY:LDA (&EC),Y:STA &1B6F                       ; bca_ab (view angle; BCA_WS+$2F)
    ; --- render one frame into the hidden buffer (cleared for us by the
    ;     previous iteration's flip scheduler) ---
    LDA backhi:STA &70                              ; rasteriser scrstrt hi
    LDA #4 :STA &FE30 : JSR &2C09                   ; br_view_setup
    LDA #6 :STA &FE30 : JSR &8000                   ; span_init / pool
    LDA #4 :STA &FE30 : JSR &2C1B : JSR &2C15       ; init_frame + render_frame
    ; --- flip + beam-scheduled clear of the buffer coming off display ---
    JSR flip_sched                                  ; toggles backhi
    ; --- advance to next frame (wrap at 64) ---
    INC angidx
    LDA angidx:CMP #64:BCC adv
    LDA #0:STA angidx
    LDA #LO(tabbase):STA ptlo : LDA #HI(tabbase):STA pthi
    JMP frame
.adv
    CLC:LDA ptlo:ADC #8:STA ptlo : LDA pthi:ADC #0:STA pthi
    JMP frame
.drv_end

; --- unrolled framebuffer clears (in the $4000-$47FF the render never touches).
;     Split at the half-screen boundary (80 rows = 10 pages) so the flip
;     scheduler can clear the beam-passed top half early. STA abs,Y = 5cyc.
;     clr58t/clr58b = top/bottom of FB0 ($5800); clr6Ct/clr6Cb = FB1 ($6C00).
;     Each clobbers A,Y. ---
ORG &2400
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

; --- flip_sched: show the just-rendered buffer, then clear the buffer coming
; off display without ever touching a row the beam has yet to draw.
;
; Field timeline (T1 phase e = us since vsync, one field = 19968us):
;   e in [0,5632)      vertical blanking; frame top (CRTC reloads R12/R13)
;                      at e=5632
;   e in [5632,15872)  display rows 0..159 of the CURRENT address
;   e in [15872,19968) bottom border
;
; After we write R12/R13 the OLD buffer keeps displaying only until the next
; frame top. So: rows the beam has already drawn this field are clearable NOW;
; rows still ahead of the beam must wait for the vsync flag. If the display of
; the old buffer has already finished (blanking or bottom border), everything
; is clearable and no wait is needed at all.
;
; T1 high byte H -> class (4-line granularity, boundaries biased conservative):
;   H  0..14  bottom border          -> class 2: clear all, no wait
;   H 15..34  beam in bottom half    -> class 1: clear top now, wait, clear bot
;   H 35..56  beam in top half       -> class 0: wait, then clear all
;   H 57..77  post-vsync blanking    -> class 2
;   H 78..255 unreachable/transient  -> class 0 (safe fallback)
; Toggles backhi. Re-phases T1 at each vsync it waits on. Clobbers A,X.
; (walk_drv carries a journalling variant of this same routine.)
; ---------------------------------------------------------------------------
.flip_sched
    ; R12/R13 straddle guard: the pair must not bracket the frame-top reload
    ; (e=5632 -> T1 = 14334 = $37FE). Spin while H in [$36,$38] (<=768us, rare).
.fs_guard
    LDA &FE45
    CMP #&36 : BCC fs_go
    CMP #&39 : BCS fs_go
    JMP fs_guard
.fs_go
    LDA #12:STA &FE00 : LDA backhi:LSR A:LSR A:LSR A:STA &FE01          ; R12=hi>>3
    LDA #13:STA &FE00 : LDA backhi:AND #7:ASL A:ASL A:ASL A:ASL A:ASL A:STA &FE01
    LDA backhi:EOR #(&58 EOR &6C):STA backhi        ; backhi = buffer coming off display
    LDX &FE45
    LDA beamtbl,X
    BEQ fs_cls0
    CMP #1 : BEQ fs_cls1
    JMP fs_clrall                                   ; class 2: no wait
.fs_cls0                                            ; beam in top half: all must wait
    LDA #2:STA &FE4D
.fs_w0
    LDA &FE4D:AND #2:BEQ fs_w0
    LDA #&4D:STA &FE45                              ; re-phase T1 to this vsync
    JMP fs_clrall
.fs_cls1                                            ; beam in bottom half
    LDA #2:STA &FE4D                                ; arm BEFORE clearing (flag latches)
    JSR fs_clrtop
    ; Stale-latch guard (see walk_drv): if vsync landed during the top
    ; clear, re-phasing from the latched flag would shift the beam clock
    ; by up to the clear time. Only re-phase on a fresh edge.
    LDA &FE4D:AND #2:BNE fs_w1_stale
.fs_w1
    LDA &FE4D:AND #2:BEQ fs_w1
    LDA #&4D:STA &FE45                              ; fresh edge: re-phase T1
.fs_w1_stale
    JMP fs_clrbot
; fs_clrall falls through into fs_clrbot after the top; fs_clrtop/fs_clrbot
; clear the half of whichever buffer backhi now names (the one just taken
; OFF display — the CRTC is showing the other one).
.fs_clrall
    JSR fs_clrtop
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

; --- T1hi -> beam class, indexed directly by the raw high byte (256 entries,
; page-aligned so the LDA abs,X never crosses); boundaries as per the
; flip_sched header, padded with the safe class 0 above 77. ---
ALIGN &100
.beamtbl
    FOR n, 0, 255
      IF n <= 14
        EQUB 2
      ELIF n <= 34
        EQUB 1
      ELIF n <= 56
        EQUB 0
      ELIF n <= 77
        EQUB 2
      ELSE
        EQUB 0
      ENDIF
    NEXT
.clr_end
SAVE "ANIMDRV", &2000, clr_end, &2000
