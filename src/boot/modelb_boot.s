.segment "CODE"
; modelb_boot.asm — !BOOT loader for a plain Model B + sideways RAM (no *SRLOAD).
; Acorn DFS has no *SRLOAD, so we *LOAD each 16K bank file into a main-RAM staging
; area ($3000) and copy it into the target sideways bank via ROMSEL ($FE30). Then
; stage LOW at $3000 and copy down to LOW_BASE $0D00 (strip+driver+engine), MODE 4, and
; jump to the driver. Banks 4/6/7 = L0/C/L2 (all writable SWRAM on a Model B).
;
; *RUN as !BOOT (boot option 2) -> SHIFT-BREAK autoboots. PAGE=$1900 (DFS).
;
; ldr — load/copy each bank in turn, then LOW, then hand off. Each
; JSR $FFF7 is OSCLI on a command string; OS calls are fine here (the
; driver's SEI is where the OS goes away). The $3000 staging area is
; plain user RAM under the boot-time MODE 7, and LOW (LOW_BASE $1600+)
; only lands after the last bank copy has consumed the staging — loaded
; by the relocated $0900 stub, because it covers this loader's $1900.
   .include "../abi.inc"
.segment "CODE"
ldr:
; CPU probe (2026-07-26): opcode &1A is INC A on a 65C02, a 1-byte NOP
; on the NMOS 6502 — A tells the CPUs apart with no OS involvement.
; A C02 host gets the C02-built engine images (LOWC + BANK1C: only the
; engine CODE and the bank-C clipper/raster/HUD differ; L0/L2 are data
; and ship once). The copro path never reaches here (!BOOT tube test).
    LDA #0
    .byte $1A   ; NMOS: NOP / C02: INC A
    STA cpuflag   ; 0 = NMOS, 1 = 65C02
    LDX #<(c_b0)
    LDY #>(c_b0)
    JSR $FFF7   ; *LOAD BANK0 3000  (L0)
    LDA #4
    JSR copy   ; -> bank 4
    LDA cpuflag
    BNE ld_b1c
    LDX #<(c_b1)
    LDY #>(c_b1)
    BNE ld_b1go   ; (Y = HI = &19: always taken)
ld_b1c:
    LDX #<(c_b1c)
    LDY #>(c_b1c)
ld_b1go:
    JSR $FFF7   ; *LOAD BANK1|BANK1C 3000 (C)
    LDA #6
    JSR copy   ; -> bank 6
    LDX #<(c_b2)
    LDY #>(c_b2)
    JSR $FFF7   ; *LOAD BANK2 3000  (L2)
    LDA #7
    JSR copy   ; -> bank 7
; --- finale runs RELOCATED at $0900 (2026-08-19 window slide): LOW
;     now loads at LOW_BASE = $1600, which covers this loader at
;     $1900 — the last *LOAD must execute from memory it does not
;     overwrite. $0900-$0Bxx is cassette/RS423 buffer space, idle
;     under DFS disc ops (DFS's own load state is ZP + $0D00 NMI +
;     the catalog at $0E00-$0FFF; the $1600-$18FF span LOW covers is
;     only OPENIN/BGET buffer space, and no file is open). ---
    LDX #stub_len
rl: LDA stub_image-1,X
    STA $0900-1,X
    DEX
    BNE rl
    LDA cpuflag   ; stub branches on it
    JMP $0900
cpuflag: .byte 0

; copy — copy the 16K staged at $3000-$6FFF into sideways bank A.
; In: A = target bank number (4/6/7). Uses ZP $80-$83 as src/dst pointers.
; SEI brackets the copy so no IRQ handler runs while ROMSEL points at the
; SWRAM bank (the OS would index the wrong ROM); $F4 (the OS's ROMSEL
; shadow) is kept in sync both ways so the DFS ROM is correctly restored
; for the next *LOAD. Clobbers A,X,Y,$80-$83.
copy:   ; A = target bank; copy $3000-$6FFF -> $8000 bank
    LDX $F4
    STX oldrom   ; save OS's current ROM
    SEI   ; no IRQ -> ROMSEL stays put during the copy
    STA $FE30
    STA $F4   ; page target bank (keep $F4 in sync)
    LDA #0
    STA $80
    LDA #$30
    STA $81   ; src ptr = $3000
    LDA #0
    STA $82
    LDA #$80
    STA $83   ; dst ptr = $8000
    LDX #$40   ; 64 pages = 16K
cp1:
    LDY #0
cp2:
    LDA ($80),Y
    STA ($82),Y
    INY
    BNE cp2
    INC $81
    INC $83
    DEX
    BNE cp1
    LDA oldrom
    STA $FE30
    STA $F4   ; restore OS's ROM for next *LOAD
    CLI
    RTS
oldrom: .byte 0

c_b0:  .byte "LOAD BANK0 3000"
.byte 13
c_b1:  .byte "LOAD BANK1 3000"
.byte 13
c_b2:  .byte "LOAD BANK2 3000"
.byte 13
c_b1c: .byte "LOAD BANK1C 3000"
.byte 13   ; 65C02 clipper/raster/HUD bank
stub_image:   ; the $0900 finale rides here

.segment "STUB"          ; COPYBLOCK: ld65 load/run split
stub:   ; entry: A = cpuflag
    BNE s_c02
    LDX #<(s_low)
    LDY #>(s_low)
    BNE s_go   ; (Y = HI = &09: always taken)
s_c02:
    LDX #<(s_lowc)
    LDY #>(s_lowc)
s_go:
    JSR $FFF7   ; *LOAD LOW|LOWC 3000 (STAGED:
; LOW_BASE is $0D00 since the
; 2026-08-26 low-RAM map, and a
; direct *LOAD there lands on
; DFS's NMI workspace + catalog
; DURING the transfer)
; copy $3000.. down to $0D00-$57FF, ascending (dst < src throughout;
; MODE 7 screen at $7C00 clears the $3000-$7AFF staging)
    LDA #$00
    STA $80
    LDA #$30
    STA $81   ; src = $3000
    LDA #$00
    STA $82
    LDA #$0F
    STA $83   ; dst = $0F00 (LOW_BASE)
    LDY #0
s_cp:
    LDA ($80),Y
    STA ($82),Y
    INY
    BNE s_cp
    INC $81
    INC $83
    LDA $83
    CMP #$58   ; dst page = $5800: done
    BNE s_cp
    LDA #22
    JSR $FFEE
    LDA #4
    JSR $FFEE   ; MODE 4 (last OS call)
    JMP DRV_ORG   ; -> driver (its SEI kills
; the OS)
s_low:  .byte "LOAD LOW 3000"
.byte 13
s_lowc: .byte "LOAD LOWC 3000"
.byte 13   ; 65C02 engine CODE image
s_end:
stub_len = s_end - stub
   .assert LOW_BASE = $0F00, error   ; the copy loop above targets
; COPYBLOCK -> the STUB segment loads here and runs at $0900
; SAVE "!BOOT", &1900, stub_image + stub_len -> the build script
