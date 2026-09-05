.segment "CODE"
; banked_boot.asm — BBC Model B boot + render-one-frame driver for the banked
; standalone DOOM E1M1 renderer. Proves the banked build runs on real hardware.
;
; Disc files: !BOOT (this, $0900) ; BANK0/1/2 (16K -> sideways banks 4/6/7) ;
; LOW (strip+driver+code, LOW_BASE $0D00-$57FF, staged at $3000). No DRV file.
; Boot: copy banks, load LOW, MODE 4, JMP driver. Driver: SEI, set spawn ZP +
; CRTC, span_init (bank C), clear FB, render (bank L0->...), display, spin.

; (legacy equates from an earlier copy-loop bootloader; nothing below uses
; them — the driver stores scrstrt to $70 directly)
   .include "../abi.inc"   ; cross-file addresses from the ABI table
   .include "../../engine_syms.inc"   ; engine entries from the ld65 map (asmbuild.gen_engine_syms)
zp_src = $70
zp_dst = $72
zp_save = $74

; ============================ BOOTLOADER ($0900) ============================
; boot — runs via *RUN !BOOT (SHIFT-BREAK). Each JSR $FFF7 is OSCLI on one
; of the command strings below; *SRLOAD needs a Master MOS / SWRAM utility
; ROM (modelb_boot.asm is the plain-DFS equivalent that stages each bank
; through main RAM and copies via ROMSEL instead). Ends with a jump into
; the driver; never returns.
.segment "BOOTLD"
boot:
; *SRLOAD each bank straight into sideways RAM (no main-RAM staging, no
; ROMSEL/shadow dance) — Master MOS 3.20 / B with SWRAM utils.
    LDX #<(cmd_b0)
    LDY #>(cmd_b0)
    JSR $FFF7   ; SRLOAD BANK0 8000 4 (L0)
    LDX #<(cmd_b1)
    LDY #>(cmd_b1)
    JSR $FFF7   ; SRLOAD BANK1 8000 6 (C)
    LDX #<(cmd_b2)
    LDY #>(cmd_b2)
    JSR $FFF7   ; SRLOAD BANK2 8000 7 (L2)
; --- LOW loads STAGED at $3000 and copies down (2026-08-26 low-RAM
;     map): the strip starts at LOW_BASE $0F00 (COLPORT left for
;     bank B 2026-09-01) — under DFS a direct *LOAD there lands on
;     the catalog workspace while the transfer is USING it. Stage high
;     (MODE 7 screen at $7C00 clears $3000-$7AFF), copy ascending
;     (dst < src throughout). The DRV file is GONE: the driver is
;     inside the LOW image ($0F00, LOW_BASE..$57FF is one span). ---
    LDX #<(cmd_low)
    LDY #>(cmd_low)
    JSR $FFF7   ; *LOAD LOW 3000
    LDA #$00
    STA $80
    LDA #$30
    STA $81   ; src = $3000
    LDA #$00
    STA $82
    LDA #$0F
    STA $83   ; dst = $0F00 (LOW_BASE)
    LDY #0
lcp:
    LDA ($80),Y
    STA ($82),Y
    INY
    BNE lcp
    INC $81
    INC $83
    LDA $83
    CMP #$58   ; dst page = $5800: done
    BNE lcp
    LDA #22
    JSR $FFEE
    LDA #4
    JSR $FFEE   ; MODE 4
    JMP DRV_ORG   ; -> driver

cmd_b0:  .byte "SRLOAD BANK0 8000 4"
.byte 13
cmd_b1:  .byte "SRLOAD BANK1 8000 6"
.byte 13
cmd_b2:  .byte "SRLOAD BANK2 8000 7"
.byte 13
cmd_low: .byte "LOAD LOW 3000"
.byte 13
boot_end:
; SAVE "BOOT", &0900, boot_end -> the build script

; ============================ DRIVER ($2000) ===============================
; Lives in the driver slot ($2000-$2BFF) below the engine CODE region at $2C00.
; drv — render exactly ONE frame and halt (hardware proof, not a game loop;
; anim_drv/walk_drv are the looping drivers built on this skeleton).
; SEI then direct hardware only. Phases: spawn ZP (position, sincos for
; angle-byte 128, raws) -> CRTC + screen start
; $5800 -> view_setup then span_init (canonical render_frame order) ->
; clear the framebuffer -> init_frame + render_frame -> spin for ever.
.segment "DRV"
drv:
    SEI
; --- REAL-HW hardening: ZERO PAGE (2026-08-23).  MUST come before the
;     spawn ZP block below, which only establishes the driver's own
;     contract bytes.  The engine reads OTHER ZP bytes it never writes
;     and relies on them being 0 (tools/zpvirgin.py lists them); real
;     hardware hands over OS/BASIC or tube MOS workspace instead.
;     plotq_mode ($A1) is the fatal one -- a stray bit 7 queues every
;     line instead of drawing it.  test_bare_boot now runs this driver
;     a second time with ZP pre-filled with $A5 and requires an
;     identical framebuffer, so this block is gated.
    LDA #0
    TAX
zpclr:
    STA $00,X
    INX
    BNE zpclr
; --- Master 128: clear ACCCON -> $8000 = sideways bank (not ANDY), $3000-7FFF
;     main, display main. Plain Model-B+SWRAM behaviour. Harmless on a B. ---
    LDA #0
    STA $FE34
; --- spawn player ZP (precomputed for 1056,-3616, angle 128;
;     center -3248 since 2026-08-10: py = -46.0 units exactly) ---
    LDA #$00
    STA $00
    LDA #$EE
    STA $01   ; ZP_PX (8.8 frac/lo)
    LDA #$00
    STA $02
    LDA #$D2
    STA $03   ; ZP_PY
    LDA #$FF
    STA $9D
    STA $9E   ; ZP_PX_E/PY_E (s16 int hi
; bytes; spawn is negative
; both axes after centring)
    LDA #$06
    STA $04   ; ZP_VZ
    LDA #$00
    STA $05
    LDA #$00
    STA $06
    LDA #$00
    STA $07   ; sin mag/neg/one
    LDA #$00
    STA $08
    LDA #$01
    STA $09
    LDA #$01
    STA $0A   ; cos mag/neg/one
    LDA #$70
    STA $90
    LDA #$FF
    STA $91   ; ZP_PXRAW
    LDA #$90
    STA $92
    LDA #$FE
    STA $93   ; ZP_PYRAW (-368, center -3248)
; exact-descent state (2026-08-26): tie-broken doubled raws (integer
; spawn: raw*2, frac bit 0) + the PM_FXW world-frac block, which is
; REAL RAM and must be stored, not assumed zero
; doubled raws + fraction bytes at their REAL homes (the 2026-08-31
; zp rotation moved three of the four raws + both fracs to the WORK
; segment; the old &1D/&7F/&BA pokes were landing on OTHER scalars)
    LDA #$E0
    STA $1C   ; px2 lo (still zp)
    LDA #$FE
    STA ENG_BR_PX2H   ; px2 = -288
    LDA #$20
    STA ENG_BR_PY2L
    LDA #$FD
    STA ENG_BR_PY2H   ; py2 = -736
    LDA #$00
    STA ENG_BR_PXF
    STA ENG_BR_PYF   ; integer spawn: fracs 0
    LDA #$00
    STA $0D00
    STA $0D02   ; PM_FXW x/y = 0 (WORK arena +$200, 2026-09-01)
    LDA #$80
    STA BCA_AB   ; view angle byte
; (ROM pointers retired 2026-07-10: layout.inc constants)
    LDA #$58
    STA $70   ; rasteriser scrstrt hi
; --- CRTC: narrow 256x160, centered, cursor off, screen start $5800 ---
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
    LDA #10
    STA $FE00
    LDA #$20
    STA $FE01
    LDA #12
    STA $FE00
    LDA #$0B
    STA $FE01   ; R12 = $5800>>3 hi
    LDA #13
    STA $FE00
    LDA #$00
    STA $FE01   ; R13
; (RNS stack-page copy retired 2026-07-12: block lives in CODE)
; --- canonical order (matches render_frame): view_setup BEFORE span_init ---
    JSR ENG_SQR_FILL   ; the sqr quad is boot-
; GENERATED (OS pages, no
; disc file covers $0200)
    JSR ENG_OBJ_FILL   ; OBJ_ANYB bitmap copy
; ($11xx ships nothing —
; the game boots it via
; anim_init; this DRV
; never runs anims)
    LDA #4
    STA $FE30
    JSR ENG_VIEW_SETUP   ; view_setup (pages L0/L2)
    LDA #6
    STA $FE30
    JSR ENG_SPAN_INIT   ; span_init / pool (bank C)
; --- clear framebuffer $5800-$6BFF (20 pages) using $EE/$EF ptr ---
    LDA #0
    STA $EE
    LDA #$58
    STA $EF
    LDX #20
    LDY #0
    LDA #0
clr:
    STA ($EE),Y
    INY
    BNE clr
    INC $EF
    DEX
    BNE clr
; --- render one frame (entries page banks internally) ---
    LDA #4
    STA $FE30
; (per-frame init is inline at the render_frame entry, 2026-07-15)
    JSR ENG_RENDER_FRAME   ; render_frame
spin:
    JMP spin
drv_end:
; SAVE "DRV", DRV_ORG, drv_end -> the build script
