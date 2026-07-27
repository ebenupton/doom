; modelb_boot.asm — !BOOT loader for a plain Model B + sideways RAM (no *SRLOAD).
; Acorn DFS has no *SRLOAD, so we *LOAD each 16K bank file into a main-RAM staging
; area ($3000) and copy it into the target sideways bank via ROMSEL ($FE30). Then
; *LOAD LOW at $1C00 (sqr tables + code + driver @ $2000 + sincos @ $2200), MODE 4, and
; jump to the driver. Banks 4/6/7 = L0/C/L2 (all writable SWRAM on a Model B).
;
; *RUN as !BOOT (boot option 2) -> SHIFT-BREAK autoboots. PAGE=$1900 (DFS).
;
; ldr — load/copy each bank in turn, then LOW, then hand off. Each
; JSR $FFF7 is OSCLI on a command string; OS calls are fine here (the
; driver's SEI at $2000 is where the OS goes away). The $3000 staging
; area is plain user RAM under the boot-time MODE 7, and LOW ($1C00+)
; only lands after the last bank copy has consumed the staging.
; (LOW rebased $1B40 -> $1C00 2026-07-26: BCA_WS retired.)
INCLUDE "abi_beeb.inc"
ORG &1900
.ldr
; CPU probe (2026-07-26): opcode &1A is INC A on a 65C02, a 1-byte NOP
; on the NMOS 6502 — A tells the CPUs apart with no OS involvement.
; A C02 host gets the C02-built engine images (LOWC + BANK1C: only the
; engine CODE and the bank-C clipper/raster/HUD differ; L0/L2 are data
; and ship once). The copro path never reaches here (!BOOT tube test).
    LDA #0
    EQUB &1A                                     ; NMOS: NOP / C02: INC A
    STA cpuflag                                  ; 0 = NMOS, 1 = 65C02
    LDX #LO(c_b0): LDY #HI(c_b0): JSR &FFF7      ; *LOAD BANK0 3000  (L0)
    LDA #4:  JSR copy                            ; -> bank 4
    LDA cpuflag : BNE ld_b1c
    LDX #LO(c_b1): LDY #HI(c_b1): BNE ld_b1go    ; (Y = HI = &19: always taken)
.ld_b1c
    LDX #LO(c_b1c): LDY #HI(c_b1c)
.ld_b1go
    JSR &FFF7                                    ; *LOAD BANK1|BANK1C 3000 (C)
    LDA #6:  JSR copy                            ; -> bank 6
    LDX #LO(c_b2): LDY #HI(c_b2): JSR &FFF7      ; *LOAD BANK2 3000  (L2)
    LDA #7:  JSR copy                            ; -> bank 7
    LDA cpuflag : BNE ld_lowc
    LDX #LO(c_low): LDY #HI(c_low): BNE ld_lowgo ; (Y = HI = &19: always taken)
.ld_lowc
    LDX #LO(c_lowc): LDY #HI(c_lowc)
.ld_lowgo
    JSR &FFF7                                    ; *LOAD LOW|LOWC 1C00
    LDA #22: JSR &FFEE : LDA #4 : JSR &FFEE      ; MODE 4 (FIRST: its clear
                                                 ; wipes $5800-$7FFF — the
                                                 ; $7000 staging must load
                                                 ; AFTER; banks stage $3000,
                                                 ; below the screen, safe)
    LDX #LO(c_sqrh): LDY #HI(c_sqrh)
    JSR &FFF7                                    ; *LOAD SQRH 7000 (staged —
                                                 ; NOT $3000: LOW spans
                                                 ; $1C00-$57FF and the first
                                                 ; cut stomped engine code)
; sqr HI pages -> $0200/$0300 (banked SQRH_BASE, 2026-07-27). The OS
; vector page dies here: interrupts OFF first (the driver's own SEI
; would be too late — an IRQ through half-copied vectors is a crash),
; and NO OS calls after this point (MODE 4 above was the last).
    SEI
    LDX #0
.sqh
    LDA &7000,X : STA &200,X
    LDA &7100,X : STA &300,X
    INX : BNE sqh
    JMP DRV_ORG                                  ; -> animation driver
.cpuflag EQUB 0

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
.c_low EQUS "LOAD LOW 1C00"   : EQUB 13
.c_sqrh EQUS "LOAD SQRH 7000" : EQUB 13
.c_b1c EQUS "LOAD BANK1C 3000": EQUB 13          ; 65C02 clipper/raster/HUD bank
.c_lowc EQUS "LOAD LOWC 1C00": EQUB 13          ; 65C02 engine CODE image
.ldr_end
SAVE "!BOOT", &1900, ldr_end, &1900
