; doom_loader.asm — BBC Micro boot loader for DOOM E1M1
; Loaded at $0900 by DFS *RUN !BOOT
;
; Loads ROM bank data from disc, copies to sideways RAM,
; loads code + tables, sets Mode 4 with narrow/centered display,
; and runs the game loop with keyboard input.

ORG &0900

; ZP used by copy routine (safe — not yet in game)
zp_src = &70
zp_dst = &72

; Player ZP addresses (must match doom_fe.asm)
ZP_PX_INT    = &10
ZP_PY_INT    = &11
ZP_PX_LO     = &12
ZP_PY_LO     = &13
ZP_VZ_PS     = &14
ZP_ANGLE     = &15
ZP_SIN_MAG   = &16
ZP_SIN_NEG   = &17
ZP_COS_MAG   = &19
ZP_COS_NEG   = &1A
ZP_PX_INT_HI = &04
ZP_PY_INT_HI = &05
ZP_WX        = &C0
ZP_WY        = &C2

; Key scan codes (internal key numbers for BBC keyboard)
KEY_Z = &61    ; rotate left
KEY_X = &42    ; rotate right
KEY_K = &46    ; move forward
KEY_M = &65    ; move backward

; Movement speed (world units per frame, applied to wx/wy)
MOVE_SPEED = 16
TURN_SPEED = 4

.start
    ; Print title
    LDX #0
.print_loop
    LDA title,X
    BEQ print_done
    JSR &FFEE
    INX
    BNE print_loop
.print_done

    ; --- Load ROM banks to staging area ($3000), copy to sideways RAM ---
    LDX #LO(cmd_bank0) : LDY #HI(cmd_bank0) : JSR &FFF7
    LDA #0 : JSR copy_bank

    LDX #LO(cmd_bank1) : LDY #HI(cmd_bank1) : JSR &FFF7
    LDA #1 : JSR copy_bank

    LDX #LO(cmd_bank2) : LDY #HI(cmd_bank2) : JSR &FFF7
    LDA #2 : JSR copy_bank

    ; --- Load code and tables to final RAM addresses ---
    LDX #LO(cmd_code)  : LDY #HI(cmd_code)  : JSR &FFF7
    LDX #LO(cmd_recip) : LDY #HI(cmd_recip) : JSR &FFF7
    LDX #LO(cmd_qsq)   : LDY #HI(cmd_qsq)   : JSR &FFF7

    ; Select bank 0 for rendering
    LDA #0 : STA &FE30

    ; --- Set Mode 4 ---
    LDA #22 : JSR &FFEE
    LDA #4  : JSR &FFEE

    ; --- CRTC: narrow + centered + no cursor + double buffer ---
    LDA #1  : STA &FE00 : LDA #32  : STA &FE01   ; R1=32 displayed cols (256px)
    LDA #2  : STA &FE00 : LDA #45  : STA &FE01   ; R2=45 h-sync (center)
    LDA #6  : STA &FE00 : LDA #20  : STA &FE01   ; R6=20 displayed rows (160px)
    LDA #7  : STA &FE00 : LDA #28  : STA &FE01   ; R7=28 v-sync (center)
    LDA #10 : STA &FE00 : LDA #&20 : STA &FE01   ; R10: cursor off

    ; Disable interrupts, clear decimal flag
    SEI
    CLD

    ; Set up System VIA for direct keyboard scanning:
    ; DDRB: bits 3-0 output (IC32 latch control)
    LDA #&0F : STA &FE42
    ; DDRA: bits 6-0 output (key address), bit 7 input (key result)
    LDA #&7F : STA &FE43
    ; Clear IC32 bit 3: enables column/row scan mode (vs "any key" mode)
    ; Port B value: bits 2-0 = 3 (IC32 address), bit 3 = 0 (clear)
    LDA #&03 : STA &FE40

    ; --- Initial player state ---
    ; Spawn: (1056, -3616), angle=64 (East)
    ; map_center=(1200,-3250), prescale=8
    ; wx = -144 = $FF70, wy = -366 = $FE92
    ; px_88 = wx*32 = -4608 = $EE00 → px_int=$EE, px_lo=$00
    ; py_88 = wy*32 = -11712 = $D240 → py_int=$D2, py_lo=$40
    LDA #&EE : STA ZP_PX_INT
    LDA #&00 : STA ZP_PX_LO
    LDA #&FF : STA ZP_PX_INT_HI
    LDA #&D2 : STA ZP_PY_INT
    LDA #&40 : STA ZP_PY_LO
    LDA #&FF : STA ZP_PY_INT_HI
    LDA #&70 : STA ZP_WX
    LDA #&FF : STA ZP_WX+1
    LDA #&92 : STA ZP_WY
    LDA #&FE : STA ZP_WY+1
    LDA #6   : STA ZP_VZ_PS
    LDA #64  : STA ZP_ANGLE
    LDA #&6C : STA &70         ; first back buffer = $6C00 (display shows $5800)

    ; --- Layout offsets (hardcoded for E1M1) ---
    ; off_verts=0, off_nodes=$074C, off_ss=$160C, off_seg_hdr=$19C0, n_nodes=236
    LDA #&00 : STA &02D8 : STA &02D9
    LDA #&4C : STA &02DA
    LDA #&07 : STA &02DB
    LDA #&0C : STA &02DC
    LDA #&16 : STA &02DD
    LDA #&C0 : STA &02DE
    LDA #&19 : STA &02DF
    LDA #&EC : STA &02E0
    LDA #&00 : STA &02E1

    ; Jump to game loop in doom_fe code region (safe from vcache overwrites)
    ; game_loop address from doom_fe.asm assembly listing
    JMP &48AB

; (Movement routines moved to doom_fe.asm game_loop)

; ======================================================================
; COPY_BANK — copy 16KB from $3000 to sideways RAM bank A
; ======================================================================
.copy_bank
{
    STA &FE30
    LDA #&00 : STA zp_src : STA zp_dst
    LDA #&30 : STA zp_src+1
    LDA #&80 : STA zp_dst+1
    LDX #64                 ; 64 pages = 16KB
.copy_page
    LDY #0
.copy_byte
    LDA (zp_src),Y
    STA (zp_dst),Y
    INY
    BNE copy_byte
    INC zp_src+1
    INC zp_dst+1
    DEX
    BNE copy_page
    RTS
}

; ======================================================================
; DATA
; ======================================================================
.title
    EQUS "DOOM E1M1"
    EQUB 13, 10, 0

.cmd_bank0  EQUS "LOAD BANK0 3000" : EQUB 13
.cmd_bank1  EQUS "LOAD BANK1 3000" : EQUB 13
.cmd_bank2  EQUS "LOAD BANK2 3000" : EQUB 13
.cmd_code   EQUS "LOAD CODE 2640"  : EQUB 13
.cmd_recip  EQUS "LOAD RECIP 4F7E" : EQUB 13
.cmd_qsq    EQUS "LOAD QSQ 5400"   : EQUB 13

.end_loader

SAVE "doom_loader.bin", &0900, end_loader, &0900
