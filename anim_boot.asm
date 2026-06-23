; anim_boot.asm — !BOOT for the rotating E1M1 disc. *SRLOADs the three banks,
; *LOADs LOW (which already contains the animation driver at $3C00 + sincos table
; at $3E00), selects MODE 4, and jumps to the driver. Boot option 2 (*RUN) +
; SHIFT-BREAK autoboots it.
ORG &0900
.boot
    LDX #LO(cmd_b0): LDY #HI(cmd_b0): JSR &FFF7      ; SRLOAD BANK0 8000 4 (L0)
    LDX #LO(cmd_b1): LDY #HI(cmd_b1): JSR &FFF7      ; SRLOAD BANK1 8000 6 (C)
    LDX #LO(cmd_b2): LDY #HI(cmd_b2): JSR &FFF7      ; SRLOAD BANK2 8000 7 (L2)
    LDX #LO(cmd_low):LDY #HI(cmd_low):JSR &FFF7      ; *LOAD LOW 1B40
    LDA #22 : JSR &FFEE : LDA #4 : JSR &FFEE          ; MODE 4
    JMP &3C00                                        ; -> animation driver
.cmd_b0  EQUS "SRLOAD BANK0 8000 4" : EQUB 13
.cmd_b1  EQUS "SRLOAD BANK1 8000 6" : EQUB 13
.cmd_b2  EQUS "SRLOAD BANK2 8000 7" : EQUB 13
.cmd_low EQUS "LOAD LOW 1B40"   : EQUB 13
.boot_end
SAVE "ANIMBOOT", &0900, boot_end, &0900
