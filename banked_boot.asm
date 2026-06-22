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
    LDX #LO(cmd_b0): LDY #HI(cmd_b0): JSR &FFF7 : LDA #4 : JSR copy_bank
    LDX #LO(cmd_b1): LDY #HI(cmd_b1): JSR &FFF7 : LDA #6 : JSR copy_bank
    LDX #LO(cmd_b2): LDY #HI(cmd_b2): JSR &FFF7 : LDA #7 : JSR copy_bank
    LDX #LO(cmd_low):LDY #HI(cmd_low):JSR &FFF7      ; *LOAD LOW 1B40
    LDX #LO(cmd_drv):LDY #HI(cmd_drv):JSR &FFF7      ; *LOAD DRV 3C00
    LDA #22 : JSR &FFEE : LDA #4 : JSR &FFEE          ; MODE 4
    JMP &3C00                                        ; -> driver

.copy_bank
    LDX &F4 : STX zp_save        ; save current (DFS/language) ROM bank
    STA &FE30                    ; page target SWRAM bank (A = target)
    LDA #0 : STA zp_src : STA zp_dst
    LDA #&30 : STA zp_src+1
    LDA #&80 : STA zp_dst+1
    LDX #64
.cb_pg
    LDY #0
.cb_by
    LDA (zp_src),Y : STA (zp_dst),Y : INY : BNE cb_by
    INC zp_src+1 : INC zp_dst+1 : DEX : BNE cb_pg
    LDA zp_save : STA &FE30      ; restore so the next *LOAD finds the FS ROM
    RTS

.cmd_b0  EQUS "LOAD BANK0 3000" : EQUB 13
.cmd_b1  EQUS "LOAD BANK1 3000" : EQUB 13
.cmd_b2  EQUS "LOAD BANK2 3000" : EQUB 13
.cmd_low EQUS "LOAD LOW 1B40"   : EQUB 13
.cmd_drv EQUS "LOAD DRV 3C00"   : EQUB 13
.boot_end
SAVE "BOOT", &0900, boot_end, &0900

; ============================ DRIVER ($3C00) ===============================
; Lives in the clipper-vacated low space the render never touches ($3C00-$47FF).
ORG &3C00
.drv
    SEI
    ; --- spawn player ZP (precomputed for 1056,-3616, angle 128) ---
    LDA #&00:STA &00  : LDA #&EE:STA &01            ; ZP_PX (8.8)
    LDA #&40:STA &02  : LDA #&D2:STA &03            ; ZP_PY
    LDA #&06:STA &04                                ; ZP_VZ
    LDA #&00:STA &05  : LDA #&00:STA &06 : LDA #&00:STA &07  ; sin mag/neg/one
    LDA #&00:STA &08  : LDA #&01:STA &09 : LDA #&01:STA &0A  ; cos mag/neg/one
    LDA #&70:STA &90  : LDA #&FF:STA &91            ; ZP_PXRAW
    LDA #&92:STA &92  : LDA #&FE:STA &93            ; ZP_PYRAW
    LDA #&80:STA &3A2F                              ; bca_ab
    LDA #&58:STA &70                                ; rasteriser scrstrt hi
    ; --- CRTC: narrow 256x160, centered, cursor off, screen start $5800 ---
    LDA #1 :STA &FE00: LDA #32 :STA &FE01
    LDA #2 :STA &FE00: LDA #45 :STA &FE01
    LDA #6 :STA &FE00: LDA #20 :STA &FE01
    LDA #7 :STA &FE00: LDA #28 :STA &FE01
    LDA #10:STA &FE00: LDA #&20:STA &FE01
    LDA #12:STA &FE00: LDA #&0B:STA &FE01           ; R12 = $5800>>3 hi
    LDA #13:STA &FE00: LDA #&00:STA &FE01           ; R13
    ; --- pool init (span_init in bank C @ $8000) ---
    LDA #6 :STA &FE30 : JSR &8000
    ; --- clear framebuffer $5800-$6BFF (20 pages) using $EE/$EF ptr ---
    LDA #0 :STA &EE : LDA #&58:STA &EF
    LDX #20 : LDY #0 : LDA #0
.clr
    STA (&EE),Y : INY : BNE clr : INC &EF : DEX : BNE clr
    ; --- render one frame (entries page banks internally) ---
    LDA #4 :STA &FE30
    JSR &4809                                       ; br_view_setup
    JSR &481B                                       ; br_init_frame
    JSR &4815                                       ; br_render_frame
.spin
    JMP spin
.drv_end
SAVE "DRV", &3C00, drv_end, &3C00
