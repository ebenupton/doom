; banked_boot.asm — BBC Model B boot + render-one-frame driver for the banked
; standalone DOOM E1M1 renderer. Proves the banked build runs on real hardware.
;
; Disc files: !BOOT (this, $0900) ; BANK0/1/2 (16K -> sideways banks 4/6/7) ;
; LOW (low code+tables $1B40-$5784) ; DRV (driver, $3C00).
; Boot: copy banks, load LOW, MODE 4, JMP driver. Driver: SEI, set spawn ZP +
; CRTC, span_init (bank C), clear FB, render (bank L0->...), display, spin.

zp_src = &70
zp_dst = &72
zp_save = &74

; ============================ BOOTLOADER ($0900) ============================
ORG &0900
.boot
    ; *SRLOAD each bank straight into sideways RAM (no main-RAM staging, no
    ; ROMSEL/shadow dance) — Master MOS 3.20 / B with SWRAM utils.
    LDX #LO(cmd_b0): LDY #HI(cmd_b0): JSR &FFF7      ; SRLOAD BANK0 8000 4 (L0)
    LDX #LO(cmd_b1): LDY #HI(cmd_b1): JSR &FFF7      ; SRLOAD BANK1 8000 6 (C)
    LDX #LO(cmd_b2): LDY #HI(cmd_b2): JSR &FFF7      ; SRLOAD BANK2 8000 7 (L2)
    LDX #LO(cmd_low):LDY #HI(cmd_low):JSR &FFF7      ; *LOAD LOW 1B40
    LDX #LO(cmd_drv):LDY #HI(cmd_drv):JSR &FFF7      ; *LOAD DRV 3C00
    LDA #22 : JSR &FFEE : LDA #4 : JSR &FFEE          ; MODE 4
    JMP &3C00                                        ; -> driver

.cmd_b0  EQUS "SRLOAD BANK0 8000 4" : EQUB 13
.cmd_b1  EQUS "SRLOAD BANK1 8000 6" : EQUB 13
.cmd_b2  EQUS "SRLOAD BANK2 8000 7" : EQUB 13
.cmd_low EQUS "LOAD LOW 1B40"   : EQUB 13
.cmd_drv EQUS "LOAD DRV 3C00"   : EQUB 13
.boot_end
SAVE "BOOT", &0900, boot_end, &0900

; ============================ DRIVER ($3C00) ===============================
; Lives in the clipper-vacated low space the render never touches ($3C00-$47FF).
ORG &3C00
.drv
    SEI
    ; --- Master 128: clear ACCCON -> $8000 = sideways bank (not ANDY), $3000-7FFF
    ;     main, display main. Plain Model-B+SWRAM behaviour. Harmless on a B. ---
    LDA #0 : STA &FE34
    ; --- spawn player ZP (precomputed for 1056,-3616, angle 128) ---
    LDA #&00:STA &00  : LDA #&EE:STA &01            ; ZP_PX (8.8)
    LDA #&40:STA &02  : LDA #&D2:STA &03            ; ZP_PY
    LDA #&06:STA &04                                ; ZP_VZ
    LDA #&00:STA &05  : LDA #&00:STA &06 : LDA #&00:STA &07  ; sin mag/neg/one
    LDA #&00:STA &08  : LDA #&01:STA &09 : LDA #&01:STA &0A  ; cos mag/neg/one
    LDA #&70:STA &90  : LDA #&FF:STA &91            ; ZP_PXRAW
    LDA #&92:STA &92  : LDA #&FE:STA &93            ; ZP_PYRAW
    LDA #&80:STA &3A2F                              ; bca_ab
    ; --- ROM table pointers (banked-model deltas; LOW file starts at $1B40 so
    ;     these sub-$1B40 pointers are otherwise never written on real HW) ---
    LDA #&4C:STA &42  : LDA #&87:STA &43            ; zp_rom_nodes -> $874C (L0)
    LDA #235:STA &4C  : LDA #0:STA &4D               ; zp_root_node = n_nodes-1 (236-1)
    LDX #15
.ptrcpy
    LDA ptrtab,X : STA &0BE8,X : DEX : BPL ptrcpy
    LDA #&58:STA &70                                ; rasteriser scrstrt hi
    ; --- CRTC: narrow 256x160, centered, cursor off, screen start $5800 ---
    LDA #1 :STA &FE00: LDA #32 :STA &FE01
    LDA #2 :STA &FE00: LDA #45 :STA &FE01
    LDA #6 :STA &FE00: LDA #20 :STA &FE01
    LDA #7 :STA &FE00: LDA #28 :STA &FE01
    LDA #10:STA &FE00: LDA #&20:STA &FE01
    LDA #12:STA &FE00: LDA #&0B:STA &FE01           ; R12 = $5800>>3 hi
    LDA #13:STA &FE00: LDA #&00:STA &FE01           ; R13
    ; --- canonical order (matches render_frame): view_setup BEFORE span_init ---
    LDA #4 :STA &FE30 : JSR &4809                   ; br_view_setup (pages L0/L2)
    LDA #6 :STA &FE30 : JSR &8000                   ; span_init / pool (bank C)
    ; --- clear framebuffer $5800-$6BFF (20 pages) using $EE/$EF ptr ---
    LDA #0 :STA &EE : LDA #&58:STA &EF
    LDX #20 : LDY #0 : LDA #0
.clr
    STA (&EE),Y : INY : BNE clr : INC &EF : DEX : BNE clr
    ; --- render one frame (entries page banks internally) ---
    LDA #4 :STA &FE30
    JSR &481B                                       ; br_init_frame
    JSR &4815                                       ; br_render_frame
.spin
    JMP spin
.ptrtab
    EQUB &00,&24, &00,&8E, &00,&80, &00,&00         ; fhch bbox verts (unused)
    EQUB &0C,&96, &C0,&99, &00,&A2, &00,&24         ; ss seg_hdr vwh detail
.drv_end
SAVE "DRV", &3C00, drv_end, &3C00
