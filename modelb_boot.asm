; modelb_boot.asm — !BOOT loader for a plain Model B + sideways RAM (no *SRLOAD).
; Acorn DFS has no *SRLOAD, so we *LOAD each 16K bank file into a main-RAM staging
; area ($3000) and copy it into the target sideways bank via ROMSEL ($FE30). Then
; *LOAD LOW (code + animation driver @ $3C00 + sincos table @ $3E00), MODE 4, and
; jump to the driver. Banks 4/6/7 = L0/C/L2 (all writable SWRAM on a Model B).
;
; *RUN as !BOOT (boot option 2) -> SHIFT-BREAK autoboots. PAGE=$1900 (DFS).
;
; ldr — load/copy each bank in turn, then LOW, then hand off. Each
; JSR $FFF7 is OSCLI on a command string; OS calls are fine here (the
; driver's SEI at $3C00 is where the OS goes away). The $3000 staging
; area is plain user RAM under the boot-time MODE 7, and LOW ($1B40+)
; only lands after the last bank copy has consumed the staging.
ORG &1900
.ldr
    LDX #LO(c_b0): LDY #HI(c_b0): JSR &FFF7      ; *LOAD BANK0 3000  (L0)
    LDA #4:  JSR copy                            ; -> bank 4
    LDX #LO(c_b1): LDY #HI(c_b1): JSR &FFF7      ; *LOAD BANK1 3000  (C)
    LDA #6:  JSR copy                            ; -> bank 6
    LDX #LO(c_b2): LDY #HI(c_b2): JSR &FFF7      ; *LOAD BANK2 3000  (L2)
    LDA #7:  JSR copy                            ; -> bank 7
    LDX #LO(c_low):LDY #HI(c_low):JSR &FFF7      ; *LOAD LOW 1B40
    LDA #22: JSR &FFEE : LDA #4 : JSR &FFEE      ; MODE 4
    JMP &3C00                                    ; -> animation driver

; copy — copy the 16K staged at $3000-$6FFF into sideways bank A.
; In: A = target bank number (4/6/7). Uses ZP $80-$83 as src/dst pointers.
; SEI brackets the copy so no IRQ handler runs while ROMSEL points at the
; SWRAM bank (the OS would index the wrong ROM); $F4 (the OS's ROMSEL
; shadow) is kept in sync both ways so the DFS ROM is correctly restored
; for the next *LOAD. Clobbers A,X,Y,$80-$83.
.copy                            ; A = target bank; copy $3000-$6FFF -> $8000 bank
    LDX &F4 : STX oldrom         ; save OS's current ROM
    SEI                          ; no IRQ -> ROMSEL stays put during the copy
    STA &FE30 : STA &F4          ; page target bank (keep $F4 in sync)
    LDA #0:STA &80 : LDA #&30:STA &81            ; src ptr = $3000
    LDA #0:STA &82 : LDA #&80:STA &83            ; dst ptr = $8000
    LDX #&40                                     ; 64 pages = 16K
.cp1
    LDY #0
.cp2
    LDA (&80),Y : STA (&82),Y : INY : BNE cp2
    INC &81 : INC &83 : DEX : BNE cp1
    LDA oldrom : STA &FE30 : STA &F4             ; restore OS's ROM for next *LOAD
    CLI
    RTS
.oldrom EQUB 0

.c_b0  EQUS "LOAD BANK0 3000" : EQUB 13
.c_b1  EQUS "LOAD BANK1 3000" : EQUB 13
.c_b2  EQUS "LOAD BANK2 3000" : EQUB 13
.c_low EQUS "LOAD LOW 1B40"   : EQUB 13
.ldr_end
SAVE "!BOOT", &1900, ldr_end, &1900
